#!/usr/bin/env bash
#
# mayhem/build.sh — build the RainerScript replace()/wrap() libFuzzer harness (mayhem/fuzz_rainerscript.c) with
# the sanitized project, plus the project's normal testbench build that mayhem/test.sh runs. Both builds are out-of-tree under mayhem/ (gitignored) so the upstream
# source tree stays pristine and re-runs are incremental.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

OPTS=(--enable-debug --enable-testbench --enable-imdiag --enable-libzstd
      --disable-elasticsearch-tests --disable-kafka-tests --disable-libfaketime
      --without-valgrind-testbench --disable-valgrind)

[ -f configure ] || autoreconf -fi

# 1) Test build: the project's NORMAL flags, plus the testbench helper programs (tcpflood etc.).
mkdir -p mayhem/build-test
(
  cd mayhem/build-test
  env -u CFLAGS -u LDFLAGS CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "$SRC/configure" "${OPTS[@]}" >configure.log 2>&1 \
    || { tail -40 configure.log; exit 1; }
  make -j"$MAYHEM_JOBS"
  make -j"$MAYHEM_JOBS" -C tests check TESTS=
)

# 2) Fuzz build: the whole project instrumented with $SANITIZER_FLAGS at DWARF 3. ASan's leak checker
#    is switched off at link time by mayhem/lsan_off.c; the function-type UBSan check is excluded
#    because rsyslog's module ABI calls through generic callback pointers.
FUZZ_BUILD="$SRC/mayhem/build-fuzz"
mkdir -p "$FUZZ_BUILD"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
(
  cd "$FUZZ_BUILD"
  # The rpath lets the built ELFs find rsyslog's shared runtime modules.
  export CFLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function $DEBUG_FLAGS"
  export LDFLAGS="$SANITIZER_FLAGS -fno-sanitize=function -Wl,-rpath,$FUZZ_BUILD/runtime/.libs"
  ASAN_OPTIONS=detect_leaks=0 "$SRC/configure" "${OPTS[@]}" --enable-fuzzing >configure.log 2>&1 \
    || { tail -40 configure.log; exit 1; }
  make -j"$MAYHEM_JOBS"
  # The harness locates the runtime modules relative to its own path, so its binary stays in tools/.
  # fuzz_rainerscript is not in upstream's tools/Makefile.am: mayhem/fuzz_rainerscript.mk adds it to the
  # generated Makefile, reusing rsyslogd's objects (and so the sanitized project) from fuzz_rsyslog_message.
  relink() {  # <extra link inputs>
    rm -f tools/fuzz_rainerscript
    make -C tools -f Makefile -f "$SRC/mayhem/fuzz_rainerscript.mk" MAYHEM_SRC="$SRC" \
         "LIB_FUZZING_ENGINE=$1" fuzz_rainerscript
  }
  t=fuzz_rainerscript
  # Non-fuzzer reproducer: the same harness linked against the run-once driver.
  relink "$FUZZ_BUILD/standalone_main.o $FUZZ_BUILD/lsan_off.o"
  mv "tools/$t" "tools/$t-standalone"
  relink "$LIB_FUZZING_ENGINE $FUZZ_BUILD/lsan_off.o"
)

for t in fuzz_rainerscript; do
  printf '#!/bin/sh\nexec %s "$@"\n' "$FUZZ_BUILD/tools/$t-standalone" > "$SRC/$t-standalone"
  chmod 755 "$SRC/$t-standalone"
done
