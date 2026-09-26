# Profiler

UntoldEngine profiling has two layers that are meant to be used together:

1. **Structured metrics** (stable numbers for trends and regressions)
2. **Category logs** (on-demand narrative traces for deep debugging)

Use structured metrics as the source of truth, then enable category logs only when you need extra context.

## Quick Start

Enable the profiler at runtime:

```swift
setEngine(.metrics(.enabled))
```

Or via environment variable:

```bash
export UNTOLD_METRICS=1
./YourApp
```

Enable periodic frame stats logging:

```swift
setEngineStatsLogging(
    enabled: true,
    profile: .compact,    // or .verbose
    intervalSeconds: 1.0
)
```

### Verbose output format

With `profile: .verbose`, the engine logs a multi-line snapshot every interval:

```
Frame 1234 | CPU 12.34ms (81.0 fps, smoothed)  GPU 8.45ms exec / 90.0 fps cadence  [GPU-bound]
Timing: frame 12.34ms (raw CPU) | update 1.23ms | render 8.45ms | cull 0.45ms | stream 2.34ms | batchTick 0.12ms | batchRebuild 0.00ms
Systems: scenegraph 0.05ms | extensions 0.02ms | lod 0.10ms | animation 0.60ms | scripting 0.01ms | physics 0.30ms (1 steps) | custom 0.00ms | game 0.12ms | semWait 0.00ms
Render: draws 45 (opaque 32, transparent 3, shadow 8, batched 28) | triangles 125000 | visible 89
Culling: frustum 234/512 failed 278 | occlusion 198/234 failed 36 | usedHZB true validHZB true
Streaming: loaded 847 loading 3 unloaded 12 | active 3 | nearby 124 candidates 5 slots 4 | backlog 0 | pendingUploads 3 | gateMs 0.00
Streaming: tick=true workMs 1.23 | evictions 0 | avgLoadMs 45.67 | applyMs 0.89 | tileSwapWarn 0 | repGap 0 | lod0VisWarn 0 covered 0 open 0 | hierGateSkip 0
TileReps: resident full/lod/hlod 24/8/2 | visible full/lod/hlod 18/5/1 | overlap visible full+lod/full+hlod/lod+hlod 0/0/0 residentFull+fallback 0 | fades 0 waiting 0
TileRenderCost: visible full/lod/hlod 18/5/1 | draws full/lod/hlod 22/6/1 | tris full/lod/hlod 84000/9000/1200
Batching: groups 132 | batchedMeshes 916 | dirty 0→0 | defWork 0 skipComplex 2 | dispatched 0→0 groups | rebuilds/s 0 | rebuildMs 0.00
Memory: mesh 312/512mb | tex 198/512mb | total 50% | entities 847 | gpuAlloc 910mb | avail 2400mb | thermal nominal
Hitches: budget 11.11ms | over 3/5400 (0.06%) | lastSec 0/90 over, worst 9.80ms | hist <4 0 | <8 1200 | <11.2 4190 | <16.8 8 | <33.4 2 | <100 0 | >=100 0
Compositor: views 2 @ 2048x1984 | update 2.10ms | inputSlack 1.45ms | submit 3.20ms | semWait 0.00ms | deadlineMargin 2.35ms | presentMargin 6.80ms | missed 3/5400 (0.06%) | noAnchor 0
```

**Compositor line** (visionOS only, absent elsewhere) — how the frame did against the Compositor Services deadlines. This is the number that matters on Apple Vision Pro: a frame whose GPU work finishes after the rendering deadline is reprojected by the compositor and felt as judder, whatever the average frame rate says.

