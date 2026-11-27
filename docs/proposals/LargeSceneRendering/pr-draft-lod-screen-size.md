# Draft: [Feature] Select LOD levels by the size of the entity on screen

Branch `feature/lod_screen_size` (one commit on upstream develop, rebased on 2026-10-07 after #1299 merged). OPENED 2026-10-08 as untoldengine/UntoldEngine#1322.

---

## Summary

Stage 1d of `docs/proposals/LargeSceneRendering.md`, the half that #1299 left open. A level of detail is chosen by the camera's distance to the entity, and a distance suits one size of object under one field of view: a chain cooked for a tree is wrong for the same tree placed at half its scale, and every chain is wrong once the camera zooms. An entity can now choose its level by how large it is on screen: each level ends where the entity covers the `screenPercentage` of the next one, read as the LOD pass runs from the entity's world radius and the projection in use.

![The same model at the same distance, in a wide and a zoomed view, with each rule](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/LargeSceneRendering/lod_screen_size.jpg)

The sheet is a test model with the chain `untoldengine bake-lods` writes for it, from one camera position. Top row, a 60° field of view: the model is small on screen and both rules draw its coarsest level. Bottom row, the camera zoomed to 20°: the distance has not changed, so the distance rule keeps the coarsest level, now large and visibly simplified; the screen-size rule draws the full model.

The levels of the automatic chains of a `.untoldpack` (#1299) are selected this way. #1299 turned each level's screen size into a switch distance when the pack loaded, from the field of view of that moment; the switch now follows the field of view and the entity's scale as they are, and a placement scaled after the load switches at its new size.

## Changes

- **`LODComponent.selectsByScreenSize`** (opt-in; the pack loader sets it on the levels of a chain) and **`LODComponent.screenSizeRadius`**: the radius, in the entity's own space, of the sphere measured on screen; 0 measures the sphere around the entity's bounding box. The parts of a pack model of several nodes carry the radius of the whole model, so they switch together.
- **`LODSystem`**: `lodScreenSizeReach(projection:)` reads `projection[1][1]` (that is `1 / tan(fovY / 2)`) once per update, nil under an orthographic projection. In stereo the eyes are rendered after the update, so the reach is the larger of the two eye projections' from the frame rendered last, and until an eye has been rendered the stored distances apply (the review's first point). For a component that selects by screen size, level *i* ends at `worldRadius × reach / screenPercentage(i + 1)`; the bias and the hysteresis apply to these distances as to stored ones. A level whose successor has no screen size, and every level under an orthographic projection, ends at its stored `maxDistance` as before.
- **Resolution-independent on purpose:** the size is a share of the viewport height, whatever its resolution. A denser display draws the same levels; `setLOD(.distanceBias(...))` is the knob for a platform that wants more or less detail. (A first version scaled the size by the viewport's pixel height; a Retina window or a headset then drew several times the triangles for detail that is not seen. Unreal and Unity do not scale it either.)
- **`LODLevel.screenPercentage`** existed, was serialized and was never read; existing tests set it to arbitrary values, which is why the selection is opt-in rather than automatic for every component with a size.
- **Pack loader:** sets the flag and the radius on each level it registers; the stored switch distances are still written, for the orthographic case and for an engine without this change.
- Documented in `docs/API/UsingLODSystem.md` ("Selecting by Screen Size") and `docs/Architecture/lodSystem.md`.

## Verification

- `LODScreenSizeTests` (14): the reach of a projection, the switch distance for a radius and a screen size, levels without a size, the orthographic fallback, the bias and the hysteresis on computed distances, `screenSizeRadius`, and that a component without the flag selects as before.
- `UntoldPackLODRenderTests` (+4, 15 in all): a placement selects its levels by its size on screen and its parts carry the model's radius; a placement scaled after the load switches at its new size; halving the field of view moves the switches out and doubling the resolution does not; a view without perspective switches at the distances of the load.
- With the flag forced off inside the LOD system, three of those tests fail: the rule is what they measure.
- `swift test --filter UntoldEngineTests`: 1,640 run. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name.
- The render suite: 1,185 pass, 69 are skipped as on develop. Its 22 reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have: 14 match their reference exactly, the lowest of the others is at 68 dB against thresholds of 11 to 30.
- Zero warnings in the strict-concurrency build (`scripts/strict-concurrency-guardrails.sh` with `MAX_UNIQUE_CONCURRENCY_WARNINGS=0`); no new SwiftFormat findings in the changed files.

## Limits

- The scene serializer does not save the two new fields: a scene saved by the editor reloads its LOD entities through `addLODLevel` with distances only. Tracked in #1326 with the rest of what a saved scene loses (shared builds and chains do not survive a save either).
- Nothing changes for a component that does not set the flag.
