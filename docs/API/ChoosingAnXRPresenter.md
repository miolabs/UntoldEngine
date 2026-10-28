# Choosing an XR presenter on visionOS: Compositor Services or RealityKit

The engine renders an XR frame the same way whoever shows it: the loop (`XRFrameLoop`) takes a
frame from a frame source (`XRFrameSource`), draws each eye into the textures the source hands
it, and gives the frame back. Two sources exist, and a game picks one by the immersive space it
opens. This page says what each gives and costs, and how to pick.

## The two routes

**Compositor Services** (`CompositorFrameSource`, `UntoldEngineXR` with a `LayerRenderer`): the
space holds a `CompositorLayer`; the engine draws straight into the compositor's drawables from
the device's tracked eyes, with the compositor's timing, its foveation and its depth-based
reprojection. The templates and the other visionOS examples (ProceduralGeometry among them) run
this way, and `docs/API/UsingXRImmersionMode.md` and `docs/Architecture/xrRenderingSystem.md`
describe it.

**RealityKit** (`RealityKitFrameSource`, `XRRealityKitPresenter`, the `UntoldEngineXRRealityKit`
target): the space holds a `RealityView` (`UntoldXRPresenterView`); the engine draws each eye into
a `LowLevelTexture` with its depth, a compute kernel places a grid per eye on that depth, and
RealityKit draws the grids as world-locked meshes with the engine's picture on them, beside
anything else RealityKit holds. The example is `RealityKitPresenterExample` in the arcade; the
design and every measurement are in `docs/proposals/XRRealityKitPresenter.md`.

## What RealityKit gives that the compositor layer cannot

- **The system's own content in the same space**: Spatial Personas in a SharePlay session,
  system windows and volumes, RealityKit entities (a native cube, a hand-tracked tool) drawn by
  the device beside the engine's scene. A `CompositorLayer` owns the whole space and gets none of
  these (`docs/proposals/SpatialPersonasResearch.md`: unchanged in visionOS 27). This is the
  reason the presenter exists.
- **Mixed immersion with the system's rules**: the room lit and composited by the system, the
  engine's objects occluding and occluded by RealityKit's through depth.

## What it costs, measured on the headset (Release, 2026-10-19 to 27)

- **A refresh of latency.** RealityKit shows a frame at its own update after the engine's command
  buffer completes, and the device time-slices that buffer beside RealityKit's render (a 4 ms
  frame stretches to 20 ms on a quick turn, where the compositor path stretches 1.6×). The
  presenter runs two refreshes deep by default (`pipelineDepth = 2`) and poses the frame 22 ms
  plus a refresh ahead, which makes late frames go and keeps a head-locked probe still; the
  price is about 10 ms more lead than the compositor path at 100 Hz.
- **The eyes must be measured.** RealityKit renders the grids from the device's tracked eyes and
  never tells the app where they are; the engine renders from nominal eyes at the device anchor
  unless told otherwise. On one headset the tracked eyes sat 24.7 mm below the anchor, and that
  difference showed as kinks and shimmer on every silhouette drawn at a cell's approximate depth.
  The example measures the eyes at start through a bare compositor layer (`XREyeMeasurement`,
  the `EyeCalibration` space) and hands them to the presenter (`eyeTransforms`); a game must do
  the same or set them. The compositor path gets the tracked eyes every frame for free.
- **Silhouettes are the grid's.** Each eye's picture is a texture on a mesh placed at the
  engine's depth; the blended core (the default) draws it with its depth kept, the kernel's rules
  (nearest depth, skirt, tear mask, silhouette cells) decide where cells lie. With the measured
  eyes the cubes of the example match a RealityKit cube beside them; a curved limb keeps the
  engine's own subtle shimmer. The compositor path has none of this: the engine's pixels are the
  display's.
- **GPU**: the engine's frame plus the kernel (about 0.05 ms on the Mac) and RealityKit's render
  of two grids of 256 × 240 cells; MSAA in the engine is needed for the silhouettes' coverage.
- **Lighting is the engine's either way**: on both routes the scene is lit by what the game
  sets; the room's estimate (`setXRLightingMode(.realWorldEstimate)`) must be selected, see
  `docs/proposals/XRRoomLightEstimation.md`.

## How to pick

- A game alone in its space, with no Personas, no system windows and no RealityKit content:
  **Compositor Services**. Lowest latency, the device's eyes and foveation, pixels as rendered.
- A game that shares its space with Personas, SharePlay participants or RealityKit entities, or
  that must live inside the system's mixed immersion with its windows: **RealityKit**, with the
  eye measurement at start, the two-refresh pipeline, and the blended core.
- Both in one app: the frame source is chosen per immersive space; the engine's scene, systems
  and assets are the same, only the `ImmersiveSpace` differs (`CompositorLayer` against
  `UntoldXRPresenterView`). The example's `eyeCalibration` space shows a compositor layer and a
  RealityView opened one after the other in the same app.

## Settings that matter on the RealityKit route

`XRRealityKitPresenterConfiguration`: `pipelineDepth` (2), `silhouette` (`.blendedCore`),
`silhouetteCells` (`.skirt`), `eyeTransforms` or `interpupillaryDistance` and
`viewOffsetMetres`, `renderScale` (1), `foveation` (the presenter's own rate map), `leadSeconds`
(22 ms) with `adaptiveLead` off, `mipmapped` off. The example's window exposes them all with
the readings that set them.
