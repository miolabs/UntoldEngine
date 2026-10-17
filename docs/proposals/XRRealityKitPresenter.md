# A second presenter for the engine's XR frame: RealityKit — Plan

Status: plan; stages 0 and 1 built (see Progress). Tracked as untoldengine/UntoldEngine#1371; the notes are on the fork as draft PR miolabs/UntoldEngine#80. Written 2026-10-16 against the fork develop checkout of that day (the main `UntoldEngine` folder), after the decision recorded in `SpatialPersonasResearch.md` section 8: the engine keeps rendering every frame itself, and for the games that want Spatial Personas a `RealityView` immersive space presents the frame instead of a `CompositorLayer`.

Question: how does the engine support a second way of presenting its stereo frame on visionOS, next to Compositor Services, without a second renderer and without touching the games that stay on Compositor Services?

## TL;DR

- The engine's XR module is one file that does three jobs at once: the XR runtime (ARKit session and providers, world anchors, environment lighting, spatial input, PSVR2 observers, diagnostics), the Compositor Services frame loop (`LayerRenderer` frames, timing, pacing, drawables, foveation, present, deadlines) and the generic per-frame driving of the renderer (update, cull once, each eye, depth pyramid, stats). Only the second job is specific to Compositor Services. The core renderer itself is already texture-bound (`renderXR` takes a pass descriptor and matrices), and the editor has already driven it from a loop of its own through a small frame-source protocol.
- The plan cuts that seam inside the engine (stage 1), then adds a second frame source that gets its textures from RealityKit (stage 2): the engine draws each eye into a `LowLevelTexture` and a compute kernel of ours turns each eye's depth into a `LowLevelMesh` grid; a `RealityView` shows the two grids with a shader-graph material that picks the eye with the Camera Index Switch node. The system then owns the space, so the group immersive space, the spatial template and the Personas are the system's; the engine's LOD, glass, streaming, batching, culling, splats and every shader keep running unchanged.
- Four unknowns decide the details and are settled first in a throwaway spike on the headset (stage 0): the per-frame texture hand-off, the per-eye material, the pose timing and origin, and the Personas themselves. Then stages 3 to 5 tune quality, wire SharePlay and CoolSaber, and ship templates and docs.
- About six to seven weeks of engine work in all, of which stage 1 (the seam, one week, no headset needed) can start now and is worth doing on its own: it also gives the editor's Mac preview a home in the engine.

## 1. What the engine has (2026-10-16)

