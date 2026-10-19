# Spatial Personas in Untold games on visionOS — Research

Status: research, concluded; the decision and the plan are in `XRRealityKitPresenter.md`, tracked as untoldengine/UntoldEngine#1371 (fork draft PR miolabs/UntoldEngine#80). Researched 2026-10-16 against the XROS 27.0 SDK (Xcode 27.0, 27A266a), Apple's documentation and forum answers, and the engine as checked out that day. Question: we want FaceTime/SharePlay Spatial Personas inside some games, but the engine draws its immersive space with Metal through Compositor Services, where Personas never appear. What can the engine do about it?

## TL;DR

1. **The limit is real, Apple-stated, and unchanged in visionOS 27.** Two Apple Vision Pro engineers wrote in July and September 2025 that "personas are not available while displaying content with Compositor Services" and that "there is no way to use persona apart from a SharePlay experience"; both asked for a Feedback Assistant report. Nothing in visionOS 26 (WWDC25 session 294) or visionOS 27 (WWDC26 sessions 287 and 279, the "What's new in visionOS 27" page) mentions Personas for Metal apps, and the Compositor Services module interface in the XROS 27.0 SDK carries 22 `visionOS 26` availability marks and zero `visionOS 27` ones: the framework did not change this year.
2. **Personas only exist inside a SharePlay group session, placed by the system around a scene that RealityKit draws.** So the engine's picture has to pass through RealityKit for a Persona to stand in it. There are two ways: give RealityKit a texture of our frame, or let RealityKit render the scene itself.
3. **Apple has named the texture route.** Answering a question about the new `LowLevelRenderer` (June 2026): "Composition with RealityView content can be done by presenting [the] output to a LowLevelTexture, sampled from a RealityKit mesh via ShaderGraphMaterial. Depth compositing can also be approximated by using a tessellated grid mesh, again through ShaderGraphMaterial and geometry modifier." That applies to any renderer's output, ours included. A new visionOS 27 sample ("Displaying low-latency connected video") shows the zero-copy texture hand-off, stereo included.
4. **The Google answer is right about the conclusion and wrong about the mechanism.** `CustomMaterial` does not exist on visionOS (Apple, April 2025), so "pass your Metal code into RealityKit using CustomMaterial" cannot be done; the "privacy / out-of-process" explanation is nowhere in Apple's material; `LowLevelMesh` only helps in the sense that RealityKit draws it with RealityKit's materials, not ours.
5. **Four options**, in increasing cost: (A) keep Compositor Services and draw the other player ourselves — works today, no Persona; (B) a RealityKit lobby with Personas, the Metal space for play; (C) the hybrid: the engine renders off screen, RealityKit shows the frame on a depth-displaced grid, Personas stand in the scene with approximate occlusion; (D) RealityKit as the engine's visionOS render backend, which is what Apple's own Godot plugin and Unity's PolySpatial do.
6. **Recommendation:** do A now for CoolSaber (the poses are already synchronised; the opponent only has to be drawn), file the Feedback Apple asked for, and prototype C (two to three weeks) to measure the two things that decide it: the extra frame of latency on moving objects and the edge artifacts of depth-displaced grids. D is a second renderer; only for games whose look fits RealityKit's materials.

---

## 1. What Apple says (verified sources)

### 1.1 Personas and Compositor Services

| Source | Statement |
|---|---|
| Forum thread 791591 "Metal Compositor Service & Persona (VisionOS)", Jul–Sep 2025 | OP: a collaborative app shows Personas in a `RealityView` but "when I tried to use Compositor Layer ... the personas disappeared." Apple engineer 1: "There is no way to use persona apart from a SharePlay experience." Apple engineer 2: "personas are not available while displaying content with Compositor Services. If you would like to see this capability, I'd really appreciate it if you could file feedback." |
| Forum thread 801420 "SharePlay on the VisionOS with remote participants", Sep 2025 | A Metal immersive app using SharePlay and shared world anchors. Apple: same sentence about Personas; shared world anchors (`sharedWithNearbyParticipants`) "are for nearby participants only. For remote participants, you'd need to sync the position yourself." The OP reports nearby sharing working in the Metal app. |
| Forum thread 766378 "CompositorServices Or RealityKit", Oct 2024 | Apple: "both technologies cannot be used in the same immersive space." RealityKit's ECS (hover effects, physics, collisions) is not available to a Compositor Services app. |
| Forum thread 778674, Apr 2025 | Apple: "visionOS does not support custom shaders in RealityKit ... Compositor Services does support custom shaders, but is not compatible with RealityKit." |

