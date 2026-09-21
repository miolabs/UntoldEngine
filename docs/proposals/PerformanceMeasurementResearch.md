# Engine Performance on macOS, iOS and visionOS — Measurement, Bottlenecks and Improvement Candidates (Research)

Status: research only, no implementation. Researched 2026-09-20 against the main engine worktree (`feature/morph_format`, tip `69756116`) with Xcode 27.0 (27A266a) and the visionOS 27.0 SDK on this Mac. Goal: make the engine faster on macOS, iOS and visionOS, with Vision Pro first. Two questions: how do we measure what a feature costs and find the bottleneck when a frame is slow (sections 1 to 4), and where does the code as it stands leave performance on the table (sections 5 and 6).

Progress (2026-09-20): phases A and B (section 4) are implemented on the fork branch `feature/perf_counters` (worktree `UntoldEngine-perf`, cut from `origin/develop`, draft PR miolabs/UntoldEngine#53): A1 compositor accounting, A2 GPU pass timer, A3 hitch histogram and JSON Lines recorder, A5 thermal and GPU memory, A6 runtime stats switch (D1 decided: runtime flag, on in debug, off in release, `UNTOLD_STATS=1`), A7 per-system signposts, B1 `Examples/PerfBench` (D2 decided: engine Examples) with seven scenes on macOS, iOS and visionOS, B2 `scripts/perf/run_bench.sh` and `compare_baseline.py`, B3 baselines under `perf/baselines/`. A4 (StateReporting) still waits on D3. First macOS runs of every scene succeeded; no headset run yet. Phase C (workflow docs) is partly done in `docs/API/UsingProfiler.md`.

First measurements (Mac16,5, M4 Max, 1920 × 1080, release, display-paced at 120 Hz), and what they taught:

- Two runs of the same build differ by 20 to 50 % in per-pass GPU and per-system CPU times when a scene fits in a frame: the machine idles most of the frame and its clocks drift. The remedy is in the tooling now: `--repeat N`, aggregation by the minimum of each time metric, per-pass GPU minimums instead of means, and per-system CPU means in the summary. Baselines and comparisons must use the same repeat count.
- The CPU-bound scene is the stable one and already shows where the time goes at scale. `primitives-10k` (10 000 batched primitives, 1016 batched draws) spends about 1.8 ms in update, of which 1.7 ms is the scene-graph walk (C9), about 4.3 ms in CPU-side culling (C8) and about 18 ms encoding (C2, C3, C11: per-entity locked scene copies and per-draw binding), against 4 ms of GPU time. The frame is CPU-bound three to one, on a desktop-class CPU.
- First Apple Vision Pro run (RealityDevice17,1, visionOS 27, dedicated layout, no foveation, full immersion, 2048 × 1984 per eye; baseline under `perf/baselines/RealityDevice17_1`): every scene missed the compositor deadline on almost every frame. Light scenes (animation-16, stadium, gaussian; 14 to 160 visible instances) are GPU-bound at 8.6 to 9.7 ms mean GPU time, all of it fixed per-frame cost of full-screen passes at two eyes: the Gaussian pass ran its tile stages and a depth copy with no splats (3.6 to 4.9 ms, now skipped in batch one), G-buffer + light 3.3 to 4.5 ms with a dozen draws, pre-composite 1.1, output transform 0.8 to 1.9, post-processing bypass 0.4 to 2.0, environment 0.5 to 1.0, HZB and depth copies about 1. Heavy scenes are CPU-bound: 24 ms of encode for 2671 draws (primitives-1k) and 48 ms for the 10k scene, about 9 µs per draw on the headset CPU, with the eye-dependent graph run twice. Thermal state stayed nominal; GPU allocation 0.9 to 1.2 GB of 4.2 GB available. Priorities confirmed: V1 foveation and V2 layered stereo for the GPU side, C2/C3/C11 and G3 for the encode side, and every full-screen pass at that resolution costs 0.5 to 1.3 ms per eye and needs a reason to exist.
- Second and third headset runs (2026-09-20, same session, device warming to thermal state "fair" by the third run): run-to-run noise on the headset is 0 to 10 % on mean GPU time and under 2 % on frame percentiles, so single runs are usable there. The batch-one build (Gaussian pass skipped) removed 0.7 to 1.4 ms of pass time per frame from every non-splat scene, but the frame-level gain was small (animation-16 mean GPU 9.3 to 8.9 ms, stadium 10.6 to 10.0 ms, deadline miss rate 98.5 to 96.5 % on animation-16): the remaining full-screen passes got slower by a similar amount (pre-composite minimum 1.2 to 1.8 ms) as the GPU gained slack, which reads as clock management. On a GPU-bound headset frame, removing one pass mostly lets the others stretch until the frame is again just over the deadline; the metric to watch is the miss rate and the deadline margin, and the light scenes still need 2 to 3 ms more, which is the environment, pre-composite, post-processing bypass and output-transform chain (four full-screen passes, 5 to 6 ms per frame at two eyes) and, after that, foveation.
- Fourth headset run (2026-09-20, MSAA via `UNTOLD_BENCH_AA=msaa`, batch-one build): the user still sees near objects shake and far edges shimmer, less than with FXAA. The numbers say why. Every light scene runs at exactly 90 Hz and still misses the deadline on 97 to 100 % of frames: cube 4.3 ms CPU submission + 9.4 ms GPU against a window of about 10.9 ms between `optimalInputTime` and `renderingDeadline` (measured as submission + GPU + margin on every scene: 10.8 to 10.95 ms, one display period), margin -2.8 ms; animation-16 -1.4; stadium -3.3; gaussian -6.5. Throughput only needs max(CPU, GPU) under 11.1 ms, but the deadline needs CPU submission + GPU inside one period, so with a 9 ms GPU frame the encode would have to take about 1 ms. Meanwhile the update phase ends 3 to 7 ms before `optimalInputTime` (`inputSlack`) and that time is thrown away. Two consequences were acted on: (1) `XRFramePacer` (commit c1f1b0c1 on `feature/perf_batch1`) starts the submission phase ahead of `optimalInputTime` by the measured miss plus a 1.5 ms target margin, bounded by the slack, trading pose age for on-time frames; it cannot fix scenes whose 2 × submission + GPU exceeds two periods (gaussian, the heavy scenes). (2) The device anchor was being queried at `presentationTime`; it is now queried at `trackableAnchorTime` as Compositor Services specifies (matters in mixed immersion). Also checked and excluded as causes: the output transform writes real reverse-Z scene depth into the compositor drawable (`OutputTransformShader.metal`, clamped to 1e-4 for the sky), the projection comes from `drawable.computeProjection`, and in MSAA mode the resolved depth reaches `depthMap`. Per-pass minimums with MSAA on the cube scene (two eyes): G-buffer+light 3.05 ms, pre-composite 2.03, output transform 0.90, environment 0.78, look 0.49, HZB copy+build 0.7. The `HZB Build Mip 0` mean (1.7 ms) versus its minimum (0.43) is the compute pass waiting on the preceding render pass's fragment tail at the stage boundary, not work. Next: commit the per-frame and first-eye work as their own command buffers so the GPU starts while the second eye is encoded (about 2 ms earlier start), then collapse pre-composite + look + output transform into one pass when no effect sits between them.
- Batch one's first commit (C7 pause flag, C16 lazy error names, C3-lite unfair lock; `feature/perf_batch1`, stacked on the counters branch) compared over three runs each against a three-run baseline: update, scene graph and culling CPU time down 13 to 16 % on the primitive scenes, the 10k scene's mean frame down 7 %; the light scenes are within noise. GPU time is judged by the fastest frame and the per-pass minimums from now on; the GPU mean follows the clock state, not the workload.

## TL;DR

1. **On visionOS the number that matters is the compositor deadline, not frames per second.** Every frame carries `optimalInputTime`, `renderingDeadline` and `presentationTime` (`LayerRenderer.Frame.Timing`). A good frame is submitted at the optimal input time and finished on the GPU before the deadline; anything else is reprojected and felt as judder. The XR loop waits for the input time but records nothing about the outcome. Recording deadline margin per frame is a one-day change and the first thing to build (A1).
2. **The engine has a usable CPU profiler and no usable GPU profiler.** Signposts, per-frame splits, draw counters and streaming diagnostics exist (section 2). GPU time is one number per command buffer, which on visionOS holds culling, Gaussian sorting, both eyes and the HZB build. Per-pass timestamps through `MTLCounterSampleBuffer` work on Apple GPUs at stage boundaries; a probe run today on this Mac confirms it (section 3.3). A pass timer in the render graph is the second thing to build (A2).
3. **Xcode covers the deep dives and most of it can be scripted.** RealityKit Trace shows deadline misses and the power envelope for any visionOS app, Metal System Trace shows per-encoder GPU time next to the engine's signposts, GPU frame capture gives per-draw cost, the shader profiler and Insights, and Metal GPU Counters names the limiter. `xctrace record` and `devicectl` run the Instruments part headless, so a benchmark on the paired headset can be automated. The simulator is only good for CPU-side and correctness work. On macOS and iOS the same tools apply, plus the Metal HUD, `metalperftrace` (macOS 27) and MetricKit frame-rate reports (iOS and macOS 27).
4. **The code survey found a small number of large, cheap wins that apply on every platform, and two configuration levers that dominate visionOS.** Every ECS access takes a recursive lock and copies the `Scene` struct, then takes a second lock to resolve the component type; the draw loop does this fifteen to twenty times per entity, per eye. The render graph is rebuilt, validated, sorted twice and compiled every frame, and twice per frame on visionOS. Skinning compute and animation sampling run for every character in the scene whether visible or not, and the animation pause check walks the entity's subtree with fresh allocations per frame. On visionOS foveation is off and the layout is `.dedicated`, so two full 2048 × 1984 eyes are shaded and the eye-dependent graph runs twice. Section 5 lists twenty-two candidates with evidence and expected gain; section 6 orders them.
5. **Measure first, then fix in that order.** Phase A counters (one week) give the numbers; the first optimization batch (ECS access, graph cache, visibility gates, scene-channel checks; one to two weeks) is low risk and platform-independent; the visionOS levers (foveation, layered stereo with vertex amplification; two to three weeks) come next because their gain is largest but their proof needs the counters; draw submission and lighting follow.

---

## 1. What "fast enough" means per platform

**visionOS (Apple Vision Pro).**
- Apple: "The system tries to render new frames for the Apple Vision Pro at 90 frames per second", and the rate can change with content and environment. At 90 Hz the frame is 11.1 ms and the app does not get all of it: the GPU must finish between `optimalInputTime` and `renderingDeadline`.
- The engine's loop (`Sources/UntoldEngineXR/UntoldEngineXR.swift`, `renderNewFrame()`) follows the contract: `queryNextFrame()` → `predictTiming()` → `startUpdate()` … `endUpdate()` → wait until `optimalInputTime` → `startSubmission()` → `queryDrawable()` (`queryDrawables()` from visionOS 26) → encode → `encodePresent` → `endSubmission()`. All the timestamps needed to measure the contract are already in hand.
- A missed deadline is a dropped frame, not a lower frame rate. RealityKit Trace colours frames green (well within), orange (barely), red (dropped). The steady-state metric is missed-deadline rate and p99 margin.
- Apple: keep the "System Power Impact" lane nominal "for as much time as possible"; sustained power triggers thermal mitigation and lower clocks. Benchmarks must run for minutes and in isolation.
- Immersion style changes the system's share: mixed (passthrough) costs the system GPU time, full does not. Both must be measured.
- Render quality (`LayerRenderer.renderQuality`, 0 to 1, visionOS 26) enlarges drawable textures when foveation is on; Apple's advice is to set `maxRenderQuality` to the minimum that looks right. Every measurement must record layout, foveation, render quality and texture size.
- Two GPUs: the M2 headset (Apple8, `RealityDevice14,1`) is the floor; the M5 headset (`RealityDevice17,1`) is faster. Both headsets paired with this Mac report `RealityDevice17,1`; an M2 has to be borrowed for floor baselines.

**macOS.**
- `MTKView` drives `draw(in:)` on the main thread; the engine caps it at `preferredFramesPerSecond = 60` (`Sources/UntoldEngine/Renderer/UntoldEngine.swift:59`) and sets `framebufferOnly = false` (line 61), which forbids the compositor's cheapest path for the drawable. The budget is 16.7 ms and the CPU shares the main thread with AppKit and the editor UI.
- Apple silicon Macs are the same tile-based deferred architecture as the headset, so the single-pass G-buffer + light pass with memoryless attachments is right on both; a macOS measurement of GPU pass costs is a fair proxy for iOS and a rough one for visionOS (same architecture, different clocks and resolution).

**iOS and iPadOS.**
- Templates cap at 60 Hz (`BuildSystem/BuildTemplates.swift:263, 675, 822`); ProMotion devices could run 120 Hz (decision D7). Thermal throttling arrives faster than on macOS; memory limits are hard (jetsam). MetricKit and the OS 27 Control Center performance trace give field data.

**Common budget rule.** Whatever the platform, the useful split is: CPU update, CPU submission (encode plus commit), GPU per pass, and on visionOS the deadline margin. Section 7 proposes numbers.

---

## 2. What the engine has today for measurement (main worktree, 2026-09-20)

| Piece | Where | What it gives | Limits |
|---|---|---|---|
| `EngineProfiler` | `Sources/UntoldEngine/Profiling/EngineProfiler.swift` | CPU frame ring buffer (2000 samples, mean, p95, p99, min, max), GPU command-buffer time from `gpuStartTime`/`gpuEndTime`, signpost scopes. Runtime toggle `enableEngineMetrics` or `UNTOLD_METRICS=1`. Works in release. | One GPU number per command buffer. No deadline data. No histogram, so a single 40 ms hitch vanishes into p99. |
| `EngineSignposts` | `Profiling/EngineSignposts.swift` | `os_signpost` intervals, subsystem `com.untoldengine.profiling`, categories Frame, Render, Culling, Streaming, Batching; scopes Frame, Update, RenderPrep, Encode, Submit, ShadowPass, Culling, StreamingRegion, GeometryStreaming, BatchingTick, BatchingRebuild. | Nothing per system inside Update (animation, physics, deformation, scripting) and nothing per render pass. |
| `EngineStatsMonitor` / `EngineStatsSnapshot` | `Profiling/EngineStatsMonitor.swift`, `EngineStatsSnapshot.swift` | Per-frame split (update, render prep, encode, submit, culling, streaming, batching), GPU execution and cadence, 30-frame smoothed CPU time, draw and triangle counts, culling and HZB state, streaming residency, batching scheduler, memory budgets; compact and verbose logging. | Compiled only with `ENGINE_STATS_ENABLED`, which `Package.swift` defines for debug builds only (lines 97 and 127). Not `Codable`. |
| `RenderStatsCollector` | `Profiling/RenderStatsCollector.swift` | Draw calls and triangles per category via the `drawIndexedPrimitivesTracked` wrappers. | Same compile-time gate. |
| XR loop instrumentation | `UntoldEngineXR.swift`, `executeXRSystemPass` | Culling, render prep, per-eye encode, submit and render ms; GPU ms from the completion handler; semaphore stall prints over 100 ms or 16 ms. | Stall time is printed, not recorded. `optimalInputTime` slack never stored; `renderingDeadline` and `presentationTime` never read. |
| Once-per-frame guards | `Renderer/RenderPasses.swift:1099, 1205, 1302, 1430`; `Systems/GraphBuilder.swift:931` | Shadow, deformation and other once-per-frame stages run for eye 0 only; culling, Gaussian depth and sort, HZB build run once per frame outside the eye loop. | The eye-dependent graph (G-buffer + light, SSAO, transparency, post) executes twice with separate encoders. |
| `GaussianProfiling` | `Profiling/GaussianProfiling.swift` | Splat counts, dispatches, resident bytes, elapsed ms per stage when the category log is on. | Log only. |
| `PerformanceTests` | `Tests/UntoldEngineRenderTests/PerformanceTest.swift` | Three macOS XCTest cases (GPU-synced average, profiler CPU stats, GPU stats), 17 ms budgets. | macOS only, one case skipped on CI, no `measure(metrics:)` anywhere in `Tests/`, no baselines, no per-feature scenes. |
| CI | `.github/workflows/ci-build-test.yml` | `swift test` on `macos-26`, render tests compared by PSNR. | No device, no perf gate beyond the 17 ms mean. |
| Docs | `docs/API/UsingProfiler.md` | Enabling metrics, reading every stats line, Instruments Points of Interest. | Nothing on GPU passes, deadlines, devices or regressions. |

Other facts that shape the plan: three command buffers in flight (`Utils/Globals.swift:1663`); no `ProcessInfo.thermalState` anywhere; Metal 3 only (no `MTL4` symbols); every visionOS app configures `layout = .dedicated`, `isFoveationEnabled = false`, `colorFormat = .bgra8Unorm_srgb` (`BuildSystem/BuildTemplates.swift:1255`, `UntoldArcade/HomeDesign/.../HomeDesignApp.swift:29`, CoolCloth and CoolWater); the XR viewport is hard-coded to 2048 × 1984 with a `**VERIFY THIS**` comment (`UntoldEngineXR.swift:114`) and corrected from the first drawable.

---

## 3. Apple's tools: what each one answers, and what a script can drive

### 3.1 Map

| Tool | Answers | Platforms | Scriptable |
|---|---|---|---|
| RealityKit Trace (Instruments) | Per-frame compositor deadline status, CPU vs GPU time per frame, System Power Impact, main-thread hangs. Works for Compositor Services apps: the frames come from the render server. | visionOS | `xctrace record --template 'RealityKit Trace'`, `xctrace export` |
| Metal System Trace | GPU timeline per command buffer and encoder, CPU encoding threads, display, GPU performance state, plus the engine's signpost lanes on one timeline. Apple, for Metal apps on visionOS: "the most useful tool will be the Metal System Trace template". Per-pass GPU time with no code change: encoder labels already name the passes. | all | same |
| Metal GPU Counters | Which unit limits a pass: ALU, texture, bandwidth, occupancy, tile memory. | device only | same |
| GPU frame capture (Metal debugger) | Per-draw and per-encoder GPU time, shader profiler per line, Performance report and Insights (redundant state, unneeded load/store, missing memoryless, occupancy), dependency graph. | all | capture from code with `MTLCaptureManager` to `.gputrace` (`MTL_CAPTURE_ENABLED=1` outside Xcode); reading is GUI |
| Time Profiler, CPU Profiler, CPU Counters, Processor Trace | CPU hot spots. Processor Trace is a full instruction trace on M4/A18 and later; unverified on the M5 headset. | all | `xctrace` |
| os_signpost instrument | The engine's scopes as intervals and Points of Interest. | all | `xctrace export` gives XML |
| Game Performance Overview (Xcode 27) | Aggregated Metal metrics plus Time Profiler for sessions of minutes or hours: thermal soak runs. | all | `xctrace` |
| Power Profiler (Xcode 26) | Energy, thermal state, per-core activity over time. | device | `xctrace` |
| Metal Performance HUD | Live fps, GPU time, present interval, memory, per-encoder GPU time; `MTL_HUD_LOG_ENABLED=1` logs once per second. | macOS, iOS, iPadOS, tvOS documented; visionOS unlisted, verify | `log stream` |
| StateReporting (OS 27) | Domains and states (scene, phase, quality) shown as Instruments tracks, in the HUD, aggregated by `metalperftrace`, and used by MetricKit to split frame rate. The visionOS 27 SDK header says `visionos(27.0)`. | all OS 27 | yes |
| `metalperftrace` (macOS 27) | Background trace of the last N hours, `overview --json` for scripts. | macOS | yes |
| MetricKit | Field data: hangs, crashes, energy; on iOS and macOS 27 a Metal frame-rate metric by StateReporting state. visionOS has received diagnostics but not performance metrics; OS 27 status unverified. | iOS, macOS; visionOS partial | daily reports |
| XCTest metrics | `measure(metrics:)` with `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric`, `XCTOSSignpostMetric(subsystem:category:name:)` over the engine's signposts. Baselines only inside Xcode; `swift test` compares nothing. | macOS, simulators | `swift test`, `xcodebuild test`; our own JSON baselines |
| visionOS simulator | Correctness, CPU-side regressions, API checks. GPU numbers are the Mac's, foveation unavailable. | n/a | `xcodebuild test -destination 'platform=visionOS Simulator,...'` |

### 3.2 A deep-dive order that works

1. RealityKit Trace (visionOS) or Metal System Trace (macOS, iOS) for two to three minutes: are deadlines or vsyncs missed, how often, is power nominal.
2. Metal System Trace with `UNTOLD_METRICS=1`: CPU-late (the `Encode` and `Submit` signposts end after the optimal input time) or GPU-late (the GPU track runs past the deadline). The encoder rows name the heaviest pass without new code.
3. GPU frame capture of one frame: Performance report and Insights first (they flag TBDR mistakes), then the shader profiler on the heaviest pass.
4. Metal GPU Counters on that pass to name the limiter.
5. Time Profiler or Processor Trace for CPU-late frames, looking first at the candidates in section 5.2.

### 3.3 Verified on this Mac today

- `xcrun xctrace list templates` includes RealityKit Trace, Metal System Trace, Game Performance, Game Performance Overview, Time Profiler, CPU Counters, Processor Trace, Power Profiler, os_signpost, Swift Concurrency, Game Memory.
- `xcrun xctrace list devices` lists "Javier's Apple Vision Pro (27.0)" and a second headset (26.6.1), both offline at the time; the two visionOS simulators (26.5 and 27.0) are booted. `xcrun devicectl list devices` shows the headset as "available (paired)".
- The visionOS 27 SDK ships `StateReporting.framework` (`visionos(27.0)`), `CompositorServices` with `cp_frame_timing_get_rendering_deadline`, `cp_layer_renderer_set_render_quality` and `cp_frame_query_drawables`, and `Metal` with `MTL4CounterHeap` tagged `macos(26.0), ios(26.0)` only. Do not plan on Metal 4 counters for the headset.
- `/usr/bin/metalperftrace` exists (macOS 27).
- A 60-line probe (`scratchpad/probe/probe.swift`, not committed) on the M4 Max: `supportsCounterSampling(.atStageBoundary)` true, draw, dispatch and blit boundaries false, `counterSets` is `["timestamp"]` only, sampled encoder time equals `gpuEndTime - gpuStartTime` for the same command buffer, GPU ticks equal nanoseconds. The reports of zeroed timestamps on macOS 26 concern Metal 4 command buffers; the Metal 3 path the engine uses is fine. Confirm once on the headset with the same probe.

---

## 4. Proposed measurement stack

### Phase A: engine-side counters that work in release (about one week)

**A1. Compositor frame accounting (one day).** In `renderNewFrame()` and `executeXRSystemPass()` record per frame: update-phase ms, slack when the wait for `optimalInputTime` begins (negative means late), submission encode ms, semaphore wait ms, GPU completion (`gpuEndTime` converted through `LayerRenderer.Clock` and the existing `compositorInstantToCATime`) against `renderingDeadline` and `presentationTime`, missed-anchor count, per-eye texture size. New `EngineTimingStats` fields (`xrUpdateMs`, `xrInputSlackMs`, `xrSubmitMs`, `xrSemaphoreWaitMs`, `xrDeadlineMarginMs`, `xrMissedDeadline`) and a `Compositor` signpost category (`Update`, `WaitForInput`, `Submission` intervals, `MissedDeadline` event). On macOS and iOS the equivalent is present interval versus `preferredFramesPerSecond` and the semaphore wait.

**A2. Per-pass GPU timing (two to three days).** A `GPUPassTimer` on `renderInfo`: one `MTLCounterSampleBuffer` per in-flight frame (timestamp set, `.shared`, two samples per pass), `makeRenderCommandEncoder(descriptor:label:)` and `makeComputeCommandEncoder(descriptor:label:)` helpers that set `sampleBufferAttachments[0]` (`startOfVertexSampleIndex`/`endOfFragmentSampleIndex` for render, `startOfEncoderSampleIndex`/`endOfEncoderSampleIndex` for compute) before creating the encoder, resolve in the completion handler one frame later into `[String: Double]` keyed by pass label. Passes in `RenderPasses.swift` and the systems create their own encoders, so the change is mechanical but touches every pass; the helper is a no-op when the timer is off. Report per-pass ms in the verbose stats and expose the dictionary in the snapshot.

**A3. Hitch accounting and export (one day).** Per-second counts of frames over the deadline and over budget, worst frame, a small log-scale histogram. Make `EngineStatsSnapshot` `Codable`; add `EngineStatsRecorder` writing JSON Lines per frame or per second into the app container, plus a summary at stop.

**A4. StateReporting domains (half a day).** Behind `#available(visionOS 27, macOS 27, iOS 27, *)`: `com.untoldengine.scene`, `com.untoldengine.phase` (`loading`, `streaming`, `steady`), `com.untoldengine.quality` (layout, foveation, render quality as stable metadata). Transitions at user-action cadence, as Apple asks.

**A5. Thermal and memory (half a day).** `ProcessInfo.thermalState` transitions as a signpost event and in the snapshot; `device.currentAllocatedSize` and `os_proc_available_memory()` sampled per second.

**A6. Make the stats available in release (decision D1).** Promote `ENGINE_STATS_ENABLED` to a runtime flag (measure the lock cost; expected well under 0.1 ms) or add a `profiling` configuration for the benchmark app. Without this every device measurement is of a debug build.

**A7. Per-system signposts (half a day).** `Animation`, `Deformation`, `Physics`, `Scripting`, `LOD`, `Scenegraph` intervals inside `Update`, so Instruments attributes CPU time to systems without Time Profiler symbolication.

### Phase B: a benchmark that can be re-run on all three platforms (about one and a half weeks)

**B1. `PerfBench` app (three to four days).** One SwiftUI app with macOS, iOS and visionOS targets (decision D2 on location) that loads a fixed set of scenes with no input: Starter, LargeSceneStreaming fly-through on a scripted camera path (the engine has `CameraPathTest` and `RemoteStreamFlyThroughTests`), a Gaussian scene, an animation-heavy scene exercising compiled samplers, the deformation pass and morph channels, and one "everything on" scene. Each runs N seconds after `AssetLoadingGate` clears, then the recorder writes JSON. Head motion cannot be scripted on the headset, so the path is fixed relative to the scene origin. On macOS the app renders both eyes offscreen at headset size for CPU-side comparisons only.

**B2. Driver script (two days).** `scripts/perf/run_bench.sh`: `xcodebuild` per platform, `xcrun devicectl device install app` and `device process launch --console` (or `xcrun simctl` / direct launch on macOS), optional `xcrun xctrace record --template 'Metal System Trace' --device <udid> --attach <pid>`, `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'` (and the GPU interval table) into XML, a Python parser that joins the engine JSON with the exported intervals into one CSV, `xcrun devicectl device copy from` for the JSON, and `compare_baseline.py` failing when p95 frame time, missed-deadline rate or any per-pass GPU ms regresses past a threshold against `perf/baselines/<device-model>/<scene>.json`. Every baseline records layout, foveation, render quality, texture size, OS build, engine commit and thermal state at start.

**B3. Gates (one day).** macOS CI switches `PerformanceTests` to `measure(metrics:)` with `XCTOSSignpostMetric` over `Frame` and `Encode` and compares against the JSON baseline. Headset and iPhone runs are manual or nightly; results land in `perf/results/` as JSON.

### Phase C: write the workflow down (one day)

Extend `docs/API/UsingProfiler.md` with the order in 3.2, the `xctrace` and `devicectl` commands, the new stats fields, and a feature-PR checklist: per-pass GPU ms and per-system CPU ms on the benchmark scenes, before and after, on device, in release.

---

## 5. Where the engine can get faster (candidates, with evidence)

Each item gives evidence (file:line in the main worktree), platforms, an expected gain, and how to confirm it. Gains are estimates from reading the code; the counters in phase A replace them. "Large" means several milliseconds or a double-digit percentage of the frame on a 1000-entity scene; "medium" about a millisecond; "small" below that but free.

### 5.1 visionOS configuration levers

| # | Candidate | Evidence | Expected gain | Confirm with |
|---|---|---|---|---|
| V1 | **Turn foveation on** where `capabilities.supportsFoveation`, and adopt `maxRenderQuality` / `renderQuality`. The compositor's rasterization rate map then shades most of each eye at reduced rate for free. | All apps set `isFoveationEnabled = false` (`BuildTemplates.swift:1256`, `HomeDesignApp.swift:30`). Engine must use `drawable.rasterizationRateMaps` and the map-aware viewport in every eye pass, and read post-process targets through the map. | Large on fragment-bound passes (light, SSAO, transparency, post): the shaded pixel count drops substantially. | A2 per-pass GPU ms before/after; RealityKit Trace deadline colours. |
| V2 | **`.layered` layout with vertex amplification**, one render graph execution per frame instead of one per eye. | `.dedicated` everywhere (`BuildTemplates.swift:1255`); `renderXR` runs the eye-dependent graph twice (`UntoldEngineXR.swift:810-850`, `Renderer/UntoldEngine.swift:838`). Prerequisite already scoped in `VirtualizedGeometryResearch.md`. | Large on CPU (halves encode work and the per-eye graph build) and medium on GPU (shared vertex work, fewer encoder boundaries). Required for progressive immersion and hover effects too. | `Encode` signpost, A2. |
| V3 | **Build the render graph once per frame, not once per eye** (see C1 below; on visionOS it is twice as bad). | `Systems/RenderingSystem.swift:165` inside the per-eye callback. | Medium CPU. | `Encode` split per eye. |
| V4 | **Lower the fixed 2048 × 1984 assumption** once V1 lands: sizeable resources should follow the drawable, and the quality value should be recorded in stats. | `UntoldEngineXR.swift:114` hard-coded viewport with `**VERIFY THIS**`. | Correctness of memory numbers. | A1 texture-size field. |

### 5.2 CPU hot paths (all platforms; visionOS pays them per eye)

| # | Candidate | Evidence | Expected gain | Confirm with |
|---|---|---|---|---|
| C1 | **Cache the compiled render graph** behind a signature (AA mode, post-FX toggles, immersion style, extension set, debug flags). Today `buildExecutableGameModeGraph()` runs every frame: a fresh builder, every extension's `buildGraph`, about forty String-keyed `RenderPass` values, two topological sorts with `Set<String>`, hazard scheduling and validation, ten `keys.sorted()` on Strings. Execution itself is a plain loop. | `Systems/RenderingSystem.swift:91` and `:165`; `:553-555` has no cache; `Systems/GraphBuilder.swift:1038, 1063, 1068, 1092, 1104, 1448-1450`; no `cachedGraph`/`graphDirty` symbol exists. | Medium: likely a few hundred microseconds per build, twice per frame on visionOS, all allocation-heavy. | Time Profiler on `buildGameModeGraphWithCompilation`; `Encode` signpost. |
| C2 | **Stop copying `Scene` under a recursive lock on every access.** The global `scene` getter locks `NSRecursiveLock` and returns the struct by value (four reference fields to retain and release); `renderInfo` (about thirty reference fields) and `textureResources` (about forty-five) do the same. `renderInfo` is read inside the per-mesh draw body. Replace with a borrow (`withScene { }`), or a `final class` held `unowned`, and hoist `renderInfo` reads out of loops. | `Utils/Globals.swift:72-78, 156-159, 240-243`; `Renderer/RenderPasses.swift:1698`; about 150 `renderInfo.` sites in `RenderPasses.swift`. | Large at scale: fifteen to twenty accesses per entity per frame per eye means tens of thousands of lock and refcount operations per frame at 1000 visible entities; plausibly one to three ms on the M2, more on iPhone. Also removes a contended lock between the render thread and loaders. | Time Profiler (look for `swift_retain`/`swift_release` and `NSRecursiveLock` under the draw loop). |
| C3 | **Resolve component ids statically.** `scene.get` calls `getComponentId`, which takes a second `NSLock` and hashes an `ObjectIdentifier` on every call; ids never change after registration. A per-type static (`enum ComponentID<T> { static let id }`) or a cached property removes it. | `ECS/Scenes.swift:187`; `ECS/ComponentPool.swift:44-49`. | Medium to large: same call count as C2. | Same. |
| C4 | **Make scene-channel visibility checks lock-free.** `renderMode(for:)` takes an `NSLock`, builds an array of raw channel values and `compactMap`s it, and is called twice per entity in every draw loop plus once per submesh; entities without a channels component fall back to building an entity-name String and two more `scene.get`. It is a bitmask test. | `Utils/SceneContextVisibility.swift:85-88, 123-124, 555-562`; call sites `RenderPasses.swift:1632-1633, 2099-2100, 3448-3449, 593-594`. | Medium: two locks and four allocations per entity per pass. | Time Profiler. |
| C5 | **Gate skinning compute on visibility.** The deformation pass encodes a dispatch for every entity with deformation, skeleton and render components, on or off screen; it also sorts morph weights per mesh per frame. Intersect with `visibleEntityIds` (plus shadow casters). | `Systems/DeformationSystem.swift:128-139, 389`. | Large in character-heavy scenes: GPU and CPU for every off-screen character. | A2 `Deformation Pass` ms vs visible character count. |
| C6 | **Gate animation sampling on visibility or distance**, with a cheap "keep animating but skip pose/IK" tier for off-screen characters. Clip sampling, root motion, blending, foot IK, `updateWorldPose` and `updateJointMatrices` run for all animated entities. | `Systems/AnimationSystem.swift:146-148, 232, 240`. | Large in the same scenes. | A7 `Animation` signpost. |
| C7 | **Read the pause flag directly.** `isAnimationComponentPaused` walks the entity's subtree recursively, allocating a `Set` and an array per node with a `scene.get` per node, per animated entity per frame, to read one `Bool` the loop already holds. | `Systems/AnimationSystem.swift:165, 308, 78-79, 49-71, 111-112`. | Medium, and it removes an allocation storm. | A7. |
| C8 | **Cache AABBs for GPU culling.** Both culling paths walk every renderable entity on the CPU each frame with five locked scene accesses and a heap array per entity to rebuild the upload; the GPU only saves the plane tests. Keep a persistent AABB buffer updated from transform dirty flags and residency events. | `Systems/CullingSystem.swift:613-668` and `:942-981`; `:163, 171`. | Large for streaming scenes with tens of thousands of entities. | `Culling` signpost, `cullingMs`. |
| C9 | **Index the scene graph by level and keep a dirty queue.** When anything moves, `traverseSceneGraph` scans all entities to find the maximum level, then rescans all entities once per level. | `Systems/ScenegraphSystem.swift:212-223, 200-209`. | Medium to large in deep or large hierarchies with any motion. | A7 `Scenegraph`. |
| C10 | **Cache packed light buffers and cull lights.** Point, spot and area lights are re-queried from the ECS, rebuilt and re-uploaded every frame per eye with no frustum or range culling; `maxCount: 1024` is passed although `maxNumPointLights` is 100. | `Renderer/RenderPasses.swift:2370, 2379, 2388`; `Systems/LightingSystem.swift:750-793, 858, 1034-1080`; `Utils/Globals.swift:28`. | Small to medium CPU; enables G1. | A7, Time Profiler. |
| C11 | **Reduce scene touches in the draw loop.** About fourteen to eighteen locked scene accesses per entity, four per mesh, two per submesh (channels, LOD fade, tile fade, camera, render, transforms, gizmo and light checks, deformation and skeleton lookups). Prepare a per-frame draw list once (after culling) with the component references resolved, and iterate that in every pass. | `Renderer/RenderPasses.swift:1629-1673` (duplicated at `:2097-2115`); `Renderer/RenderVertexStreamBinding.swift:95, 112`. | Large combined with C2 and C3; also removes the duplicated loop. | Time Profiler. |
| C12 | **Shadow caster filtering once per frame, not per cascade.** The candidate cache is dirty-gated, but each of the three cascades re-filters every candidate with two channel queries and three `scene.get`; spot and point paths repeat the shape. | `Renderer/RenderPasses.swift:591-604, 650, 707`. | Small to medium. | `ShadowPass` signpost. |
| C13 | **Physics: fetch components once per body per step.** Six helpers each re-fetch their components, about twelve `scene.get` per body, up to five fixed steps per frame. | `Systems/PhysicsSystem.swift:103-114, 123-154, 413-427`; `Renderer/UntoldEngine.swift:634-647`. | Medium when bodies are numerous. | A7 `Physics`. |
| C14 | **Transparent list: reserve and avoid class-reference tuples.** Rebuilt and sorted per frame per eye with retains per append. | `Renderer/RenderPasses.swift:3444, 3491`. | Small. | Time Profiler. |
| C15 | **ECS queries allocate three collections per call**, and about ten full queries run per frame (culling twice, animation, physics up to five, lights three, deformation, LOD, Gaussian twice even with no splats). Cache query results per frame keyed by component set, or keep per-archetype entity lists. | `ECS/Scenes.swift:257-271`; `Systems/GaussianSystem.swift:89-90, 362`. | Medium. | Time Profiler. |
| C16 | **Error paths build Strings eagerly.** `handleError(_:_:)` formats the entity name before the log-level gate; it sits on per-entity paths in the draw loop and culling. | `Systems/ErrorHandlingSystem.swift:280-281`; `RenderPasses.swift:1648-1658`; `CullingSystem.swift:620-636`. | Small, free. | n/a |
| C17 | **Scripts: pre-resolve event names and variables.** The USC interpreter scans instructions with String compares per script per entity per frame and stores variables in `[String: Value]`. | `Systems/USCSystem.swift:86, 196-203`; `Scripting/USCInterpreter.swift:61-68, 114`. | Medium when many scripted entities. | A7 `Scripting`. |
| C18 | **Extension and custom-system lists rebuilt per call.** `compactMap` over the order arrays per frame per eye and per fixed step. | `Renderer/RenderExtensions.swift:2476, 2301, 2307`; `ECS/Scenes.swift:389`. | Small. | n/a |

### 5.3 GPU and Metal submission (all platforms)

| # | Candidate | Evidence | Expected gain | Confirm with |
|---|---|---|---|---|
| G1 | **Light culling.** The TBDR light pass loops over every point light (cap 1024) and every spot light per pixel, with no tile or cluster lists; transparency does the same. On Apple GPUs a tile shader or a compute-built cluster grid keeps the per-pixel loop to the lights that touch the tile. | `Shaders/LightShader.metal:703-704, 725`; `Shaders/TransparencyShader.metal:107, 122`; `Shaders/ShadersUtils.h:44-48`. | Large in scenes with more than a handful of lights; none with one light. | A2 `G-Buffer + Light Pass (TBDR)` ms vs light count; GPU Counters (ALU limited). |
| G2 | **Shadow filtering cost.** Sixteen-tap Poisson PCF per pixel on the selected cascade at 2048² per cascade, three cascades, plus spot and point paths with the same kernel. Options: fewer taps at distance, hardware 2×2 compare with fewer taps, cascade resolution per platform. | `Shaders/LightShader.metal:19, 69-70, 124-125, 208`; `Utils/Globals.swift:326`. | Medium on the light pass; large on iPhone. | A2, shader profiler. |
| G3 | **Draw submission: sort by material, track bound state, instance repeats.** Six texture/sampler binds and three `setFragmentBytes` per submesh with no redundancy filtering; `Uniforms` (about 320 bytes) pushed twice per mesh; six vertex buffers rebound per mesh; instancing exists only for Gaussian splats; no indirect command buffers. Static batching already merges geometry; the remaining per-draw overhead is CPU encode time. | `Renderer/RenderPasses.swift:1700-1708, 1723-1784, 4503`; `Renderer/RenderVertexStreamBinding.swift:25-54, 101-119`. | Medium CPU on every platform; scales with draw count. | `Encode` signpost vs draw count; Metal System Trace encoder CPU time. |
| G4 | **Drop the depth copy for HZB.** A full-resolution blit copies opaque depth into an HZB source texture every frame; the first HZB mip could read the depth texture directly (it is stored anyway for the compositor) or the copy could be fused into the mip-0 downsample. | `Renderer/RenderPasses.swift:476-497`; `Systems/CullingSystem.swift:366, 434`. | Small to medium bandwidth, per frame; per eye once V2 lands. | A2 `Copy Opaque Depth for HZB`. |
| G5 | **Reconstruct position from depth instead of an `rgba16Float` position attachment.** The G-buffer keeps a 64-bit position target in tile memory alongside albedo, normal, material, emissive and 16-bit scene colour. Memoryless keeps it off DRAM, but tile memory per pixel bounds occupancy and the tile size the GPU can use. | `Renderer/ColorPipelineConfig.swift:48-53` (`gBufferPosition: .rgba16Float`); `Renderer/RenderInitializer.swift:594-650`. | Small to medium on occupancy-limited passes; measurable only with GPU Counters. | GPU Counters (occupancy), A2. |
| G6 | **SSAO chain.** Sixteen samples plus low-res, blur and upsample passes; half-resolution and fewer samples on visionOS with foveation, or temporal reuse. | `Shaders/SSAOShader.metal:53-57`; passes `SSAO Low-Res`, `SSAO Blur`, `SSAO Upsample`. | Medium when SSAO is on. | A2. |
| G7 | **macOS drawable.** `framebufferOnly = false` on the view disables the compositor's direct path; if it exists for picking or tests, gate it. | `Renderer/UntoldEngine.swift:61`; `BuildTemplates.swift:265, 1654`. | Small, macOS only. | Metal HUD present mode. |
| G8 | **Per-frame `MemoryBudgetManager.markUsed`** probes a dictionary per visible entity on the completion thread; a per-frame stamp on the draw list is cheaper. | `Systems/RenderingSystem.swift:131`; `Systems/MemoryBudgetManager.swift:366-368`. | Small. | n/a |

### 5.4 Already right (leave alone)

Memoryless G-buffer and MSAA targets with single-pass tile lighting (`RenderInitializer.swift:594-700`, `LightShader.metal:626-635`); pipeline and depth-state creation confined to init or memoized (`RenderPasses.swift:106-157`); lazy G-buffer and sample-count reallocation (`RenderInitializer.swift:159, 567`); IBL prefilter runs at environment load, not per frame (`Utils/FuncUtils.swift:362`); post effects all off by default and gated (`RenderingSystem.swift:602-637`); LOD selection gated by interval and camera displacement (`Systems/LODSystem.swift:43-50`); streaming and texture streaming interval gates; the shadow-candidate cache; per-frame visible-set snapshots; `Logger` bodies behind `@autoclosure` gates.

---

## 6. Recommended order

1. **Phase A counters** (one week). Without A1 and A2 nothing below can be proven, and the benchmark scenes need them.
2. **Batch one, platform-independent and low risk** (one to two weeks): C2, C3, C4, C7, C5, C6, C1, C16. All are local changes with obvious correctness; together they remove most per-entity locking and allocation from the frame and the per-frame graph rebuild. Expect the biggest CPU improvement per day of work here.
3. **visionOS levers** (two to three weeks): V1 foveation with render quality, then V2 layered stereo with vertex amplification (which also delivers V3). Largest GPU gain on the headset and the prerequisite for progressive immersion, hover effects and the virtualized-geometry work.
4. **Batch two, structural CPU** (two to three weeks): C11 draw list, C8 AABB cache, C9 scene-graph index, C15 query caching, C10 light cache, C13 physics.
5. **GPU work** (as measurements dictate): G1 light culling if scenes have many lights, G2 shadow filtering per platform, G3 submission ordering and state tracking, G4, G5, G6.
6. **Continuous**: every feature PR carries A2 pass numbers and A7 system numbers on the benchmark scenes, in release, on device.

---

## 7. Provisional budgets (to be replaced by measurements)

| Platform | Frame | GPU total | CPU update | CPU submit | Other |
|---|---|---|---|---|---|
| visionOS, 90 Hz, both eyes, M2 | 11.1 ms | under 8 ms | under 3 ms | under 2 ms | missed deadlines under 1 in 1000; semaphore wait 0; thermal never `.serious` over 20 min |
| iOS, 60 Hz (120 Hz optional, D7) | 16.7 ms | under 10 ms | under 4 ms | under 2 ms | thermal never `.serious` over 20 min |
| macOS, 60 Hz cap | 16.7 ms | under 10 ms | under 4 ms | under 2 ms | main thread free for UI |
| Per new feature | | under 0.5 ms | under 0.3 ms | | or a written justification |

---

## 8. Open decisions

- **D1.** Runtime stats flag in release, or a dedicated profiling build configuration (A6).
- **D2.** Where `PerfBench` lives: engine `Examples/`, or an Arcade package.
- **D3.** Adopt StateReporting now (OS 27 only, engine minimum is visionOS 2) behind availability checks, or wait.
- **D4.** Benchmark default immersion style on visionOS (both recorded, one gates).
- **D5.** Keep `EngineProfiler` and `EngineStatsMonitor` separate, or fold the ring buffers into the monitor once A3 adds histograms.
- **D6.** When an M2 headset can be borrowed for floor baselines.
- **D7.** Allow 120 Hz on ProMotion iPhones and iPads, or keep the 60 Hz cap for battery.
- **D8.** ECS access refactor shape for C2: a borrow API around the existing struct, or `Scene` as a final class. The borrow keeps the public API; the class changes value semantics that tests may rely on.
- **D9.** Whether to keep the `rgba16Float` position attachment (G5) once GPU Counters show whether the light pass is occupancy-limited.

---

## 9. Key references

- Apple, "Analyzing the performance of your visionOS app": https://developer.apple.com/documentation/visionos/analyzing-the-performance-of-your-visionos-app
- WWDC23 "Meet RealityKit Trace": https://developer.apple.com/videos/play/wwdc2023/10099/
- WWDC23 "Discover Metal for immersive apps": https://developer.apple.com/videos/play/wwdc2023/10089/
- WWDC24 "Render Metal with passthrough in visionOS": https://developer.apple.com/videos/play/wwdc2024/10092/
- WWDC25 "What's new in Metal rendering for immersive apps": https://developer.apple.com/videos/play/wwdc2025/294/
- WWDC26 "Find and fix performance issues in your Metal games": https://developer.apple.com/videos/play/wwdc2026/388/
- WWDC26 "Meet the new MetricKit": https://developer.apple.com/videos/play/wwdc2026/222/
- Apple, `LayerRenderer.Frame.Timing`: https://developer.apple.com/documentation/compositorservices/layerrenderer/frame/timing
- Apple, GPU counters and counter sample buffers: https://developer.apple.com/documentation/metal/gpu-counters-and-counter-sample-buffers
- Apple, `MTLCounterSamplingPoint.atStageBoundary`: https://developer.apple.com/documentation/metal/mtlcountersamplingpoint/atstageboundary
- Apple, Metal Performance HUD: https://developer.apple.com/documentation/xcode/gaining-performance-insights-with-metal-performance-hud and https://developer.apple.com/documentation/Xcode/Monitoring-your-Metal-apps-graphics-performance
- Apple, StateReporting: https://developer.apple.com/documentation/StateReporting/getting-started-with-statereporting
- Apple, Processor Trace: https://developer.apple.com/documentation/xcode/analyzing-cpu-usage-with-processor-trace
- `xctrace(1)` man page: https://keith.github.io/xcode-man-pages/xctrace.1.html
- wgpu issue on zeroed `MTLCounterSampleBuffer` timestamps under Metal 4 on macOS 26: https://github.com/gfx-rs/wgpu/issues/9414
- Practical notes on Compositor Services rendering: https://github.com/gnikoloff/drawing-graphics-on-apple-vision-with-metal-rendering-api
- Engine docs this note builds on: `docs/API/UsingProfiler.md`, `docs/Architecture/xrRenderingSystem.md`, `docs/proposals/VirtualizedGeometryResearch.md`