- `Sources/UntoldEngineXR/UntoldEngineXR.swift` (1,696 lines) is `UntoldEngineXR`: `init(layerRenderer:)` → `initUntoldXR` (render path, spatial-event bridge, PSVR2 observer, lighting observer, session monitor, `startARKitProviders`, `UntoldRenderer.createXR(...)` with the layer's colour and depth formats and a guessed viewport), `runLoop()` → `renderNewFrame()` (queryNextFrame, predictTiming, startUpdate, progressive loader tick, spatial input, `syncStreamingCameraPosition`, `updateXR(presentationTime:)`, endUpdate, the wait for the optimal input time with the half-rate policy, startSubmission, `queryDrawables`, device anchor per drawable with the cached-anchor fallback, `executeXRSystemPass`, stats, endSubmission) and `executeXRSystemPass` (semaphore, command buffer, viewport fit, visible entities snapshot, frustum cull, Gaussian cull/preprocess/sort, per view: camera matrix from `deviceAnchor × view.transform`, `computeProjection`, the pass descriptor on the drawable's textures with reverse Z, `makeFoveationFrame`, `renderer.renderXR`, then `buildHZBDepthPyramid`, `encodePresent`, the deadline accounting in the completion handler, commit). The drawable is read in ten places (colorTextures 7, depthTextures 4, deviceAnchor 4, rasterizationRateMaps 3, frameTiming 3, target 3, views 2, encodePresent 2, depthRange 2, computeProjection 1); the frame in seven; the clock throughout the pacing.
- The other files of the module are presenter-independent already: `UntoldEngineXRWorldAnchors.swift` (280 lines, world anchors incl. `sharedWithNearbyParticipants`), `XREnvironmentLightingSystem.swift` (964, the ARKit light estimation probe), `XRSpatialGestureRecognizer.swift` (514, `SpatialEventCollection` → `XRSpatialInputSnapshot` → `InputSystem`), `UntoldEngineXRShutdown.swift` (54, `resetUntoldWorldForXR`, `shutdownUntoldEngineXR`).
- The core renderer: `UntoldRenderer.createXR(configuration:device:commandQueue:colorPixelFormat:depthPixelFormat:viewPort:)` (Renderer/UntoldEngine.swift:813), `updateXR(presentationTime:useExternalStatsLifecycle:)`, `setXRCameraWorldPosition`, `finalizeXRStatsAndMonitors`, `renderXR(commandBuffer:passDescriptor:viewMatrix:projectionMatrix:eyeIndex:)` (:895), `fitStereoTargets(to:)`, plus the public helpers the loop uses (`performFrustumCulling`, `executeGaussianFrustumCulling`, `executeGaussianPreprocess`, `executeRadixSort`, `buildHZBDepthPyramid`, `acquireUniformFrameSlot`, `tripleVisibleEntities`, `visibleEntityIds`, `cullFrameIndex`, `commandBufferSemaphore`, `renderInfo`). `renderInfo.immersionStyle` (`UntoldImmersionMode`), `isXRStereoMode`, `currentEye`, `viewPort`, `xrFoveation`, `xrEyeCameraPosition`.
- The editor's Mac preview (`UntoldEditor/Sources/UntoldEditor/Editor/VisionPro/`): `VisionProFrameSource.swift` (the protocols `VisionProFrameSource` / `VisionProFrame` and the structs `VisionProEye` / `VisionProFrameEyes`), `CompositorFrameSource.swift` (the `LayerRenderer` adapter for macOS 26 remote spaces) and `VisionProPreviewLoop.swift` (the generic driver: update, wait, acquire eyes, cull once, each eye, pyramid, present, stats; tested with a texture-backed source). This is the seam, already proven, in the wrong repository for a game to use.
- Games: every visionOS example and both build templates (`BuildSystem/BuildTemplates.swift:1254` and `:1594`) do `ImmersiveSpace { CompositorLayer(configuration:) { layerRenderer in UntoldEngineXR(layerRenderer:) ... Thread { xr.runLoop() } } }`. CoolSaber adds SharePlay (`SaberSessionController`, `SaberDuelMailbox`).
- Tests: `Tests/UntoldEngineRenderTests/XRImmersionContractTest.swift`, `UpdateXRRenderingSystemTest.swift`, `XRFoveationTests.swift` cover the XR render graph, immersion alpha and the rate maps; nothing covers the loop itself (it needs a `LayerRenderer`).
- SDK facts (XROS 27.0): `LowLevelMesh` and `LowLevelTexture` since visionOS 2 with GPU-side updates (`LowLevelMesh.replace(bufferIndex:using:)` and `LowLevelTexture.replace(using:)` hand back a Metal buffer or texture to write within a command buffer; both are main-actor calls), `LowLevelDeviceResource(sharedTextureHandle:)` in 27 for a zero-copy shared texture, `SceneEvents.Update` once per RealityKit frame on the main thread, `SpatialEventGesture` delivering the same `SpatialEventCollection` the Compositor bridge already consumes, the Camera Index Switch, Unlit Surface (with "Apply Post Process Tone Map" and "Opacity Threshold") and Geometry Modifier nodes, `ShaderGraphMaterial(named:from:in:)` loading a MaterialX graph from a `.usda` in a bundle.

## 2. Design

### 2.1 Three pieces instead of one