### 1.2 Where Personas appear and what an app must do

From "Adding spatial Persona support to an activity" (GroupActivities), WWDC23 session 10087, WWDC25 session 318 and the visionOS 26 sample "Implementing SharePlay for immersive spaces in visionOS":

- Personas are system-drawn, arranged by a spatial template (side by side, conversational, surround, custom) around the shared scene; windows and volumes get them automatically. "The system doesn't display spatial Personas in a Full Space by default": the app sets `SystemCoordinator.Configuration.supportsGroupImmersiveSpace = true`, and the system then builds a shared coordinate system whose origin is no longer the user ("participants are no longer at the center"). The app opens its immersive space itself when `groupImmersionStyle` reports one, and uses `localParticipantStates.isSpatial` to know when extra state must be kept in sync. Apple's sample: "Set supportsGroupImmersiveSpace to true to see personas in the immersive space."
- WWDC23: "People in the group immersive space will see each other as Personas"; in a private immersive space the system hides the others and shows you as a contact photo.
- visionOS 26 nearby sharing (WWDC25 318): people in the same room see each other through passthrough, not as Personas; "If they join on visionOS, they'll appear in your space as a spatial Persona" is for remote participants. Shared world anchors align nearby devices; `ParticipantState.pose` is not live (updated at key events).
- The sample immersive space is a `RealityView`. Everything above works in `.mixed` or `.full` immersion as far as the documents say; whether a `.full` group space looks right with our content is a device check (section 6).

### 1.3 What visionOS 26 and 27 changed

- Compositor Services, visionOS 26 (WWDC25 294): `queryDrawables()`, hover effects through a tracking-areas texture, dynamic render quality, the progressive immersion style with a portal stencil, Mac spatial rendering (`RemoteImmersiveSpace`). No Persona or RealityKit composition.
- visionOS 27 (WWDC26 287 and 279, "What's new in visionOS 27"): RealityKit gained physical-space lighting, projective textures, cloth, reverb meshes, Gaussian splats (`GaussianSplatComponent`), `LevelOfDetailComponent` (by camera distance or screen area) and lightmaps; Godot got a Compositor Services path and a RealityKit rendering plugin; the Spatial Preview framework arrived. Compositor Services: "you can adopt the CompositorServices API directly — on both visionOS and macOS", nothing new. Personas are not mentioned anywhere.
- New in visionOS 27 and worth knowing: `LowLevelRenderer` and `LowLevelRenderContextStandalone` (RealityKit, module `RealityCoreRenderer`, a sub-framework in the SDK). RealityKit's own renderer encodes into a command buffer we own, with stereo outputs (`Output.renderTargetArrayLength`, per-camera `viewports`, a `rasterizationRateMap`) and user-written Metal surface shaders with the `CustomMaterial` ABI. Apple: "interoperability with CompositorServices API is an intended use case", but it is "intended for use in offscreen draws / exclusive rendering"; drawing inside a `RealityView` with shared depth is not supported (feature request FB23042990 filed by the asker). This is the reverse direction of what we need: RealityKit content (for example its splats or materials) drawn into our frame. It brings no Persona.

### 1.4 The Google AI Mode answer, checked

| Claim | Verdict |
|---|---|
| Personas are unavailable with Compositor Services | True (section 1.1). |
| Because of "privacy and out-of-process isolation" / "untrusted shader memory" | Not stated by Apple. The engineers only say it is not available and ask for feedback. A plausible guess, nothing more. |
| "You must shift to RealityKit so the system can inject the avatars" | True in substance: only a RealityKit-drawn scene gets Personas. |
| `LowLevelMesh`: "because the final rendering pass is handled by RealityKit, the OS ... will natively inject your participants' Spatial Personas" | Half true. `LowLevelMesh` (visionOS 2) is a vertex/index buffer that RealityKit draws with RealityKit materials. Personas appear because the space is a `RealityView` one, not because of the mesh. Our shading would not run on it. |
| `CustomMaterial` "via Metal Shader Graph nodes" to run our fragment shaders inside RealityKit | False on visionOS. `CustomMaterial` is iOS/macOS only; visionOS has `ShaderGraphMaterial` (MaterialX graphs) and, since 27, Metal surface shaders only inside the offscreen `LowLevelRenderer`. |
| Unity: Metal app mode vs RealityKit app mode | Consistent with Unity's documentation ("PolySpatial and RealityKit will not be used in applications set to this mode"); the cited Unity thread does not actually discuss SharePlay. |

