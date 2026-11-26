#!/usr/bin/env bash
#
# measure.sh - run the app against the local exchange server for a fixed time and keep the latency lines it prints.
#
# Usage:
#   Scripts/measure.sh <label> <rateMultiplier> <stress:true|false> <extraLatencyMs> <seconds>
#
#   APP_PATH=build/DerivedDataRelease/Build/Products/Release-iphonesimulator/TradePulse.app \
#     Scripts/measure.sh release-baseline 1 false 0 30
#
# What it does, in order:
#   1. Checks that the exchange server answers (start it with `make server` in another terminal), that an iPhone 18 Pro
#      simulator is booted, and that the app is installed on it. If the environment variable APP_PATH names an .app
#      directory, that app is installed first, so the run says which build it measured.
#   2. Sets the lab to the given rate, stress mode and injected latency (jitter off, no dropped updates), reads the
#      settings back from the server, which clamps what it is given, and prints what the server confirmed. Those
#      confirmed settings are what the run is labelled with.
#   3. Launches the app on the simulator with `--print-latency --open-symbol PTT`, so that a chart is on screen and the
#      tick-to-render metric has samples, lets it run for <seconds> and terminates it. The app prints one JSON line five
#      seconds after it starts and one more every five seconds. Every line is cumulative since the launch, so the LAST
#      line of a file is the result of the run. Every run starts from a fresh launch: the clock-offset estimate and
#      the first connection are part of it.
#   4. Keeps the lines that are JSON, checks that each one parses and has the expected shape (t, frames and hitches, and
#      the six metrics, each with its count, its clamped count and its three percentiles), and writes them to
#      docs/results/<label>.jsonl, next to docs/results/<label>.run.json, a small record of the settings and the build
#      the run used (Scripts/summarize.py reads both).
#
# However the script ends, also after a failure or an interrupt, it terminates the app and sets the lab back to its
# defaults. The lab's settings live in the server process, and a run that left them changed would spoil the next one.
#
# A run that fails writes no result: docs/results is left as it was, and an earlier result of the same label stays.
# The script ending the app itself after <seconds> is the normal end of a run. An app that has gone before that, for
# whatever reason, is a failed run however many lines it had printed.
#
# Exit codes: 0 done; 1 the run failed (the app exited before the <seconds> were over, fewer than 5 JSON lines, a line
# that is not a latency line); 2 refused before anything was changed (wrong arguments, no server, no simulator, no app).

set -eu -o pipefail

BUNDLE_ID="dev.tradepulse.poc.TradePulse"
DEVICE_NAME="iPhone 18 Pro"
SERVER_URL="http://127.0.0.1:18080"
MIN_LINES=5
LAB_DEFAULTS='{"rateMultiplier":1,"stress":false,"extraLatencyMs":0,"jitterMs":0,"dropUpdates":false}'
# The metrics every line of the app's output holds, in the order it prints them.
METRIC_NAMES='["tickToApp","tickToApplied","tickToRender","orderSubmitToAck","orderServerProcessing","orderSubmitToFill"]'

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_PATH")")"
RESULTS_DIR="$REPO_ROOT/docs/results"

# Filled in as the script goes; the exit handler reads them.
WORK_DIR=""
UDID=""
OS_VERSION=""
BUILD=""
LAB_TOUCHED=0
LAUNCH_PID=""
APP_EXITED_AT=""
CONFIRMED=""
LABEL=""
RATE=""
STRESS=""
EXTRA_LATENCY_MS=""
DURATION=""
STARTED_AT=""
IDLE_BEFORE="null"
IDLE_AFTER="null"
RAW_OUTPUT=""
RAW_ERRORS=""
LINES_FILE=""
LINE_COUNT=0

usage() {
  cat >&2 <<'EOF'
usage: Scripts/measure.sh <label> <rateMultiplier> <stress:true|false> <extraLatencyMs> <seconds>

  label            names the result: docs/results/<label>.jsonl (letters, digits, '.', '_' and '-')
  rateMultiplier   how many times the normal tick rate the market runs at; the server clamps it to 0.1 .. 10
  stress           true or false: the market's stress mode
  extraLatencyMs   delay the lab adds to every frame of the market feed; the server clamps it to 0 .. 5000
  seconds          how long the app runs; it prints a line every 5 s, and 5 lines are needed (30 gives 5 or 6)

  APP_PATH         optional: an .app directory to install on the simulator before the run
EOF
}

