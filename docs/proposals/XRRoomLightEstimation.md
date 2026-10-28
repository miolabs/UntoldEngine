# XR Room Light Estimation: lighting the engine's scene by the room on visionOS (proposal)

Status: proposal, written 2026-10-28 to be picked up in a session of its own. It gathers what the
RealityKit presenter work found about the engine's lighting on the device (2026-10-27), the study
that followed (`docs/proposals/XRLightingParity.md` on the fork branch `docs/xr_lighting_parity`,
`b25315a9`, with a Mac render test on `test/xr_lighting_parity_limb`, `a2d6432b`), what is already
changed, and what is left to decide and build. The presenter's own plan is
`docs/proposals/XRRealityKitPresenter.md` (branch `docs/xr_realitykit_presenter`); its entries of
2026-10-27 hold the headset readings quoted here.

## TL;DR

- The engine's XR runtime can light a scene by the room: ARKit's environment light estimation,
  prefiltered into an irradiance and specular chain, with the estimate's intensity scaled to a
  white point and portal lights from windows (`XREnvironmentLightingSystem`). But the lighting
  mode starts as the static picture (`.staticIBL`), and a game that sets nothing is lit by the
  bundled HDR's irradiance and its authored lights, on the headset as on the Mac. The RealityKit
  presenter example was lit that way for two days of edge readings without anyone noticing, and
  its "Room light estimate" switch moved a contribution factor that had nothing to multiply.
- RealityKit lights every lit material with ARKit's probe and a system light, even all round,
  with no set-up. Beside it, an engine object under a sun of strength 3 and a picture shows a
  sunlit top and a blue-grey shadowed bottom, and its glossy limb a reflection the shadow makes
  visible. That is the scene's lighting, not a fault of the environment term, which conserves
  energy at the limb (no occlusion or Fresnel clamp is wanted).
- The one limb fault the Mac reproduces is the old back-face rule on the presenter branch, which
  turns a limb normal a hair past 90 degrees round into the sun; the face rule of upstream #1359
  (`a9ceb401`) removes it and is not yet on that branch (decision taken 2026-10-28: later).
- Done so far: the study and its render test; the example's switch now moves the mode with the
  estimate on and the sun at 0 by default (arcade `feature/realitykit_presenter_example`,
  `6298935`, pushed, not yet built for the headset).
- Left: the headset reading of the example with the estimate on; three engine defaults for a
  mixed immersion (the estimate as the sole indirect light, its scale without the scene's
  ambient, a neutral fallback), the tone map question, the prefilter's cost on the device, and
  the face rule onto the presenter branch. Each is a small change with one headset reading.

## 1. What the engine has

Files, all on the fork's `develop` and the presenter branch alike:

