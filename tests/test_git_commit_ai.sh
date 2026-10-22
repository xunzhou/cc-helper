#!/bin/bash
# Contract tests for git-commit-ai.sh — the agent-facing surface.
#
# Seam: GIT_COMMIT_AI_LLM_CMD overrides the LLM runner.
#   - set to `false`  -> proves a code path makes NO LLM call (false would fail)
#   - set to a fake   -> deterministic JSON, and can capture the prompt it received
#
# Run: bash tests/test_git_commit_ai.sh   (exit 0 = all pass)

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/git-commit-ai.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

assert_eq() { # name expected actual
    if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$2] got [$3]"; fi
}
assert_exit() { # name expected actual
    if [ "$2" = "$3" ]; then pass; else fail "$1: expected exit $2 got $3"; fi
}
assert_contains() { # name haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then pass; else fail "$1: [$2] missing [$3]"; fi
}
assert_not_contains() { # name haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1: [$2] should not contain [$3]"; else pass; fi
}

# A staged change in a throwaway repo with one prior commit.
mkrepo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" config user.email t@t.test
    git -C "$d" config user.name tester
    echo seed >"$d/file.txt"
    git -C "$d" add -A
    git -C "$d" commit -qm "chore: seed"
    printf 'more\n' >>"$d/file.txt"
    git -C "$d" add -A
    echo "$d"
}

# run <repo> <args...> ; sets OUT, ERR, CODE. Env (GIT_COMMIT_AI_*) is inherited.
run() {
    local repo="$1"
    shift
    local errf
    errf=$(mktemp)
    OUT=$(cd "$repo" && "$SCRIPT" "$@" 2>"$errf")
    CODE=$?
    ERR=$(cat "$errf")
    rm -f "$errf"
}

jget() { printf '%s' "$1" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"$2\"])"; }

# Fake LLM: optionally capture the prompt (stdin) to \$PROMPT_CAPTURE, emit \$FAKE_JSON.
FAKE_LLM=$(mktemp)
cat >"$FAKE_LLM" <<'EOF'
#!/bin/bash
if [ -n "${PROMPT_CAPTURE:-}" ]; then cat >"$PROMPT_CAPTURE"; else cat >/dev/null; fi
printf '%s' "${FAKE_JSON:-{\"subject\":\"chore: fake\",\"bullets\":[],\"breaking_change\":\"\"}}"
EOF
chmod +x "$FAKE_LLM"

echo "== author mode (-m): enforce-only, no LLM =="

# T1: -m skips the LLM entirely (LLM=false would fail if called) and emits the subject.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "fix(parser): handle empty input"
assert_exit "T1 -m skips LLM" 0 "$CODE"
assert_eq "T1 -m emits subject" "fix(parser): handle empty input" "$OUT"

# T2: -m preserves the agent's full body verbatim (no verbose-level truncation).
repo=$(mkrepo)
msg=$'feat(api): add token refresh\n\n- reason one\n- reason two\n- reason three\n- reason four'
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "$msg"
assert_contains "T2 keeps subject" "$OUT" "feat(api): add token refresh"
assert_contains "T2 keeps 4th bullet" "$OUT" "reason four"

# T3: -m with a non-conventional subject is rejected (exit 2 = unusable message).
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "just some prose without a type"
assert_exit "T3 rejects non-conventional subject" 2 "$CODE"

# T4: -m strips AI attribution + emoji (policy enforced in core), keeps real body.
repo=$(mkrepo)
msg=$'fix(ui): polish button \U0001F389\n\n- real detail\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "$msg"
assert_not_contains "T4 strips attribution" "$OUT" "Co-Authored-By"
assert_not_contains "T4 strips emoji" "$OUT" $'\U0001F389'
assert_contains "T4 keeps real body" "$OUT" "real detail"

# T5: author via stdin (--stdin).
repo=$(mkrepo)
errf=$(mktemp)
OUT=$(cd "$repo" && printf 'fix(z): via stdin' | GIT_COMMIT_AI_LLM_CMD=false "$SCRIPT" --stdin 2>"$errf")
CODE=$?
rm -f "$errf"
assert_exit "T5 --stdin exit 0" 0 "$CODE"
assert_eq "T5 --stdin subject" "fix(z): via stdin" "$OUT"

# T6: JIRA prefix applies in author mode.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "fix(x): thing" PROJ-123
assert_contains "T6 jira prefix" "$OUT" "[PROJ-123] fix(x): thing"

echo "== JIRA prefix is applied once =="

# T6a: generate mode where the LLM mimicked a prefixed git log -> no duplicate.
repo=$(mkrepo)
FAKE_JSON='{"subject":"[PROJ-123] chore(x): thing","bullets":[],"breaking_change":""}' \
    GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo" PROJ-123
assert_eq "T6a generate dedupes ticket" "[PROJ-123] chore(x): thing" "$OUT"

# T6b: author JSON draft already prefixed -> no duplicate.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m '{"subject":"[PROJ-123] fix(x): thing"}' PROJ-123
assert_eq "T6b author JSON dedupes ticket" "[PROJ-123] fix(x): thing" "$OUT"