| Field | What it tells you |
|---|---|
| `views W@HxV` | Views (eyes) rendered and the per-view drawable size. Changes with foveation and render quality. |
| `update` | CPU time between `startUpdate()` and `endUpdate()`: game update, input, streaming ticks. |
| `inputSlack` | Time left until the compositor's `optimalInputTime` when the update phase ended. Negative means the update ran late and the submission started behind schedule. |
| `submit` | CPU time from `startSubmission()` to the command buffer commit, both eyes. Includes `semWait`. |
| `semWait` | Time spent waiting for a free in-flight command buffer. Persistently non-zero means the GPU is pacing the CPU. Also reported on macOS and iOS as `timing.semaphoreWaitMs`. |
| `deadlineMargin` | Time between the GPU finishing the most recently completed frame and that frame's `renderingDeadline`. Negative (and `MISSED`) means the compositor did not get the frame in time. Comes from the command buffer completion handler, so it can lag the CPU frame by one or two frames. |
| `presentMargin` | Same, against the frame's `presentationTime`. |
| `missed a/b (rate)` | Frames that missed the deadline over frames sampled since the monitor was reset. Steady-state target: well under 1 in 1000. |
| `noAnchor` | Frames presented without a fresh device anchor since reset (tracking gaps). |

Programmatic access: `getEngineStatsSnapshot().compositor` (`EngineCompositorStats`), including `missedDeadlineRate`.

**Systems line** — where the `update` time goes, per engine system. Each value is the CPU time of that system this frame; `physics` and `custom` sum every fixed step and the step count is shown. The same scopes are emitted as signposts in the `Systems` category, so Instruments shows them as lanes without symbolication.

| Field | What it tells you |
|---|---|
| `scenegraph` | World-transform propagation. Non-zero only when something moved; large values mean many dirty transforms or a deep hierarchy scan. |
| `extensions` | Render and engine extension `update` hooks. |
| `lod` | Mesh and Gaussian LOD selection (interval and camera-displacement gated). |
| `animation` | Clip sampling, blending, root motion, IK, pose and joint matrix updates for every animated entity. |
| `scripting` | USC script execution. |
| `physics` | Fixed-step physics, summed over the steps taken this frame. More than one step per frame at 90 Hz means the frame is late. |
| `custom` | Registered custom systems, summed over the fixed steps. |
| `game` | The app's `gameUpdate` callback. |
| `semWait` | Time waiting for a free in-flight command buffer before encoding (see the Compositor line). |

**Streaming line 1** — entity counts and slot pressure:

| Field | What it tells you |
|---|---|
| `loaded / loading / unloaded` | Entity residency state across the full scene. |
| `active` | Concurrent async loads in flight. |
| `nearby … candidates … slots` | Entities in range → eligible this tick → slots free. A gap between candidates and slots means the concurrency limit is the bottleneck. |
| `backlog` | Candidates that couldn't start because all slots were taken. Persistent nonzero = slot-starved. |
| `pendingUploads` | Meshes waiting on the GPU upload gate. |
| `gateMs` | Time the frame spent blocked waiting for the upload gate. |

**Streaming line 2** — per-tick operational detail:

| Field | What it tells you |
|---|---|
| `tick=true/false` | Whether the streaming update ran this frame. `false` = throttle interval hasn't elapsed. |
| `workMs` | CPU time inside the streaming tick. Spikes here cause frame hitches. |
| `evictions` | Mesh evictions triggered by memory pressure this tick. Frequent nonzero = budget too tight. |
| `avgLoadMs` | Mean I/O + parse time per mesh load. High values = I/O bound, not slot-starved. |
| `applyMs` | Main-thread GPU upload cost when a completed load is applied. |
| `tileSwapWarn` | Cumulative tile representation thrash events (≥ 6 swaps in 5 s). |
| `repGap` | Cumulative tile-representation gap warnings — a tile briefly had no representation resident during a swap. |
| `lod0VisWarn / covered / open` | Cumulative warnings for a visible tile missing its LOD0 representation; `covered` = a fallback representation was available, `open` = nothing was available to fall back to. |
| `hierGateSkip` | Tiles skipped this tick by the hierarchy gate (parent representation not yet resident). |

**TileReps line** — per-tile representation residency and overlap:

