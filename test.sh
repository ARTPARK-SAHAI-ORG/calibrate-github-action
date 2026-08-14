#!/usr/bin/env bash
#
# Checks run.sh end to end with a stand-in for curl, so no backend is needed:
#   bash test.sh
#
# Covers the gate-if-worse comparison (the only non-trivial logic here) and the
# exit codes of all three modes. Everything else — resolving names, polling,
# the PR comment — still needs a live backend and a real workflow.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-$HERE/run.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand-in for curl: answers the endpoints run.sh calls with canned JSON. Test
# counts come from the A_*/B_* env vars each case exports.
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
BASE='{"uuid-a":{"total":20,"passed":18},"uuid-b":{"total":20,"passed":18}}'

# calibrate MODE BASELINE_JSON -> runs run.sh, sets OUT and RC.
calibrate() {
  printf '%s' "$2" >"$TMP/baseline.json"
  OUT="$(CALIBRATE_API_KEY=k CALIBRATE_AGENTS='alpha,beta' CALIBRATE_BASE_URL=http://x \
    CALIBRATE_APP_URL= CALIBRATE_MODE="$1" CALIBRATE_POLL_INTERVAL=0 CALIBRATE_TIMEOUT=5 \
    CALIBRATE_BASELINE_FILE="$TMP/baseline.json" bash "$RUN" 2>&1)"
  RC=$?
}

# case NAME "A_TOTAL A_PASSED" "B_TOTAL B_PASSED" MODE BASELINE EXPECT_RC EXPECT_TEXT
case_run() {
  export A_TOTAL="${2%% *}" A_PASSED="${2##* }" B_TOTAL="${3%% *}" B_PASSED="${3##* }"
  calibrate "$4" "$5"
  if [[ "$RC" != "$6" ]]; then
    echo "FAIL $1: exit ${RC}, wanted $6"; echo "$OUT"; FAILS=1; return
  fi
  if ! printf '%s' "$OUT" | grep -qF "$7"; then
    echo "FAIL $1: missing \"$7\""; echo "$OUT"; FAILS=1; return
  fi
  echo "ok   $1 (exit ${RC})"
}

case_run "same rate passes"      "20 18" "20 18" gate-if-worse "$BASE" 0 "Pass rate: 90% (36/40) — was 90% (36/40)"
case_run "rate up passes"        "20 19" "20 18" gate-if-worse "$BASE" 0 "Pass rate: 92.5% (37/40) — was 90% (36/40)"
case_run "rate down fails"       "20 17" "20 18" gate-if-worse "$BASE" 1 "Pass rate: 87.5% (35/40) — was 90% (36/40)"
case_run "more tests, same rate" "25 22" "25 23" gate-if-worse "$BASE" 0 "Pass rate: 90% (45/50) — was 90% (36/40)"
case_run "no record passes"      "20 17" "20 18" gate-if-worse '{}' 0 "no previous run on record"
case_run "corrupt record passes" "20 17" "20 18" gate-if-worse 'not json' 0 "no previous run on record"
case_run "unknown agent ignored" "20 17" "20 18" gate-if-worse '{"uuid-z":{"total":9,"passed":1}}' 0 "no previous run on record"
case_run "compares only agents on both sides" "20 17" "20 20" gate-if-worse \
  '{"uuid-a":{"total":20,"passed":18}}' 1 "Pass rate: 85% (17/20) — was 90% (18/20)"
case_run "gate still fails on a failing test"    "20 17" "20 18" gate "$BASE" 1 "test(s) failed"
case_run "report still passes on a failing test" "20 17" "20 18" report "$BASE" 0 "test(s) failed"

# The record takes this run's numbers and keeps agents this run didn't touch.
export A_TOTAL=20 A_PASSED=19 B_TOTAL=20 B_PASSED=20
calibrate gate-if-worse '{"uuid-other":{"total":8,"passed":8},"uuid-a":{"total":20,"passed":18}}'
GOT="$(jq -c -S . "$TMP/baseline.json")"
WANT='{"uuid-a":{"passed":19,"total":20},"uuid-b":{"passed":20,"total":20},"uuid-other":{"passed":8,"total":8}}'
if [[ "$GOT" == "$WANT" ]]; then echo "ok   record updated"; else echo "FAIL record: $GOT"; FAILS=1; fi

# A typo in mode is a usage error, not a silent pass.
CALIBRATE_API_KEY=k CALIBRATE_AGENTS='alpha' CALIBRATE_BASE_URL=http://x \
  CALIBRATE_MODE=gate-if-worst bash "$RUN" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then echo "ok   unknown mode exits 2"; else echo "FAIL unknown mode"; FAILS=1; fi

[[ "$FAILS" -eq 0 ]] && echo "all checks passed"
exit "$FAILS"
