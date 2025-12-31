#!/bin/bash
# AI-powered commit message generator for lazygit
# Usage: git-commit-ai [-v|-vv] [-c] [JIRA-TICKET]

set -euo pipefail

# Validate environment
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not in a git repository" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found in PATH" >&2
    exit 1
fi

# Parse arguments
VERBOSE_LEVEL=0
JIRA_TICKET=""
AUTO_COMMIT=false
LLM_TIMEOUT_SECONDS="${GIT_COMMIT_AI_TIMEOUT_SECONDS:-30}"
LLM_CMD_TEMPLATE="${GIT_COMMIT_AI_LLM_CMD:-claude}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -vv|--very-verbose)
            VERBOSE_LEVEL=2
            shift
            ;;
        -v|--verbose)
            VERBOSE_LEVEL=1
            shift
            ;;
        -c|--commit)
            AUTO_COMMIT=true
            shift
            ;;
        -h|--help)
            echo "Usage: git-commit-ai [-v|-vv] [-c] [JIRA-TICKET]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose       Add brief body (1-3 bullets)"
            echo "  -vv,--very-verbose  Add detailed body (3-5 bullets)"
            echo "  -c, --commit     Automatically commit with generated message"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Environment:"
            echo "  GIT_COMMIT_AI_LLM_CMD              LLM runner: claude (default), opencode, or a custom command."
            echo "                                    Prompt is provided via stdin unless your command references __PROMPT_FILE__ or GIT_COMMIT_AI_PROMPT_FILE."
            echo "  GIT_COMMIT_AI_TIMEOUT_SECONDS      LLM timeout in seconds (default: 30)"
            echo "  GIT_COMMIT_AI_LLM_USE_STDIN        Force stdin usage: auto (default), false"
            echo ""
            echo "Arguments:"
            echo "  JIRA-TICKET      Optional JIRA ticket ID to prepend (e.g., PROJ-123)"
            exit 0
            ;;
        *)
            JIRA_TICKET="$1"
            shift
            ;;
    esac
done

# Ensure HOME is set (lazygit might not set it)
if [ -z "$HOME" ]; then
    HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
fi

# Check if there are staged changes
if git diff --cached --quiet; then
    echo "Error: No staged changes to commit" >&2
    exit 1
fi

# Get the git diff and recent commit messages for context
GIT_DIFF=$(git diff --cached)
GIT_NAME_STATUS=$(git diff --cached --name-status)
GIT_SHORTSTAT=$(git diff --cached --shortstat 2>/dev/null || echo "")
GIT_LOG=$(git log --oneline -5 2>/dev/null || echo "No previous commits")

# Create prompt file with proper escaping
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT

# Write prompt to file safely (avoids bash substitution issues)
cat > "$PROMPT_FILE" <<TEMPLATE
# Generate Commit Message (JSON)

You are a Git commit message specialist. Your role is to analyze code changes and generate concise, professional commit messages.

Output must follow VERBOSE_LEVEL rules exactly:
- If VERBOSE_LEVEL = 0: subject only (via JSON with empty bullets)
- If VERBOSE_LEVEL = 1: always include 1-3 bullets
- If VERBOSE_LEVEL = 2: always include 3-5 bullets

## Methodology

When analyzing changes to generate commit messages:

1. **Examine the Git Diff**: Carefully review all code changes to understand the full scope of modifications. Look for patterns, related changes, and the overall intent.

