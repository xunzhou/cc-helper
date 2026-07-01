# cc-helper

Claude Code helper scripts

## Scripts

### cc-statusline

Status line for Claude Code: model + effort, path, branch, context usage, 5h quota bar, session cost.

```
Opus 4.7 hi | cc-helper | main | 4% 37k/1M | 48% ███▓▓░░░░░ 3h30m | $0.41
```

Reads every value from Claude Code's stdin — no network calls, no external tools.
The effort suffix (`lo`/`md`/`hi`/`xh`/`mx`) is appended when the model supports
the `effort` parameter.

The 5h quota bar is 10 cells (10% each): `█` used on pace, `▓` used ahead of
pace, `░` remaining. It turns yellow when ahead of pace, red at ≥90%. Set
`NO_COLOR` or `CC_STATUSLINE_NO_COLOR` to render it plain. The quota bar and `$`
segments drop when their fields are absent.

<details>
<summary>Context-handoff signal</summary>

Response quality degrades as context fills, so the context segment is an
escalating cue to switch to a fresh session **before** the rot: it turns
**yellow** at ≥50% (`amber` — start thinking about a handoff), **red** at ≥65%,
and stays red at ≥80% (`degraded` — switch now). Override the thresholds with
`CC_HANDOFF_AMBER_PCT` / `CC_HANDOFF_RED_PCT` / `CC_HANDOFF_DEGRADED_PCT`.

On every render it also publishes the state to a cache file for out-of-band
consumers (a polybar indicator, an i3-cc handoff-switch) — same atomic
temp-then-`mv` pattern as the quota bar's `cc-quota` cache:

```
# $XDG_CACHE_HOME/cc-context.<profile>   (one line)
# <pct> <tokens> <limit> <state> <session_id> <cwd>
55 550000 1000000 amber 8f3c… /data/proj/hq/.worktrees/01-foo
```

`cwd` is last so a reader can `read -r pct tokens limit state sid cwd` and `cwd`
absorbs the trailing path. `state` is `init` before the first API response.
</details>

<details>
<summary>Setup</summary>

```bash
chmod +x cc-statusline.sh
cp cc-statusline.sh ~/.local/bin/
```

Add to `~/.claude/settings.json`:
```json
"statusLine": {
  "type": "command",
  "command": "cc-statusline.sh",
  "padding": 0
}
```

Requirements: bash, git, jq, Claude Code >= 2.1.132
</details>

<details>
<summary>Context-limit detection</summary>

Read from `.context_window.context_window_size` in stdin — the per-account
effective limit (200k on base plans, 1M on Max). Override with
`CC_STATUSLINE_CONTEXT_LIMIT` if needed:

```bash
CC_STATUSLINE_CONTEXT_LIMIT=1000000 claude
```
</details>

### cc-usage

Rate-limit utilization without launching Claude. Auto-discovers every `~/.claude*`
profile and queries the same `/api/oauth/usage` endpoint Claude Code's `/usage` screen uses.

```
 default
5h         █████░░░░░░░░░░░░░░░   24.0%  resets in 3h 36m
7d         █░░░░░░░░░░░░░░░░░░░    4.0%  resets in 1d 6h
7d sonnet  ░░░░░░░░░░░░░░░░░░░░    2.0%  resets in 1d 6h
```

```bash
cc-usage                 # all profiles
cc-usage -p work         # one profile (repeatable)
cc-usage --list          # name -> dir
cc-usage --raw           # raw JSON
```

<details>
<summary>Setup</summary>

```bash
chmod +x cc-usage
cp cc-usage ~/.local/bin/
```

For a proxied profile, set `HTTPS_PROXY` on the call:
```bash
alias cc-usage-work='HTTPS_PROXY=http://proxy:port cc-usage -p work'
```

Requirements: [uv](https://docs.astral.sh/uv/) — deps declared inline (PEP 723), no manual install.
</details>

### git-commit-ai

Conventional commit message generator with a deterministic house-style enforcer
in the core (conventional subject, no AI attribution, no emoji, JIRA prefix). It
serves both humans and agents — the message *source* is pluggable, the *policy* is
not.

```bash
git-commit-ai -c                  # Generate from the diff and commit (human default)
git-commit-ai -v / -vv            # ...with a brief / detailed body
git-commit-ai PROJ-123            # Prepend a JIRA ticket
git-commit-ai --amend -c          # Reword the last commit (folds in staged changes)
git-commit-ai                     # Print message only (no commit)
```

Agent-facing (the staged diff is still what gets committed):

```bash
# The agent already knows the WHY -> it authors; the wrapper enforces + commits.
# No second LLM call; the agent's body is kept verbatim.
git-commit-ai -c -m "fix(api): guard nil token refresh

- root cause: race between refresh and revoke
- mutex over retry to avoid token churn"

git-commit-ai -c --stdin <<<"$msg"   # same, message on stdin

# The agent has the WHY but wants help phrasing -> inject intent, LLM writes.
git-commit-ai -c -v --context "race between refresh and revoke; mutex avoids churn"

# Structured output for programmatic consumers (versioned contract, v1).
git-commit-ai --json -m "fix(x): y"
# {"version":1,"subject":"fix(x): y","body":"","bullets":[],
#  "breaking_change":"","message":"fix(x): y","committed":false,"commit":null}
```

`-m`/`--stdin` (author) and `--context` (generate) are mutually exclusive.
Exit codes: `0` ok · `1` usage/env error · `2` message unusable · `124` LLM timeout.
Run `git-commit-ai --help` for the full surface. Tests: `bash tests/test_git_commit_ai.sh`.

<details>
<summary>Setup</summary>

```bash
chmod +x git-commit-ai.sh
cp git-commit-ai.sh ~/.local/bin/git-commit-ai
```

Requirements: bash, git, python3; claude CLI (only for generate modes — `-m` needs neither)
</details>