---

## 2. What the engine has today

Checked on the main worktrees on 2026-10-16 (engine fork develop, arcade main, editor fork develop).

- **The visionOS loop is written against Compositor Services.** `Sources/UntoldEngineXR/UntoldEngineXR.swift` (1,683 lines) drives `LayerRenderer` (`queryNextFrame`, `frame.predictTiming/startUpdate/endUpdate/queryDrawables/startSubmission/endSubmission`, `LayerRenderer.Clock` waits for pacing) and reads the drawable in `executeXRSystemPass`: `colorTextures` (7 uses), `depthTextures` (4), `deviceAnchor` (4), `rasterizationRateMaps` (3), `frameTiming` (3), `target` (3), `views` (2), `encodePresent` (2), `depthRange` (2), `computeProjection` (1). It owns its own `ARKitSession` with a `WorldTrackingProvider` (and the PSVR2 accessory provider through `InputSystem`). The games configure `.dedicated` layout with foveation off (for example `SaberLayerConfiguration`), one render pass per eye, immersion `.mixed` or `.full` (`setImmersionMode`, the clear alpha from `getAlphaForImmersionMode`).
- **The core renderer is already texture-bound.** `UntoldEngine.renderXR(commandBuffer:passDescriptor:viewMatrix:projectionMatrix:eyeIndex:)` (`Sources/UntoldEngine/Renderer/UntoldEngine.swift:895`) takes any pass descriptor and matrices; `updateXR`, `buildHZBDepthPyramid`, `setXRCameraWorldPosition`, `finalizeXRStatsAndMonitors` are public. The editor's Vision Pro preview drives exactly these from its own loop through a frame-source abstraction (`VisionProFrameSource` / `VisionProEye`: colour and depth textures, `viewFromOrigin`, `projection`; `Editor/VisionPro/VisionProPreviewLoop.swift:203`). An off-screen stereo frame is therefore a third frame source, not a renderer change.
- **SharePlay already exists in CoolSaber** (`UntoldArcade/CoolSaber/Examples/CoolSaberVisionOS/.../visionOS/`): `SaberActivity` (a `GroupActivity`), `SaberSessionController` with `supportsGroupImmersiveSpace = true`, the `.conversational` template, `isSpatial` from `localParticipantStates`, `groupImmersionStyle` mirrored into open/dismiss, an unreliable messenger for poses and a reliable one for events, and `SaberDuelMailbox` to hand data to the render thread without touching the main actor. The game draws only the opponent's blades (`SaberXRGame.updateRemote`), re-based onto an anchor 2 m ahead when the session is not spatial. This is exactly the setup in which Apple's forum posters saw no Persona: everything about the session works, the avatar is simply not drawn over a Compositor Services layer.

---

## 3. Options

### A. Keep Compositor Services, draw the other player ourselves (works today)

- **Same room:** with visionOS 26 nearby sharing the opponent is a real person seen through passthrough in `.mixed` immersion; shared world anchors (`WorldAnchor(originFromAnchorTransform:sharedWithNearbyParticipants:)`, nearby only) align the two devices, and the forum shows this working in a Metal app. Nothing to draw.
- **Remote (FaceTime):** no Persona is possible. Send the head pose and the hand or controller poses over the existing `GroupSessionMessenger` (the blade poses already travel that way) and draw an engine avatar: head, hands, blades. `HandTrackingProvider` joints (26 per hand) at 30 Hz are small enough to send for hand avatars. Voice comes from FaceTime regardless.
- Cost: days, inside the game. Loses the Persona's face, expressions and eye direction.

### B. Two spaces: a RealityKit lobby with Personas, the Metal space for play

A `RealityView` immersive space (or a volume) carries the SharePlay session: Personas are present in the lobby, between rounds and while spectating; entering the `CompositorLayer` space hides them for everyone (the switch is a dismiss and an open; `groupImmersionStyle` tells the others). Unity ships this as "Hybrid" mode (Compositor Services for the game, RealityKit volumes alongside).

- Cost: about a week per game, no engine change. Does not give Personas during play.

### C. The hybrid: the engine renders off screen, RealityKit presents (Apple's suggested bridge)

Design sketch:

