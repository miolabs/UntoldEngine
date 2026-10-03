#!/usr/bin/env bash
#
# Builds and runs Examples/PerfBench on macOS, an iOS device or an Apple Vision Pro, collects the
# run folder (JSON Lines per scene plus summary.json) and compares it against the stored baseline.
#
# Usage:
#   scripts/perf/run_bench.sh macos   [options]
#   scripts/perf/run_bench.sh ios     --device <udid|name> [options]
#   scripts/perf/run_bench.sh visionos --device <udid|name> [options]
#
# Sessions (--session NAME) bundle the options for the three ways the benchmark is used:
#   quick   four scenes (cube, primitives-1k, animation-16, stadium), 10 s each, three repeats,
#           compared against the baseline. About three minutes: the one to run for every change.
#   locks   the engine built with ENGINE_LOCK_DIAGNOSTICS, on primitives-1k and the three lock
#           scenes (public API calls, loading, a second thread), two repeats, judged on lock calls
#           and lock wait time per frame against the lock baseline.
#   full    every scene, three repeats, then the locks session. With --update-baseline it refreshes
#           both baselines.
# An option given explicitly wins over what the session sets.
#
# Options:
#   --session NAME        quick, locks or full (see above)
#   --scenes a,b,c        scene ids (default: all)
#   --seconds N           recorded seconds per scene (default: 15)
#   --warmup N            warm-up seconds per scene (default: 3)
#   --out DIR             where run folders land (default: perf/results)
#   --label TEXT          stored in summary.json (default: git describe)
#   --config Debug|Release (default: Release)
#   --repeat N            run the whole scene set N times and aggregate (minimum of each time and rate)
#   --refresh N           macOS: run on a connected display whose maximum refresh rate is N Hz
#                         (default: the fastest connected display). Baselines are keyed by the rate.
#   --xctrace TEMPLATE    also record an Instruments trace, e.g. "Metal System Trace" (device runs)
#   --lock-diagnostics    build the engine with ENGINE_LOCK_DIAGNOSTICS: every engine lock is counted
#                         and timed, and each scene reports lock calls, contention, wait and hold
#                         time. Frame times of such a build are not comparable with a normal one;
#                         the run is compared against the lock baseline, on its lock numbers only.
#   --no-compare          skip the baseline comparison
#   --update-baseline     write this run as the new baseline for the device model
#
# Requirements: xcodegen (brew install xcodegen), Xcode with the platform SDKs, a paired device for
# device runs (xcrun devicectl list devices).

set -euo pipefail

PLATFORM="${1:-}"
[ -n "$PLATFORM" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2; }
shift

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_DIR="$REPO/Examples/PerfBench"
OUT_DIR="$REPO/perf/results"
BASELINES="$REPO/perf/baselines"
SCENES="all"
SECONDS_PER_SCENE=15
WARMUP=3
LABEL="$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo unknown)"
CONFIG=Release
DEVICE=""
XCTRACE_TEMPLATE=""
LOCK_DIAGNOSTICS=0
COMPARE=1
UPDATE_BASELINE=0
REPEAT=1
REFRESH=""
SESSION=""
SCENES_SET=0
SECONDS_SET=0
REPEAT_SET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --scenes) SCENES="$2"; SCENES_SET=1; shift 2 ;;
    --seconds) SECONDS_PER_SCENE="$2"; SECONDS_SET=1; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; REPEAT_SET=1; shift 2 ;;
    --refresh) REFRESH="$2"; shift 2 ;;
    --xctrace) XCTRACE_TEMPLATE="$2"; shift 2 ;;
    --lock-diagnostics) LOCK_DIAGNOSTICS=1; shift ;;
    --no-compare) COMPARE=0; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

case "$SESSION" in
  "") ;;
  quick)
    [ "$SCENES_SET" = 1 ] || SCENES="cube,primitives-1k,animation-16,stadium"
    [ "$SECONDS_SET" = 1 ] || SECONDS_PER_SCENE=10
    [ "$REPEAT_SET" = 1 ] || REPEAT=3
    ;;
  locks)
    LOCK_DIAGNOSTICS=1
    [ "$SCENES_SET" = 1 ] || SCENES="primitives-1k,locks-api,locks-loading,locks-threads"
    [ "$SECONDS_SET" = 1 ] || SECONDS_PER_SCENE=10
    [ "$REPEAT_SET" = 1 ] || REPEAT=2
    ;;
  full)
    # Two passes with their own builds: every scene in a normal build, then the locks session.
    COMMON=(--out "$OUT_DIR" --config "$CONFIG" --label "$LABEL")
    [ -z "$DEVICE" ] || COMMON+=(--device "$DEVICE")
    [ -z "$REFRESH" ] || COMMON+=(--refresh "$REFRESH")
    [ "$UPDATE_BASELINE" = 0 ] || COMMON+=(--update-baseline)
    [ "$COMPARE" = 1 ] || COMMON+=(--no-compare)
    STATUS=0
    "$0" "$PLATFORM" --repeat "$([ "$REPEAT_SET" = 1 ] && echo "$REPEAT" || echo 3)" "${COMMON[@]}" || STATUS=$?
    "$0" "$PLATFORM" --session locks "${COMMON[@]}" || STATUS=$?
    exit "$STATUS"
    ;;
  *) echo "session must be quick, locks or full"; exit 2 ;;
esac

RUN_ID="$(date +%Y%m%d-%H%M%S)-$PLATFORM"
DERIVED="$BENCH_DIR/.build/DerivedData"
EXTRA_BUILD_SETTINGS=()
if [ "$LOCK_DIAGNOSTICS" -eq 1 ]; then
  # A separate build folder, so switching modes does not rebuild the engine each time. A build
  # setting given on the command line reaches the engine package's targets as well.
  DERIVED="$BENCH_DIR/.build/DerivedData-lockdiag"
  EXTRA_BUILD_SETTINGS+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ENGINE_LOCK_DIAGNOSTICS')