```
UntoldEngineXR (public API unchanged for games)
 ├─ XRRuntime            ARKit session + providers, world anchors, environment lighting,
 │                       spatial input bridge, PSVR2 observers, device-anchor cache, diagnostics
 ├─ XRFrameLoop          the generic driver: for each frame from a source — update, wait,
 │                       acquire eyes, cull once, draw each eye, pyramid, unproject (if asked),
 │                       present, stats; owns nothing platform-specific
 └─ XRFrameSource        where frames come from
     ├─ CompositorFrameSource      LayerRenderer: timing, pacing, drawables, foveation, present, deadlines
     └─ RealityKitFrameSource      (new target) RealityKit textures and grids, the main-thread cadence
```

The frame contract is the editor's, moved into the engine and widened for what the Compositor path has that the editor did not need:

```swift
public protocol XRFrameSource: AnyObject {
    func nextFrame() -> XRFrame?          // blocks until the presenter wants a frame; nil when it is gone
    func stop()
}
public protocol XRFrame: AnyObject {
    var timing: XRFrameTiming { get }     // predicted presentation (media time), optimal input time, deadline (optional)
    func beginUpdate(); func endUpdate()
    func waitForDrawingTime()             // Compositor: the clock wait; RealityKit: nothing
    func beginDrawing() -> Bool
    func acquireEyes() -> XREyes?         // nil: nothing drawn, nothing presented (the compositor's "no drawable")
    func present(commandBuffer: MTLCommandBuffer)   // Compositor: encodePresent; RealityKit: the grid unprojection
    func endDrawing()
}
public struct XREye { color, depth: MTLTexture; viewFromOrigin, projection: simd_float4x4; viewport: MTLViewport; foveation: XRFoveationFrame? }
public struct XREyes { originFromDevice: simd_float4x4?; eyes: [XREye]; primary: Bool }   // primary false: a capture target
```

`XRFrameLoop` is `renderNewFrame` + `executeXRSystemPass` with the drawable and the frame replaced by the protocol: the same order of calls, the same semaphore, the same stats. The half-rate policy, the optimal-input wait and the deadline accounting move into `CompositorFrameSource`, where the clock is; the loop only asks the source for the timing it has.

### 2.2 The RealityKit presenter

A new library target `UntoldEngineXRRealityKit` (visionOS only, depends on `UntoldEngineXR`), so that games on Compositor Services never import RealityKit. It provides:

