#!/usr/bin/env bash
#
# Checks run.sh end to end with a stand-in for curl, so no backend is needed:
#   bash test.sh
#
# Covers the gate-if-worse comparison (the only non-trivial logic here): which
# past run gets picked, and the exit codes of all three modes.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-$HERE/run.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand-in for curl: answers the endpoints run.sh calls with canned JSON. This
# run's numbers come from A_*/B_*; the agents' past runs come from PAST_A/PAST_B
# (newest first, the shape the run-list endpoint returns).
cat >"$TMP/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X | -H | -d | -w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
body='{}'; status=200
case "$url" in
  */agents/resolve) body='{"resolved":{"alpha":"uuid-a","beta":"uuid-b"},"not_found":[]}' ;;
  */agent-tests/agent/uuid-a/runs*) body="{\"items\":${PAST_A}}" ;;
  */agent-tests/agent/uuid-b/runs*) body="{\"items\":${PAST_B}}" ;;
  */agent-tests/agent/uuid-a/run) body='{"task_id":"task-a"}' ;;
  */agent-tests/agent/uuid-b/run) body='{"task_id":"task-b"}' ;;
  */agent-tests/run/task-a)
    body="{\"status\":\"done\",\"total_tests\":${A_TOTAL},\"passed\":${A_PASSED},\"failed\":$((A_TOTAL - A_PASSED))}" ;;
  */agent-tests/run/task-b)
    body="{\"status\":\"done\",\"total_tests\":${B_TOTAL},\"passed\":${B_PASSED},\"failed\":$((B_TOTAL - B_PASSED))}" ;;
  *) status=404 ;;
esac
printf '%s' "$body" >"$out"
printf '%s' "$status"
STUB
chmod +x "$TMP/curl"
export PATH="$TMP:$PATH"

FAILS=0
# One earlier run each, 18 of 20 passed: 90% to beat.
PAST='[{"uuid":"old-1","total_tests":20,"passed":18}]'

# case NAME "A_TOTAL A_PASSED" "B_TOTAL B_PASSED" MODE PAST_A PAST_B EXPECT_RC EXPECT_TEXT
case_run() {
  export A_TOTAL="${2%% *}" A_PASSED="${2##* }" B_TOTAL="${3%% *}" B_PASSED="${3##* }"
  export PAST_A="$5" PAST_B="$6"
  local out rc
  out="$(CALIBRATE_API_KEY=k CALIBRATE_AGENTS='alpha,beta' CALIBRATE_BASE_URL=http://x \
    CALIBRATE_APP_URL= CALIBRATE_MODE="$4" CALIBRATE_POLL_INTERVAL=0 CALIBRATE_TIMEOUT=5 \
    bash "$RUN" 2>&1)"
  rc=$?
  if [[ "$rc" != "$7" ]]; then
    echo "FAIL $1: exit ${rc}, wanted $7"; echo "$out"; FAILS=1; return
  fi
  if ! printf '%s' "$out" | grep -qF "$8"; then
    echo "FAIL $1: missing \"$8\""; echo "$out"; FAILS=1; return
  fi
  echo "ok   $1 (exit ${rc})"
}

case_run "same rate passes"      "20 18" "20 18" gate-if-worse "$PAST" "$PAST" 0 "Pass rate: 90% (36/40) — was 90% (36/40)"
case_run "rate up passes"        "20 19" "20 18" gate-if-worse "$PAST" "$PAST" 0 "Pass rate: 92.5% (37/40) — was 90% (36/40)"
case_run "rate down fails"       "20 17" "20 18" gate-if-worse "$PAST" "$PAST" 1 "Pass rate: 87.5% (35/40) — was 90% (36/40)"
case_run "no earlier run passes" "20 17" "20 18" gate-if-worse '[]' '[]' 0 "no earlier run to compare with"

# Only agent alpha has history: beta is left out of both sides of the sum.
case_run "compares only agents with history" "20 17" "20 20" gate-if-worse "$PAST" '[]' 1 \
  "Pass rate: 85% (17/20) — was 90% (18/20)"

# A hand-run over 3 tests is newer, but the 20-test run is the one to beat.
case_run "ignores a run over fewer tests" "20 18" "20 18" gate-if-worse \
  '[{"uuid":"old-2","total_tests":3,"passed":0},{"uuid":"old-1","total_tests":20,"passed":18}]' "$PAST" \
  0 "was 90% (36/40)"

# A run that errored carries junk numbers; it must not become the bar.
case_run "ignores an errored run" "20 18" "20 18" gate-if-worse \
  '[{"uuid":"old-2","total_tests":20,"passed":20,"error":true},{"uuid":"old-1","total_tests":20,"passed":18}]' "$PAST" \
  0 "was 90% (36/40)"

# Tests were deleted since: a 25-test run covered tests that no longer exist.
case_run "ignores a run over more tests" "20 18" "20 18" gate-if-worse \
  '[{"uuid":"old-2","total_tests":25,"passed":25},{"uuid":"old-1","total_tests":20,"passed":18}]' "$PAST" \
  0 "was 90% (36/40)"

# Tests were added since: still compares, against the last full run at 20.
case_run "tests added since, still compares" "25 23" "25 22" gate-if-worse "$PAST" "$PAST" 0 \
  "Pass rate: 90% (45/50) — was 90% (36/40)"

# Two equally large past runs: the newer one is the bar.
case_run "newest of the largest past runs" "20 18" "20 18" gate-if-worse \
  '[{"uuid":"old-2","total_tests":20,"passed":18},{"uuid":"old-1","total_tests":20,"passed":10}]' "$PAST" \
  0 "was 90% (36/40)"

case_run "gate still fails on a failing test"    "20 17" "20 18" gate   "$PAST" "$PAST" 1 "test(s) failed"
case_run "report still passes on a failing test" "20 17" "20 18" report "$PAST" "$PAST" 0 "test(s) failed"

# A typo in mode is a usage error, not a silent pass.
CALIBRATE_API_KEY=k CALIBRATE_AGENTS='alpha' CALIBRATE_BASE_URL=http://x \
  CALIBRATE_MODE=gate-if-worst bash "$RUN" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then echo "ok   unknown mode exits 2"; else echo "FAIL unknown mode"; FAILS=1; fi

[[ "$FAILS" -eq 0 ]] && echo "all checks passed"
exit "$FAILS"
