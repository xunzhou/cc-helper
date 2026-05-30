#!/usr/bin/env bash
# Claude Code Statusline - Minimal fundamentals display
# Shows: model | path | branch | context window | 5h quota bar | session cost
# Requires: jq (JSON processor) or compatible alternative (e.g., jaq)

set -o pipefail

JQ_BINARY="${CC_STATUSLINE_JQ:-jq}"

if ! command -v "$JQ_BINARY" &>/dev/null; then
    echo "Error: $JQ_BINARY is required but not installed" >&2
    if [[ "$JQ_BINARY" == "jq" ]]; then
        echo "Install with: sudo apt install jq (Debian/Ubuntu) or brew install jq (macOS)" >&2
    else
        echo "The binary '$JQ_BINARY' (set via CC_STATUSLINE_JQ) was not found in PATH" >&2
        echo "Either install '$JQ_BINARY' or unset CC_STATUSLINE_JQ to use default 'jq'" >&2
    fi
    exit 1
fi

# ANSI colors for the quota bar. Honor NO_COLOR (https://no-color.org/) and a
# script-specific override; when either is set, color vars are empty so the
# output is plain glyphs with no escape bytes.
if [[ -n "${NO_COLOR:-}" || -n "${CC_STATUSLINE_NO_COLOR:-}" ]]; then
    C_RESET="" C_DIM="" C_YELLOW="" C_RED=""
else
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
fi

if [[ -t 0 ]]; then
    echo "Error: No JSON input on stdin" >&2
    echo "This script is meant to be called by Claude Code via statusLine configuration" >&2
    exit 1
fi

JSON_INPUT=$(cat)

get_model_name() {
    local name id version effort
    name=$(echo "$1" | "$JQ_BINARY" -r '(.model.display_name | select(length > 0)) // .model.id // "Unknown"' 2>/dev/null)
    id=$(echo "$1" | "$JQ_BINARY" -r '.model.id // ""' 2>/dev/null)

    # Strip the "(1M context)" qualifier; the context window is shown elsewhere.
    name=$(echo "$name" | sed -E 's/ *\(1M context\)//')

    # display_name is bare (e.g. "Opus"); pull the M.N version out of the id
    # (claude-opus-4-7 -> 4.7) and append it, unless the name already has digits.
    if [[ "$name" != *[0-9]* ]]; then
        version=$(echo "$id" | grep -oE '[0-9]+-[0-9]+' | head -1 | tr '-' '.')
        [[ -n "$version" ]] && name="$name $version"
    fi

    # Append 2-char effort suffix when the model supports it. Absent for models
    # without an effort parameter.
    effort=$(echo "$1" | "$JQ_BINARY" -r '.effort.level // empty' 2>/dev/null)
    case "$effort" in
        low)    name="$name lo" ;;
        medium) name="$name md" ;;
        high)   name="$name hi" ;;
        xhigh)  name="$name xh" ;;
        max)    name="$name mx" ;;
    esac
    echo "$name"
}

get_directory() {
    local current_dir
    current_dir=$(echo "$1" | "$JQ_BINARY" -r '.workspace.current_dir // ""' 2>/dev/null)
    [[ -z "$current_dir" ]] && current_dir=$(pwd)
    basename "$current_dir"
}

