# Draft: [Bugfix] Test occlusion from the camera the depth pyramid was built with

Branch `bugfix/hzb_occlusion_reprojection` (one commit on upstream develop). OPENED 2026-10-08 as untoldengine/UntoldEngine#1323.

---

## Summary

The occlusion test drops the entities that the depth pyramid of the previous frame hides. It projected this frame's entities with this frame's camera into that pyramid, which was rendered from the previous frame's camera, with a fixed depth bias as the only allowance for the difference. A step that uncovered what a near surface had covered put entities on texels that still held the near depth, and the test's camera could differ from the pyramid's for other reasons too: the editor's Vision Pro preview culls with the camera entity's head-centre view and builds the pyramid from an eye's depth, two eyes to a frame. There, on a large site, the trees vanished while the camera flew with the keys and came back when it stopped.

The pyramid now records the camera it was built from, and the test projects with that camera: an entity seen from both places is tested where the pyramid holds its own depth, however the camera moved in between, and an entity the old camera could not see at all is kept. What a step uncovers from behind a near surface shows one frame late. After a step larger than a set distance (a jump, a fast flight; 0.5 units by default) the pyramid says too little about the frame and the test is skipped: the frame draws what the frustum keeps.

**What it changes on screen, measured on a BIM site** (21,576 render entities; release build, headless; from each viewpoint the camera takes 20 steps of a set length in a direction, and the cull of the last step's frame, which runs against the pyramid of one step before, is compared with the cull at the same place once the pyramid comes from there; counts are the cull's candidates and what it kept, read from `HZBDebugMonitor`):

| Camera | Candidates | Before: kept while moving / at rest | After: kept while moving / at rest |
|---|---|---|---|
| Rising 0.1 units a frame inside a tree's canopy, 6 units up | 26,806 | 12,669 / 17,357 | 12,891 / 17,357 |
| Strafing 0.3 units a frame inside the canopy | 26,510 | 17,468 / 19,017 | 17,601 / 19,017 |
| Flying forward 1.0 units a frame through the canopy | 15,423 | 6,142 / 5,293 | 15,423 / 5,293 (test skipped) |
| Walking, backing, strafing or rising in the open, 0.1 to 1.0 units a frame | 5,300 to 27,700 | within 1 % of rest | within 1 % of rest |

In the open views the stale test dropped nothing measurable on the Mac, because the kernel's bias is 0.02 in reverse-Z depth: with a near plane of 0.1 only an occluder within about 5 units hides anything at all, and a far entity moves a fraction of a pixel per step. Inside a canopy the near leaves uncover something new at every step, and what they uncover shows one frame late with either camera: that is the latency of a temporal test, not the wrong camera, and the fix moves it by 5 to 9 %. Where the wrong camera showed was the editor's Vision Pro preview: it culls with the camera entity's head-centre view, renders the two eyes, and builds the pyramid from the last eye's depth, so the test's camera never matched the pyramid's, and the steps between frames were larger (two eyes rendered per frame; the flight speed 1 is 6 units a second). With this change the test takes the pyramid's own camera there too, whatever built it; a flight faster than the step skips the test. Checked in the headset on that site: the trees no longer vanish while the camera flies.

## Changes

- **`RenderInfo.hzbFrame`** (`HZBPyramidFrame`): the view-projection, scene root included, and the position of the camera the pyramid was rendered from. `buildHZBDepthPyramid` records it from the active camera and the projection in use, which in stereo are those of the eye rendered last, as the mono pyramid's depth is.
- **`executeHZBOcclusionCulling`** takes the current camera's position instead of its view-projection: the kernel projects with the pyramid's, and the test is skipped when the camera moved farther than `HZBOcclusionCulling.maxCameraStep` since the build. The three call sites (the frustum cull, the reduce-scan cull, both eyes of the stereo cull) pass their camera's position. The unused `hzbPyramidOverride` parameter is gone.
- **Setting:** `setRendering(.occlusionCullingMaxCameraStep(_:))` and `getOcclusionCullingMaxCameraStep()`; documented in `docs/API/UsingEngineAPI.md` and `docs/Architecture/renderingSystem.md` (Step 6).
- The kernel and the bias are unchanged.

## Verification

- `HZBOcclusionReprojectionTests` (6): an object seen from both places stays visible when the camera rises (a wall 3 units ahead, a box 80 units out over its top; before the change the box is dropped on the frame after the rise); an object behind the wall stays hidden across a small step; the test is skipped for the frame after a jump and runs again from the new place; the camera of a view matrix; the pyramid records its camera; the setting's round trip.
- With the test projecting from this frame's camera again, the rising test fails; with the step rule taken out, the jump test fails. `CullingTest`'s three direct runs of the occlusion pass set the pyramid's camera the way the build does.
- `swift test --filter UntoldEngineTests`: 1,632 run. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name.
- The render suite: 1,187 pass, 69 are skipped as on develop. Its reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have; the lowest is at 68 dB against thresholds of 11 to 30.
- Zero warnings in the strict-concurrency build (`scripts/strict-concurrency-guardrails.sh` with `MAX_UNIQUE_CONCURRENCY_WARNINGS=0`); no new SwiftFormat findings in the changed files.

## Limits

- The bias is a constant in depth units, so with a near plane of 0.1 nothing farther than about 5 units from the camera occludes; a bias in view-space distance would let walls and ground at a distance count. Not changed here.
- What a step uncovers from behind a near surface shows one frame late, as with any test against the previous frame's depth.
- In stereo both eyes are still tested against the one pyramid, built from the eye rendered last; the per-eye pyramids are allocated but nothing renders the per-eye depth they would be built from. The eyes stand a few centimetres apart, which the bias covers; the frames stood a camera step apart, which it did not.
- The Gaussian chunk cull tests against the same pyramid with the current frame's per-eye matrices (`GaussianChunkCull`), as before.
