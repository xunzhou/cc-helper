# cc-helper

Claude Code helper scripts

## Scripts

### cc-statusline

Status line for Claude Code: model + effort, path, branch, context usage, 5h rate-limit, session cost.

```
Opus 4.7 hi | cc-helper | main | 4% · 37k/1M | lim 21% (3h13m) | $0.41
```

Reads every value from Claude Code's stdin — no network calls, no external tools.
The effort suffix (`lo`/`md`/`hi`/`xh`/`mx`) is appended when the model supports
the `effort` parameter. The `lim` and `$` segments drop automatically when the
underlying fields are absent (base plans without `rate_limits`, fresh sessions).

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

AI-powered conventional commit message generator.

```bash
git-commit-ai -c                  # Generate and commit
git-commit-ai -v                  # Add brief body
git-commit-ai -vv                 # Add detailed body
git-commit-ai PROJ-123            # Prepend JIRA ticket
git-commit-ai                     # Print message only
```

<details>
<summary>Setup</summary>

```bash
chmod +x git-commit-ai.sh
cp git-commit-ai.sh ~/.local/bin/git-commit-ai
```

Requirements: bash, git, claude CLI
</details>