say() {
  echo "measure.sh: $*"
}

# Refuses the run before anything has been changed.
refuse() {
  echo "measure.sh: $*" >&2
  exit 2
}

# Ends a run that went wrong after it had begun.
fail() {
  echo "measure.sh: $*" >&2
  exit 1
}

# --- Arguments and preconditions ------------------------------------------------------------------------------------

parse_arguments() {
  if [ "$#" -ne 5 ]; then
    usage
    exit 2
  fi
  LABEL="$1"
  RATE="$2"
  STRESS="$3"
  EXTRA_LATENCY_MS="$4"
  DURATION="$5"

  case "$LABEL" in
    "" | *[!A-Za-z0-9._-]* | [.-]*)
      refuse "the label must be letters, digits, '.', '_' or '-' and must not start with '.' or '-': '$LABEL'"
      ;;
  esac
  if ! echo "$RATE" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || ! awk -v rate="$RATE" 'BEGIN { exit !(rate > 0) }'; then
    refuse "rateMultiplier must be a positive number, not '$RATE'"
  fi
  case "$STRESS" in
    true | false) ;;
    *) refuse "stress must be true or false, not '$STRESS'" ;;
  esac
  if ! echo "$EXTRA_LATENCY_MS" | grep -Eq '^[0-9]+$'; then
    refuse "extraLatencyMs must be a whole number of milliseconds, not '$EXTRA_LATENCY_MS'"
  fi
  if ! echo "$DURATION" | grep -Eq '^[0-9]+$' || [ "$DURATION" -lt 1 ]; then
    refuse "seconds must be a whole number above 0, not '$DURATION'"
  fi
}

check_tools() {
  local tool
  for tool in curl jq xcrun awk; do
    command -v "$tool" >/dev/null 2>&1 || refuse "$tool is needed and was not found"
  done
}

check_server() {
  if ! curl -sS -f --max-time 3 -o /dev/null "$SERVER_URL/v1/time" 2>/dev/null; then
    refuse "the exchange server does not answer GET $SERVER_URL/v1/time: start it with 'make server'"
  fi
}

# Takes the UDID and the OS version of the booted iPhone 18 Pro (the first one, if there are several).
find_simulator() {
  local listing found
  listing="$(xcrun simctl list devices booted -j)" || refuse "xcrun simctl could not list the simulators"
  found="$(echo "$listing" | jq -r --arg name "$DEVICE_NAME" '
    [ .devices | to_entries[] | .key as $runtime | .value[]
      | select(.name == $name and .state == "Booted") | [.udid, $runtime] ]
    | first // empty | @tsv')"
  if [ -z "$found" ]; then
    refuse "no $DEVICE_NAME simulator is booted: boot it with 'xcrun simctl boot \"$DEVICE_NAME\"'"
  fi
  UDID="$(echo "$found" | cut -f1)"
  OS_VERSION="$(echo "$found" | cut -f2 | sed -E 's/.*iOS-([0-9]+)-([0-9]+).*/\1.\2/')"
}

# Checks APP_PATH, if it is set, and takes the build from the folder Xcode puts the app in. An app that was installed
# earlier cannot be told apart, and its build is recorded as "not recorded".
check_app_path() {
  BUILD="not recorded"
  [ -n "${APP_PATH:-}" ] || return 0
  [ -d "$APP_PATH" ] || refuse "APP_PATH does not exist or is not a directory: $APP_PATH"
  case "$APP_PATH" in
    *.app | *.app/) ;;
    *) refuse "APP_PATH must name an .app directory: $APP_PATH" ;;
  esac
  case "$APP_PATH" in
    *Release-iphonesimulator*) BUILD="Release" ;;
    *Debug-iphonesimulator*) BUILD="Debug" ;;
  esac
}

# Installs APP_PATH if it is set, and otherwise checks that the app is already on the simulator.
prepare_app() {
  if [ -n "${APP_PATH:-}" ]; then
    xcrun simctl install "$UDID" "$APP_PATH" || fail "could not install $APP_PATH on the simulator"
    say "installed $APP_PATH (build: $BUILD)"
  else
    if ! xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
      refuse "$BUNDLE_ID is not installed on the simulator: build it ('make app') and set APP_PATH to the .app"
    fi
    say "APP_PATH is not set: measuring the app that is already installed (build: $BUILD)"
  fi
}

