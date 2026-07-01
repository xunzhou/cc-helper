#!/usr/bin/env bash
# SessionStart(startup) hook — auto-seed a fresh Claude session from a handoff.
#
# The attended context-handoff flow: when response quality degrades, the human
# spawns a fresh session in the same worktree (e.g. via i3-cc). If the prior
# session left `<repo-root>/.handoff/HANDOFF.md` (written by the `/handoff`
# skill), this hook injects it as session context so the new session resumes
# cold-but-oriented — no manual re-briefing.
#
# Contract:
#   - stdin: Claude Code SessionStart JSON ({cwd, source, session_id, ...}).
#   - stdout: the handoff doc (SessionStart injects stdout as context). Empty
#     when there is nothing fresh+unconsumed to inject.
#   - Never blocks session start: always exits 0, tolerates missing jq/git.
#
# Idempotency: a handoff is injected once per *version* (mtime). Re-opening the
# same worktree won't re-inject a stale doc; rewriting it (new mtime) re-arms it.
# Staleness: skipped when older than CC_HANDOFF_MAX_AGE_H hours (default 48).
set -u

input=$(cat 2>/dev/null)

cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
fi
[ -n "$cwd" ] || cwd="$PWD"

# The handoff lives at the repo/worktree root, so it's found from any subdir.
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root="$cwd"
doc="$root/.handoff/HANDOFF.md"
[ -f "$doc" ] || exit 0

mtime=$(stat -c %Y "$doc" 2>/dev/null) || exit 0
now=$(date +%s 2>/dev/null) || exit 0

# Stale -> skip silently.
max_age_h="${CC_HANDOFF_MAX_AGE_H:-48}"
if [ $(( (now - mtime) / 3600 )) -gt "$max_age_h" ]; then
  exit 0
fi

# Already consumed at this version -> skip.
marker="$root/.handoff/.pickup-consumed"
if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$mtime" ]; then
  exit 0
fi

# Inject, framed so the agent treats it as resume state rather than reference.
printf '## Resuming from a session handoff\n\n'
printf 'A prior session in this worktree left the handoff below (`%s`). Continue from **Next action** — do not re-derive decisions already recorded here.\n\n' "$doc"
cat "$doc"

printf '%s' "$mtime" > "$marker" 2>/dev/null
exit 0
