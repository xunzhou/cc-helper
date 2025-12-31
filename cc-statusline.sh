#!/usr/bin/env bash
# Claude Code Statusline - Minimal fundamentals display
# Shows: model | path | branch | context window
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
    echo "$1" | "$JQ_BINARY" -r '(.model.display_name | select(length > 0)) // .model.id // "Unknown"' 2>/dev/null
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

get_context_limit() {
    local model_id_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    if [[ "$model_id_lower" == *"sonnet-4-5"* ]] || [[ "$model_id_lower" == *"sonnet-3-7"* ]] || [[ "$model_id_lower" == *"sonnet-3.7"* ]]; then
        echo 200000
    elif [[ "$model_id_lower" == *"opus-4-5"* ]] || [[ "$model_id_lower" == *"haiku-4"* ]]; then
        echo 200000
    elif [[ "$model_id_lower" == *"glm-4.5"* ]] || [[ "$model_id_lower" == *"kimi-k2"* ]]; then
        echo 128000
    elif [[ "$model_id_lower" == *"qwen"* ]]; then
        echo 256000
    else
        echo 200000
    fi
}

get_transcript_tokens() {
    local transcript_path="$1"
    [[ ! -f "$transcript_path" ]] && echo "0" && return
    local tokens=0 found=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local msg_type=$(echo "$line" | "$JQ_BINARY" -r '.type // ""' 2>/dev/null)
        if [[ "$msg_type" == "assistant" ]]; then
            tokens=$(echo "$line" | "$JQ_BINARY" -r '
                .message.usage as $u |
                if $u then
                    (($u.input_tokens // 0) +
                     ($u.output_tokens // 0) +
                     ($u.cache_read_input_tokens // 0) +
                     ($u.cache_creation_input_tokens // 0))
                else 0 end
            ' 2>/dev/null)

            if [[ "$tokens" -gt 0 ]]; then
                found=true
                break
            fi
        fi
    done < <(tac "$transcript_path" 2>/dev/null)
    echo "${tokens:-0}"
}

format_context() {
    local tokens="$1" limit="$2"

    [[ "$tokens" == "0" || -z "$tokens" || "$tokens" -le 0 ]] && echo "- · -" && return

    local percentage=$(awk "BEGIN {printf \"%.0f\", ($tokens / $limit) * 100}" 2>/dev/null)
    [[ -z "$percentage" ]] && percentage=0

    local token_display
    if [[ "$tokens" -ge 1000 ]]; then
        token_display=$(awk "BEGIN {printf \"%.0fk\", $tokens / 1000}" 2>/dev/null)
    else
        token_display="$tokens"
    fi

    echo "${percentage}% · ${token_display} tokens"
}

get_context_window() {
    local model_id transcript_path
    model_id=$(echo "$1" | "$JQ_BINARY" -r '.model.id // ""' 2>/dev/null)
    transcript_path=$(echo "$1" | "$JQ_BINARY" -r '.transcript_path // ""' 2>/dev/null)

    local limit=$(get_context_limit "$model_id")

    local tokens=$(get_transcript_tokens "$transcript_path")

    format_context "$tokens" "$limit"
}

MODEL=$(get_model_name "$JSON_INPUT")
DIRECTORY=$(get_directory "$JSON_INPUT")
BRANCH=$(get_git_branch "$JSON_INPUT")
CONTEXT=$(get_context_window "$JSON_INPUT")

echo "${MODEL} | ${DIRECTORY} | ${BRANCH} | ${CONTEXT}"
