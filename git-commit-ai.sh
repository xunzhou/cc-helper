#!/bin/bash
# AI-powered commit message generator for lazygit
# Usage: git-commit-ai [-v|-vv] [-c] [--amend] [JIRA-TICKET]

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
AMEND=false
OUTPUT_JSON=false
AUTHOR_MODE=false   # agent supplied the final message; enforce-only, no LLM call
AGENT_MESSAGE=""    # the author-supplied draft (-m / --message-file / --stdin)
AGENT_CONTEXT=""    # the author-supplied WHY injected into generation (--context)
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
        --amend)
            AMEND=true
            shift
            ;;
        -m|--message)
            # Author mode: agent supplies the final message; wrapper enforces + commits, no LLM.
            AUTHOR_MODE=true
            [ $# -ge 2 ] || { echo "Error: -m/--message requires a value (use - for stdin)" >&2; exit 1; }
            if [ "$2" = "-" ]; then AGENT_MESSAGE="$(cat)"; else AGENT_MESSAGE="$2"; fi
            shift 2
            ;;
        --message-file)
            AUTHOR_MODE=true
            [ $# -ge 2 ] || { echo "Error: --message-file requires a path (use - for stdin)" >&2; exit 1; }
            if [ "$2" = "-" ]; then AGENT_MESSAGE="$(cat)"; else AGENT_MESSAGE="$(cat -- "$2")"; fi
            shift 2
            ;;
        --stdin)
            AUTHOR_MODE=true
            AGENT_MESSAGE="$(cat)"
            shift
            ;;
        --context)
            # Generate mode: agent supplies the WHY; the LLM writes the message using diff + this.
            [ $# -ge 2 ] || { echo "Error: --context requires a value (use --context-file - for stdin)" >&2; exit 1; }
            if [ -n "$AGENT_CONTEXT" ]; then AGENT_CONTEXT="$AGENT_CONTEXT
$2"; else AGENT_CONTEXT="$2"; fi
            shift 2
            ;;
        --context-file)
            [ $# -ge 2 ] || { echo "Error: --context-file requires a path (use - for stdin)" >&2; exit 1; }
            if [ "$2" = "-" ]; then _ctx="$(cat)"; else _ctx="$(cat -- "$2")"; fi
            if [ -n "$AGENT_CONTEXT" ]; then AGENT_CONTEXT="$AGENT_CONTEXT
$_ctx"; else AGENT_CONTEXT="$_ctx"; fi
            shift 2
            ;;
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        -h|--help)
            cat <<'HELP'
Usage: git-commit-ai [-v|-vv] [-c] [--amend] [--json] [-m MSG|--stdin|--context WHY] [JIRA-TICKET]

Three ways to get a message (the staged diff is always the subject of the commit):

  1. Generate from the diff (human / no-context default)
       git-commit-ai -c
     The LLM writes the message from the staged diff. -v/-vv add a body, but it
     can only restate the diff (it has no access to the WHY).

  2. Generate with author intent (agent has the WHY but wants help phrasing)
       git-commit-ai -c -v --context "race between refresh and revoke; mutex avoids churn"
     The WHY is injected into the prompt; the LLM composes from diff + intent.

  3. Author + enforce (agent already wrote the message; NO second LLM call)
       git-commit-ai -c -m "fix(api): guard nil token refresh

       - root cause: race between refresh and revoke
       - mutex over retry to avoid token churn"
     The wrapper validates conventional style, strips AI attribution + emoji,
     applies the JIRA prefix, and commits. The agent's body is kept verbatim.

Options:
  -v, --verbose        Add brief body (1-3 bullets)            [generate modes]
  -vv,--very-verbose   Add detailed body (3-5 bullets)         [generate modes]
  -c, --commit         Commit with the resulting message
  --amend              Reword the last commit (folds in staged changes)
  -m, --message MSG    Author mode: use MSG as the message (- = read stdin)
  --message-file FILE  Author mode: read the message from FILE (- = stdin)
  --stdin              Author mode: read the message from stdin
  --context WHY        Generate mode: inject author intent (repeatable)
  --context-file FILE  Generate mode: read intent from FILE (- = stdin)
  --json               Emit a JSON object on stdout (versioned contract, v1):
                       {version, subject, body, bullets, breaking_change,
                        message, committed, commit}
  -h, --help           Show this help message

Exit codes:  0 ok  |  1 usage/environment error  |  2 message unusable
             (no conventional subject)  |  124 LLM timed out

Note: --message/--stdin (author) and --context (generate) are mutually exclusive.

