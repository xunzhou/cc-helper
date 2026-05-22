# cc-helper

Claude Code helper scripts

## Scripts

### cc-statusline

Status line for Claude Code showing model (with version), path, branch, and context usage.

```
Opus 4.7 | cc-helper | main | 45% · 90k/200k
```

The context limit is detected from the model name Claude Code provides: an
extended window shows up as e.g. `Opus 4.7 (1M context)`, which is parsed to
1M. Without such a hint it defaults to 200k. Override with
`CC_STATUSLINE_CONTEXT_LIMIT` if needed:

```bash
CC_STATUSLINE_CONTEXT_LIMIT=1000000 claude   # force a 1M limit
```

**Setup:**
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

**Requirements:** bash, git, jq, Claude Code >= 2.1.132

### git-commit-ai

AI-powered conventional commit message generator.

```bash
git-commit-ai -c                  # Generate and commit
git-commit-ai -v                  # Add brief body
git-commit-ai -vv                 # Add detailed body
git-commit-ai PROJ-123            # Prepend JIRA ticket
git-commit-ai                     # Print message only
```

**Setup:**
```bash
chmod +x git-commit-ai.sh
cp git-commit-ai.sh ~/.local/bin/git-commit-ai
```

**Requirements:** bash, git, claude CLI

