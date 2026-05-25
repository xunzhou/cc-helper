#!/usr/bin/env bash
# Claude Code Statusline - Minimal fundamentals display
# Shows: model | path | branch | context window | lim rate-limit | session cost
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
        echo "- · -"
        return
    fi

    local percentage=$(awk "BEGIN {printf \"%.0f\", ($input_tokens / $limit) * 100}" 2>/dev/null)
    local token_display=$(format_token_count "$input_tokens")

    echo "${percentage}% · ${token_display}/$(format_token_count "$limit")"
}

# Session cost in USD from .cost.total_cost_usd. Empty if missing/zero so the
# caller can drop the segment.
get_session_cost() {
    local cost
    cost=$(echo "$1" | "$JQ_BINARY" -r '.cost.total_cost_usd // empty' 2>/dev/null)
    [[ -z "$cost" ]] && return
    awk "BEGIN {if ($cost <= 0) exit 1; printf \"\$%.2f\", $cost}" 2>/dev/null
}

# 5h rate-limit usage + time until reset. Empty if Claude Code didn't send the
# bucket (e.g. base plan without rate_limits).
get_rate_limit() {
    local pct resets_at
    pct=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
    [[ -z "$pct" ]] && return
    # Round to 1 decimal place; %g drops trailing .0 (e.g. 28.0000004 -> 28, 28.5 -> 28.5)
    pct=$(awk "BEGIN { printf \"%g\", int($pct * 10 + 0.5) / 10 }" 2>/dev/null)
    resets_at=$(echo "$1" | "$JQ_BINARY" -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)

    local remaining=""
    if [[ -n "$resets_at" ]]; then
        local diff=$(( resets_at - $(date +%s) ))
        if [[ $diff -gt 0 ]]; then
            local h=$(( diff / 3600 ))
            local m=$(( (diff % 3600) / 60 ))
            if [[ $h -gt 0 ]]; then
                remaining=" (${h}h${m}m)"
            else
                remaining=" (${m}m)"
            fi
        fi
    fi
    echo "lim ${pct}%${remaining}"
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