| Field | What it tells you |
|---|---|
| `resident full/lod/hlod` | Count of tiles currently resident at each representation tier. |
| `visible full/lod/hlod` | Count of resident tiles at each tier that are also visible this frame. |
| `overlap visible full+lod/full+hlod/lod+hlod` | Tiles where two representation tiers are visible simultaneously — should trend toward zero outside of transition fades. |
| `residentFull+fallback` | Tiles where the full representation is resident alongside a fallback (LOD/HLOD) representation. |
| `fades / waiting` | Active cross-fade transitions between representations, and fades queued but not yet started. |

**TileRenderCost line** — rendering cost attributed to each tile representation tier:

| Field | What it tells you |
|---|---|
| `visible full/lod/hlod` | Same visible-instance counts as the `TileReps` line, restated here alongside cost. |
| `draws full/lod/hlod` | Estimated draw calls contributed by each tier. |
| `tris full/lod/hlod` | Estimated triangles contributed by each tier. A high `full` triangle count relative to `lod`/`hlod` suggests LOD switching is happening too late (or not at all) for distant tiles. |

**Batching line** — rebuild scheduler state:

| Field | What it tells you |
|---|---|
| `dirty X→X` | Dirty cells before vs after the work-budget prune. A large reduction means the scheduler is throttling rebuilds. |
| `defWork` | Cells deferred because they exceeded the per-tick CPU budget. Persistent nonzero = rebuild falling behind. |
| `skipComplex` | Cells permanently skipped by the complexity guard. These will never batch until the budget is raised. |
| `dispatched→groups` | Cells rebuilt this tick → batch groups produced. |
| `rebuildMs` | Total CPU time spent on rebuild work this tick. |

**Memory line:**

| Field | What it tells you |
|---|---|
| `mesh X/Ymb` | Geometry memory used vs geometry budget. |
| `tex X/Ymb` | Texture memory used vs texture budget. |
| `total X%` | Combined utilization across both pools. |
| `PRESSURE` | Appears when either pool hits ≥ 85 % utilization. |
| `gpuAlloc` | Bytes the Metal device has allocated for the process (`MTLDevice.currentAllocatedSize`): drawables, render targets, streamed meshes and textures together. |
| `avail` | Memory the process may still allocate before the system terminates it (`os_proc_available_memory`). iOS and visionOS only. |
| `thermal` | `ProcessInfo.thermalState`: nominal, fair, serious or critical. A `ThermalStateChanged` signpost event marks every transition. A benchmark that ends in `serious` is a failed run whatever the frame times say. |

**Hitches line** — the frame-time distribution since the monitor was reset. Means and percentiles hide single long frames; these counts do not.

| Field | What it tells you |
|---|---|
| `budget` | Frame budget for the over-budget counts. 16.67 ms by default; the visionOS runtime sets 11.11 ms (90 Hz). Change it with `EngineStatsMonitor.shared.frameBudgetMs`. |
| `over a/b (rate)` | Frames over budget out of all frames sampled. |
| `lastSec x/y over, worst` | The last completed one-second window: frames over budget, frames, and the worst frame time. Use this for a live overlay. |
| `hist` | Cumulative frame count per bucket. The bucket bounds (4, 8, 11.2, 16.8, 33.4, 100 ms) straddle the 90 Hz and 60 Hz periods, so the `<11.2`/`<16.8` split shows how many frames just missed 90 Hz. |

Programmatic access: `getEngineStatsSnapshot().hitches` (`EngineHitchStats`, with `overBudgetRate`).

---

Read profiler snapshots programmatically:

```swift
let metrics = EngineProfiler.shared.snapshot()
print("CPU mean: \(metrics.cpuFrame.meanMs) ms")
print("GPU mean: \(metrics.gpuCommandBuffer.meanMs) ms")

let frameStats = getEngineStatsSnapshot()
print("Frame: \(frameStats.frameIndex)")
print("Update: \(frameStats.timing.updateMs) ms")
print("Render: \(frameStats.timing.renderTotalMs) ms")
```