# --- The lab -----------------------------------------------------------------------------------------------------------

lab_get() {
  curl -sS -f --max-time 5 "$SERVER_URL/v1/admin/lab"
}

lab_post() {
  curl -sS -f --max-time 5 -X POST -H 'Content-Type: application/json' -d "$1" "$SERVER_URL/v1/admin/lab"
}

# Sets the lab and keeps the settings the server confirmed. Jitter and dropped updates are put at their defaults too, so
# that a run is only what its label says.
configure_lab() {
  local request
  request="$(jq -cn --arg rate "$RATE" --argjson stress "$STRESS" --arg latency "$EXTRA_LATENCY_MS" \
    '{rateMultiplier: ($rate | tonumber), stress: $stress, extraLatencyMs: ($latency | tonumber),
      jitterMs: 0, dropUpdates: false}')"
  LAB_TOUCHED=1
  lab_post "$request" >/dev/null || fail "could not set the lab"
  CONFIRMED="$(lab_get)" || fail "could not read the lab back"
  say "lab asked for:       $request"
  say "lab the server holds: $(echo "$CONFIRMED" | jq -c .)"
  if ! jq -en --argjson asked "$request" --argjson held "$CONFIRMED" \
      '$asked | to_entries | all(.[]; $held[.key] == .value)' >/dev/null; then
    say "note: the server changed some of the values it was given (it clamps them); the run is labelled with the held ones"
  fi
}

reset_lab() {
  if lab_post "$LAB_DEFAULTS" >/dev/null 2>&1; then
    say "lab set back to its defaults: $(lab_get 2>/dev/null | jq -c . 2>/dev/null || echo 'could not read it back')"
  else
    echo "measure.sh: WARNING: could not set the lab back to its defaults; do it by hand: POST $SERVER_URL/v1/admin/lab $LAB_DEFAULTS" >&2
  fi
}

# --- The machine --------------------------------------------------------------------------------------------------------

# How much of the machine's CPU was idle over about a second, in percent, as `top` reports it; "null" when it cannot be
# read. It is taken just before the app is launched and just after it has been terminated, never during the run, so that
# the run's own numbers can be judged against what else the machine was doing.
cpu_idle_percent() {
  local idle
  idle="$(top -l 2 -s 1 -n 0 2>/dev/null | awk '/^CPU usage/ { line = $0 } END { print line }' \
    | sed -E 's/.* ([0-9.]+)% idle.*/\1/')" || idle=""
  if echo "$idle" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    echo "$idle"
  else
    echo "null"
  fi
}

# --- The app ------------------------------------------------------------------------------------------------------------

