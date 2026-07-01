#!/usr/bin/env bash
# Tests for hooks/handoff-pickup.sh — the SessionStart handoff auto-seed.
# Self-contained: builds throwaway git repos under a tmp dir.
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/handoff-pickup.sh"
ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# Fresh git repo with a handoff doc; echoes the repo root.
new_repo() {
  local d; d="$(mktemp -d "$ROOT_TMP/repo.XXXX")"
  git init -q "$d"; mkdir -p "$d/.handoff" "$d/sub"
  printf '# Handoff — sentinel-%s\n\n## Next action\nrun the thing\n' "$RANDOM" > "$d/.handoff/HANDOFF.md"
  echo "$d"
}
# Run the hook with cwd set to a repo subdir (exercises git-toplevel resolution).
run() { printf '{"cwd":"%s/sub","source":"startup"}' "$1" | bash "$HOOK" 2>/dev/null; }

# 1. Fresh, unconsumed -> injects the doc + resume framing, writes marker.
R=$(new_repo); OUT=$(run "$R")
[[ "$OUT" == *"Resuming from a session handoff"* ]] && ok || bad "fresh: missing resume framing"
[[ "$OUT" == *"## Next action"* ]] && ok || bad "fresh: missing doc body"
[[ -f "$R/.handoff/.pickup-consumed" ]] && ok || bad "fresh: marker not written"

# 2. Second run at same version -> consumed, empty.
OUT=$(run "$R")
[[ -z "$OUT" ]] && ok || bad "consumed: expected empty, got output"

# 3. Rewrite (new mtime) -> re-arms and re-injects.
sleep 1; printf '# Handoff — v2\n\n## Next action\ndo v2\n' > "$R/.handoff/HANDOFF.md"
OUT=$(run "$R")
[[ "$OUT" == *"do v2"* ]] && ok || bad "rewrite: did not re-inject"

# 4. Stale doc (older than max age) -> skipped.
R=$(new_repo); touch -d '3 days ago' "$R/.handoff/HANDOFF.md"
OUT=$(run "$R")
[[ -z "$OUT" ]] && ok || bad "stale: expected empty"
# ...but a lower ceiling via env still injects a same-age doc.
OUT=$(CC_HANDOFF_MAX_AGE_H=200 run "$R")
[[ "$OUT" == *"Next action"* ]] && ok || bad "stale: env ceiling did not re-enable"

# 5. No doc at all -> empty, no crash.
D=$(mktemp -d "$ROOT_TMP/nodoc.XXXX"); git init -q "$D"; mkdir -p "$D/sub"
OUT=$(printf '{"cwd":"%s/sub"}' "$D" | bash "$HOOK" 2>/dev/null)
[[ -z "$OUT" ]] && ok || bad "no-doc: expected empty"

# 6. cwd fallback when not a git repo (no jq path exercised via bare cwd).
D=$(mktemp -d "$ROOT_TMP/nogit.XXXX"); mkdir -p "$D/.handoff"
printf '# Handoff\n\n## Next action\nx\n' > "$D/.handoff/HANDOFF.md"
OUT=$(printf '{"cwd":"%s"}' "$D" | bash "$HOOK" 2>/dev/null)
[[ "$OUT" == *"Next action"* ]] && ok || bad "non-git: cwd fallback failed"

echo "handoff-pickup: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