Environment:
  GIT_COMMIT_AI_LLM_CMD            LLM runner: claude (default), opencode, or a custom command.
                                  Prompt is provided via stdin unless your command references __PROMPT_FILE__ or GIT_COMMIT_AI_PROMPT_FILE.
  GIT_COMMIT_AI_TIMEOUT_SECONDS    LLM timeout in seconds (default: 30)
  GIT_COMMIT_AI_LLM_USE_STDIN      Force stdin usage: auto (default), false

Arguments:
  JIRA-TICKET      Optional JIRA ticket ID to prepend (e.g., PROJ-123)
HELP
            exit 0
            ;;
        *)
            JIRA_TICKET="$1"
            shift
            ;;
    esac
done

# Author mode (final message supplied) and --context (intent for generation) are
# mutually exclusive: one bypasses the LLM, the other feeds it. Fail visibly.
if [ "$AUTHOR_MODE" = true ] && [ -n "$AGENT_CONTEXT" ]; then
    echo "Error: --message/--stdin (author mode) cannot be combined with --context (generate mode)" >&2
    exit 1
fi

# Ensure HOME is set (lazygit might not set it)
if [ -z "$HOME" ]; then
    HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
fi

if [ "$AMEND" = true ]; then
    # Amend mode: require an existing commit; staged changes are optional
    # (no staged changes = pure reword). The message is generated from the
    # whole resulting commit, so newly staged changes fold in naturally.
    if ! git rev-parse --verify --quiet HEAD >/dev/null; then
        echo "Error: --amend requires at least one commit" >&2
        exit 1
    fi
    # Base for the amended commit's diff: parent if it exists, else the empty
    # tree (amending the root commit). Computing it against the index yields
    # the full content of the commit that --amend will produce.
    if git rev-parse --verify --quiet HEAD~1 >/dev/null; then
        AMEND_BASE="HEAD~1"
    else
        AMEND_BASE=$(git hash-object -t tree /dev/null)
    fi
    DIFF_LABEL="Full changes in the amended commit:"
    GIT_DIFF=$(git diff --cached "$AMEND_BASE")
    GIT_NAME_STATUS=$(git diff --cached --name-status "$AMEND_BASE")
    GIT_SHORTSTAT=$(git diff --cached --shortstat "$AMEND_BASE" 2>/dev/null || echo "")
    # Style reference excludes the commit being reworded.
    GIT_LOG=$(git log --oneline -5 "$AMEND_BASE" 2>/dev/null || echo "No previous commits")
else
    # Check if there are staged changes
    if git diff --cached --quiet; then
        echo "Error: No staged changes to commit" >&2
        exit 1
    fi

    # Get the git diff and recent commit messages for context
    DIFF_LABEL="Staged changes to commit:"
    GIT_DIFF=$(git diff --cached)
    GIT_NAME_STATUS=$(git diff --cached --name-status)
    GIT_SHORTSTAT=$(git diff --cached --shortstat 2>/dev/null || echo "")
    GIT_LOG=$(git log --oneline -5 2>/dev/null || echo "No previous commits")
fi

# --- Obtain the raw message ------------------------------------------------
# Author mode: the agent already wrote the message -> skip the LLM entirely (no
# second model call, no diff re-derivation). Generate mode: build the prompt and
# call the LLM, optionally injecting author intent (--context) as the WHY.
if [ "$AUTHOR_MODE" = true ]; then
    MESSAGE_MODE="author"
    LLM_RAW="$AGENT_MESSAGE"
else
MESSAGE_MODE="generate"

# Optional author-intent block, injected into the prompt as the authoritative WHY.
AGENT_CONTEXT_BLOCK=""
if [ -n "$AGENT_CONTEXT" ]; then
    AGENT_CONTEXT_BLOCK="## Author-Supplied Intent (AUTHORITATIVE - the WHY)

The commit author provided this rationale. Treat it as the primary source of intent:
use it to pick the type/scope and, when a body is requested, to convey the WHY rather
than restating the diff. Do not contradict it.

$AGENT_CONTEXT
"
fi

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