- `RealityKitPresenter`: owns two `LowLevelTexture`s (colour, `bgra8Unorm_srgb`, the render size), two of the engine's own depth textures (`depth32Float`, reverse Z as today), two `LowLevelMesh` grids (N×M vertices, position + uv + one half attribute for the tear mask, a static index buffer, one part with a large bound), the two entities (one per eye, identity transform, `ModelComponent(mesh: MeshResource(from: grid), materials: [eyeMaterial(eye)])`), the material, an input entity, and the ticket mailbox.
- `RealityKitFrameSource: XRFrameSource`: `nextFrame()` blocks on the mailbox. Once per RealityKit frame, on the main thread (`SceneEvents.Update`), the presenter makes a command buffer, calls `replace(using:)` on both colour textures and `replace(bufferIndex:using:)` on both grids, stamps the ticket with a target presentation time (`CACurrentMediaTime()` + a lead, two refresh periods to start, tuned in stage 3) and posts it. If the engine thread is still on the previous ticket, the new one replaces it (dropped tickets are counted). The frame's `acquireEyes()` queries the runtime's device anchor for the ticket's time (with the cached-anchor fallback the Compositor path has), builds the two eyes from a nominal IPD and the presenter's projection (a field of view a few degrees wider than the headset's per-eye view, with the same reverse-Z infinite projection the engine uses), and hands back the ticket's colour textures and the presenter's depth textures. `present(commandBuffer:)` encodes the unprojection kernel for each eye into the ticket's command buffer; the loop commits it as it does today, and RealityKit shows the new content when the command buffer completes.
- The unprojection kernel (`Shaders/XRGridUnproject.metal`): one thread per grid vertex; samples the eye's depth at the vertex's pixel (the nearest depth of its footprint, so that near silhouettes are kept), unprojects with the inverse projection and the inverse view into the origin's space, writes position and uv; depth 0 (reverse-Z far) goes to a far shell (100 m) so that sky and passthrough areas keep a surface; a vertex whose footprint spans a depth jump above a threshold gets the tear mask set (stage 3 decides what the material does with it).
- The material (`Resources/XRPresenter.usda`, a MaterialX graph written by hand and checked in Reality Composer Pro): parameters `colorTexture` (that eye's texture) and `eye` (1 left, 2 right); Camera Index Switch (integer, mono 0, left 1, right 2) compared with `eye` → 1 or 0; opacity = texture alpha × that; Unlit Surface with the colour, the opacity, "Opacity Threshold" 0.5 and "Apply Post Process Tone Map" off. Each entity is therefore discarded in the other eye, and alpha below the threshold leaves passthrough (mixed immersion) or black (full).
- Input: one invisible entity with `InputTargetComponent` and a large collision sphere around the user, so that every pinch is targeted; the `RealityView` carries a `SpatialEventGesture` whose `SpatialEventCollection` goes to the existing bridge (`enqueueSpatialInputSnapshot`), the same type the `LayerRenderer.onSpatialEvent` path feeds today. Hands, PSVR2 accessories, planes, world anchors and the lighting probe are ARKit providers on the runtime's own session and need no change.
- `UntoldXRPresenterView`: the SwiftUI view a game puts in its `ImmersiveSpace`: makes the `RealityView`, builds the presenter, creates the `UntoldEngineXR` with it (`init(presenter:)`), starts the engine thread with `runLoop()`, subscribes to `SceneEvents.Update`, and on disappear stops the source (the loop ends, the thread exits) and calls `shutdownUntoldEngineXR` as the Compositor apps do.

### 2.3 Coordinates, immersion, pacing

- Spaces: the grid positions are in the ARKit origin's space, the entities sit at identity in the RealityKit scene. In a plain immersive space the two origins coincide; in a group immersive space the system moves the space origin (`immersiveSpaceDisplacement`), and stage 4 settles whether the device anchor already includes it or the presenter applies it to the entities.
- Immersion: `.mixed` and `.full` as today through `renderInfo.immersionStyle` (the alpha the engine writes); `.progressive` comes from RealityKit for free. The `ImmersiveSpace` modifier `immersionStyle(selection:in:)` stays the game's.
- Pacing: RealityKit runs at the display rate and decides when to render the grids; the engine's loop runs once per ticket, so an engine frame that takes longer than a refresh simply makes RealityKit show the previous frame again, which is what the half-rate policy did by hand. The policy stays with the Compositor source. Stats get a RealityKit set: ticket age at pickup, dropped tickets, engine CPU and GPU time, lead in use.

## 3. Stages

### Stage 0 — the headset spike (3–4 days, needs the Apple Vision Pro; a second one or a FaceTime participant with a Vision Pro for the last item)

A throwaway visionOS app (xcodegen `project.yml` like the arcade examples, under `UntoldArcade/Spikes/RealityKitPresenter`, deleted or kept as the try-out app once stage 2 exists) with no engine: a `RealityView` immersive space, two grids, a test pattern drawn by a small Metal pass into `LowLevelTexture`s at 90 Hz from a thread of its own, the per-eye material, the depth grid fed from a synthetic depth. It answers, in this order:

1. `LowLevelTexture.replace(using:)` and `LowLevelMesh.replace(bufferIndex:using:)` once per frame from the main thread, the command buffer committed from another thread: frame rate, dropped frames, and what happens when the previous command buffer is still in flight. If this costs frames, the visionOS 27 route (`LowLevelDeviceResource(sharedTextureHandle:)` with two device resources toggled per frame) is tried next; the plan assumes the first.
2. The material: Camera Index Switch inside the graph discarding the other eye; the tone map off reproducing a known colour ramp; alpha below the threshold showing passthrough.
3. Timing and origin: `queryDeviceAnchor(atTimestamp:)` in a `RealityView` space, the lead that makes a head-locked test pattern stable, and whether the ARKit origin and the scene origin coincide (a cube at the device anchor must sit on the head).
4. Personas: with `supportsGroupImmersiveSpace`, a SharePlay session from a FaceTime call: does the other person's Persona render in front of and behind the grid in `.mixed` and in `.full`, with the depth the grid provides.

Done: a one-page result at the end of this note's "Progress" section with the numbers; the four decisions D2–D5 below taken.

### Stage 1 — the seam in the engine (1 week, no headset: the simulator and the tests)

Branch `feature/xr_frame_source` on a worktree `UntoldEngine-xrseam`, from the fork develop (the upstream PR is cut from upstream develop at the end, as always).

- Split `UntoldEngineXR.swift` into `XRRuntime.swift` (ARKit, anchors, lighting hooks, input bridge, PSVR2, diagnostics, the device-anchor cache and recovery), `XRFrameSource.swift` (the protocols and structs of 2.1), `CompositorFrameSource.swift` (the `LayerRenderer` loop: `nextFrame`, timing, pacing, drawables with the capture-target rule, foveation frames, present, deadline accounting) and `XRFrameLoop.swift` (the generic driver). `UntoldEngineXR` keeps its public surface (`init(layerRenderer:)`, `setupCallbacks`, `start`, `stop`, `runLoop`, `setImmersionMode`, lighting and gesture entry points, `currentDevicePose`, the counters) and gains `init(frameSource:device:)`, which the Compositor init calls with a `CompositorFrameSource`.
- `createXR` gets its colour and depth formats and the viewport from the source instead of the layer configuration (the "VERIFY THIS" viewport guess goes with it: the source states the eye size).
- Tests (`Tests/UntoldEngineRenderTests/XRFrameLoopTests.swift`): a texture-backed `XRFrameSource` on macOS drives the loop for a few frames (frames drawn, eyes in order, the cull once per frame, the pyramid once, a frame without eyes neither drawn nor presented, stop ends the loop), as the editor's preview tests do; the existing XR tests stay green; SwiftFormat 0.60.1 rules (see `upstream-ci-quirks`).
- Verification: the visionOS simulator build of an arcade example and the CoolSaber app unchanged in behaviour; a headset run of one example to confirm the Compositor path still paces (the half-rate policy and the deadline counters are the regression risk).

Done: PR to upstream (`refactor: the XR frame loop takes its frames from a source`), no behaviour change, the module's file sizes halved.

### Stage 2 — the RealityKit presenter (2 weeks, headset for the last days)

Branch `feature/xr_realitykit_presenter` on the seam.

- The target `UntoldEngineXRRealityKit` in `Package.swift` (visionOS, depends on `UntoldEngineXR`, resources: the `.usda`), with `RealityKitPresenter.swift`, `RealityKitFrameSource.swift`, `XRGrid.swift` (the `LowLevelMesh` and its index buffer), `XRGridUnproject.metal` + `XRGridUnprojectPass.swift` (the kernel and its encoder; the kernel also compiles into the engine's metallib for the tests), `XRPresenterMaterial.swift` (loads the graph, sets the parameters), `XRPresenterInput.swift` (the input entity and gesture), `UntoldXRPresenterView.swift`, `XRPresenterStats.swift`.
- Tests on macOS: the kernel against a CPU reference (a synthetic depth of two planes and a hole: positions, the far shell, the tear mask), the grid's index topology, the `.usda` loading as a `ShaderGraphMaterial` with the two parameters (RealityKit on macOS loads shader graphs), the ticket mailbox (replace-not-queue, counts).
- The try-out app: the stage 0 spike rebuilt on the engine (or the ProceduralGeometry example with its `ImmersiveSpace` body swapped for `UntoldXRPresenterView`), run on the headset: the scene appears on the grids, head motion stable, mixed and full immersion, pinch events reaching the engine, hands and PSVR2 wands tracked, the stats on screen.

Done: an example app on the presenter in the arcade (`UntoldArcade/ProceduralGeometry` gets a second scheme, or a new `RealityKitPresenterExample`), the fork PR with before/after frame-time numbers against the same scene on Compositor Services.

### Stage 3 — quality and cost (1–2 weeks, headset)

- The lead: measured swim of a world-locked object against the Compositor path; the lead becomes adaptive (ticket age + GPU time of the last frames).
- Edges: the tear mask in the material (discard the stretched triangles), grid density per region (denser near the centre), the nearest-depth footprint rule tuned.
- Moving objects: the engine's existing motion prediction (`ObjectMotion`) posed for the ticket time; a measurement of blade lag in CoolSaber against the Compositor build.
- Cost: the mono-plus-depth mode (one centre eye rendered, both grids built from it, half the GPU) measured as an option (D3).
- Glass: the depth the grid takes (opaque only, or with glass) as a per-game setting (D4).

Done: the numbers in this note; a decision whether the hybrid ships for CoolSaber.

### Stage 4 — SharePlay and CoolSaber (1 week, two headsets or a FaceTime participant on a Vision Pro)

- The group immersive space origin (`immersiveSpaceDisplacement`, `localParticipantState.pose`) applied so that the engine's scene and the system's seating agree; `groupActivityAssociation` on the view as the forum advises.
- CoolSaber on the presenter: `CoolSaberVisionOSXRApp` gets a second `ImmersiveSpace` body (the presenter) chosen by a setting, `SaberSessionController` unchanged, the avatar of the option-A card as the fallback when the opponent is not spatial.
- Verification: the Persona in the arena, occlusion against the arena geometry, the opponent's blades in step with the Persona's hands.

Done: CoolSaber playable with a Persona; the finding recorded in `SpatialPersonasResearch.md`.

### Stage 5 — templates, docs, editor (3–4 days)

- `BuildTemplates.swift`: a "RealityKit presenter" variant of the visionOS app template (an option of the build system, default stays Compositor Services), its README lines.
- Docs: a page on choosing the presenter and what it costs (from `SpatialPersonasResearch.md` section 8).
- Editor (optional, its own PR): the Mac preview's `VisionProFrameSource` replaced by the engine's `XRFrameSource` (the `CompositorFrameSource` of macOS 26 remote spaces becomes a second platform adapter of the engine's), removing the duplicate loop from the editor.

## 4. Decisions

- **D1 A separate target.** `UntoldEngineXRRealityKit` rather than RealityKit inside `UntoldEngineXR`: Compositor games keep their imports and binary; the presenter can require visionOS 2 features without touching the module's minimum.
- **D2 The texture hand-off** (stage 0 decides): `replace(using:)` from the main thread per frame as the baseline (visionOS 2, RealityKit manages the completion), the shared handle of visionOS 27 as the fallback if the main-thread coupling costs frames.
- **D3 Per-eye rendering** by default; the mono-plus-depth mode is measured in stage 3 and offered as a setting if the look holds.
- **D4 The grid's depth**: opaque geometry only by default (glass excluded, as the research note's table explains); a per-game switch to include glass.
- **D5 Render size**: the headset's per-eye drawable size (1920 × 1824 on the current drawables) and the engine's existing render-scale setting; the presenter's projection a few degrees wider than the display's.
- **D6 The frame contract lives in the engine**, the editor adopts it later (stage 5, optional).
- **D7 The spike is throwaway code** outside the engine package; nothing from it is merged except what stage 2 rewrites with tests.
- **D8 The loop's public API does not change** for Compositor games in stage 1; the arcade apps and the templates compile as they are.

## 5. Risks

- The main-actor calls per frame (`replace(using:)`, `replace(bufferIndex:using:)`, entity updates) tie the presenter's cadence to the game's main thread; a busy SwiftUI window could drop tickets. Measured in stage 0; the shared-handle route decouples it on visionOS 27.
- RealityKit gives no presentation timestamp: the lead is an estimate (stage 3 makes it adaptive). A wrong lead shows as swim of world-locked content, the symptom to watch.
- The group immersive space origin may not be where the ARKit origin is; a wrong assumption shows as the scene and the Persona seating disagreeing (stage 4).
- The exposure of an unlit surface in mixed immersion may differ from the Compositor path even with the tone map off; compared in stage 0 with a colour ramp.
- Simulator: `LowLevelTexture` and `LowLevelMesh` work there, so the structure can be run without the headset; the shared handles do not; Personas never.
- The seam refactor touches the frame pacing that was tuned on the headset (half rate, deadlines); the stage 1 headset run exists for that.

## 6. Progress

### Stage 0 — the spike (2026-10-16: built and checked in the simulator; the headset run is pending)

- Where: `UntoldArcade/Spikes/RealityKitPresenter/` (xcodegen `project.yml`, committed on the arcade branch `spike/realitykit_presenter`, visionOS 2 minimum with the visionOS 27 parts behind `#available`), its `README.md` and the headset run in `CHECKLIST.md`. It builds for the simulator and, signed with automatic provisioning, for the Apple Vision Pro (the group-session entitlement is in the app). No engine code.
- What it has: a `RealityView` immersive space with two `LowLevelMesh` grids (256 × 240 vertices, position + uv + a half2 tear mask, static indices, one part bounded at ±200 m) at identity; a Metal pass of its own on a render thread drawing a synthetic scene (a floor on y = 0, a wall 2.5 m ahead with a round hole at head height, sky written with alpha 0) or a head-locked angular checker, plus view overlays (crosshair, 10° ring, a bar sweeping in 4 s, a 14-swatch sRGB ramp mirrored in the window, per-eye marks) into two 1920 × 1824 `bgra8Unorm_srgb` textures; tickets from `SceneEvents.Update` (main thread: command buffer, the replace calls, target time = post time + lead); a compute kernel filling the grids from the synthetic depth in the space of `queryDeviceAnchor(atTimestamp: target)` with the engine's retry-then-cache fallback; the hand-written material of section 2.2 (`Resources/EyeMaterial.usda`); a window with the switches (route, lead, immersion, pattern, anchor cube, passthrough sky, overlays, texture size, grid update, head-locked distance, IPD) and the numbers; a `GroupActivity` with `supportsGroupImmersiveSpace` and the side-by-side template, opening the space from `groupImmersionStyle`.
- Found while building:
  1. **Shared Metal textures: device yes, simulator no.** `makeSharedTexture(descriptor:)` and `makeSharedTextureHandle()` typecheck for the visionOS device target (XROS 27.0 SDK) and are marked unavailable only in the simulator SDK, which is why Apple's sample guards them with `#if targetEnvironment(simulator)`; the spike, built against the simulator, took that for the platform (corrected 2026-10-16). D2's fallback therefore has two forms: the shared handle on the device, and the IOSurface-backed `LowLevelDeviceResource(textureDescriptor:iosurface:plane:)` the spike implemented, which runs in both and is the one to measure first. The spike has both as switches (two device resources per eye toggled with `replace(deviceResource:using:)`; the shared handle compiled out in the simulator), so the headset run compares the three routes; the plan's and the research note's wording stands.
  2. RealityKit samples a `LowLevelTexture` with v = 0 at the first (top) row: the grid uv is written unflipped (the USD-style `1 − v` showed the frame upside down). Stage 2's unprojection kernel must do the same.
  3. The graph loads as `ShaderGraphMaterial(named: "/Root/EyeMaterial", from: url)` from a loose `.usda` in the bundle, parameters `colorTexture` and `eye`; `ND_realitykit_geometry_switch_cameraindex_integer` compared with `eye` through `ND_ifequal_floatI`; a mono view (the simulator) shows the left eye's grid through an extra comparison. `MaterialParameters.Value.int` is `Int32`.
  4. A ticket's command buffer must be committed once `replace(using:)` or `replace(bufferIndex:using:)` ran on it, so when the render thread still holds the previous ticket the main thread posts none for that frame (a counted drop) instead of replacing it; closing the mailbox commits a leftover ticket empty.
- Simulator (visionOS 26.5 on the Mac, replace route, full size): 90 fps, 90 updates/s, 0 dropped tickets, ticket age at pickup under 0.1 ms, GPU 0.2 ms, commit→completion 3 ms, up to 2 command buffers in flight at commit, every anchor query answered for a 22 ms lead; the picture right (wall, hole showing passthrough, crosshair and ring centred, floor below). **The main thread spent 8 ms per frame inside the replace calls, with spikes to 19–27 ms, almost all of it in the two `LowLevelTexture.replace(using:)` calls (8.1–8.4 ms average, 20 ms max) and only 0.03 ms in the two `replace(bufferIndex:using:)`** — the risk of section 5, and a hint that RealityKit copies or reallocates the 14 MB texture per replace; the headset numbers decide, and the spike can halve the texture or freeze the grids to isolate it. One simulator screenshot caught the moving bar torn between two frames; whether that is RealityKit or the capture is for the headset to tell.
- D2–D5: pending the headset run (checklist items 1–4; item 3's observations give D5's frustum, item 2's edge notes feed stage 3).

### Stage 1 — the seam (2026-10-16: BUILT, commit `eec61bdc` on `feature/xr_frame_source`, worktree `UntoldEngine-xrseam`, no PR)

- The branch is cut from the fork develop `2cc546d2`, not upstream develop: upstream still lacks #1359, which the module's pacing code comes from; the upstream PR is cut once #1359 merges.
- What moved where (`Sources/UntoldEngineXR`): `XRFrameSource.swift` (129 lines, the contract, compiles on every platform: a source states its colour and depth formats and an eye size and hands out frames; a frame has an update, a wait, a drawing with one target per drawable, a presentation per target, an end), `XRFrameLoop.swift` (375, the old `renderNewFrame` from the update phase on plus `executeXRSystemPass` per target, moved verbatim with the drawable replaced by the target; compiles on macOS for the tests), `CompositorFrameSource.swift` (798, everything that touched the layer renderer: the state machine in `nextFrame`, the half-rate pacing, timing prediction and clock measurements, the optimal-input wait with its automatic mode, drawables with the capture-target rule, the foveation frames and their ring, `encodePresent` with the deadline handler, the once-a-second line), `XRRuntime.swift` (756, ARKit session and providers with their recovery, the device-anchor cache, the input bridge's event conversion, lighting hooks, the PSVR2 observer, the plane monitor, diagnostics), `UntoldEngineXR.swift` (177, the facade with the same surface, plus `init(frameSource:runtime:device:)`; `createXR` takes formats and eye size from the source; the public `initUntoldXR`, called by nothing in the arcade or the templates, is gone).
- Deviations from section 2.1: the runtime is created before the source and passed to the init (a source poses its frames by the runtime's anchors); an eye carries `deviceFromView` rather than `viewFromOrigin`, so the loop builds the view matrix with the old expression and the eyes keep their textures when there is no pose; `acquireEyes` returns one target per drawable, empty meaning nothing drawn nor presented; the rate-map ring is one slot deeper because the copy happens when the eyes are acquired, before the pass takes its semaphore slot; the dead `lastRenderedPresentation` is gone.
- Verified: Mac build clean, the strict-concurrency guardrail at zero before and after, lint only the local 0.62.1 rules the old file triggered too; core suite 1,755 + 59 component-kit tests (the one known folder-name failure), render suite 1,377 (18 comparison failures were a PATH python without cv2; rerun with the Homebrew python all pass); the eight new tests in `Tests/UntoldEngineRenderTests/XRFrameLoopTests.swift` pass and the three existing XR test classes stay green; simulator builds of the package scheme, ProceduralGeometry and the CoolSaber app; ProceduralGeometry ran 45 s in the simulator with the same once-only lines in the same order as the old loop (63 frames spaced 16.7 ms, no errors).
- A headset run must still confirm: the half-rate pacing entering and leaving under load with the paced frames an exact cadence apart, the deadline counters and the automatic wait moving as before, the capture target when recording the view, pinches reaching the engine through the bridge the compositor source now installs.
- Side findings, untouched: a world-anchors branch in progress edits the old file, and its four hunks belong in `XRRuntime.swift` after this split (expect that conflict when the two meet); a visionOS build template calls `startRenderLoop`, a method the module never had; the arcade's ProceduralGeometry lacks its `GameData` folder, which xcodegen refuses.