stop_app() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# Launches the app with its console attached to a file, waits DURATION seconds (or until the app exits) and terminates it.
# When the app is gone before the DURATION seconds are over, APP_EXITED_AT holds the seconds that had passed.
run_app() {
  local raw="$WORK_DIR/console.out" err="$WORK_DIR/console.err" elapsed=0 waited=0
  stop_app
  sleep 1
  say "launching $BUNDLE_ID on $DEVICE_NAME $OS_VERSION ($UDID) for $DURATION s"
  xcrun simctl launch --console "$UDID" "$BUNDLE_ID" --print-latency --open-symbol PTT >"$raw" 2>"$err" &
  LAUNCH_PID=$!

  while [ "$elapsed" -lt "$DURATION" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
      APP_EXITED_AT="$elapsed"
      say "the app exited after $elapsed s, before the run's $DURATION s were over"
      break
    fi
  done

  stop_app
  # simctl ends by itself once the app has gone and its output is written out; give it a little time, then stop it.
  while kill -0 "$LAUNCH_PID" 2>/dev/null && [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill "$LAUNCH_PID" 2>/dev/null || true
  fi
  wait "$LAUNCH_PID" 2>/dev/null || true
  LAUNCH_PID=""
  RAW_OUTPUT="$raw"
  RAW_ERRORS="$err"
}

# --- The result ---------------------------------------------------------------------------------------------------------

# Keeps the lines that start with '{' (simctl adds a line of its own that is not JSON) and checks every one of them: t,
# frames and hitches are numbers, and metrics holds each of the six metrics with a count, a clamped count and the three
# percentile keys (a percentile is null while the metric has no samples). Scripts/summarize.py reads exactly these.
collect_lines() {
  local lines="$WORK_DIR/lines.jsonl" number=0 line
  grep '^{' "$RAW_OUTPUT" >"$lines" || true
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if ! echo "$line" | jq -e --argjson names "$METRIC_NAMES" '
        (.t | type == "number") and (.frames | type == "number") and (.hitches | type == "number")
        and (.metrics | type == "object")
        and (. as $line | $names | all(.[]; . as $name | $line.metrics[$name]
          | type == "object" and (.count | type == "number") and (.clamped | type == "number")
            and has("p50Ns") and has("p95Ns") and has("p99Ns")))' >/dev/null 2>&1; then
      fail "line $number of the app's output is not a latency line: $line"
    fi
  done <"$lines"
  LINES_FILE="$lines"
  LINE_COUNT="$number"
}

write_results() {
  local symbols
  symbols="$(curl -sS -f --max-time 5 "$SERVER_URL/v1/symbols" | jq 'length')" || fail "could not read the symbol list"
  mkdir -p "$RESULTS_DIR"
  cp "$LINES_FILE" "$RESULTS_DIR/$LABEL.jsonl"
  jq -n --arg label "$LABEL" --arg build "$BUILD" --arg device "$DEVICE_NAME" --arg os "$OS_VERSION" \
    --argjson seconds "$DURATION" --argjson symbols "$symbols" --argjson lab "$CONFIRMED" \
    --arg startedAt "$STARTED_AT" --argjson idleBefore "$IDLE_BEFORE" --argjson idleAfter "$IDLE_AFTER" \
    '{label: $label, build: $build, device: $device, os: $os, seconds: $seconds, symbols: $symbols, lab: $lab,
      startedAt: $startedAt, cpuIdlePercentBeforeRun: $idleBefore, cpuIdlePercentAfterRun: $idleAfter}' \
    >"$RESULTS_DIR/$LABEL.run.json"
  say "kept $LINE_COUNT lines in docs/results/$LABEL.jsonl (run record: docs/results/$LABEL.run.json)"
}

# --- Leaving ------------------------------------------------------------------------------------------------------------

# Runs however the script ends. The lab is set back and the app terminated whatever happened; the raw console output is
# kept when the run failed, so that the failure can be looked at.
finish() {
  local status=$?
  trap - EXIT
  if [ -n "$LAUNCH_PID" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill "$LAUNCH_PID" 2>/dev/null || true
  fi
  if [ -n "$UDID" ]; then
    stop_app
  fi
  if [ "$LAB_TOUCHED" -eq 1 ]; then
    reset_lab
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    if [ "$status" -ne 0 ]; then
      say "the raw console output of the failed run is in $WORK_DIR"
    else
      rm -rf "$WORK_DIR"
    fi
  fi
  exit "$status"
}

main() {
  parse_arguments "$@"
  check_tools
  check_app_path
  check_server
  find_simulator
  prepare_app

  WORK_DIR="$(mktemp -d -t tradepulse-measure)"
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  configure_lab
  IDLE_BEFORE="$(cpu_idle_percent)"
  run_app
  IDLE_AFTER="$(cpu_idle_percent)"
  say "CPU idle before the run: $IDLE_BEFORE %, after it: $IDLE_AFTER % (whole machine, from top)"
  if [ -n "$APP_EXITED_AT" ]; then
    # The app went away before the script ended it, so what it printed is not a run of $DURATION s whatever its length.
    local captured
    captured="$(grep -c '^{' "$RAW_OUTPUT" || true)"
    echo "measure.sh: the app exited after $APP_EXITED_AT s of the $DURATION s run (latency lines captured: $captured);" \
      "the run is not recorded: docs/results/$LABEL.jsonl and docs/results/$LABEL.run.json are not written" >&2
    if [ -s "$RAW_ERRORS" ]; then
      echo "measure.sh: what the app wrote to its error output:" >&2
      head -n 20 "$RAW_ERRORS" >&2
    fi
    exit 1
  fi
  collect_lines

  if [ "$LINE_COUNT" -lt "$MIN_LINES" ]; then
    echo "measure.sh: only $LINE_COUNT latency lines were captured in $DURATION s, and $MIN_LINES are needed" >&2
    if [ -s "$RAW_ERRORS" ]; then
      echo "measure.sh: what the app wrote to its error output:" >&2
      head -n 20 "$RAW_ERRORS" >&2
    fi
    exit 1
  fi
  write_results
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
