#!/usr/bin/env bash
#
# mayhem/test.sh — RUN a subset of rsyslog's own testbench (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Each test starts a real rsyslogd (via imdiag), injects messages, and compares what the output actions wrote
# against asserted values, so a neutered rsyslogd cannot pass. The subset covers the message parsers, the
# imtcp framing / decompression paths and RainerScript's replace()/wrap(), and runs fully offline.
TESTS="parsertest-parse1.sh parsertest-parse2.sh parsertest-parse3.sh parsertest-parse-3164-buggyday.sh
 parsertest-parse_8bit_escape.sh parsertest-parse-nodate.sh pmrfc3164-AtSignsInHostname.sh
 pmrfc3164-defaultTag.sh pmrfc3164-headerless.sh pmrfc3164-msgFirstSpace.sh pmrfc3164-tagEndingByColon.sh
 pmrfc3164_force_tag_no_colon.sh rfc5424parser.sh rfc5424parser-sp_at_msg_start.sh
 hostname-with-slash-pmrfc3164.sh hostname-with-slash-pmrfc5424.sh parser-drop-trailing-cr.sh
 imtcp-basic.sh imtcp_addtlframedelim.sh imtcp-multiline.sh imtcp-NUL.sh imtcp_framing_regex.sh
 imtcp-stream-always-zlib-basic.sh imtcp-stream-always-zstd-basic.sh imtcp_no_octet_counted.sh
 imtcp-maxFrameSize.sh fac_local0.sh rscript_contains.sh rscript_replace_complex.sh
 rscript_replace-overlap.sh rscript_wrap2.sh rscript_wrap3.sh"

BUILD="$SRC/mayhem/build-test"
[ -f "$BUILD/tests/Makefile" ] || { echo "mayhem/test.sh: $BUILD missing; mayhem/build.sh must run first" >&2; emit_ctrf "rsyslog-testbench" 0 1 0; exit 1; }

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
# check-TESTS only runs the tests; build.sh already built rsyslogd and the testbench helpers.
make -C "$BUILD/tests" check-TESTS TESTS="$(echo $TESTS)" >"$LOG" 2>&1
grep -E '^(PASS|FAIL|SKIP|XFAIL|XPASS|ERROR):' "$LOG" || true

passed=$(grep -cE '^(PASS|XFAIL):' "$LOG" || true)
failed=$(grep -cE '^(FAIL|XPASS|ERROR):' "$LOG" || true)
skipped=$(grep -cE '^SKIP:' "$LOG" || true)
if [ "$passed" -lt 10 ]; then
  echo "mayhem/test.sh: only $passed tests passed; suite did not run properly" >&2
  tail -30 "$LOG" >&2
  failed=$((failed + 1))
fi
emit_ctrf "rsyslog-testbench" "$passed" "$failed" "$skipped"
