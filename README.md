# cc-statusline.sh

A minimal, standalone bash script for Claude Code `statusLine` that prints:

```
model | path | branch | context window
```

Example:

```
Sonnet 4.5 | cc-statusline | master | 52% · 105k tokens
```

## Install

Make it executable and put it on your `PATH` (one option):

```bash
chmod +x cc-statusline.sh
mkdir -p ~/.local/bin
cp cc-statusline.sh ~/.local/bin/cc-statusline.sh
```

## Configure

In `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "cc-statusline.sh",
  "padding": 0
}
```

## Requirements

- `bash`
- `git` (branch detection)
- `jq` (or a jq-compatible alternative; see `CC_STATUSLINE_JQ`)
- `tac` (used to scan the transcript from the end; on macOS you may only have it if GNU coreutils is installed)

## Environment Variables

- `CC_STATUSLINE_JQ`: jq binary name (default: `jq`)