get_git_branch() {
    local current_dir
    current_dir=$(echo "$1" | "$JQ_BINARY" -r '.workspace.current_dir // ""' 2>/dev/null)
    [[ -z "$current_dir" ]] && current_dir=$(pwd)

    if [[ -d "$current_dir/.git" ]] || git -C "$current_dir" rev-parse --git-dir &>/dev/null; then
        local branch=$(git -C "$current_dir" --no-optional-locks branch --show-current 2>/dev/null)
        [[ -n "$branch" ]] && echo "$branch" && return
        branch=$(git -C "$current_dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
        echo "${branch:--}"
    else
        echo "-"
    fi
}

# Effective context limit, in tokens. Resolution order:
# CC_STATUSLINE_CONTEXT_LIMIT override, then .context_window.context_window_size
# from Claude Code's stdin (per-account effective limit — e.g. 200000 on base
# plans, 1000000 on Max), then 200000 as a last-resort fallback.
get_context_limit() {
    if [[ -n "${CC_STATUSLINE_CONTEXT_LIMIT:-}" ]]; then
        echo "$CC_STATUSLINE_CONTEXT_LIMIT"
        return
    fi

    local size
    size=$(echo "$1" | "$JQ_BINARY" -r '.context_window.context_window_size // 0' 2>/dev/null)
    if [[ "$size" -gt 0 ]]; then
        echo "$size"
        return
    fi

    echo 200000
}

format_token_count() {
    local tokens="$1"
    if [[ "$tokens" -ge 1000000 ]]; then
        awk "BEGIN {printf \"%g\", $tokens / 1000000}" 2>/dev/null | sed 's/$/M/'
    elif [[ "$tokens" -ge 1000 ]]; then
        awk "BEGIN {printf \"%.0fk\", $tokens / 1000}" 2>/dev/null
    else
        echo "$tokens"
    fi
}

get_context_window() {
    local input_tokens="$1" limit="$2"

    # No usage yet: before the first API response, or right after /compact.
    if [[ -z "$input_tokens" || "$input_tokens" -le 0 ]]; then
        echo "- -"
        return
    fi

    local percentage=$(awk "BEGIN {printf \"%.0f\", ($input_tokens / $limit) * 100}" 2>/dev/null)
    local token_display=$(format_token_count "$input_tokens")

    echo "${percentage}% ${token_display}/$(format_token_count "$limit")"
}

# Session cost in USD from .cost.total_cost_usd. Empty if missing/zero so the
# caller can drop the segment.
get_session_cost() {
    local cost
    cost=$(echo "$1" | "$JQ_BINARY" -r '.cost.total_cost_usd // empty' 2>/dev/null)
    [[ -z "$cost" ]] && return
    awk "BEGIN {if ($cost <= 0) exit 1; printf \"\$%.2f\", $cost}" 2>/dev/null
}

# 5h rate-limit usage as a 10-cell bar (each cell = 10% of quota = 30 min of
# expected runway) + percentage + time until reset. Colored by burn rate vs a
# linear pace: default = on/under pace, yellow = >~30 min ahead, red = near cap.
# Empty if Claude Code didn't send the bucket (e.g. base plan without rate_limits).
get_rate_limit() {
    local pct resets_at
    pct=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
    [[ -z "$pct" ]] && return
    resets_at=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)

    # Displayed percentage: round to 1 decimal; %g drops trailing .0
    # (e.g. 28.0000004 -> 28, 28.5 -> 28.5). Raw $pct feeds the bar/state math.
    local disp
    disp=$(awk "BEGIN { printf \"%g\", int($pct * 10 + 0.5) / 10 }" 2>/dev/null)

    local now remaining=""
    now=$(date +%s)

    local pct7 resets7
    pct7=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
    resets7=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}" profile
    profile=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"); profile=${profile#.}
    # Cache line: <5h_pct> <5h_resets> <written> <7d_pct> <7d_resets>
    printf '%s %s %s %s %s\n' "$pct" "${resets_at:-0}" "$now" "${pct7:-NA}" "${resets7:-0}" > "${cache_dir}/.cc-quota.${profile}.$$" 2>/dev/null \
        && mv -f "${cache_dir}/.cc-quota.${profile}.$$" "${cache_dir}/cc-quota.${profile}" 2>/dev/null

    if [[ -n "$resets_at" ]]; then
        local diff=$(( resets_at - now ))
        if [[ $diff -gt 0 ]]; then
            local h=$(( diff / 3600 ))
            local m=$(( (diff % 3600) / 60 ))
            if [[ $h -gt 0 ]]; then
                remaining=" ${h}h${m}m"
            else
                remaining=" ${m}m"
            fi
        fi
    fi

    # Filled-cell count: round used/10, but reserve the 10th cell for a true
    # 100% so 90-99.9% never looks completely full.
    local filled
    filled=$(awk "BEGIN { f=int($pct/10+0.5); if ($pct<100 && f>9) f=9; if (f<0) f=0; if (f>10) f=10; print f }" 2>/dev/null)

    # Color state + overage split. state: red near cap, yellow if >~30 min ahead
    # of linear pace, else default. solid = consumed cells within the expected
    # pace; the rest of the filled cells are "overage" (consumed faster than the
    # clock) and get a distinct glyph so burn rate reads without color. Overage
    # is only split out in alert states, so an on-pace bar stays plain.
    # (Don't name an awk var `exp` -- it's a gawk builtin.)
    local state solid
    read -r state solid <<<"$(awk -v used="$pct" -v resets="$resets_at" -v now="$now" -v filled="$filled" 'BEGIN{
        state="default"; solid=filled;
        if (resets != "") {
            elapsed = 18000 - (resets - now);
            if (elapsed < 0) elapsed = 0; if (elapsed > 18000) elapsed = 18000;
            epct = elapsed/18000*100;
            if (used+0 > epct + 10) state="yellow";
        }
        if (used+0 >= 90) state="red";
        if (state != "default" && resets != "") {
            expc = int(epct/10 + 0.5);
            solid = (filled < expc) ? filled : expc;
            if (solid < 0) solid=0; if (solid > filled) solid=filled;
        }
        print state, solid;
    }' 2>/dev/null)"
    [[ -z "$solid" ]] && solid="$filled"

    local color=""
    case "$state" in
        red)    color="$C_RED" ;;
        yellow) color="$C_YELLOW" ;;
    esac

    # Build the bar: solid cells (█) consumed within pace, overage cells (▓)
    # consumed ahead of pace, remaining cells (░) dim. The filled run is wrapped
    # in the state color; the overage glyph keeps the signal when color is off.
    local i bar="" overage=$(( filled - solid ))
    for (( i=0; i<solid; i++ )); do bar+="█"; done
    for (( i=0; i<overage; i++ )); do bar+="▓"; done
    bar="${color}${bar}${C_RESET}${C_DIM}"
    for (( i=filled; i<10; i++ )); do bar+="░"; done
    bar+="${C_RESET}"

    echo "${bar} ${color}${disp}%${C_RESET}${remaining}"
}

MODEL=$(get_model_name "$JSON_INPUT")
DIRECTORY=$(get_directory "$JSON_INPUT")
BRANCH=$(get_git_branch "$JSON_INPUT")

# total_input_tokens (input + cache read/write) is the numerator Claude Code
# uses for used_percentage; we recompute it against the effective limit.
INPUT_TOKENS=$(echo "$JSON_INPUT" | "$JQ_BINARY" -r '.context_window.total_input_tokens // 0' 2>/dev/null)
LIMIT=$(get_context_limit "$JSON_INPUT")
CONTEXT=$(get_context_window "$INPUT_TOKENS" "$LIMIT")
COST=$(get_session_cost "$JSON_INPUT")
RATE=$(get_rate_limit "$JSON_INPUT")

LINE="${MODEL} | ${DIRECTORY} | ${BRANCH} | ${CONTEXT}"
[[ -n "$RATE" ]] && LINE="${LINE} | ${RATE}"
[[ -n "$COST" ]] && LINE="${LINE} | ${COST}"
echo "$LINE"