## Recording A Run To Disk

Every field of `EngineStatsSnapshot` is `Codable`. A recorder writes the published snapshots to a JSON Lines file on a utility queue, so a benchmark can dump a whole run and a script can compare it against a baseline:

```swift
let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("perf/starter-scene.jsonl")
try startEngineStatsRecording(to: url, interval: .perSecond)   // or .perFrame
// ... run the scene ...
let summary = stopEngineStatsRecording()
print(summary?.p99FrameMs ?? 0, summary?.missedDeadlines ?? 0)
```

Each line is `{"type":"frame","frame":{...}}` with the full snapshot; `.perFrame` writes every frame, `.perSecond` the last frame of each second. The final line is `{"type":"summary","summary":{...}}` (`EngineStatsRecordingSummary`): frame count and duration, mean, p50, p95, p99 and worst frame time, frames over budget, mean GPU execution time, compositor deadline misses, the mean GPU time per pass label, the worst thermal state seen and the peak GPU allocation. The summary always covers every frame, whatever the interval. On a device, pull the file with `xcrun devicectl device copy from`.

`startEngineStatsRecording` throws `EngineStatsRecordingError.statsNotCompiledIn` in builds without `ENGINE_STATS_ENABLED`.

## Benchmarking A Build

`Examples/PerfBench` is a benchmark app for macOS, iOS and visionOS that runs a fixed set of scenes with the stats and the GPU pass timer on, records every frame with the recorder above and writes a `summary.json` per run. `scripts/perf/run_bench.sh <platform>` builds it, runs it (on a paired device through `devicectl`), pulls the results into `perf/results/` and compares them with the baseline stored under `perf/baselines/<device model>/` (`--update-baseline` writes one). See `Examples/PerfBench/README.md`.

## GPU Pass Timing

`GPUPassTimer` measures every labelled render, compute and blit pass of the frame command buffer on the GPU, using `MTLCounterSampleBuffer` timestamps at stage boundaries (the only sampling point Apple GPUs support). It costs two timestamp samples per pass and no extra GPU work, so it can stay on during a benchmark.

Enable it at runtime or from the environment:

```swift
GPUPassTimer.shared.isEnabled = true
```

```bash
UNTOLD_GPU_PASS_TIMING=1 ./YourApp
```

Read the last resolved frame directly, or through the engine stats snapshot:

```swift
let passes = GPUPassTimer.shared.snapshot()          // GPUPassTimingSnapshot
for pass in passes.passes {
    print("\(pass.label): \(pass.ms) ms x\(pass.count)")
}
print(getEngineStatsSnapshot().gpuPasses.ms(for: "Shadow Cascade 0") ?? 0)
```

The verbose stats output adds one line with the twelve heaviest passes:

```
GPU passes (14, sum 6.21ms): G-Buffer + Light Pass (TBDR)x2 3.10 | Shadow Cascade 0 0.62 | SSAO Passx2 0.55 | Post-Processing Passx2 0.40 | HZB Build Mip 0 0.12 | ...
```

| Field | What it tells you |
|---|---|
| `label` | The encoder label, the same name Metal System Trace and the Metal debugger show. |
| `xN` | The pass was encoded N times this frame under that label (once per eye on visionOS, once per cascade only when the label does not carry the index). The time is the sum. |
| `sum` | Sum of all pass times. Passes can overlap on the GPU, so this is an upper bound on the command buffer's GPU time. |
| `skipped` | Passes beyond `GPUPassTimer.maxPassesPerFrame` (128) that were not timed this frame. |

Results come from the command buffer's completion handler, so the snapshot describes the most recently *completed* frame. `GPUPassTimer.shared.isSupported` is false on devices without stage-boundary timestamp sampling, in which case the snapshot stays empty.

