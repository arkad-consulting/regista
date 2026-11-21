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
#
# --clean-preferences (#137), opt-in, never by default: before the run, removes the property lists that test runs made
# before #137 left in the Preferences folder, and only those: `regista-<kind>-<UUID>.plist` (kind = lowercase letters
# and hyphens, UUID = the upper-case 8-4-4-4-12 form). It says how many it removed; the run then goes on as usual.
# (REGISTA_SWIFT, REGISTA_CRASH_REPORTS and REGISTA_PREFERENCES_DIR replace swift, the crash report folder and the
# Preferences folder: the test of this script.)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
SWIFT="${REGISTA_SWIFT:-swift}"
REPORTS="${REGISTA_CRASH_REPORTS:-$HOME/Library/Logs/DiagnosticReports}"

clean_preferences=0; rest=()
for a in "$@"; do
  if [ "$a" = --clean-preferences ]; then clean_preferences=1; else rest+=("$a"); fi
done
set -- ${rest[@]+"${rest[@]}"}
if [ "$clean_preferences" = 1 ]; then
  prefs="${REGISTA_PREFERENCES_DIR:-$HOME/Library/Preferences}"
  # Listed characters, not ranges: a range like A-F can take in lower-case letters in some locales.
  h='[0123456789ABCDEF]'
  pattern="^regista-[abcdefghijklmnopqrstuvwxyz][abcdefghijklmnopqrstuvwxyz-]*-$h{8}-$h{4}-$h{4}-$h{4}-$h{12}\.plist\$"
  removed=0
  for f in "$prefs"/regista-*.plist; do
    if [[ "${f##*/}" =~ $pattern ]] && [ -f "$f" ] && [ ! -L "$f" ]; then
      rm -f -- "$f" && removed=$((removed + 1))
    fi
  done
  echo "test.sh: --clean-preferences removed $removed file(s) named regista-<kind>-<UUID>.plist from $prefs"
fi
# The macOS SDK it can build SwiftUI with, without Xcode (#136); not for the test of this script (its swift is a stand-in).
if [ -z "${REGISTA_SWIFT:-}" ]; then
  sdk="$(bash -c '. scripts/lib.sh; swift_sdk && printf %s "${SDKROOT:-}"')" \
    || { bash -c '. scripts/lib.sh; t sdk_needs_xcode' >&2; echo >&2; exit 1; }
  if [ -n "$sdk" ]; then export SDKROOT="$sdk"; fi
fi
args=()
if [ -d "$DEV/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  args=(-Xswiftc -F -Xswiftc "$DEV/Frameworks"
        -Xlinker -F -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi

# The run's own temporary folder (#138): every temporary file of the tests and of the processes they start goes there
# (REGISTA_TMPDIR, read by TemporaryFolder; Foundation's temporary directory ignores TMPDIR on macOS), and the folder
# goes when the run ends, whatever its result. A run that was stopped leaves its folder: such folders go once they are
# a day old.
system_tmp="${TMPDIR:-/tmp}"; system_tmp="${system_tmp%/}"
find "$system_tmp" -maxdepth 1 -name 'regista-run-*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true
run_tmp="$system_tmp/regista-run-$$"
rm -rf "$run_tmp"; mkdir -p "$run_tmp"
export REGISTA_TMPDIR="$run_tmp"
scratch="$(mktemp -d "$run_tmp/regista-test.XXXXXX")"
trap 'rm -rf "$run_tmp"' EXIT
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
# The same for the test processes' folders of defaults suites (TestDefaults, #137): a process that ends normally
# removes its own; one that was stopped or crashed leaves it.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'regista-tests-defaults-*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true

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
# missing. Never green by itself: the run is taken up again, without the tests that already passed, up to
# REGISTA_TEST_RUNS runs in all (default 4); if the last one does not reach its summary either, the run fails. A test
# is left out only when every test of that name passed in one same run (two suites can share a function name).
# A test that failed before the early end runs again with the rest, but its failure stands (#55): a pass in a later run
# does not undo it, the run fails and the failures are printed again next to the verdict.
RUNS="${REGISTA_TEST_RUNS:-4}"
unfinished() { [ "$rc" = 0 ] && ! grep -qE "Test run with [0-9]+ tests? .*passed" "$log"; }
runs=1; ids=""; passed="$scratch/passed-ids"; : > "$passed"; skips=()
failed="$scratch/failed"; : > "$failed"
while unfinished && [ "$runs" -lt "$RUNS" ]; do
  grep -E "✘ Test .+ failed" "$log" >> "$failed" || true
  echo
  echo "test.sh: the test process ended before the run's summary: the run did not finish (the last tests started are above)."
  [ -n "$ids" ] || ids="$("$SWIFT" test list ${args[@]+"${args[@]}"} 2>/dev/null || true)"
  # The names that passed in this run, with how many times each.
  sed -nE 's/^[^T]*Test (.+\)) (passed|with [0-9]+ test cases? passed) after .*/\1/p' "$log" | sort | uniq -c | while read -r count name; do
    matches="$(printf '%s\n' "$ids" | awk -v n="/$name" 'length($0) >= length(n) && substr($0, length($0) - length(n) + 1) == n')"
    if [ -n "$matches" ] && [ "$count" -ge "$(printf '%s\n' "$matches" | grep -c .)" ]; then printf '%s\n' "$matches" >> "$passed"; fi
  done
  skips=()
  while IFS= read -r id; do
    if [ -n "$id" ]; then skips+=(--skip "^$(printf '%s' "$id" | sed 's/[][\\.*^$(){}?+|]/\\&/g')(/|\$)"); fi   # the id may be followed by its source location
  done < <(sort -u "$passed")
  runs=$((runs + 1))
  echo "test.sh: run $runs of at most $RUNS, without the $(( ${#skips[@]} / 2 )) tests that already passed."
  log="$scratch/resume-$runs.log"
  rc=0; run "$@" ${skips[@]+"${skips[@]}"} || rc=$?
done
if unfinished; then
  echo "test.sh: the run did not finish after $runs runs."
  rc=1
fi
if [ -s "$failed" ]; then
  echo "test.sh: a run that ended early had these failures; a later run does not undo them:"
  sort -u "$failed"
  rc=1
fi
exit "$rc"
