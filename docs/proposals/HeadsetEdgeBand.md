# The dark bands along model edges on the headset (PR #1359)

*2026-10-16. Harold's recording of his UntoldXRTest app on an Apple Vision Pro with upstream PR
untoldengine/UntoldEngine#1359, the Simple Dungeons kit (`dungeon.blend`). The images and the
probe tooling are in `HeadsetEdgeBand/`.*

## What the recording shows

Dark, soft-looking bands follow the edges of every model: the far part of a rail's top face, the
side faces of the octagonal balusters and pillars near their silhouettes, the edges of the stair
rail. Measured on the 1080p capture (`images/harold_frame5.png`, `images/harold_frame30.png`):

- Above the top rail of the balustrade the band reads 11–13 of 255, next to a wall that reads
  60–95: nearly black, not a darkened wall.
- Across the middle pillar the band (39–59) sits between the background (78) and the pillar's lit
  face (83): it is on the pillar's own grazing faces.
- The bands keep their place relative to the geometry from frame to frame (no lag, no flicker).

## The cause: the PR's back-face normal flip on averaged normals

The PR lights back faces "with the normal turned towards the viewer" in `fragmentModelShader`:

```metal
if (dot(N, uniforms.cameraPosition - verticesInWorldSpace.xyz) < 0.0) {
    normalVectorInWorldSpace = -normalVectorInWorldSpace;
    N = -N;
}
```

`N` is the interpolated vertex normal. The Simple Dungeons kit carries "custom split normals"
that are not split at all but fully averaged: the corner normals tilt 40–72° from their faces on
the railing pillars, 45° on the wall boxes (`tools/normals_tilt.py`). On a front-facing face seen
at a moderate angle, the interpolated normal passes 90° from the view vector before the face's
far edge, the test fires, and that part of the face is lit with its normal turned into the
object. Under the headset's room probe (light from above and from one side) a normal turned that
way receives next to nothing: the fragment goes black. Under the Mac's test HDR, which lights
every direction, the same fragments only dim a little, which is why nothing showed on the Mac
until the light was made room-like.

Evidence, all on this Mac with the PR head (`cc51e076`) and the exported pack:

- `images/flipmask_C_normals.png`, `images/flipmask_A_normals.png`: the pixels whose G-buffer
  normal changes when the flip is disabled (red). They are strips along the edges of the pillar,
  the balusters, the rails, the stairs and the crates, 1.2–2.6 % of each frame.
- `images/harold_vs_mac.png`: Harold's frame, then the Mac with the flip on under a side-lit
  image light, then with the flip off. `images/flip_compare_A.png`, `images/flip_compare_C.png`:
  the same before/after at two viewpoints.
- Ruled out by rendering the pack on the Mac through the PR's settings matrix (deferred and
  forward paths, SSAO on and off, MSAA, TAA, MSAA+TAA, mixed immersion, a rasterization rate
  map with a moving camera): none of them produces a band. SSAO does make a soft halo on a
  surface within its half-metre radius of an occluder (`images/ao_ratio_B.png`), but it is far
  too weak to reach black and it is off by default.

## The fix

Decide the flip with the geometric normal, not the interpolated one, the way the transparency
pass already does: `faceNormal = cross(dfdx(worldPos), dfdy(worldPos))`, oriented by the vertex
normal (`dot(faceNormal, N) < 0 ? -faceNormal : faceNormal`), then flip only when
`dot(faceNormal, cameraPosition - worldPos) < 0`. A front face keeps its (tilted) shading normal
whatever the interpolation does; a true back face of an open mesh (a dart's flight, a leaf) is
still turned. The degenerate case (no derivatives) falls back to the current test. All seven
metallibs need rebuilding (`buildkernels.sh`), and a render test with a smooth-shaded box seen at
a grazing angle under a one-sided image light would pin it.

To confirm on the device without the fix: Harold's bands should vanish on develop (no flip) and
on the PR with the flip neutralised, independently of AA mode, SSAO and foveation.

## Status (2026-10-17)

Fixed as `a9ceb401` on `bugfix/backface_flip_face_normal` (worktree `UntoldEngine-flipfix`, cut
from the PR head `cc51e076`): the decision on the derivative face normal oriented by the vertex
normal, two undecidable cases left alone (a face within a few degrees of edge-on, a vertex normal
within 12° of its plane), the seven metallibs rebuilt, and `BackFaceFlipTests` (a quad under a
zenith-cap light at a grazing angle: averaged normals leave no dark strip, turned-away normals
are still lit). The test fails on the PR head's shader (22,240 of the quad's 181,772 pixels
dark, 908 allowed) and passes with the fix (0). Ten render test classes around the model shader
pass. On the dungeon pack under a side light the fix differs from the flip compiled out only on
0.06–0.5 % of the pixels, one-to-two-pixel rims on faces whose vertex normals the kit points
inward (`images/fix_vs_noflip_signed_A.png`); the old decision darkened 0.6–1.4 % of the frame
with its strips. Pushed onto the PR branch on 2026-10-17 (PR #1359's head is `a9ceb401`); the comment to Harold (`HeadsetEdgeBand/PR1359-comment.md`) was posted the same day; Harold tries it on his device, we do not set up a project of our own for it.