- `Sources/UntoldEngine/Renderer/RuntimeEnvironmentLighting.swift`: `RuntimeEnvironmentLightingMode`
  (`.authoredOnly`, `.staticIBL`, `.realWorldEstimate`) and the store; the renderer resolves the
  environment once a frame (`resolveCurrentEnvironmentLighting`). Under `.realWorldEstimate` with a
  valid estimate: the estimate's maps, `applyIBL` on, ambient = `ambientIntensity × intensityScale ×
  realWorldLightingContribution`. Otherwise the static maps. `applyIBL` off keeps the static
  picture's diffuse term and zeroes only its specular (`computeIBLParts`, `Shaders/LightShader.metal`).
- `Sources/UntoldEngineXR/XREnvironmentLightingSystem.swift`: ARKit's
  `EnvironmentLightEstimationProvider` (visionOS 2 and later), a probe accepted at most every 0.5 s,
  read back (texels, per-face luminance, a tint clamped 0.25 to 2.5 per channel), moved towards
  with a 3 s time constant and re-prefiltered every 0.1 s while a transition runs, the intensity
  scale `cameraScaleReference / 1000` clamped to 64 (the white point calibrated once against
  RealityKit on a dartboard: reference 19016, scale about 19), prefiltered
  (`Shaders/iblPreFilterShaders.metal`: nine spherical harmonics from 1024 directions, the
  irradiance map, six specular levels of 256 × 256) and published double-buffered.
  `XREnvironmentLightingDiagnostics` reports `lastPrefilterDurationMs`. Cost on the M4 Max: 10 to
  12 ms of GPU per prefilter.
- `LightPortalSystem` / `LightingSystem`: two-sided area lights from light portals, under the
  estimate only.
- `UntoldEngineXR.setXRLightingMode(_:)` and `setXRLightingContribution(_:)`: the runtime's
  switches; the mode drives `XREnvironmentLightingSystem.setEnabled`.
- The model shader's environment term (`Shaders/modelShader.metal`, `computeIBLParts`): the
  lookup table's `(A, B)` at `(NoV, roughness)`, diffuse × (1 − R1), specular × R1 with Kulla and
  Conty's compensation, no occlusion, no horizon fade. Energy-conserving at the limb (measured:
  under an even room a white glossy sphere is the room all over, the limb within 12 %).
- The look pass: ACES by default; `.none` exists and is documented for mixed immersion from a
  dartboard measurement (whites at 87 of 255 under the filmic curve against the room's 113).

## 2. What was found on the headset (2026-10-27)

Beside a RealityKit control sphere (SimpleMaterial, roughness 0.2, the same radius) the engine's
sphere showed a sunlit white top and a blue-grey bottom, and sparse pale neutral pixels along its
lower edge (capture: luma 150 to 164 against the wall's 129 and the sphere's 78 just inside,
colour about (158, 159, 166)). Readings: the example's "Room light estimate" switch on or off
changed nothing (it moved only the contribution); the sphere's roughness at 0.6 and 0.9 changed
nothing; the sun at 0.5 diluted the specks; the presenter's own settings (band, tears, placement,
mips, scale, the centroid fix upstream #1389) left them. The study then found the mode had never
left `.staticIBL`, and that the specks' only Mac-reproducible source is the presenter branch's old
back-face rule (13 of 47 partly covered bottom-arc edge texels at 1.5 to 9 times the surface
beside them; none with the face rule).

## 3. What is already changed

- The study and its guard: `docs/xr_lighting_parity` (`b25315a9`),
  `Tests/UntoldEngineRenderTests/XRLightingParityLimbTests.swift` on `test/xr_lighting_parity_limb`
  (`a2d6432b`): the example's lighting as the device has it, the weaker sun's shares, the white
  furnace under an even room, a coloured sphere's rim.
- The example (arcade `feature/realitykit_presenter_example`, `6298935`): the switch moves the
  mode (`.realWorldEstimate` against `.staticIBL`, the contribution 1), on by default; the sun's
  picker 0 / 0.5 / 3 with 0 the default; README. Not built for the headset yet: the installed
  build of 2026-10-27 18:06 (`14faf2b`) has the old switch.
- The presenter branch (`feature/xr_realitykit_presenter`, `d414627c`) carries the centroid fix
  (#1389) and not the face rule.

## 4. Decisions to take

- D1. The default mode on visionOS in a mixed immersion: `.realWorldEstimate` unless the game chose
  (one line in the runtime's start, guarded by a "chosen" flag on the store, as the render path
  does); a full immersion keeps `.staticIBL`. Known games that select the estimate themselves:
  BedroomTwin, CoolWater, the viewer.
- D2. The estimate's scale without `ambientIntensity`: under `.realWorldEstimate` the resolve uses
  `intensityScale × realWorldLightingContribution` alone, the scene's ambient left to the static
  environment; the white point re-read once on the device (Q1: at what ambient was 1000
  calibrated?).
- D3. The fallback under `.realWorldEstimate` with no estimate: a neutral grey ambient (the last
  published scale or a small constant), never the bundled picture; and the engine's default
  `hdrURL` empty on visionOS.
- D4. Authored lights against the room's level: the example's sun at 0 for the comparison, 0.3 to
  0.5 as a key light; a guideline for games, not a rule in code.
- D5. No specular occlusion, horizon fade or Fresnel clamp (decided by the measurement).
- D6. The face rule onto the presenter branch: cherry-pick `a9ceb401` with that branch's kernel
  binaries kept and rebuilt (`buildkernels.sh`), as the centroid fix was, or merge upstream
  `develop`. Deferred on 2026-10-28.
- D7. The tone map in mixed immersion: `.none` against ACES, judged beside the control sphere (Q2).

## 5. Stages for the next session

1. **The example on the headset** (no engine change, half an hour): build and install the example
   at `6298935` (the plan session installs), open a space with the estimate on and the sun at 0,
   and read beside the control sphere: the body's shading (even, the room's colour) and the
   lower edge's specks with the sun at 0, 0.5 and 3. Then `lastPrefilterDurationMs` through the
   numbers line or a log line: the prefilter's cost on the device (Q3), and whether the 0.1 s
   transition step or the 256 × 256 quadrature should shrink.
2. **The face rule** (D6, an hour): onto the presenter branch with the kernels rebuilt, the
   centroid and anti-aliasing suites green, the same reading again; specks gone closes the thread,
   specks remaining hands it to the presenter's raster (the study's Q4: read the eye texture, not
   the display).
3. **The engine defaults** (D1 to D3, a day with the headset): one branch from `upstream/develop`,
   `feature/xr_room_light_defaults`, with a test per rule on the Mac (the mode chosen at start in
   a mixed immersion, the resolve's ambient under the estimate, the fallback's colour) and one
   headset reading each (a white matte surface facing the ceiling against the passthrough's white
   for the white point; the fallback's seconds after a space opens). Upstream PR with before/after
   images on `docs/proposal_drafts`.
4. **The tone map** (D7, an hour): the example's `setRendering(.tonemapOperator(.none))` as a
   toggle, the two whites against the control sphere's.
5. **Write-up**: the study updated with the device's numbers, the decisions marked, the
   presenter's README naming the lighting defaults a game should set until the engine's change.

## 6. How to measure

- On the Mac: `CI=true UNTOLD_PYTHON=/opt/homebrew/bin/python3 /usr/bin/swift test --package-path
  <worktree> --filter 'XRLightingParity|XRRealityKitPresenter|LookPassCoverageAlpha|MSAACentroid'`
  (the `swift` shim is broken). Shader edits need `./buildkernels.sh` and the metallibs committed.
- On the headset: the RealityKit presenter example's lighting switches (live) with its control
  cube and sphere (`--control-cube`); captures measured by
  `docs/proposals/XRRealityKitPresenter/tools/edge_measure.py` and the sphere-edge script of the
  plan note's 2026-10-27 entries (an annulus just outside the disc, the bright pixels per sector).
  ProceduralGeometry on the Compositor path is the second engine route for a comparison without
  the presenter.
- The headset is one device with one bundle id per app: only the plan session installs, every
  number on Release builds.

## 7. Risks

- The white point's calibration (1000) may not survive D2: one reading re-does it.
- The prefilter's cost on the device is unmeasured; a transition's ten prefilters a second could
  cost a frame. The number to read first.
- Changing defaults moves every visionOS scene that set nothing; the known games select the
  estimate themselves, but the viewer's and the templates' scenes should be checked.