1. **The immersive space is a `RealityView`.** The group immersive space, spatial template, Personas and the shared coordinate system are then the system's business, as in Apple's sample.
2. **A third frame source for the engine loop** (the pattern of the editor's preview): head pose from our own `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)` predicted for the display time; a stereo projection of our own (a nominal IPD, a field of view wider than the display's so the edges never run out); two colour targets created with `MTLDevice.makeSharedTexture` and wrapped in `LowLevelTexture`s via `LowLevelDeviceResource(sharedTextureHandle:)` (zero copy; the visionOS 27 sample "Displaying low-latency connected video" does exactly this for a stereo camera feed, toggling two device resources per frame so RealityKit notices the new content); depth stays on our side.
3. **Presentation on a depth-displaced grid.** Per eye, a tessellated grid (about 256 × 240 vertices, one per 8 × 8 pixels of the 1920 × 1824 target) whose vertices a small compute kernel of ours moves to the unprojected depth of that eye's frame, writing a `LowLevelMesh` vertex buffer in the world space of the pose we rendered with. Material: `ShaderGraphMaterial` with an Unlit Surface, "Apply Post Process Tone Map" off, colour from a Camera Index Switch node between the two textures (the node that Apple's stereoscopic image sample uses), and an opacity threshold so each eye's grid is discarded in the other eye. Apple's wording ("ShaderGraphMaterial and geometry modifier") is the shader-only variant of the same thing; the compute kernel keeps the unprojection in our code and avoids depending on Camera Index Switch inside a geometry modifier.
4. **Mixed immersion** falls out of the alpha the engine already writes: alpha below the threshold leaves passthrough. Personas sort against our content per vertex, so occlusion is approximate but present.

What it buys: Personas standing inside the scene, with occlusion; the system's foveation, hover effects (`HoverEffectComponent`) and reprojection; and the reprojection works in our favour, because the grid is world-locked geometry built from our depth, so head motion between our render and the display is corrected by RealityKit (a depth-mesh reprojection, like positional time warp).

Costs and risks, to be measured on a prototype:

- **Latency on moving things.** Our frame reaches the display through RealityKit's next frame: at least one extra 11 ms at 90 Hz for anything that moves in the world (blades), while head motion is covered by the grid. Pacing has to be ours too: no `LayerRenderer.Clock`; drive the engine thread from `RealityView`'s per-frame update or a timer and feed it ARKit timestamps.
- **Edges.** Depth discontinuities stretch triangles; disocclusions show as smears until the next frame. Transparent content (glass, particles) has one depth per pixel.
- **Quality.** The frame is resampled once more; our texture is still rendered uniformly (as today, foveation is off), but RealityKit rasterises the grid with its own foveation; colour management of an unlit surface needs checking (tone map off is a node input).
- **What Compositor Services gives that goes away:** the system's per-eye view transforms (we render at a nominal IPD, but RealityKit displays the grid from the true eye positions, so depth cues stay right), the tracking-areas hover texture, dynamic render quality, the progressive-immersion stencil.
- **Memory and bandwidth:** two shared colour textures and two grids; negligible next to a frame.

Cost: a two-to-three-week prototype (engine frame source, the RealityKit presenter, CoolSaber hooked up), several more weeks for production (input and accessories in the new space, both immersion modes, pacing, diagnostics).

### D. RealityKit as the engine's visionOS render backend

Keep the engine for everything but drawing (ECS, physics, animation, streaming, scripts, SharePlay) and mirror renderable entities into RealityKit: `ModelComponent` with `MeshResource` or `LowLevelMesh`, `PhysicallyBasedMaterial` / `ShaderGraphMaterial`, lights, `MeshInstancesComponent` (visionOS 26), `LevelOfDetailComponent` (27), `GaussianSplatComponent` (27). This is what Apple's GodotRealityKit does ("RealityKit replaces Godot's renderer": PBR and visual-shader graphs convert, GLSL does not, no shadowed point lights) and what Unity's PolySpatial does.

- Full integration: Personas with true depth, foveation, hover, system lighting, windows and volumes.
- Loses the engine's renderer: custom Metal shaders and render extensions, post-processing, our LOD chains (they would map onto `LevelOfDetailComponent`), HZB culling, the exact look of every game.
- Cost: months; a second renderer to keep in step with the first. Only for games whose look fits RealityKit's material model.

### Comparison

