# cc-helper

Claude Code helper scripts

## Scripts

### cc-statusline.sh

Status line for Claude Code showing model, path, branch, and context usage.

```
Sonnet 4.5 | cc-helper | main | 52% · 105k tokens
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

**Requirements:** bash, git, jq, tac

### git-commit-ai.sh

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