Passes are timed when they create their encoder through the labelled helpers `makeRenderCommandEncoder(descriptor:passLabel:)`, `makeComputeCommandEncoder(passLabel:)` or `makeBlitCommandEncoder(passLabel:)` on `MTLCommandBuffer`. New passes and rendering extensions should use them; they behave exactly like the plain Metal calls when the timer is off or the command buffer is not the frame's.

## OOC And Asset Triage Mode

High-volume instrumentation categories are disabled by default:

- `OOCTiming`
- `OOCStatus`
- `AssetLoader`

Enable them when diagnosing OOC/loader behavior:

```swift
// Keep structured profiler metrics on
setEngine(.metrics(.enabled))
setEngineStatsLogging(enabled: true, profile: .compact, intervalSeconds: 1.0)

// Add focused trace logs
setLogger(.categories([.oocStatus, .oocTiming, .assetLoader], true))
```

Disable after capture:

```swift
setLogger(.categories([.oocTiming, .oocStatus, .assetLoader], false))
```

## Static Batching Triage

When FPS is lower than expected and the `draws` count in the engine stats is high relative to `visible` entities, the static batching system may not be producing as many groups as expected.

Enable the `.batching` log category to get a material-diversity report:

```swift
// One-shot snapshot at any point (e.g. after the scene finishes loading)
setLogger(.category(.batching, true))
BatchingSystem.shared.logMaterialDiagnosticsNow()
setLogger(.category(.batching, false))
```

Or arm it to fire automatically every 30 seconds during a session:

```swift
setLogger(.category(.batching, true))
// engine loop calls logMaterialDiagnosticsIfDue() each frame — no extra code needed
```

### Reading the output

```
[BatchMaterial] staticBatch=916 registered=916 resolved=916 batchable=87%
  | singletons=119 groupable=797 | cellsBlocked=2
  | uniqueMatLOD=80 singletonKeys=119 groupableKeys=132

[BatchMaterial] cell(0,-1,0)  ents=224 uniqueKeys=49 singletons=22 groupable=27 groups=0  ratio=0.45
[BatchMaterial] cell(-1,-1,0) ents=238 uniqueKeys=42 singletons=16 groupable=26 groups=0  ratio=0.38
[BatchMaterial] cell(-2,-1,0) ents=49  uniqueKeys=24 singletons=12 groupable=12 groups=12 ratio=0.50
```

**Scene-level fields:**

| Field | What it tells you |
|-------|-------------------|
| `staticBatch` | How many entities have `StaticBatchComponent`. If this is 0 the asset was not set up for batching. |
| `registered / resolved` | Should match `staticBatch` once all tiles are resident. A large gap means entities are failing eligibility checks (animation, transparency). |
| `batchable` | Percentage of resolved entities that share a material key with a peer. Above 80% is healthy. |
| `cellsBlocked` | Cells rejected by the runtime complexity guard — their entities are rendered individually regardless of material sharing. |
| `uniqueMatLOD` | Distinct (material × LOD) keys globally. A small number (< 200) with high `batchable` is ideal. |

**Per-cell fields:**

| Field | What it tells you |
|-------|-------------------|
| `ents` | Entities registered in the cell. Very high counts (> 150) risk hitting the complexity guard. |
| `uniqueKeys` | Distinct material keys in the cell. Many keys spread across few entities = high diversity. |
| `groups` | Batch groups actually built. `0` with non-zero `groupable` means the cell has not been built yet or was blocked. |
| `ratio` | `singletonKeys / uniqueKeys`. Close to 1.0 means nearly every material is unique to one entity — nothing will batch. |

### Diagnosing common patterns

**`groups=0` on large cells, `cellsBlocked > 0`**  
The complexity guard is rejecting cells with too many vertices. Reduce the batch cell size (default 32 world units) so fewer entities land per cell, or raise `maxRuntimeCellVertices` / `maxRuntimeCellBufferBytes` in the platform tuning profile.

**High `uniqueMatLOD` count, `ratio` near 1.0 per cell**  
Material diversity in the asset: each mesh instance uses a slightly different material, preventing grouping. The fix is asset-side — consolidate materials into shared PBR parameter sets or texture atlases.