| | Personas during play | Occlusion against our content | Engine renderer kept | Engine work | Risk |
|---|---|---|---|---|---|
| A. Own avatars | no (avatar) | n/a | yes | none (game only) | low |
| B. Lobby + Metal | lobby only | n/a | yes | none (game only) | low |
| C. Hybrid texture bridge | yes | approximate (per-vertex depth) | yes | frame source + presenter | latency, edges |
| D. RealityKit backend | yes | exact | no | a second renderer | months, look changes |

---

## 4. Recommendation

1. **Now, for CoolSaber:** option A. Draw the remote opponent (head and hands from the synced poses) and rely on passthrough for a nearby one. File the Feedback Assistant report both engineers asked for ("Spatial Personas in a Compositor Services immersive space") and keep its number here.
2. **Next:** prototype option C on the editor's frame-source pattern and measure: motion-to-photon for a blade swing versus today; the look of depth edges; whether the Persona's occlusion is acceptable; whether a `.full` group space works as well as `.mixed`. Decide with numbers.
3. **D:** not now. Revisit only for a game that is designed for RealityKit's materials from the start.

---

## 5. Pieces a prototype of option C would touch

- Engine: a protocol like the editor's `VisionProFrameSource` promoted into `UntoldEngineXR` or the core (eyes as textures and matrices; the loop already exists in the editor's `VisionProPreviewLoop`); a compute kernel that unprojects the depth texture into a `LowLevelMesh` vertex buffer; the double-buffered shared colour textures.
- App side (reusable across games): the `RealityView` immersive space, the grid entities and material (a Reality Composer Pro graph: Camera Index Switch → Unlit Surface with tone map off and opacity threshold), the ARKit session feeding poses, the per-frame kick.
- CoolSaber: swap the `CompositorLayer` space for the RealityKit one and keep `SaberSessionController` as it is (it already configures the group immersive space).

## 6. Open questions to verify on the device

1. Do Personas render in a `.full` group immersive space with our grid in front of them, and does the system's placement (the template origin) land where the game expects?
2. The prediction horizon of `queryDeviceAnchor(atTimestamp:)` versus RealityKit's display time: measure the residual swim, then the lag of moving objects.
3. Does the Unlit Surface with the tone map off reproduce our colours (gamut and exposure) exactly?
4. Shared-texture hand-off: the sample says "not supported in the simulator", so this is headset-only work from day one.
5. If the shader-only depth variant is ever wanted: whether Camera Index Switch is honoured inside a geometry modifier.

## 7. References

- Apple forum 791591, "Metal Compositor Service & Persona (VisionOS)": https://developer.apple.com/forums/thread/791591
- Apple forum 801420, "SharePlay on the VisionOS with remote participants": https://developer.apple.com/forums/thread/801420
- Apple forum 831767, "LowLevelRenderer: visionOS custom shaders, composition with RealityView": https://developer.apple.com/forums/thread/831767
- Apple forum 766378, "CompositorServices Or RealityKit": https://developer.apple.com/forums/thread/766378
- Apple forum 778674 (no CustomMaterial on visionOS): https://developer.apple.com/forums/thread/778674
- Adding spatial Persona support to an activity: https://developer.apple.com/documentation/groupactivities/adding-spatial-persona-support-to-an-activity
- Implementing SharePlay for immersive spaces in visionOS (sample, visionOS 26): https://developer.apple.com/documentation/visionos/implementing-shareplay-for-immersive-spaces-in-visionos
- WWDC23 10087, Build spatial SharePlay experiences: https://developer.apple.com/videos/play/wwdc2023/10087/
- WWDC25 318, Share visionOS experiences with nearby people: https://developer.apple.com/videos/play/wwdc2025/318/
- WWDC25 294, What's new in Metal rendering for immersive apps: https://developer.apple.com/videos/play/wwdc2025/294/
- WWDC26 287, Build next-generation experiences with visionOS 27: https://developer.apple.com/videos/play/wwdc2026/287/
- WWDC26 279, Explore advances in RealityKit: https://developer.apple.com/videos/play/wwdc2026/279/
- What's new in visionOS 27: https://developer.apple.com/visionos/whats-new/
- Displaying low-latency connected video (sample, visionOS 27; LowLevelTexture + LowLevelDeviceResource, stereo): https://developer.apple.com/documentation/realitykit/displaying-low-latency-connected-video
- Displaying a stereoscopic image (Camera Index Switch): https://developer.apple.com/documentation/visionos/displaying-a-stereoscopic-image-in-visionos
- Camera Index Switch node: https://developer.apple.com/documentation/shadergraph/realitykit/camera-index-switch-(realitykit)
- Unlit Surface node (Apply Post Process Tone Map, Opacity Threshold): https://developer.apple.com/documentation/shadergraph/realitykit/unlit-surface-(realitykit)
- Geometry Modifier node: https://developer.apple.com/documentation/shadergraph/realitykit/geometry-modifier-(realitykit)
- LowLevelRenderer (visionOS 27): https://developer.apple.com/documentation/realitykit/lowlevelrenderer and LowLevelRenderer.Output: https://developer.apple.com/documentation/realitykit/lowlevelrenderer/output-swift.struct
- Apple plugins for Godot (GodotRealityKit, Rendering.md): https://github.com/apple/plugins-for-godot
- Unity, Metal-based apps on visionOS: https://docs.unity3d.com/Packages/com.unity.polyspatial.visionos@3.0/manual/MetalApps.html