fi
mkdir -p "$OUT_DIR"

case "$PLATFORM" in
  macos)    SCHEME="PerfBench-macOS";    DESTINATION="platform=macOS,arch=arm64" ;;
  ios)      SCHEME="PerfBench-iOS";      [ -n "$DEVICE" ] || { echo "--device is required for ios"; exit 2; }; DESTINATION="id=$DEVICE" ;;
  visionos) SCHEME="PerfBench-visionOS"; [ -n "$DEVICE" ] || { echo "--device is required for visionos"; exit 2; }; DESTINATION="id=$DEVICE" ;;
  *) echo "platform must be macos, ios or visionos"; exit 2 ;;
esac

echo "== Generating project"
(cd "$BENCH_DIR" && xcodegen generate --quiet)

echo "== Building $SCHEME ($CONFIG)"
xcodebuild build \
  -project "$BENCH_DIR/PerfBench.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  ${EXTRA_BUILD_SETTINGS[@]+"${EXTRA_BUILD_SETTINGS[@]}"} \
  -quiet

SUMMARIES=()
for ((REP = 1; REP <= REPEAT; REP++)); do
if [ "$REPEAT" -gt 1 ]; then RUN_ID="$(date +%Y%m%d-%H%M%S)-$PLATFORM-r$REP"; echo "== Repeat $REP of $REPEAT"; fi
case "$PLATFORM" in
  macos)
    APP="$DERIVED/Build/Products/$CONFIG/PerfBench.app"
    echo "== Running $APP"
    UNTOLD_BENCH_SCENES="$SCENES" UNTOLD_BENCH_SECONDS="$SECONDS_PER_SCENE" UNTOLD_BENCH_WARMUP="$WARMUP" \
    UNTOLD_BENCH_OUTPUT="$OUT_DIR" UNTOLD_BENCH_RUN_ID="$RUN_ID" UNTOLD_BENCH_LABEL="$LABEL" \
    UNTOLD_STATS=1 UNTOLD_GPU_PASS_TIMING=1 UNTOLD_BENCH_REFRESH="$REFRESH" \
      "$APP/Contents/MacOS/PerfBench" | tee "$OUT_DIR/$RUN_ID.log" | grep -v "^PERFBENCH_SUMMARY_JSON"
    ;;

  ios|visionos)
    if [ "$PLATFORM" = ios ]; then
      APP="$DERIVED/Build/Products/$CONFIG-iphoneos/PerfBench.app"; BUNDLE_ID="com.untoldengine.perfbench.ios"
    else
      APP="$DERIVED/Build/Products/$CONFIG-xros/PerfBench.app"; BUNDLE_ID="com.untoldengine.perfbench.visionos"
    fi
    echo "== Installing on $DEVICE"
    xcrun devicectl device install app --device "$DEVICE" "$APP" --quiet
    ENV_JSON=$(printf '{"UNTOLD_BENCH_SCENES":"%s","UNTOLD_BENCH_SECONDS":"%s","UNTOLD_BENCH_WARMUP":"%s","UNTOLD_BENCH_RUN_ID":"%s","UNTOLD_BENCH_LABEL":"%s","UNTOLD_STATS":"1","UNTOLD_GPU_PASS_TIMING":"1"}' \
      "$SCENES" "$SECONDS_PER_SCENE" "$WARMUP" "$RUN_ID" "$LABEL")
    TRACE_PID=""
    if [ -n "$XCTRACE_TEMPLATE" ]; then
      TRACE="$OUT_DIR/$RUN_ID.trace"
      echo "== Recording '$XCTRACE_TEMPLATE' to $TRACE"
      xcrun xctrace record --template "$XCTRACE_TEMPLATE" --device "$DEVICE" --output "$TRACE" \
        --launch -- "$BUNDLE_ID" >"$OUT_DIR/$RUN_ID.xctrace.log" 2>&1 &
      TRACE_PID=$!
      echo "   (xctrace launched the app; environment is taken from the DEVICECTL defaults, use the app's Start button if it did not autostart)"
    else
      echo "== Launching $BUNDLE_ID (console attached until the app exits)"
      xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
        --environment-variables "$ENV_JSON" "$BUNDLE_ID" | tee "$OUT_DIR/$RUN_ID.log" | grep -v "^PERFBENCH_SUMMARY_JSON" || true
    fi
    if [ -n "$TRACE_PID" ]; then
      wait "$TRACE_PID" || true
    fi
    echo "== Copying results"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/PerfBench/$RUN_ID" --destination "$OUT_DIR/$RUN_ID" --quiet || {
        echo "   copy failed; the run may still be on the device under Documents/PerfBench/$RUN_ID"; }
    ;;
esac

RUN_DIR="$OUT_DIR/$RUN_ID"
[ -f "$RUN_DIR/summary.json" ] || { echo "no summary.json in $RUN_DIR"; exit 1; }
echo "== Results: $RUN_DIR"
SUMMARIES+=("$RUN_DIR/summary.json")
done

if [ "$UPDATE_BASELINE" = 1 ]; then
  python3 "$REPO/scripts/perf/compare_baseline.py" "${SUMMARIES[@]}" --baselines "$BASELINES" --update
elif [ "$COMPARE" = 1 ]; then
  python3 "$REPO/scripts/perf/compare_baseline.py" "${SUMMARIES[@]}" --baselines "$BASELINES"
fi