**`batchable=0%`, `staticBatch=0`**  
The scene entities were not tagged with `StaticBatchComponent` during export or scene setup. No batching will occur until the component is present.

**`resolved` much lower than `registered`**  
Entities are failing `resolveBatchCandidate`. Common causes: transparent submeshes, skeleton/animation components, or `preserveIdentity` scene channels. Check the entity setup.

## Geometry Streaming Diagnostics

The key per-tick streaming fields (`updateTriggered`, `updateWorkMs`, `nearbyEntitiesQueried`, `availableLoadSlots`, `evictionsPerformed`, `averageAsyncLoadMs`, `lastApplyLoadedMeshMs`, `tileSwapWarnings`) are automatically included in the verbose stats output — see [Verbose output format](#verbose-output-format) above. No extra setup is needed for routine streaming triage.

### Per-tick operational snapshot (programmatic access)

When you need to read streaming state in code rather than from the log, pull the diagnostics struct directly:

```swift
let diag = GeometryStreamingSystem.shared.getDiagnosticsSnapshot()
print("update triggered: \(diag.updateTriggered)  workMs: \(diag.updateWorkMs)")
print("nearby queried: \(diag.nearbyEntitiesQueried)  candidates: \(diag.loadCandidates)")
print("slots available: \(diag.availableLoadSlots)  started: \(diag.startedLoads)")
print("evictions: \(diag.evictionsPerformed)  tileSwapWarnings: \(diag.tileSwapWarnings)")
print("avg async load: \(diag.averageAsyncLoadMs) ms")
```

This struct also contains fields not printed by the compact log profile: `startedLoads`, `activeLoadsAtUpdateStart/End`, `lastAsyncLoadMs`, `lastAsyncReloadLODMs`, `lastFailedAsyncLoadMs`, `lastUnloadMeshMs`, `unloadCandidates`, and `processedUnloads`.

| Field | What it tells you |
|---|---|
| `updateTriggered` | Whether the streaming tick ran this frame. `false` means the throttle interval hasn't elapsed yet. |
| `updateWorkMs` | CPU time spent inside the streaming update. Spikes here cause frame hitches. |
| `nearbyEntitiesQueried` | How many entities the frustum/radius gate evaluated. |
| `loadCandidates` / `startedLoads` | How many entities were eligible vs actually kicked off. A gap means slots were full. |
| `unloadCandidates` / `processedUnloads` | How many entities were eligible for unload vs actually unloaded this tick. |
| `availableLoadSlots` | Concurrency slots free at the start of the tick. `0` = slot-starved. |
| `evictionTriggered` / `evictionsPerformed` | Whether memory pressure forced an eviction pass. Frequent evictions indicate the budget is too tight for the scene. |
| `lastAsyncLoadMs` / `averageAsyncLoadMs` | I/O + parse time per mesh. High values mean the bottleneck is I/O, not slot count. |
| `lastApplyLoadedMeshMs` | Main-thread GPU upload cost when a mesh completes loading. |
| `tileSwapWarnings` | Count of tile representation thrash events (≥ 6 swaps in 5 s). Nonzero means a tile is oscillating between LOD levels. |
| `tilesSkippedByHierarchyGate` | Tiles skipped this tick because their parent representation wasn't yet resident. |
| `tileRepresentationGapWarnings` | Tiles that briefly had no representation resident during a swap. |
| `lod0VisibilityWarnings` / `...WithFallback` / `...NoFallback` | Warnings for a visible tile missing its LOD0 representation; the `WithFallback`/`NoFallback` split tells you whether a fallback representation covered the gap. |
| `residentFull/LOD/HLODRepresentations` | Count of tiles resident at each representation tier. |
| `visibleFull/LOD/HLODRepresentations` | Count of resident tiles at each tier that are also visible this frame. |
| `fullAndLOD/fullAndHLOD/lodAndHLODVisibleOverlapTiles` | Tiles where two representation tiers are visible simultaneously. |
| `fullAndFallbackResidentOverlapTiles` | Tiles where the full representation is resident alongside a fallback representation. |
| `activeTileRepresentationFades` / `waitingTileRepresentationFades` | Cross-fade transitions currently running vs queued. |

### Streaming summary to console

For a one-shot console dump of streaming counts, cache state, and memory budget together:

```swift
GeometryStreamingSystem.shared.printStats()
```

Output includes: loaded / loading / unloaded entity counts, active load slot usage, cached file count, total cache memory, and mesh budget utilization.

### Tile streaming category log

Enable the `.tileStreaming` category for event-level traces (tile parse timeouts, eviction warnings, swap-thrash alerts):

```swift
setLogger(.category(.tileStreaming, true))
// ... reproduce the issue ...
setLogger(.category(.tileStreaming, false))
```

---

## Memory Budget Diagnostics

Memory usage (mesh mb, texture mb, combined utilization, entity count, and pressure flag) is included in the verbose stats output automatically — see the **Memory line** in [Verbose output format](#verbose-output-format) above.

For more detail than the one-line summary, `MemoryBudgetManager` provides two additional paths.

### Automatic pressure logging

`logStatus()` fires automatically whenever memory crosses the high-water or low-water mark. No setup required — watch the log for:

```
MemoryBudgetManager Status:
- Mesh Memory:    312 MB / 512 MB (60.9%)
- Texture Memory: 198 MB / 512 MB (38.7%)
- Total GPU Memory: 510 MB / 1024 MB (49.8%)
- Tracked Entities: 847
- Under Pressure: false
```

This fires at both the high-water and low-water thresholds, so you get one log when pressure starts and another when it clears.

### Manual snapshot

Call at any point to log the current state regardless of pressure:

```swift
MemoryBudgetManager.shared.logStatus()
```

### Programmatic access

```swift
let stats = MemoryBudgetManager.shared.getStats()
print("mesh: \(stats.meshMemoryUsed) / \(stats.geometryBudget)  util: \(stats.geometryUtilization)")
print("texture: \(stats.textureMemoryUsed) / \(stats.textureBudget)  util: \(stats.textureUtilization)")
print("pressure: \(stats.isUnderPressure)")
```

---

## Batching Tick Diagnostics

The key rebuild-scheduler fields (`dirty X→X`, `defWork`, `skipComplex`, `dispatched→groups`, `rebuildMs`) are included in the verbose stats output automatically — see the **Batching line** in [Verbose output format](#verbose-output-format) above.

### Full tick snapshot (programmatic access)

`getTickDiagnosticsSnapshot()` exposes the complete per-tick struct, including fields not in the verbose output (`deferredByQuiescence`, `deferredByVisibility`, `appliedArtifacts`, `inFlightBuildCells`, `maxCellRebuildMs`, `rebuiltVertices`, `rebuiltBufferBytes`):

```swift
let diag = BatchingSystem.shared.getTickDiagnosticsSnapshot()
print("dirty cells: \(diag.dirtyCellsBeforePrune) → \(diag.dirtyCellsAfterPrune) after prune")
print("dispatched builds: \(diag.dispatchedBuilds)  applied: \(diag.appliedArtifacts)")
print("deferred by quiescence: \(diag.deferredByQuiescence)")
print("deferred by work budget: \(diag.deferredByWorkBudget)")
print("rebuild work: \(diag.rebuildWorkMs) ms  max cell: \(diag.maxCellRebuildMs) ms")
```

| Field | What it tells you |
|---|---|
| `dirtyCellsBeforePrune` / `AfterPrune` | How many cells needed rebuild vs how many survived the work-budget prune. A large prune gap means the scheduler is throttling. |
| `deferredByQuiescence` | Cells skipped because entities were still arriving. Normal during initial scene load. |
| `deferredByVisibility` | Cells skipped because they were outside the camera frustum. |
| `deferredByWorkBudget` | Cells skipped to stay within the per-tick CPU budget. Persistent nonzero values mean rebuild is falling behind. |
| `skippedByComplexityGuard` | Cells with too many vertices for the runtime budget — they will never batch until the budget is raised or cell size is reduced. |
| `rebuildWorkMs` / `maxCellRebuildMs` | Total and worst-case rebuild time for this tick. |
| `rebuiltVertices` / `rebuiltBufferBytes` | Output size of the rebuild work — useful for estimating GPU buffer pressure. |

For a one-line summary suitable for frame logging:

```swift
print(BatchingSystem.shared.diagnosticSummary())
// batch: registered=916 dirty=3 rebuildMs=0.4 groups=132
```

---

## Debug-only Console Helpers

The following helpers use `print()` rather than the Logger and are intended for quick local inspection. They are not gated by log categories and have no throttle.

| Call | What it prints | Platform |
|---|---|---|
| `GeometryStreamingSystem.shared.printStats()` | Streaming counts + cache stats + memory budget in one block | All |
| `RealSurfacePlaneStore.shared.logAllPlanes()` | All ARKit-detected planes: alignment, classification, Y height, extent | AR only |

These are best used with a breakpoint or a temporary `onUpdate` call. Do not leave them in shipped code.

---

## Instruments Workflow

When metrics are enabled, the engine emits signpost scopes:

- `Frame`
- `Update`
- `RenderPrep`
- `Encode`
- `Submit`
- `CompositorUpdate`, `CompositorWaitForInput`, `CompositorSubmission` (visionOS, category `Compositor`), plus a `MissedDeadline` point event whenever the GPU finishes a frame after the compositor's rendering deadline. Put the Metal System Trace GPU track next to this lane to see whether a miss was CPU-late (submission ends after the optimal input time) or GPU-late.

To inspect timeline data:

1. Open Instruments
2. Choose **Points of Interest**
3. Filter subsystem to `com.untoldengine.profiling`
4. Run the app with `setEngine(.metrics(.enabled))` (or `UNTOLD_METRICS=1`)

## Build Configuration Notes

- `EngineProfiler` is available in all configs, but disabled by default until enabled at runtime.
- `EngineStats` collection is compiled into every configuration (`ENGINE_STATS_ENABLED`) and switched at runtime: on by default in debug builds, off by default in release builds. Turn it on with `setEngine(.metrics(.enabled))` (which also enables the profiler), `setEngineStatsCollection(enabled: true)`, or `UNTOLD_STATS=1` in the environment. This is how device measurements are taken from a release build.
- When collection is off, every per-frame call returns immediately, draw counting is skipped, and the per-frame snapshot is not gathered; `getEngineStatsSnapshot()` keeps returning the last published frame.

If `ENGINE_STATS_ENABLED` is removed from the package settings, `getEngineStatsSnapshot()` returns default values and `setEngineStatsLogging(...)` is effectively a no-op.

## Category Toggle Notes

- Category filtering applies to `Logger.log(...)` debug/info trace paths.
- Warnings and errors still emit regardless of category state.
- Logger messages are lazily evaluated, so disabled categories avoid message-building cost.

## Debug Helper (DEBUG Only)

```swift
#if DEBUG
let metricsLogger = MetricsDebugLogger()
metricsLogger.logIfNeeded() // throttle-prints approximately once per second
#endif
```

## Integrated Systems

Profiler hooks are already integrated into:

- `UntoldEngine.swift` (`runFrame`)
- `RenderingSystem.swift` (`UpdateRenderingSystem`)
- `UntoldEngineXR.swift` (`executeXRSystemPass`)
- `UntoldEngineAR.swift` (`draw`)
- `BatchingSystem.swift` (`logMaterialDiagnosticsIfDue` — fires automatically every 30 s when the `.batching` category is enabled)
- `LightPortalSystem.swift` (`logDiagnosticsIfDue` — fires automatically every 1 s when the `.lightPortal` category is enabled)