$DIFF_LABEL
\`\`\`diff
$GIT_DIFF
\`\`\`

$AGENT_CONTEXT_BLOCK
Now generate ONLY the JSON object (no explanations, no markdown blocks, just the raw JSON):
TEMPLATE

# Determine LLM command based on template
case "$LLM_CMD_TEMPLATE" in
    claude)
        # Isolate this headless commit-gen run from the user's Claude config so it
        # neither pollutes memory/history nor gets polluted by it:
        #   --setting-sources project,local : skip the USER settings.json, so none
        #       of the user-level hooks (desktop-workflow capture, vikunja) or
        #       plugins (claude-mem, honcho, superpowers) load. That stops these
        #       runs from being recorded as sessions/observations AND stops the
        #       memory dump + skills from being injected into the commit prompt.
        #       Auth is untouched (unlike --bare, which forces ANTHROPIC_API_KEY/
        #       apiKeyHelper and never reads OAuth/keychain -> would break login here).
        #   --no-session-persistence : don't write a transcript .jsonl under
        #       ~/.claude/projects (no on-disk chat history for this run).
        # CLAUDE_CODE_ENTRYPOINT is kept as a stable marker (belt-and-suspenders if
        # ever run without the flags above); inline so it survives `bash -lc`.
        LLM_CMD='CLAUDE_CODE_ENTRYPOINT=git-commit-ai claude --print --setting-sources project,local --no-session-persistence --tools "" --dangerously-skip-permissions'
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
fi  # end generate-mode branch (author mode set LLM_RAW directly)

# Enforce house style in the core and emit ONE canonical JSON object. Both surfaces
# (plain message and --json) are rendered from it by the shell below.
RESULT_JSON=$(
    env \
        LLM_RAW="$LLM_RAW" \
        MESSAGE_MODE="$MESSAGE_MODE" \
        GIT_NAME_STATUS="$GIT_NAME_STATUS" \
        GIT_SHORTSTAT="$GIT_SHORTSTAT" \
        python3 - "$VERBOSE_LEVEL" "$JIRA_TICKET" <<'PY'
import os
import json
import re
import sys

verbose_level = int(sys.argv[1])
jira_ticket = sys.argv[2]
message_mode = os.environ.get("MESSAGE_MODE", "generate")
raw = os.environ.get("LLM_RAW")
if raw is None:
    raw = sys.stdin.read()
raw = raw.replace("\r", "").strip()
git_name_status = os.environ.get("GIT_NAME_STATUS", "")
git_shortstat = os.environ.get("GIT_SHORTSTAT", "")

decoder = json.JSONDecoder()
CONVENTIONAL_PATTERN = re.compile(r"^(?:revert: )?[a-z]+(?:\([^)]+\))?!?: .+")

# House-style policy lives in the core so every surface (and every input source)
# inherits it: strip AI-attribution / promo lines and emoji per the commit
# convention. Emoji are removed first, so a "<emoji> Generated with ..." promo
# line still matches the attribution filter afterward.
ATTRIB_LINE_RE = re.compile(r"^\s*(co-authored-by:|generated with\b|signed-off-by:\s*claude)", re.IGNORECASE)
EMOJI_RE = re.compile(
    "[\U0001f300-\U0001faff\U00002600-\U000026ff\U00002700-\U000027bf"
    "\U0001f1e6-\U0001f1ff\U0000fe0f\U000020e3\U00002b00-\U00002bff]"
)


def clean_text(s: str) -> str:
    s = EMOJI_RE.sub("", s)
    s = re.sub(r"[ \t]{2,}", " ", s)
    return s.rstrip()


def strip_attrib(lines):
    return [ln for ln in lines if not ATTRIB_LINE_RE.match(ln)]


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


def find_subject_line(text: str):
    lines = [ln.rstrip() for ln in text.splitlines()]
    for i, ln in enumerate(lines):
        if CONVENTIONAL_PATTERN.match(ln.strip()):
            return ln.strip(), lines[i + 1 :]
    return "", []


def bullets_from(body_lines):
    out = []
    for ln in body_lines:
        s = ln.strip()
        if s.startswith("- ") or s.startswith("* "):
            out.append(s[2:].strip())
    return out


def trim_blanks(lines):
    lines = list(lines)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def emit(subject, body_text, bullets, breaking):
    """Assemble the canonical result object and print it as JSON, then exit."""
    subject = clean_text(subject)
    if jira_ticket:
        subject = f"[{jira_ticket}] {subject}"
    message = subject if not body_text else subject + "\n\n" + body_text
    result = {
        "version": 1,
        "subject": subject,
        "body": body_text,
        "bullets": bullets,
        "breaking_change": breaking,
        "message": message,
    }
    sys.stdout.write(json.dumps(result) + "\n")
    sys.exit(0)


def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(2)


def extract_breaking(body_lines):
    for ln in body_lines:
        s = ln.strip()
        if s.startswith("BREAKING CHANGE:"):
            return s[len("BREAKING CHANGE:") :].strip()
    return ""


def run_author():
    """The agent's message is authoritative: enforce policy, keep the body verbatim."""
    obj = extract_first_json_object(raw)
    if obj and str(obj.get("subject", "")).strip():
        subject = str(obj.get("subject", "")).strip()
        bullets = [clean_text(str(b).strip()) for b in (obj.get("bullets") or []) if str(b).strip()]
        breaking = str(obj.get("breaking_change", "")).strip()
        body_lines = []
        if breaking:
            body_lines.append(f"BREAKING CHANGE: {breaking}")
        body_lines += [f"- {b}" for b in bullets]
    else:
        subject, rest = find_subject_line(raw)
        if not subject:
            fail("author message has no conventional commit subject line (e.g. 'fix(scope): summary')")
        body_lines = trim_blanks(strip_attrib([clean_text(ln) for ln in rest]))
        bullets = bullets_from(body_lines)
        breaking = extract_breaking(body_lines)
    emit(subject, "\n".join(body_lines).rstrip(), bullets, breaking)


def synthesize_bullets(min_bullets: int, max_bullets: int):
    bullets = []
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


def generate_from_plain():
    subject, body_lines = find_subject_line(raw)
    if not subject:
        fail("LLM output did not contain a conventional commit subject line")
    body_lines = strip_attrib([clean_text(ln) for ln in body_lines])
    breaking = extract_breaking(body_lines)
    breaking_out = [f"BREAKING CHANGE: {breaking}"] if breaking else []
    if verbose_level == 0:
        emit(subject, "\n".join(breaking_out).rstrip(), [], breaking)
    max_bullets = 3 if verbose_level == 1 else 5
    bullets = bullets_from(body_lines)
    if not bullets:
        bullets = [ln.strip() for ln in body_lines if ln.strip() and not ln.strip().startswith("BREAKING CHANGE:")][:max_bullets]
    else:
        bullets = bullets[:max_bullets]
    body_out = breaking_out + [f"- {b}" for b in bullets]
    emit(subject, "\n".join(body_out).rstrip(), bullets, breaking)


def run_generate():
    obj = extract_first_json_object(raw)
    if not obj or not str(obj.get("subject", "")).strip():
        generate_from_plain()
        return
    subject = str(obj.get("subject", "")).strip()
    breaking = str(obj.get("breaking_change", "")).strip()
    bullets = obj.get("bullets", [])
    if not isinstance(bullets, list):
        bullets = []
    bullets = [clean_text(str(b).strip()).rstrip(".") for b in bullets if str(b).strip()]
    bullets = [b for b in bullets if b]
    breaking_out = [f"BREAKING CHANGE: {breaking}"] if breaking else []

    if verbose_level == 0:
        emit(subject, "\n".join(breaking_out).rstrip(), [], breaking)

    max_bullets = 3 if verbose_level == 1 else 5
    min_bullets = 1 if verbose_level == 1 else 3
    bullets = bullets[:max_bullets]
    if len(bullets) < min_bullets:
        bullets = synthesize_bullets(min_bullets, max_bullets)
    body_out = breaking_out + [f"- {b}" for b in bullets]
    emit(subject, "\n".join(body_out).rstrip(), bullets, breaking)


if message_mode == "author":
    run_author()
else:
    run_generate()
PY
)

# Derive the plain commit message from the canonical object.
COMMIT_MSG=$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])')

# Commit if requested. Git's own chatter goes to stderr so stdout stays pure data
# (a clean message in print mode, or a clean JSON object under --json).
COMMITTED=false
COMMIT_SHA=""
if [ "$AUTO_COMMIT" = true ]; then
    if [ "$AMEND" = true ]; then
        printf '%s\n' "$COMMIT_MSG" | git commit --amend -F - >&2
    else
        printf '%s\n' "$COMMIT_MSG" | git commit -F - >&2
    fi
    COMMITTED=true
    COMMIT_SHA=$(git rev-parse HEAD)
fi

# Render the requested surface.
if [ "$OUTPUT_JSON" = true ]; then
    env RJSON="$RESULT_JSON" COMMITTED="$COMMITTED" COMMIT_SHA="$COMMIT_SHA" python3 -c '
import json, os, sys
o = json.loads(os.environ["RJSON"])
o["committed"] = os.environ["COMMITTED"] == "true"
o["commit"] = os.environ["COMMIT_SHA"] or None
print(json.dumps(o))
'
else
    printf '%s\n' "$COMMIT_MSG"
fi
