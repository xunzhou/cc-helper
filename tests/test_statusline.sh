#!/usr/bin/env bash
# Tests for cc-statusline.sh context-handoff signal: escalating state, the
# in-terminal color of the context segment, and the published cc-context cache
# line consumed by polybar / i3-cc. Self-contained: isolates XDG_CACHE_HOME and
# CLAUDE_CONFIG_DIR into a tmp dir so it never touches the real cache.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cc-statusline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export XDG_CACHE_HOME="$TMP"
export CLAUDE_CONFIG_DIR="$TMP/.testcfg"   # -> profile "testcfg"
CACHE="$TMP/cc-context.testcfg"

pass=0 fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
check() { [[ "$2" == "$3" ]] && ok || bad "$1: expected [$3] got [$2]"; }

# Build statusline input JSON for a given token count (1M limit).
json() { printf '{"model":{"display_name":"Opus","id":"claude-opus-4-8"},"workspace":{"current_dir":"/tmp/wt"},"session_id":"sess-abc","context_window":{"context_window_size":1000000,"total_input_tokens":%s},"cost":{"total_cost_usd":0}}' "$1"; }

# Run the statusline; stdout in $OUT, published fields parsed into globals.
run() {
  local tokens="$1"; shift
  OUT=$(json "$tokens" | env "$@" bash "$SCRIPT" 2>/dev/null)
  read -r P_PCT P_TOK P_LIM P_STATE P_SID P_CWD < "$CACHE"
}

# --- state thresholds (defaults 50/65/80) --------------------------------------
run 400000; check "40% state"  "$P_STATE" "ok"
run 550000; check "55% state"  "$P_STATE" "amber"
run 700000; check "70% state"  "$P_STATE" "red"
run 850000; check "85% state"  "$P_STATE" "degraded"
run 0;      check "0 state"    "$P_STATE" "init"

# boundary: exactly at each threshold trips it
run 500000; check "50% boundary" "$P_STATE" "amber"
run 650000; check "65% boundary" "$P_STATE" "red"
run 800000; check "80% boundary" "$P_STATE" "degraded"

# --- published line fields -----------------------------------------------------
run 550000
check "pub pct"   "$P_PCT"   "55"
check "pub tokens" "$P_TOK"  "550000"
check "pub limit" "$P_LIM"   "1000000"
check "pub sid"   "$P_SID"   "sess-abc"
check "pub cwd"   "$P_CWD"   "/tmp/wt"

# --- in-terminal color of the context segment ----------------------------------
run 550000
[[ "$OUT" == *$'\033[33m'* ]] && ok || bad "amber colors context yellow"
run 850000
[[ "$OUT" == *$'\033[31m'* ]] && ok || bad "degraded colors context red"
run 400000
[[ "$OUT" != *$'\033['* ]] && ok || bad "ok state leaves output plain"

# NO_COLOR: no escapes in output, but state still classified in the cache
run 850000 NO_COLOR=1
[[ "$OUT" != *$'\033['* ]] && ok || bad "NO_COLOR strips escapes"
check "NO_COLOR still classifies" "$P_STATE" "degraded"

# --- env-overridable thresholds ------------------------------------------------
run 300000 CC_HANDOFF_AMBER_PCT=25
check "custom amber 25%" "$P_STATE" "amber"

echo "cc-statusline: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
