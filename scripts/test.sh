#!/bin/bash
# Runs the Swift Testing suite with the Command Line Tools only (no Xcode):
# Testing.framework and its interop dylib live outside the default search paths.
#
# At most two thirds of the CPUs run tests at once (#80): Swift Testing runs synchronous tests on Swift's cooperative
# pool (one thread per CPU), and AVFoundation's readers need a free thread of that pool too. With every pool thread
# held by a long synchronous test (rendering, synthesizing footage), copyNextSampleBuffer waited 20-30 s and renders
# hit their stall watchdogs. Override with SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH.
#
# Signal 11 (#19): when the test process crashes, the crashed thread of its crash report is printed. If this run
# compiled something, the crash may come from a stale incremental build (seen after large pulls): the debug build is
# wiped and the suite runs once more from a clean build, saying so. If nothing was compiled, the crash is the code's:
# no retry, the stack says where.
# (REGISTA_SWIFT and REGISTA_CRASH_REPORTS replace swift and the crash report folder: the test of this script.)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
SWIFT="${REGISTA_SWIFT:-swift}"
REPORTS="${REGISTA_CRASH_REPORTS:-$HOME/Library/Logs/DiagnosticReports}"
args=()
if [ -d "$DEV/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  args=(-Xswiftc -F -Xswiftc "$DEV/Frameworks"
        -Xlinker -F -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi

scratch="$(mktemp -d -t regista-test)"
trap 'rm -rf "$scratch"' EXIT
cpus="$(sysctl -n hw.activecpu 2>/dev/null || echo 4)"
width=$(( cpus * 2 / 3 )); [ "$width" -ge 2 ] || width=2
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$width}"

# crash_stack <since-marker>: the crashed thread of the newest test-runner crash report written after the marker.
crash_stack() {
  local report="" i
  for i in $(seq 1 20); do   # ReportCrash writes the report a moment after the crash
    report="$(find "$REPORTS" -maxdepth 1 -name 'swiftpm-testing-helper-*.ips' -newer "$1" 2>/dev/null | sort | tail -1)"
    [ -n "$report" ] && break
    sleep 0.5
  done
  if [ -z "$report" ]; then echo "test.sh: no crash report found in $REPORTS"; return 0; fi
  echo "test.sh: crash report $report"
  /usr/bin/python3 -I - "$report" <<'EOF' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().partition("\n")[2])
images = d.get("usedImages", [])
print("test.sh:", d.get("exception", {}).get("type"), d.get("exception", {}).get("subtype", ""))
for t in d.get("threads", []):
    if t.get("triggered"):
        print("test.sh: crashed thread (queue %s):" % t.get("queue", "?"))
        for f in t.get("frames", [])[:16]:
            image = images[f["imageIndex"]].get("name", "?") if "imageIndex" in f else "?"
            where = " (%s:%s)" % (f["sourceFile"], f.get("sourceLine", "")) if f.get("sourceFile") else ""
            print("    %s  %s%s" % (image, f.get("symbol", "?"), where))
EOF
}

# run <args…>: one swift test, its output shown and kept in $log; returns its status. A run with no result after
# REGISTA_TEST_TIMEOUT seconds (default 40 minutes, about four times a full run) hangs on a test: it is stopped and
# fails with 124, instead of blocking a commit or an agent for ever.
LIMIT="${REGISTA_TEST_TIMEOUT:-2400}"
run() {
  local rc=0 pid tailer waited=0
  : > "$log"
  "$SWIFT" test ${args[@]+"${args[@]}"} "$@" > "$log" 2>&1 & pid=$!
  tail -f "$log" 2>/dev/null & tailer=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((LIMIT * 5)) ]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      pkill -TERM -f "swiftpm-testing-helper --test-bundle-path $PWD/" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      sleep 0.3; kill "$tailer" 2>/dev/null || true; wait "$tailer" 2>/dev/null || true
      echo "test.sh: no result after ${LIMIT}s: a test hangs (the last tests started are above). The run was stopped."
      return 124
    fi
    sleep 0.2; waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  sleep 0.3; kill "$tailer" 2>/dev/null || true; wait "$tailer" 2>/dev/null || true
  return "$rc"
}

# The tests' scratch brand-kit folders are named after the test process's pid (the test targets share one): folders
# left by runs of other days go, so a reused pid never meets an old kit.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'regista-tests-kits-*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true

log="$scratch/run1.log"
touch "$scratch/start"
rc=0; run "$@" || rc=$?
if [ "$rc" != 0 ] && grep -q "unexpected signal code 11" "$log"; then
  echo
  echo "test.sh: the test process crashed with signal 11 (SIGSEGV)."
  crash_stack "$scratch/start"
  if grep -qE '^\[[0-9]+/[0-9]+\] (Compiling|Emitting module)' "$log"; then
    echo "test.sh: this run compiled code: a stale incremental build can crash like this after large pulls (#19)."
    echo "test.sh: wiping the debug build and running the suite ONCE more from a clean build."
    rm -rf .build/arm64-apple-macosx/debug .build/x86_64-apple-macosx/debug
    log="$scratch/run2.log"
    touch "$scratch/start"
    rc=0; run "$@" || rc=$?
    if [ "$rc" = 0 ]; then
      echo "test.sh: passed after a clean rebuild. The first run crashed with signal 11 (stack above): if that happens"
      echo "test.sh: again on a clean build, it is a bug in the code, not the build."
    elif grep -q "unexpected signal code 11" "$log"; then
      echo "test.sh: signal 11 again on a clean build: a bug in the code, not a stale build."
      crash_stack "$scratch/start"
    fi
  else
    echo "test.sh: nothing was compiled in this run, so this is not a stale build: a bug in the code (stack above). No retry."
  fi
fi
# A run that ended without its summary did not finish: something ended the test process with exit code 0 (the mouse
# rig's known case: a stop of the main run loop reaching the test runner's own loop), and the tests not yet run are
# missing. Never green: the suite runs ONCE more, and a second unfinished run fails.
unfinished() { [ "$rc" = 0 ] && ! grep -qE "Test run with [0-9]+ tests? .*passed" "$log"; }
if unfinished; then
  echo
  echo "test.sh: the test process ended before the run's summary: the run did not finish (the last tests started are above)."
  echo "test.sh: running the suite ONCE more."
  log="$scratch/run3.log"
  rc=0; run "$@" || rc=$?
  if unfinished; then
    echo "test.sh: the second run did not finish either."
    rc=1
  fi
fi
exit "$rc"