## 8. Decision (2026-10-16) and what the hybrid gives up

Option C, the hybrid, was chosen on 2026-10-16. It is an **optional presentation mode per game**: games that do not need Personas keep the Compositor Services path unchanged and lose nothing. For the games that opt in, this is the honest list of what changes against Compositor Services, with how much of it can be won back.

| What Compositor Services gives today | In the hybrid | Recoverable? |
|---|---|---|
| Content displayed the frame it is rendered | One RealityKit frame later (~11 ms at 90 Hz) for anything that moves in the world; head motion is corrected by the world-locked depth grid | Mostly: extrapolate moving transforms by the known delay (the engine already predicts networked objects); draw the few latency-critical things (the player's blades and hands, UI) as native RealityKit entities on top of the grid, at RealityKit's own latency and with exact depth |
| Exact per-pixel depth for passthrough compositing | Per-vertex depth on a grid: stretched triangles at depth jumps, smears on disocclusion during fast head turns | Partly: finer grid where depth varies, discard triangles whose depth span exceeds a threshold (a tear instead of a stretch), per-eye rendering so parallax disocclusions are already right at the render pose |
| One depth per pixel also for glass | Glass has no depth of its own: a Persona behind a pane is either composited in front of the pane's tint and reflection (opaque depth) or hidden by it (glass depth) | No; choose per scene which depth the grid uses. Matters for the BIM site, not for an arena |
| System foveation (rasterization rate maps) and dynamic render quality | Our texture is rendered uniformly, RealityKit foveates only its raster of the grid | Not really; today the engine renders uniformly anyway (foveation off), so nothing is lost now, only the future gain of phase 0 in the virtualized-geometry note |
| True per-eye view transforms (the wearer's IPD) | We render at a nominal IPD; RealityKit shows the grids from the true eye positions, so depth cues stay right and only view-dependent shading is slightly off | Minor and permanent |
| Hover effects on our content through the tracking-areas texture | None on engine-rendered pixels | Only for native entities (`HoverEffectComponent`) |
| Progressive immersion through the portal stencil | RealityKit does progressive immersion itself | Regained for free |
| The frame clock and predicted timing of `LayerRenderer` | We pace from RealityView's per-frame update and predict with ARKit timestamps | Mostly; some jitter risk to measure |
| Our tone mapping shown untouched | Unlit surface with the post-process tone map off | To verify (exposure in mixed immersion) |
| GPU and memory | Plus a tiny unprojection kernel, two grids of ~61k triangles each, one resampling of the frame, two shared colour textures | Small |

What the hybrid adds beyond Personas: the system's reprojection on our frame, SwiftUI attachments and native RealityKit entities in the same space (UI, splats, portals), progressive immersion, and hover effects for the native parts.

Permanent residuals, then: one frame of lag on engine-rendered moving objects, small edge smears during fast head motion, no foveation gain, no hover on engine pixels, the glass depth compromise. Everything else is recoverable or already true today. The prototype measures the first two.

---

## Appendix A. Feedback Assistant draft

Filed with Apple on 2026-10-16 (number FB________, to record here and to post in forum thread 791591 as the engineer asked). Type: Suggestion. Area: visionOS > Compositor Services (or SharePlay / Group Activities if the picker has no Compositor Services entry).

**Title:** Compositor Services: Spatial Personas are not shown in a SharePlay group immersive space rendered with Metal

**Description**

Apps that render their immersive space with Metal through Compositor Services (CompositorLayer / LayerRenderer) cannot show the Spatial Personas of the other SharePlay participants. The same GroupActivities setup (SystemCoordinator.Configuration with supportsGroupImmersiveSpace = true, a spatial template preference, groupImmersionStyle observed to open the space) shows Personas when the ImmersiveSpace holds a RealityView, but as soon as the space is a CompositorLayer the Personas are gone for everyone in the group immersive space, in both .mixed and .full immersion. Apple engineers confirmed on the developer forums that "personas are not available while displaying content with Compositor Services" (threads 791591 and 801420) and asked for a feedback report; this is it.

Why it matters: we maintain the open-source Untold Engine (github.com/untoldengine/UntoldEngine), a Swift and Metal game engine whose visionOS renderer is built on Compositor Services, and we ship games with it (for example a two-player lightsaber duel over SharePlay with PlayStation VR2 Sense controllers). Multiplayer games are a natural SharePlay use case, and every engine-based immersive game on visionOS (Untold, Unity's Metal app mode, Unreal, Godot's CompositorServices path) renders this way. Such a game can synchronise its session today but cannot show the other players. The only workarounds are engine-drawn stand-in avatars, or giving up the engine's renderer and rebuilding the game on RealityKit.

**Steps to reproduce**

1. Start from the sample "Implementing SharePlay for immersive spaces in visionOS".
2. Replace the RealityView inside the ImmersiveSpace with a CompositorLayer and a minimal Metal render loop (as in "Drawing fully immersive content using Metal"). Leave the SessionController unchanged: supportsGroupImmersiveSpace = true, the .sideBySide template, session.join().
3. On two Apple Vision Pro devices on a FaceTime call, start the activity and enter the group immersive space on both.

**Expected:** the other participant's Spatial Persona is placed by the spatial template and visible in the immersive space, exactly as with the unmodified sample.

**Actual:** no Persona is shown. The session itself works (messages arrive, localParticipantStates reports isSpatial = true), but the other person is invisible. The same happens with the .mixed and the .full immersion style.

**Suggestions** (any one of these would unblock engine-based games)

A. Composite the Personas system-side over the Compositor Services layer, depth-tested against the depth texture the app already submits with every frame. The compositor already uses that depth to blend passthrough behind the app's content in mixed immersion, and in visionOS 26 it applies hover effects from an app-provided tracking-areas texture. Personas could be composited the same way, without exposing any Persona data to the app. If useful, the app could also submit a small environment map so the Persona is lit like the scene.

B. If depth-correct compositing is not possible, draw the Personas on top of the layer, optionally with an app-provided mask texture (in the spirit of the tracking-areas texture) that tells the compositor where Personas may be visible.

C. Independently of rendering, let the app draw its own avatar for remote spatial participants from a privacy-filtered stream of their motion: head pose and hand poses at normal precision, plus a deliberately coarse gaze and expression signal (see Privacy below). Today SystemCoordinator.ParticipantState.pose is updated only at key events (sharing start, recentering), so an engine cannot even place a stand-in avatar where the other person actually is.

**Privacy**

We understand that another person's Persona data (face, eyes, expressions) is sensitive, and that visionOS never exposes gaze to apps. Either of the following trust models would satisfy us, in order of preference for privacy:

1. The system renders the Persona for us (A or B). No participant data reaches the app. The app only submits what it submits today (colour and depth, optionally a mask or an environment map), and the Persona is composited out of process, exactly as hover effects are applied to a Metal layer without the app seeing the gaze.

2. The app renders its own avatar from a degraded stream (C), for remote spatial participants only and with their consent (a prompt like the one for hand tracking). An avatar needs nothing precise: the Persona's eye animation is itself an estimate, not the raw gaze. The gaze could be delivered as a look-at point in the shared coordinate space quantised to around 10 cm, delayed and with noise added, and the expressions as a handful of coarse states (blink, smile, mouth open) at a low rate. We would use it only to animate an avatar; the system may degrade it as much as it likes, and the API could be documented and licensed for that purpose alone. Precedent: ARKit on iOS already gives apps 52 face blend shapes, the eye transforms and a look-at point with camera permission, and visionOS gives apps full hand joint poses. The app never needs the local user's own gaze.

**Configuration:** visionOS 27.x (build to fill in) on two Apple Vision Pro, Xcode 27.0 (27A266a), FaceTime call between the two devices. Also reproducible on visionOS 26.

**Attachment:** the modified sample project from step 2.
