# Posing the Frame for Its Presentation Time — Why a Moving Object Judders on Vision Pro, and the Fix

Status: proposal with a prototype on this branch (engine side done and tested; the viewer app's change applied in the viewer's pull request, and kept as `viewer-frame-time.patch` beside this document; the headset check still to do). The branch stacks on `feature/xr_headset_rendering` (untoldengine/UntoldEngine#1359), which rewrote the try branch's history. Written 2026-10-14 from a headset session of the same day with the viewer app (`UntoldArcade-viewer`), the dartboard on its eased "tour" path.

## TL;DR

1. **The engine poses the head for the instant the frame will be shown, and every object for "now at update time".** The XR loop queries the device anchor at `drawable.frameTiming.presentationTime`, but the game ran earlier on a wall-clock delta between two updates. The gap between the two instants is the wait for the compositor's optimal input time plus the encode, and it varies with the previous frame's CPU work: the object's position steps unevenly from frame to frame while the head's does not. That reads as judder at full frame rate.
2. **The viewer makes it worse by reading the system clock inside the update.** Its tour pose comes from `ProcessInfo.processInfo.systemUptime` in the game update, so it carries the same varying lag; the engine never told it when the frame would be shown.
3. **A skipped frame doubles the step either way, but delta-driven motion drifts after it.** The measured 94 fps against a 100 Hz cadence and 85 fps against 90 Hz mean about one refresh in sixteen shows the previous image again. Motion that accumulates the time between updates is then off the display's timeline by the change in lag; motion sampled at the presentation time lands where the timeline says and steps by one period again on the next frame.
4. **The fix is one value handed down the loop: the frame's predicted presentation time**, with the delta from the previous presentation and the refreshes skipped between them (`FrameTime`). The compositor predicts it (`frame.predictTiming().presentationTime`) before the update phase, so the game update stays where it is, before the wait, and poses the frame for that instant. The engine's own delta (`timeSinceLastUpdate`) becomes the presentation delta, so every delta-driven path (skeletal clips, the camera path, scripts, extensions, physics accumulation) moves in step with the display without changing.
5. **Nothing existing breaks.** `gameUpdate(deltaTime:)` keeps its parameter (now the presentation delta); `setupCallbacks(frameUpdate:handleInput:)` hands the full `FrameTime`; `UpdateEvent`, `EngineExtensionUpdateContext`, `RenderGraphBuildContext` and `RenderPassContext` gain a `frameTime` field with a default. The macOS, iOS and AR loops build the same `FrameTime` from an estimate one period ahead of the draw, or from the host's display-link target when it gives one.

## 1. What was seen

On the headset, the dartboard moving along the tour shows small random steps every frame and larger occasional jumps. RealityKit moving the same object along the same path judders less. The engine's stats reported 94 fps on the 100 Hz display mode and 85 fps on 90 Hz: about one refresh in sixteen repeated the previous frame.

The loop's budget at 100 Hz, from the engine stats (`EngineTimingStats`): loop 10.5 ms, update 1 ms, wait for the optimal input time 6.4 ms, encode 3 ms.

## 2. Where the loop samples time today (verified in the code)

The XR frame, `renderNewFrame()` in `Sources/UntoldEngineXR/UntoldEngineXR.swift`:

1. `layerRenderer.queryNextFrame()`, then `frame.predictTiming()`: the compositor's predicted `optimalInputTime`, `renderingDeadline` and `presentationTime` for this frame (`frame_timing.h`: "the Mach absolute time at which the layer presents the frame onscreen").
2. `frame.startUpdate()`; spatial input; `renderer.updateXR(useExternalStatsLifecycle: true)`, which is `runFrame` in `Sources/UntoldEngine/Renderer/UntoldEngine.swift`: `calculateDeltaTime()` set `timeSinceLastUpdate` from `CACurrentMediaTime()` minus the previous update's `CACurrentMediaTime()`; then animation, scripts, physics and `gameUpdateCallback?(timeSinceLastUpdate)`.
3. `frame.endUpdate()`; `LayerRenderer.Clock().wait(until: timing.optimalInputTime)` — the 6.4 ms, which is whatever the period leaves after the previous frame's work.
4. `frame.startSubmission()`; for each drawable, the head pose is queried at `drawable.frameTiming.presentationTime` (`queryDeviceAnchor(atTimestamp:)`), and the eyes are drawn with it.

So the head is posed for the presentation instant and the objects for the update's wall-clock instant, 9 to 11 ms earlier and varying. The viewer app (`Viewer/App/EngineSession.swift`, `update()`) computes `tourTime` from `ProcessInfo.processInfo.systemUptime` inside that update, and its RealityKit path (`Viewer/App/RealityKitSpace.swift`, `apply()`) does the same in `SceneEvents.Update`. The engine's `gameUpdate` callback only ever received a `Float` delta; nothing told the game when the frame would be shown.

The three clocks involved share one base. `CACurrentMediaTime()`, `ProcessInfo.processInfo.systemUptime` and `mach_absolute_time()` agreed to within the time between the calls when read back to back on this machine (78 µs apart, nothing more), the engine already mixes them (ARKit anchor timestamps against `systemUptime` in the lighting system, `CACurrentMediaTime()` for the anchor query), and the compositor's `LayerRenderer.Clock` counts mach absolute time from its `epoch`. The engine used to convert a compositor instant through "now" on both clocks; the prototype converts through the epoch, as Apple's Metal immersive sample does, and prints once at start how far the two conversions are apart (`XR clock: ...`), which should be the microseconds between two reads.

There is no transform keyframe or tween system for entities. The keyframes in `Sources/UntoldEngine/Mesh/Skeleton.swift` are skeletal clips sampled by `AnimationSystem`, and the camera path in `CameraSystem.swift` moves cameras. Neither is the cause; both are delta-driven and covered by the delta change below.

## 3. The fix: the frame's time, handed down the loop

### 3.1 The data

`Sources/UntoldEngine/Renderer/FrameTime.swift` (new):

```swift
public struct FrameTime: Sendable, Equatable {
    /// Seconds at which the frame is predicted to be shown (CACurrentMediaTime base).
    public let presentationTime: TimeInterval
    /// Seconds from the previous frame's presentation to this one's; 0 on the first frame.
    public let deltaTime: TimeInterval
    /// The display's period as the loop knows it (nominal, or the shortest spacing seen).
    public let period: TimeInterval
    /// Refreshes between the previous frame and this one that showed the previous frame again.
    public let skippedFrames: Int
    /// The engine's count of frames prepared, from 1.
    public let frameIndex: UInt64
    public var wasFrameSkipped: Bool { skippedFrames > 0 }
}
```

`FrameClock` (same file) makes one per frame from the presentation times the host predicts: the delta between consecutive presentations; the period, which the host declares (an MTKView's `1 / preferredFramesPerSecond`) or the clock learns as the shortest spacing between 4 ms and 42 ms seen so far (a skip never teaches it a longer period, a stall is not a period either); and `skippedFrames = round(delta / period) − 1`, clamped at 0. A presentation before the previous one (a clock going backwards) passes no time. A jitter of a tenth of a millisecond on the compositor's predictions is not a skip.

### 3.2 How it reaches the game without breaking existing callers

- `UntoldRenderer.setupCallbacks(gameUpdate:handleInput:)` is unchanged in shape. Its `deltaTime` is now the presentation delta (`timeSinceLastUpdate`); the frame's time is `renderer.frameTime` or the `currentFrameTime` global while the callback runs. The global follows the engine's `timeSinceLastUpdate` style so code components and custom systems can read it too.
- `UntoldRenderer.setupCallbacks(frameUpdate:handleInput:)` (new, also on `UntoldEngineXR` and `UntoldEngineAR`) hands the `FrameTime` itself. A distinct label, not an overload of `gameUpdate:`, because an existing `gameUpdate: { _ in ... }` would be ambiguous between a `Float` and a `FrameTime` closure and stop compiling. Each form replaces the other.
- `UpdateEvent.frameTime` for `renderer.onUpdate { event in ... }` subscribers (`Sources/UntoldEngine/Systems/FrameEvents.swift`); the internal initializer keeps `UpdateEvent(deltaTime:renderer:)` working.
- `EngineExtensionUpdateContext.frameTime` (`Sources/UntoldEngine/ECS/EngineExtensions.swift`) for `EngineExtension.update(deltaTime:context:)` and `RenderExtension`s, built by `makeEngineExtensionUpdateContext()`.
- `RenderGraphBuildContext.frameTime` and `RenderPassContext.frameTime` (`Sources/UntoldEngine/Systems/GraphBuilder.swift`), next to their `deltaTime: Float`, built by `makeRenderGraphBuildContext()` and `makeRenderPassContext(...)`. All three contexts take `frameTime: FrameTime = .zero` as the last initializer parameter, so every existing call site compiles.
- `EngineTimingStats.presentationDeltaMs` and `.skippedFrames` (`Sources/UntoldEngine/Profiling/EngineStatsSnapshot.swift`) so the viewer's diagnostics can count skipped refreshes directly instead of inferring them from fps.
- `UntoldRenderer.updateXR(presentationTime:useExternalStatsLifecycle:)`: the host loop passes the predicted presentation time; `updateXR()` and `updateXR(useExternalStatsLifecycle:)` still compile and estimate one period ahead of now.

`calculateDeltaTime(presentationTime:nominalPeriod:)` in `UntoldEngine.swift` is the only place the engine's delta is made. It advances the clock and sets `currentFrameTime`, `timeSinceLastUpdate` (the presentation delta) and `timeSinceLastUpdatePreviousTime` (now the presentation time). `firstUpdateCall == false` resets the clock, as the tests' state reset expects.

### 3.3 The XR loop

`renderNewFrame()` converts `timing.presentationTime` once, right after `predictTiming()`, and passes it to `updateXR(presentationTime:)`; the anchor query at submission converts `drawable.frameTiming.presentationTime` the same way. The two should be the same instant. `notePresentationRevision` counts the frames where the drawable's differs from the prediction by more than half a millisecond (`presentationTimeRevisions`, printed at most once a second): on such a frame the object was posed for a slightly different instant than the head, by exactly that difference. The count is the headset check that the prediction is stable (section 8).

### 3.4 The viewer's change (`viewer-frame-time.patch`, beside this document)

`Viewer/App/EngineSession.swift`: `xr.setupCallbacks(frameUpdate: { [weak self] frame in self?.update(frame: frame) }, handleInput: ...)`, `update(frame:)`, and the tour's time from the frame: `tourTime = (frame.presentationTime - object.placed).truncatingRemainder(dividingBy: Catalog.Tour.period)`. `object.placed` is already in the same clock base (`systemUptime`). For the headset check, the session sums `frame.skippedFrames` over all frames and reads `xr.presentationTimeRevisions`; both go into `EngineDiagnostics` (`skippedFrames`, `presentationRevisions`), the run summary (`MeasurementRun.swift`: ", N skipped refreshes, N presentation revisions") and the controls' engine line ("frames N (M skipped)"). The RealityKit path keeps `SceneEvents.Update`, which gives no presentation time; RealityKit poses its own frames for the compositor.

The viewer's project points at the `xr_foveation` worktree (`project.yml`, `packages.UntoldEngine.path`), which builds `feature/xr_headset_rendering`; the viewer with this change compiles once this branch is merged into that one. The change is applied in the viewer's pull request and kept as a patch here (`patch -p1 < viewer-frame-time.patch` from the `UntoldViewer` directory; three files, taken against the viewer's tree of 2026-10-14). It was compiled against this branch through a throwaway XcodeGen project outside the viewer's tree.

## 4. Where the game update runs: before the wait, posed for the predicted presentation

Two places are possible for the update that poses the objects:

**A. Before the wait (today's place), sampling the predicted presentation time.** The prediction is available from `predictTiming()` at the start of the update phase, so nothing moves. The CPU budget is untouched: at 100 Hz the update's 1 ms sits inside the 6.4 ms the loop spends waiting anyway; a slow update (a batching rebuild, a streaming tick) shortens the wait instead of threatening the deadline. The object is posed for the instant the compositor predicts, the same instant the head is posed for 6.4 ms later; whatever the prediction's error, head and object share it, which is what removes the judder.

**B. After the wait, in the submission phase.** The update would run 6.4 ms closer to presentation, so game logic that reads input (a pinch dragging the object) would act on input 6.4 ms fresher. The cost: the CPU work after `optimalInputTime` grows from the 3 ms encode to 4 ms, a third more, on every frame, and the update's variance lands directly on the rendering deadline, where it drops frames instead of shortening a wait. With the loop at 10.5 ms for a 10 ms period there is no margin for that; at 90 Hz (11.1 ms) barely.

Recommendation: A. It fixes the judder with no budget change. If fresher input matters later, the cheap form is a small "late input" hook after the wait that only reads input poses (hands at `timing.trackableAnchorTime`, the head) and writes transforms, not a full update after the wait.

## 5. Engine paths that sample time, and what each needs

| Path | File / function | Today | Change |
| --- | --- | --- | --- |
| The engine's delta | `UntoldEngine.swift` `calculateDeltaTime` | wall clock between updates | presentation delta from `FrameClock` (done) |
| Skeletal clips | `Systems/AnimationSystem.swift` `updateAnimationSystem(deltaTime:)`, `AnimationComponent.currentTime += deltaTime * playbackSpeed`; `currentGlobalTime += deltaTime` | delta-driven | none: the delta is now the presentation delta, so a clip's time stays in phase with the display; sampling a clip at an absolute time is possible but not needed |
| Camera path | `Systems/CameraSystem.swift` `updateCameraPath(deltaTime:)`, `segmentT += deltaTime / segmentDuration` | delta-driven, called by the game | none; the game passes the delta it receives. An `updateCameraPath(frame:)` sampling `segmentT` from an absolute time would make a skipped frame exact rather than in phase, a small follow-up |
| Tweening | none existed | — | `Animation/TransformTrack.swift` (new): keys with easing sampled at an absolute time, `pose(for: frame, startedAt:)` and `applyTransformTrack(entityId:track:startedAt:frame:)` |
| Scripts | `Scripting/USCScripting.swift` `USCSystem.shared.update(timeSinceLastUpdate)` | delta-driven | none |
| Physics | `UntoldEngine.swift` `physicsAccumulator += timeSinceLastUpdate`, fixed step | accumulated | none; the accumulator now follows presentations |
| Particles | none in the engine; the muscle simulation's mass points (`Systems/Muscle/MuscleSimulation.swift`) step by a fixed substep | — | none; a particle system added later takes `FrameTime` like everything else |
| Code components, custom systems | `onUpdate(deltaTime:)`, `updateCustomSystems(deltaTime:)` | delta-driven | none; `currentFrameTime` is readable inside them |
| Engine and render extensions | `ECS/EngineExtensions.swift` `update(deltaTime:context:)`; `Systems/GraphBuilder.swift` `makeRenderGraphBuildContext`, `makeRenderPassContext` | `deltaTime: Float` | `context.frameTime` added (done) |
| Update event | `Systems/FrameEvents.swift` `UpdateEvent` | `deltaTime` | `frameTime` added (done) |
| Head pose | `UntoldEngineXR.swift` `renderNewFrame`, anchor query | `drawable.frameTiming.presentationTime` through "now" on both clocks | through the compositor clock's epoch, the same conversion the game's time uses (done) |
| Room light fade | `UntoldEngineXR/XREnvironmentLightingSystem.swift` (`ProcessInfo.systemUptime`) | wall clock | optional: a slow fade, not judder; could read `currentFrameTime.presentationTime` for consistency |

## 6. The platform side: the same `FrameTime` everywhere

- **visionOS** (`UntoldEngineXR`): the compositor's prediction, as above. The period is learnt (the compositor does not state the display's rate; the loop measures 10.0 ms at 100 Hz, 11.1 ms at 90 Hz).
- **macOS / iOS `MTKView`** (`UntoldRenderer.draw(in:)`): MTKView's delegate gets no timestamp from the view's own display link, so the frame is posed one period (`1 / view.preferredFramesPerSecond`) ahead of the draw and the period is the nominal one. The delta between frames is then the spacing of the draws, as before. A host that drives the view from its own display link (`CADisplayLink` on iOS, `NSView.displayLink(target:selector:)` on macOS 14) pauses the view's loop (`isPaused = true`, `enableSetNeedsDisplay = false`), sets `renderer.predictedPresentationTime = link.targetTimestamp` and calls `view.draw()` from the link; the frame is then posed for the link's target. A follow-up can phase-lock the estimate from `CAMetalDrawable.addPresentedHandler`'s `presentedTime` without a host display link.
- **iOS AR** (`UntoldEngineAR.draw(in:)`): one of the view's periods ahead of now, passed as `updateXR(presentationTime:)`. The camera image is already in the past; the objects are posed for when the composite is shown.

## 7. Tests (all passing)

- `Tests/UntoldEngineTests/FrameClockTests.swift` (9): first frame, steady cadence, a skipped refresh counted once and the next frame back to one period, jitter is not a skip, a stall counts every refresh, a nominal period, time going backwards, the estimate ahead of now, reset.
- `Tests/UntoldEngineTests/TransformTrackTests.swift` (5), including `testARepeatedFrameDoesNotDoubleStepAnAbsoluteTimeAnimation`: slots 0, 1, 2, [3 missed], 4, 5 with updates that run a varying lag before each presentation. Sampled at presentation time, the positions are exactly the timeline's, one period per frame, two across the skipped slot and one again after it; stepped by the time between updates, no step is a period and the position after the skip is off the timeline.
- `Tests/UntoldEngineRenderTests/FrameTimeLoopTests.swift` (3, with a real renderer): the loop drives `updateXR(presentationTime:)` on a timeline a thousand seconds from the wall clock; the pose the game samples in `frameUpdate` is the pose for the frame's presentation time, the engine's delta is the presentation delta and not the microseconds between the calls, the update event and an extension receive the same `FrameTime`, the legacy `gameUpdate` delta is the presentation delta and a two-period gap reports one skipped frame; a frame without a prediction is posed one period ahead of now.

The compositor part cannot run in `swift test`; section 8 is its check.

## 8. Headset check

1. The start-up line `XR clock: the compositor epoch's time differs from the media time by N ms`: N should be the microseconds between two reads. A large constant N means the epoch assumption is wrong and the loop must go back to converting through "now" on both clocks.
2. `presentationTimeRevisions` (and its log line) over a minute of the tour: near zero means the predicted and final presentation times agree and the object is posed for the head's instant; a steady count means the prediction is revised by the compositor and the game should be posed for the drawable's time instead (option B's place), or the revision applied as a per-frame correction.
3. The viewer's run summary: "N skipped refreshes" over the run against the fps shortfall (6 in 100, 5 in 90): they should match. "N presentation revisions" is check 2.
4. The tour, with the viewer's change of section 3.4: the small per-frame steps should be gone; the occasional larger jump remains for every skipped refresh and should now be one clean double step with no drift after it.

### Results, 2026-10-15, the viewer's dartboard tour at 90 Hz

1. `XR clock: the compositor epoch's time differs from the media time by -0.000 ms`: the clock bases agree.
2. Presentation revisions: none. The drawable's presentation time is the one predicted at the update.
3. Skipped refreshes: none. The loop never saw a presentation slot go by without a frame.
4. The small per-frame steps are gone. A hop remained on the tour's lateral sweep only (0.63 m/s peak, 0.15° per frame at 2.37 m, where a frame shown a refresh late is a 12 mm sideways hop), with every counter above at zero.

The hop is the GPU finishing after the compositor's rendering deadline, which no counter of the loop's pacing sees; `deadlineMisses` and its per-second line (`XR frame timing: the GPU finished after the rendering deadline on N of M frames in the last second`) found it:

| Run | Late frames per second | Mean overrun | Worst |
| --- | --- | --- | --- |
| Wait for the optimal input time (default), board close | 80 to 91 of 90 | 0.5 to 1.3 ms | 2.6 ms |
| The same, board far (fewer pixels) | 15 to 44 of 90 | 0.2 to 0.7 ms | 3.0 ms |
| `setRendering(.optimalInputWait(.disabled))`: encode right after the update | 56 of 92 | 0.42 ms | 2.2 ms |
| A room probe's prefilter, either run, for about six seconds | every frame, at 71 to 78 fps | 5 to 15 ms | 21 ms |

The compositor keeps some slack past its stated deadline (the loop still gets 90 frames a second with nearly every frame a millisecond late), and the frames beyond that slack are the hops. Encoding right after the update starts the GPU about 6 ms earlier and brought the hops down to a few; it does not make the frames finish before the deadline, so the frame's GPU work is close to the whole window. The remedies, in order of what they keep: late-latching the head pose (encode before the wait, write the eye matrices after it: the early GPU start and the fresh head pose), cutting the frame's GPU cost (the temporal resolve, the render quality), and spreading a probe's prefilter over frames so a new probe does not cost six seconds at 74 fps.

### The adaptive wait (done)

`setRendering(.optimalInputWait(.always | .never | .automatic))`, automatic by default: the loop waits for the optimal input time while the frames meet the deadline, stops once a second had late frames (one in twenty or more), and waits again once a second's least slack before the deadline would have covered the longest wait skipped, with a 1.5 ms margin. The fresh head pose whenever the budget allows; the compositor's reprojection of an older prediction only when it does not. `optimalInputWaitActive` says what the last frame did; the viewer's switch maps to automatic or never and its summary notes "input-time wait skipped (automatic)".

### What the passes cost (2026-10-15, the viewer at 100 Hz, render quality at the platform default)

With the GPU pass timing on, a second of late frames names its heaviest passes. The board close (the tour's first phase, mistaken at first for a probe's prefilter): Forward 8.4 to 9.9 ms, TAA 1.4 to 3.5 ms, the depth pyramid 1 to 2.5 ms, a frame of 12.5 to 13 ms at 72 to 80 fps. The board far: Forward 4.2 to 6 ms, a frame of about 10 ms, half its frames a millisecond late. One switch at a time: TAA only (no MSAA) saves 1.5 to 2 ms, the one real saving; occlusion cull off removes the pyramid, built needlessly for one object's many meshes, for half a millisecond of frame rate at most; shadow taps 4 saves nothing measurable. The far phase can meet 100 Hz with TAA only and occlusion cull off; the close phase cannot by settings: the Forward pass is the board's own shading, scaling with the pixels it covers.

### Half-rate pacing (done)

`setRendering(.framePacing(.fullRate | .halfRateWhenLate | .halfRate))`, half rate when late by default. `XRHalfRatePolicy` decides from each second's measurements. It enters when, with no wait for the optimal input time left to skip, the display skipped a refresh for one frame in ten or more (from the spacing of the compositor's consecutive predicted presentations) or one frame in ten or more finished past the deadline by more than the deadline's margin, for two seconds running: the deadline sits 15 ms before the presentation on the headset, so a frame a few milliseconds past it is still shown on time (the full-rate runs with nearly every frame a millisecond late dropped nothing), and fewer hops than one in ten are fewer than the steps the half rate adds. While active the loop waits, before it asks the compositor for the next frame, until the next slot of a fixed grid: the instant the pacing started from plus a whole number of cadences (two refreshes, or three or four when the frame's typical GPU work, its mean span plus a fifth and 3 ms of encode, needs them; the cadence rises at once and falls after two fitting seconds, a millisecond's deadband at the boundary). The query itself never blocks, the compositor predicts the presentation three refreshes after it, so the grid, not the previous frame's presentation, sets the spacing, and the predicted presentations come exactly a cadence apart (22.2 ms flat at 90 Hz every second of the heavy run). Each frame is posed for the compositor's prediction plus the refreshes the frames land past it: none while they finish within the deadline's margin less a 2 ms safety, else as many as the rest reaches. Nothing waits for the GPU: the next frame's work queues behind the previous one's. (Lessons from the device: a first version let every other frame go unsubmitted, and the compositor never releases a frame taken and not submitted, three of them aborting the app with "We reached more than 3 frames in flight", so the pacing is in the taking; a second waited for each frame's GPU work before taking the next, and the idle gaps let the GPU clock down, the Forward pass going from 9 to 12 ms and the cadence from two to three, 30 fps, so the GPU is kept queued; a third snapped the query to the grid of the last frame's presentation instant, which the compositor predicts three refreshes ahead, so every frame waited a refresh too many, 30 fps again; a fourth counted the cadence from the instant the last frame was handed out, which drifted with the query's own lateness and gave an uneven 16.6 ms.) It leaves when the rendered frames' GPU work has fitted 80% of the refresh for two seconds running. `halfRatePacingActive` says the state; the per-second line adds "half rate, every N refreshes, landing +N", the frames past the margin and the refreshes skipped, and the spacing of the presentations; the viewer's switch maps to half rate when late or full rate, with "half-rate pacing active" in its summary. By eye on the device (2026-10-15, MSAA 4× with TAA and the occlusion cull at 90 Hz, the GPU at 13 to 15 ms a frame): the even 45 fps shows fewer jumps than the hopping full rate did, and still a visible stepping: a sweep at half the refresh rate is not smooth, it is evenly unsmooth, and the frame rate itself is the limit there. The cure for that configuration is the frame's GPU cost (the Forward pass at 6 to 9 ms, the 4× resolve, the HZB built for one object), not the timing.

### The frame's cost on the headset (`feature/xr_frame_cost`, in part)

The heavy configuration (MSAA 4× with TAA, the occlusion cull on, foveated 2048×1984 per eye, render quality at the platform default) measured on 2026-10-15 at 90 Hz with the sun switch off: at full rate the GPU took 16.8 to 17.6 ms a frame (Forward 8.7 to 9.2, TAA 2.2 to 3.4, Shadows 1.7), and paced to every other refresh 14 to 16 ms (the Forward pass 10 to 14 at the lower clock an idle GPU falls to). The viewer's per-pass line, both eyes summed, with the board close: Forward 10.40 ms (3.46 vertex, 6.94 fragment), TAA 2.50, Shadows 1.17 (0.93 of it vertex), Post 0.76, Culling 0.14, Transparency 0.04. The budget is 11.1 ms. Five readers mapped the passes, the forward shading, the pyramid, the temporal resolve and the timing labels, and each candidate cut was refuted against the code before it was taken; the ones that held:

- **The depth pyramid's gate counts objects.** A model loaded from a file is one entity per node under the entity it was set on, so one dartboard was many culling entities and built the depth copy, the pyramid and the occlusion test every frame (1 to 2.5 ms) for an object that hides nothing but itself. The gate counts an entity with its children as one. Confirmed on the device: HZB left the pass list.
- **No shadow cascades for a sun at zero intensity.** The viewer's sun switch leaves the light at intensity 0 with `castsShadow` on, and the cascades were drawn regardless, two 2048² depth maps of every part of the board: 0.5 to 2.9 ms a frame with no sun. The shading multiplies the shadow by the intensity, so the cascade update refuses a sun at zero.
- **The look pass without a depth attachment.** It drew through the post-process descriptor, which loads and stores the frame's depth for the passes that read it; the look pass never touches depth. It has its own colour-only descriptor and pipeline: a full-size depth read and write per eye gone.
- **The frame's colour textures compressible.** The lit colour, the composite, the look and anti-aliasing outputs and the environment were created with `shaderWrite` usage, which no kernel uses and which forbids the GPU's lossless compression of a texture; every resolve, read and write of them moved uncompressed pixels.
- **Fence waits before the fragment stage.** Every scene pass waited on the shared fence before its vertex stage, so one pass's tiler could not run while the previous pass shaded; a pass's vertex stage reads nothing a previous pass's fragments wrote, and every resource is hazard-tracked, so the wait moves to the fragment stage at 23 sites, as the temporal resolve already had it. The Forward pass's 3.5 ms of binning can now overlap the shadows' and culling's fragments.
- **No transparency pass with nothing transparent.** Its encoder loaded and stored both full-size attachments to draw nothing; the GPU spends 0.04 ms on an empty pass, so this one is tidiness.
- **The per-second line lists every pass with their sum**, and the frame's own GPU time after the frame before, so the device's numbers read against the span.

What did not hold, and why: the half-size pyramid, its single encoder and the first eye's copy skipped matter only to multi-object scenes; the transparency pass's cost was a guess an order of magnitude too high; moving the grade into the temporal resolve changes the history's space; float to half across the forward shader is not safe without a device check.

The device run of those cuts (the sun off, 90 Hz): the frame held the full rate, 8.4 to 9.0 ms a frame, no refresh skipped after the placement, the pacing never engaged; Forward 10.40 to 8.02 ms, TAA 2.50 to 2.06, Post 0.76 to 0.45, the shadows and the transparency pass gone, the cull 0.14 to 0.01.

What remained was the Forward pass's fragment work (5.5 of its 8 ms) and the temporal resolve, whose levers are in the shaders. Every `.metal` file is included by `UntoldEngineKernels.metal` and only the prebuilt metallibs ship, so those cuts rebuild the kernel libraries; they are on `feature/xr_shader_cost`, stacked on the cost branch, after twelve reviewers (Metal semantics, picture equivalence, performance, three per cut) tried to refute each:

- **The sun by its intensity.** The cascade shadow taps and the sun's Cook-Torrance BRDF are evaluated only when the sun's intensity is not zero, in the forward shader, the two light passes and the transparency shader, on a per-frame constant, so the branch is uniform; any other intensity takes the old path in the old order of products, bit for bit. The CPU's cascade gate says the same. Reviewers' estimate: 1 to 1.5 ms with the sun off.
- **Each material map sampled only when the material has it**, the normal map's decode and tangent transform included; the flags are per-draw constants, so the implicit-derivative samples stay in uniform control flow, as the height-map branch already was. The reviewers put this at nothing measurable (the removed samples were on nil textures); it stays as a cleanup.
- **Once per pixel instead of twice**: the view vector, the environment's rotation angle in radians, and the BRDF lookup table's pair, from which both reflectances derive (`brdfIntegration`); the rotation of the lookup direction is skipped at angle zero, the headset's room probe's case, with the normalize kept, since the simulator's light pass hands in a G-buffer normal as stored and the equirectangular latitude's `asin` is not scale-invariant (the reviewers' one blocker); that `asin` is clamped now, which removes a pre-existing chance of a NaN pixel at the poles.
- **The temporal resolve leaves early** for a pixel with no history or at the clear depth, before the rate-map decodes, the reprojection and the velocity fetch, which is most of a passthrough frame; the foveation rates are read as texels per screen pixel over the same screen interval from both maps, a second decode of each, instead of derivatives across the quad (which forbade any early return): the ratio is exactly 1 wherever the two maps agree, zone boundaries included, and where they differ a band at most a pixel wide before a boundary weighs a little differently than the quad's span did. Reviewers' estimate: 0.2 to 0.4 ms.

The picture tests (the material shading, per-fragment lighting, glass, probe, post-effects and temporal tests, 148 in the targeted run) pass on the rebuilt library. On the viewer's side, MSAA 2× under TAA costs 1.5 to 2 ms less than 4× for edges the temporal accumulation already resolves.

### The true late latch (not done: a refactor, for a decision)

The head pose is consumed on the CPU while the frame is encoded: the view and projection matrices are read at 41 places in `RenderPasses.swift` (each pass copies them into its own uniforms: the batches, the grid, the sky, the environment, the shadow cascades, the SSAO's projection scale), 7 in `CullingSystem.swift` (the frustum planes and the view-projection for the occlusion test), 5 in `TemporalAntiAliasing.swift` (the jitter and the reprojection), 3 in `GraphBuilder.swift`, and a few in the extension surface and the muscle debug pass. Encoding before the wait and writing the pose after it therefore needs one per-frame, per-eye camera buffer (view, projection, their inverses, the view-projection, the eye position, the jitter) bound at a fixed index for every pass and read by every shader in place of the copies; the frustum planes built on the GPU from it (a small kernel before the culls, or the culls reading the matrices directly); the temporal resolve taking the previous frame's buffer as its reprojection; the shadow cascades fitted from a provisional pose a few milliseconds older, which is harmless; and the drawable, with its foveation rate maps, taken before the wait, earlier than Apple's sample does, to be verified on the device first. It touches every pass and most shaders, a few days of work, and it should follow #1359 rather than ride on it. It buys about 3 ms of GPU window (the encode after the wait) with today's head pose; the adaptive wait buys about 9 ms with an older one when needed.

## 9. Size, and the risk to the three draft pull requests

Size: about 330 lines in `Sources` (`FrameTime.swift` 130, `TransformTrack.swift` 150, the loop and context wiring 50), 330 lines of tests, this document. The viewer's change is a few lines.

The branch was cut from `try/xr_foveation_specular_aa` and then rebased onto `feature/xr_headset_rendering` (untoldengine/UntoldEngine#1359, which supersedes the three drafts below), with no conflicts; it sits on top of foveation (`feature/xr_foveation`, untoldengine/UntoldEngine#1342), temporal anti-aliasing (`feature/taa`, untoldengine/UntoldEngine#1343) and the back-face lighting fix (`bugfix/backface_lighting`, untoldengine/UntoldEngine#1344). Landing order: #1359, then this change on top of it.

- **Foveation (#1342)**: textual overlap in `UntoldEngineXR.swift`. The PR rewrote the drawables loop (`for drawable in drawables`, the rate maps); this change adds two lines inside it (the once-per-frame revision check) and five properties next to the foveation ones. Applied after the PR: clean. Applied on `develop` without it: the loop does not exist in that form, so the hunk must be redone by hand (two lines). `GraphBuilder.swift` is touched by both, in different functions (`applyXRFoveationViewport` against the three context builders), ~15 lines apart: at worst an adjacent-hunk conflict.
- **Temporal anti-aliasing (#1343)**: one certain conflict, three lines: `updateXR` in `UntoldEngine.swift`, where the PR added `ObjectMotion.shared.beginFrame()` and this change adds the `presentationTime` parameter; the resolution keeps both. Semantically the change helps TAA: `ObjectMotion` records each entity's previous transform per frame, and an object posed for the presentation instant moves by whole periods, so its motion vectors are steady instead of carrying the update's lag jitter.
- **Back-face lighting (#1344)**: shaders only, no overlap.

Behaviour changes to note in review: `timeSinceLastUpdate` is the presentation delta (exactly a period or a multiple on the headset; the draw spacing on a Mac as before); `timeSinceLastUpdatePreviousTime` holds the presentation time; `EngineTimingStats.frameTotalMs` on the headset is the presentation delta.

## 10. Follow-ups

- The headset check (section 8), with the viewer's change of section 3.4.
- A `TransformTrackComponent` with a system that samples it at `currentFrameTime.presentationTime` every frame, so a track plays with no game code; `TransformTrack` is the value type it would hold.
- `updateCameraPath(frame:)` sampling from an absolute time.
- A presented-time feedback for the `MTKView` estimate (section 6).
- A late-input hook after the wait (section 4), or its stronger form from the headset results: late-latching the head pose, so the frame is encoded before the wait and only the eye matrices are written after it.
- The room probe's prefilter spread over frames (section 8).
