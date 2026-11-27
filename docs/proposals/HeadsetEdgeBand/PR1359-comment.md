Thanks for the recording and the .blend. Found it, fixed in `a9ceb401`, now the head of the branch.

**What it was.** The dark bands are the back-face turn this PR added to `fragmentModelShader` (an open mesh seen from behind is lit with its normal turned towards the viewer). It decided on the interpolated vertex normal, and the Simple Dungeons kit's normals are averaged across its hard edges: the corner normals sit 45–72° off their faces on the walls and balusters. So on any front face seen at an angle, the interpolated normal passes 90° from the viewer before the far edge, and that strip of the face was lit with its normal turned into the object. Under the room's light that is black. Measured on your frames: the band above the balustrade's rail reads 11–13 of 255 next to a wall at 60–95, and across the middle pillar it sits on the pillar's own grazing faces, not on the wall behind.

It is not SSAO, the TAA, the rate maps or the mixed-space compositing: the exported pack rendered on a Mac through every one of those stays clean. It showed on the Mac only under a light that comes from above or one side, like a room's; the test HDR lights every direction, so a turned normal merely dims there.

Your frame, then the Mac with the branch's shader under a side light, then with the fix:

![Harold's frame, the branch before the fix, the fix](https://raw.githubusercontent.com/miolabs/UntoldEngine/docs/proposal_drafts/docs/images/headset_edge_band_harold_vs_mac.png)

Where the interpolated-normal test fired on the dungeon (red), 1–3 % of each frame, all of it along the edges:

![Where the old test fired](https://raw.githubusercontent.com/miolabs/UntoldEngine/docs/proposal_drafts/docs/images/headset_edge_band_where_the_old_test_fired.png)

**The fix.** The decision is made on the face: the cross product of the world position's screen derivatives, oriented by the vertex normal, as `TransparencyShader.metal` already does for glass. A face within a few degrees of edge-on, or one whose vertex normal lies within 12° of its own plane, is left as it is, since deciding those is chance. A true back face is still turned. The seven metallibs are rebuilt.

Before and after on the dungeon, the branch's shader on the left, `a9ceb401` on the right:

![The pillar, before and after](https://raw.githubusercontent.com/miolabs/UntoldEngine/docs/proposal_drafts/docs/images/headset_edge_band_before_after_pillar.png)

![The balustrade, before and after](https://raw.githubusercontent.com/miolabs/UntoldEngine/docs/proposal_drafts/docs/images/headset_edge_band_before_after_balustrade.png)

**The test.** `BackFaceFlipTests` draws a quad on the forward path under an image light confined to a cap around the zenith, seen from 25° above so its far edge is at grazing. With its normals averaged 45° outwards it must be lit all over: on the previous head 22,240 of its 181,772 pixels went dark (908 allowed), with the fix none. With its normals pointing away from the viewer it must be lit all over as well, so the turn itself stays covered. The per-fragment lighting, hybrid path, hidden-surface removal, TAA and tile-light suites pass.

I have not had the headset on with this yet; if you can give the dungeon another look with the new head, that is the confirmation that counts. One thing to keep in mind for the kit: its "custom split normals" are not split, they are the plain vertex average, so it will always shade a little soft at the edges, with or without this.
