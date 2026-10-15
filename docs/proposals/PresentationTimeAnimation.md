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
