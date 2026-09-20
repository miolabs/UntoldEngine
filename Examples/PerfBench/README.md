# PerfBench

A benchmark app for the engine on macOS, iOS and visionOS. It builds a fixed set of scenes one after
another, warms each up, records every frame through the engine's stats recorder, and writes one
JSON Lines file per scene plus a `summary.json` for the run. `scripts/perf/run_bench.sh` builds it,
runs it on a Mac or a paired device, collects the run folder and compares it with the stored
baseline for that device model.

The point is repeatability: the same scenes, the same drawable size, the same camera motion, the
engine stats and the GPU pass timer on, in a release build, so a number from before a change can be
compared with a number from after it.

## Scenes

| id | What it measures |
|---|---|
| `cube` | One lit, shadowed cube on a plane: the fixed per-frame cost of the pass chain, and the scene to judge image quality on a headset. |
| `primitives-1k` | 1024 individual cubes and spheres, 4 point lights, cascaded shadows: per-entity CPU cost and encoder overhead. |
| `primitives-10k` | 10 000 primitives merged by the static batcher: batched draw cost and light-loop cost at scale. |
| `lights-64` | 1024 batched primitives with 64 point lights: the per-pixel light loop. |
| `postfx` | The 1k grid with SSAO, bloom, depth of field and SMAA: the full-screen pass chain. |
| `animation-16` | 16 skinned characters running: the animation system and GPU skinning. |
| `stadium` | The stadium and grass assets: material binds and textures. |
| `gaussian` | A small Gaussian splat plus primitives: the splat cull, depth-key and radix-sort passes. |

Assets come from `Tests/UntoldEngineRenderTests/Resources`; the project copies the `Models` and
`Animations` folders and the splat file into the app bundle.

On macOS and iOS the camera orbits each scene (`BenchCameraOrbit`). On visionOS the head is the
camera, so the scenes are built three metres in front of the user and the orbit is ignored; keep
still during a run, or accept the head motion as part of the measurement.

Frames are display-paced on every platform (the display's maximum refresh rate on macOS and iOS,
the compositor on visionOS), so a scene that fits in a frame reports the refresh interval as its
frame time. Read the cost of such a scene from `meanGPUExecutionMs`, the per-pass GPU means and the
per-system CPU times in the snapshots; frame time and the over-budget count become the signal only
when a scene no longer fits. A frame counts as over budget when it took more than one and a half
refresh intervals, that is when a refresh was skipped.

## Running

```bash
brew install xcodegen                      # once

scripts/perf/run_bench.sh macos                                  # this Mac
scripts/perf/run_bench.sh visionos --device "Javier's Apple Vision Pro"
scripts/perf/run_bench.sh ios --device <udid>

scripts/perf/run_bench.sh macos --scenes primitives-1k,postfx --seconds 10
scripts/perf/run_bench.sh macos --update-baseline                # store this run as the baseline
scripts/perf/run_bench.sh visionos --device <udid> --xctrace "Metal System Trace"
```

Runs land in `perf/results/<timestamp>-<platform>/` with `<scene>.jsonl`, `summary.json` and the
console log. The comparison prints one block per scene and exits non-zero on a regression (10 %
on frame-time, GPU-time and per-system CPU metrics, 0.5 points on the over-budget and
missed-deadline rates, 20 % on a per-pass GPU minimum).

Single runs are noisy on a machine that idles most of each frame: CPU and GPU clocks drift between
runs and the same build can differ by 20 to 50 % in a per-pass or per-system time. `--repeat 3`
runs the scene set three times and the comparer aggregates by the minimum of each time metric (a
clock drift only ever inflates a time) and the mean of each rate; record the baseline the same way.
The CPU-bound scenes (`primitives-10k`) are the least noisy; for the others read
`timingMeanMs` and `gpuPassMinMs` rather than frame time.

The app can also be opened in Xcode (`xcodegen generate`, then `PerfBench.xcodeproj`) and started
from its Start button; it reads its configuration from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `UNTOLD_BENCH_SCENES` | Comma-separated scene ids, or `all` | `all` |
| `UNTOLD_BENCH_WARMUP` | Seconds rendered before recording, per scene | `3` |
| `UNTOLD_BENCH_SECONDS` | Seconds recorded per scene | `15` |
| `UNTOLD_BENCH_OUTPUT` | Output directory | `Documents/PerfBench` |
| `UNTOLD_BENCH_RUN_ID` | Run folder name | timestamp |
| `UNTOLD_BENCH_LABEL` | Free text stored in the summary | empty |
| `UNTOLD_BENCH_KEEP_OPEN` | `1` keeps the app open after the last scene | exit |
| `UNTOLD_BENCH_AUTOSTART` | `0` waits for the Start button | start on launch |
| `UNTOLD_BENCH_IMMERSION` | `full` or `mixed` (visionOS) | `full` |
| `UNTOLD_BENCH_PER_FRAME` | `0` writes one line per second instead of per frame | per frame |
| `UNTOLD_BENCH_AA` | `fxaa`, `smaa`, `msaa` or `none` for every scene (the post-FX scene keeps SMAA) | engine default, FXAA |

On a device the app exits when the run is done so that `devicectl ... --console` returns; the run
folder is then pulled from the app's Documents container. With the app opened from Xcode, set
`UNTOLD_BENCH_KEEP_OPEN=1` in the scheme to read the report on screen.

## What a run records

Every line of `<scene>.jsonl` is a full `EngineStatsSnapshot` (frame timing, per-system CPU time,
GPU pass times, culling, streaming, batching, memory, thermal state, compositor deadline margins on
visionOS, hitch histogram), and the last line is the `EngineStatsRecordingSummary` for the scene.
`summary.json` holds the device (model, OS, GPU), the render configuration (platform, viewport,
view count, texture layout, foveation, immersion) and every scene's summary and last snapshot.
See `docs/API/UsingProfiler.md` for the meaning of each field.

## Reading a regression

1. Frame p95/p99 up, GPU time flat: CPU-side. Open the run's `jsonl` and look at `timing`: which
   system grew (`animationMs`, `scenegraphMs`, ...), or `encodeMs` for draw submission.
2. GPU time up: `gpuPasses` says which pass. Reproduce the scene in the app from Xcode and take a
   GPU frame capture of that pass.
3. Missed deadlines up on visionOS with everything else flat: look at `compositor.inputSlackMs`
   (late update phase) and `timing.semaphoreWaitMs` (GPU pacing the CPU), then a Metal System
   Trace with `--xctrace`.
4. `worstThermalState` above 1: the device throttled; rerun cool before believing the numbers.