2. **Identify Change Type**:

   **FIRST - Check for source code changes:**
   - If ANY source code files (.sh, .py, .js, .java, .c, .cpp, .rs, .go, etc.) were added/modified → NOT \`docs\`
   - If ONLY .md, .txt, or pure documentation files changed → THEN \`docs\`

   **THEN classify using conventional types:**
   - \`feat\`: New feature or functionality (NEW source code files)
   - \`fix\`: Bug fix or correction (source code fixes)
   - \`refactor\`: Code restructuring without behavior change
   - \`docs\`: Documentation changes **ONLY** (zero source code changes)
   - \`test\`: Test additions or modifications
   - \`chore\`: Maintenance tasks, dependencies, tooling
   - \`perf\`: Performance improvements
   - \`style\`: Code formatting, whitespace, style changes
   - \`ci\`: CI/CD pipeline changes
   - \`build\`: Build system or dependency changes

   **Priority rule:** Source code changes ALWAYS override documentation changes in type selection.

3. **Determine Scope**: Identify the affected component, module, or area (e.g., \`auth\`, \`api\`, \`ui\`, \`database\`). The scope should be specific enough to be meaningful but general enough to be reusable.

4. **Craft Subject Line**: Write in imperative mood ("add" not "added"), max 72 characters, no period at end. Be direct and specific.

5. **Add Body Based on Verbose Level**: VERBOSE LEVEL = $VERBOSE_LEVEL

   **CRITICAL - Follow these rules exactly:**

   * **Level 0 (default)**: "bullets" must be [] and "breaking_change" must be "" unless breaking

   * **Level 1 (-v)**: Set "bullets" to 1-3 concise items summarizing key changes

   * **Level 2 (-vv)**: Set "bullets" to 3-5 detailed items (what changed, why, key implementation details, important context)

   Breaking changes are the ONLY exception - always include "BREAKING CHANGE:" in body regardless of level.

6. **Check for Coherence**: If the diff shows multiple unrelated changes, suggest splitting the commit.

## Output Format (STRICT JSON ONLY)

Return a single JSON object (no code fences, no markdown, no extra keys) with exactly these keys:
- "subject": a conventional commit subject line like "feat(api): add token refresh"
- "bullets": an array of strings (no leading "-", no trailing periods), each a bullet item
- "breaking_change": empty string if none, otherwise a concise description (no leading "BREAKING CHANGE:")

Constraints by verbose level (MANDATORY):
- If VERBOSE_LEVEL = 0: "bullets" MUST be [] (unless breaking_change is non-empty)
- If VERBOSE_LEVEL = 1: "bullets" MUST have 1-3 items
- If VERBOSE_LEVEL = 2: "bullets" MUST have 3-5 items
- If breaking_change is non-empty: include it regardless of VERBOSE_LEVEL

## Quality Standards

- Brevity is paramount - if the subject line says it all, stop there
- Imperative mood ("add", "fix", "update")
- Avoid filler phrases ("this commit", "changes to", "updated the")
- Be specific but concise - every word should earn its place
- Match existing commit style in the repository when available

## Critical Constraints

- NEVER include promotional text like "Generated with [Claude Code]" in commit messages
- NEVER include "Co-Authored-By: Claude" or similar AI attribution lines
- NEVER use emoji (Unicode characters) in commit messages
- Text symbols (-, *, #) are acceptable
- Keep commits concise and focused on the actual changes

## Edge Cases

- Cosmetic changes: use \`style\` type, keep it brief
- Breaking changes: always flag in body
- Unrelated changes in diff: recommend splitting
- Empty or generated-only diff: suggest no commit needed
- Unclear intent: ask for clarification

---

## Output Instructions

**CRITICAL**: Output ONLY the JSON object. No preamble, no commentary, no markdown blocks.

Examine the git diff, analyze the changes, then output only the commit message.

## Git Context

Recent commits (for style reference):
\`\`\`
$GIT_LOG
\`\`\`

Staged changes to commit:
\`\`\`diff
$GIT_DIFF
\`\`\`

Now generate ONLY the JSON object (no explanations, no markdown blocks, just the raw JSON):
TEMPLATE

# Determine LLM command based on template
case "$LLM_CMD_TEMPLATE" in
    claude)
        LLM_CMD='claude --print --tools "" --dangerously-skip-permissions'
        ;;
    opencode)
        LLM_CMD='opencode run --format default "Follow the attached prompt file exactly. Output ONLY the JSON object requested." --file "$GIT_COMMIT_AI_PROMPT_FILE"'
        ;;
    *)
        LLM_CMD="$LLM_CMD_TEMPLATE"
        ;;
esac

# Handle prompt file placeholder and stdin mode
LLM_CMD="${LLM_CMD//__PROMPT_FILE__/$PROMPT_FILE}"
LLM_STDIN_MODE="${GIT_COMMIT_AI_LLM_USE_STDIN:-auto}"
LLM_STDIN_SOURCE="$PROMPT_FILE"

if [ "$LLM_STDIN_MODE" = "auto" ]; then
    if [[ "$LLM_CMD_TEMPLATE" == *"__PROMPT_FILE__"* ]] || [[ "$LLM_CMD_TEMPLATE" == *"GIT_COMMIT_AI_PROMPT_FILE"* ]]; then
        LLM_STDIN_SOURCE="/dev/null"
    fi
elif [ "$LLM_STDIN_MODE" = "0" ] || [ "$LLM_STDIN_MODE" = "false" ] || [ "$LLM_STDIN_MODE" = "no" ]; then
    LLM_STDIN_SOURCE="/dev/null"
fi

# Generate commit message payload using an LLM CLI with timeout
LLM_RAW=""
if LLM_RAW=$(
    env GIT_COMMIT_AI_PROMPT_FILE="$PROMPT_FILE" \
        timeout "$LLM_TIMEOUT_SECONDS" bash -lc "$LLM_CMD" <"$LLM_STDIN_SOURCE" 2>&1
); then
    :
else
    LLM_STATUS=$?
    if [ "$LLM_STATUS" -eq 124 ]; then
        echo "Error: LLM command timed out after ${LLM_TIMEOUT_SECONDS} seconds" >&2
        exit 1
    fi
    echo "Error: Failed to generate commit message" >&2
    echo "Command: $LLM_CMD" >&2
    echo "Output:" >&2
    echo "$LLM_RAW" >&2
    exit 1
fi

COMMIT_MSG=$(
    env \
        LLM_RAW="$LLM_RAW" \
        GIT_NAME_STATUS="$GIT_NAME_STATUS" \
        GIT_SHORTSTAT="$GIT_SHORTSTAT" \
        python3 - "$VERBOSE_LEVEL" "$JIRA_TICKET" <<'PY'
import os
import json
import re
import sys

verbose_level = int(sys.argv[1])
jira_ticket = sys.argv[2]
raw = os.environ.get("LLM_RAW")
if raw is None:
    raw = sys.stdin.read()
raw = raw.replace("\r", "").strip()
git_name_status = os.environ.get("GIT_NAME_STATUS", "")
git_shortstat = os.environ.get("GIT_SHORTSTAT", "")

decoder = json.JSONDecoder()
CONVENTIONAL_PATTERN = re.compile(r"^(?:revert: )?[a-z]+(?:\([^)]+\))?!?: .+")

def extract_first_json_object(text: str):
    for match in re.finditer(r"\{", text):
        start = match.start()
        try:
            obj, _end = decoder.raw_decode(text[start:])
            if isinstance(obj, dict):
                return obj
        except json.JSONDecodeError:
            continue
    return None

def find_subject_line(text: str) -> tuple[str, list[str]]:
    lines = [ln.rstrip() for ln in text.splitlines()]
    for i, ln in enumerate(lines):
        if CONVENTIONAL_PATTERN.match(ln.strip()):
            return ln.strip(), lines[i + 1 :]
    return "", []

def enforce_from_plain_text(text: str) -> str:
    subject, body_lines = find_subject_line(text)
    if not subject:
        raise ValueError("LLM output did not contain a conventional commit subject line")
    body_lines = [ln.rstrip() for ln in body_lines]

    breaking_lines = [ln.strip() for ln in body_lines if ln.strip().startswith("BREAKING CHANGE:")]

    bullet_lines: list[str] = []
    for ln in body_lines:
        s = ln.strip()
        if s.startswith("- "):
            bullet_lines.append(s[2:].strip())
        elif s.startswith("* "):
            bullet_lines.append(s[2:].strip())

    if verbose_level == 0:
        parts = [subject] if subject else []
        if breaking_lines:
            parts.append("")
            parts.extend(breaking_lines)
        return "\n".join(parts).rstrip() + "\n"

    max_bullets = 3 if verbose_level == 1 else 5

    if not bullet_lines:
        fallback = [ln.strip() for ln in body_lines if ln.strip() and not ln.strip().startswith("BREAKING CHANGE:")]
        bullet_lines = fallback[:max_bullets]
    else:
        bullet_lines = bullet_lines[:max_bullets]

    parts = [subject] if subject else []
    body: list[str] = []
    if breaking_lines:
        body.extend(breaking_lines)
    body.extend([f"- {b}" for b in bullet_lines])
    if body:
        parts.append("")
        parts.extend(body)
    return "\n".join(parts).rstrip() + "\n"

def synthesize_bullets(min_bullets: int, max_bullets: int) -> list[str]:
    bullets: list[str] = []

    status_map = {"A": "Add", "M": "Update", "D": "Delete", "R": "Rename", "C": "Copy"}
    for line in git_name_status.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        code = parts[0].strip()
        action = status_map.get(code[:1], "Update")
        if code.startswith("R") and len(parts) >= 3:
            bullets.append(f"{action} {parts[1]} -> {parts[2]}")
        elif len(parts) >= 2:
            bullets.append(f"{action} {parts[1]}")

    bullets = [b.rstrip(".") for b in bullets if b]

    if git_shortstat.strip():
        bullets.append(git_shortstat.strip().rstrip("."))

    if not bullets:
        bullets.append("Update staged changes")

    bullets = bullets[:max_bullets]
    if len(bullets) < min_bullets:
        bullets.extend(["Update staged changes"] * (min_bullets - len(bullets)))
        bullets = bullets[:max_bullets]

    return bullets

obj = extract_first_json_object(raw)
if not obj:
    try:
        sys.stdout.write(enforce_from_plain_text(raw))
        sys.exit(0)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(2)

subject = str(obj.get("subject", "")).strip()
bullets = obj.get("bullets", [])
breaking_change = str(obj.get("breaking_change", "")).strip()

if not subject:
    try:
        sys.stdout.write(enforce_from_plain_text(raw))
        sys.exit(0)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(2)

if not isinstance(bullets, list):
    bullets = []
bullets = [str(b).strip() for b in bullets if str(b).strip()]
bullets = [b.rstrip(".") for b in bullets if b]

if jira_ticket:
    subject = f"[{jira_ticket}] {subject}"

if verbose_level == 0:
    lines = [subject] if subject else []
    if breaking_change:
        lines.extend(["", f"BREAKING CHANGE: {breaking_change}"])
    sys.stdout.write("\n".join(lines).rstrip() + "\n")
    sys.exit(0)

max_bullets = 3 if verbose_level == 1 else 5
min_bullets = 1 if verbose_level == 1 else 3

bullets = bullets[:max_bullets]
if len(bullets) < min_bullets:
    bullets = synthesize_bullets(min_bullets=min_bullets, max_bullets=max_bullets)

lines = [subject] if subject else []
body_lines: list[str] = []
if breaking_change:
    body_lines.append(f"BREAKING CHANGE: {breaking_change}")
if bullets:
    body_lines.extend([f"- {b}" for b in bullets])

if body_lines:
    lines.append("")
    lines.extend(body_lines)

sys.stdout.write("\n".join(lines).rstrip() + "\n")
PY
)

# Output or commit
if [ "$AUTO_COMMIT" = true ]; then
    printf '%s\n' "$COMMIT_MSG" | git commit -F -
else
    printf '%s\n' "$COMMIT_MSG"
fi