# T6c: plain author draft with a ticket prefix is accepted (was rejected) and deduped.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "[PROJ-123] fix(x): thing" PROJ-123
assert_exit "T6c plain prefixed accepted" 0 "$CODE"
assert_eq "T6c plain dedupes ticket" "[PROJ-123] fix(x): thing" "$OUT"

# T6d: other tickets already in the prefix are kept; the CLI ticket goes first.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "[PROJ-9] [PROJ-123] fix(x): thing" PROJ-123
assert_eq "T6d keeps other tickets" "[PROJ-123] [PROJ-9] fix(x): thing" "$OUT"

# T6e: the prompt tells the LLM not to add a ticket prefix itself.
repo=$(mkrepo)
cap=$(mktemp)
PROMPT_CAPTURE="$cap" GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo" PROJ-123
assert_contains "T6e prompt forbids ticket prefix" "$(cat "$cap")" "NEVER prefix the subject with a ticket tag"
rm -f "$cap"

echo "== --context (generate mode): inject the WHY =="

# T7: --context text reaches the LLM prompt.
repo=$(mkrepo)
cap=$(mktemp)
FAKE_JSON='{"subject":"fix(auth): guard refresh","bullets":["race fixed"],"breaking_change":""}' \
    PROMPT_CAPTURE="$cap" GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" \
    run "$repo" -v --context "race between refresh and revoke; mutex chosen to avoid churn"
assert_exit "T7 context exit 0" 0 "$CODE"
assert_contains "T7 context in prompt" "$(cat "$cap")" "mutex chosen to avoid churn"
rm -f "$cap"

# T8: -m and --context together is a visible error (exit 1), not silent precedence.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" -m "fix(x): a" --context "why"
assert_exit "T8 -m + --context conflict" 1 "$CODE"

echo "== --json output contract =="

# T9: --json emits a structured object (version + subject) without committing.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" --json -m "fix(x): do thing"
assert_exit "T9 --json exit 0" 0 "$CODE"
assert_eq "T9 --json subject" "fix(x): do thing" "$(jget "$OUT" subject)"
assert_eq "T9 --json version" "1" "$(jget "$OUT" version)"
assert_eq "T9 --json not committed" "False" "$(jget "$OUT" committed)"

# T10: --json -c commits and reports committed=true + the sha; subject lands in the log.
repo=$(mkrepo)
GIT_COMMIT_AI_LLM_CMD=false run "$repo" --json -c -m "fix(y): commit me"
assert_eq "T10 committed true" "True" "$(jget "$OUT" committed)"
assert_eq "T10 log subject" "fix(y): commit me" "$(git -C "$repo" log -1 --pretty=%s)"

echo "== backward compatibility =="

# T11: plain generate path (no -m/--context) still prints the LLM-derived subject.
repo=$(mkrepo)
FAKE_JSON='{"subject":"chore: regenerated","bullets":[],"breaking_change":""}' \
    GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo"
assert_exit "T11 generate exit 0" 0 "$CODE"
assert_eq "T11 generate subject" "chore: regenerated" "$OUT"

# T12: generate -v renders the JSON bullets as a body (regression on the core).
repo=$(mkrepo)
FAKE_JSON='{"subject":"feat(x): thing","bullets":["did a","did b"],"breaking_change":""}' \
    GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo" -v
assert_contains "T12 -v keeps subject" "$OUT" "feat(x): thing"
assert_contains "T12 -v renders bullet" "$OUT" "- did a"

# T13: generate-mode --json emits the canonical object (regression).
repo=$(mkrepo)
FAKE_JSON='{"subject":"fix(x): y","bullets":[],"breaking_change":""}' \
    GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo" --json
assert_eq "T13 generate --json subject" "fix(x): y" "$(jget "$OUT" subject)"
assert_eq "T13 generate --json version" "1" "$(jget "$OUT" version)"

# T14: a breaking_change always lands in the body even at level 0 (regression).
repo=$(mkrepo)
FAKE_JSON='{"subject":"feat(x): z","bullets":[],"breaking_change":"drops the old flag"}' \
    GIT_COMMIT_AI_LLM_CMD="$FAKE_LLM" run "$repo"
assert_contains "T14 breaking in body" "$OUT" "BREAKING CHANGE: drops the old flag"

# T15: --amend author mode rewords the last commit (no staged change required).
repo=$(mktemp -d)
git -C "$repo" init -q
git -C "$repo" config user.email t@t.test
git -C "$repo" config user.name tester
echo seed >"$repo/f.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm "wip: bad message"
GIT_COMMIT_AI_LLM_CMD=false run "$repo" --amend -c -m "fix(core): proper message"
assert_exit "T15 amend exit 0" 0 "$CODE"
assert_eq "T15 amend reworded" "fix(core): proper message" "$(git -C "$repo" log -1 --pretty=%s)"

rm -f "$FAKE_LLM"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
