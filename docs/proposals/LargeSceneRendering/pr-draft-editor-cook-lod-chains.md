# Draft: [Feature] Build the LOD chains of a cooked pack from the Cook sheet

Editor branch `feature/cook_lod_chains` (worktree `UntoldEditor-lodcook`): one commit, `563e5c0` on upstream develop `5f58ca3` (0.24.1), rebased 2026-10-28 from `9cdda5b` of 2026-10-16. In the editor fork since 2026-10-16 (miolabs/UntoldEditor#31), where the user cooks with it. OPENED 2026-10-28 as untoldengine/UntoldEditor#193 on the user's go.

---

## Summary

A pack the editor cooks had no LOD chains: the exporter it runs (`scripts/export-untold`) writes none, and only `untoldengine bake-lods` added them afterwards. A large scene cooked from the editor therefore drew every placement at full detail (the BIM site of `docs/proposals/LargeSceneRendering.md` fell from 60 fps to 3 fps after a re-cook), and re-cooking a scene that had been baked lost its chains again.

The "Cook to Untold Asset" sheet and the Quick Preview sheet get a **Build LOD chains** toggle, on by default. After a cook that wrote a `.untoldpack`, the editor builds the chains in place through `UntoldEngineMeshCook`, as `untoldengine export` does: simplified copies of every model big enough for them (three levels at 50 %, 15 % and 3 % of the triangles for models of 2,000 triangles or more), recorded in the manifest under `lodChains`.

## Changes

- `RuntimeExportLODChains.swift` (new): finds the `.untoldpack` a cook wrote beside its `.untold` output, builds its chains with `UntoldMeshLODCooker.cookChains(forPackAt:progress:)`, and turns the report into Console lines: what was built, and a warning for each model left without a chain by something other than its size (a file in the way of a level's name, a model that could not be read or written). A failure to build the chains is a warning on the task, not a failed cook: the pack keeps working without them.
- `AssetBrowserView+RuntimeExport.swift`, `AssetBrowserView.swift`: the toggle in the Cook sheet (models only; a single `.untold` is left as it is) and the step after the texture compression, with the Tasks panel showing the progress by model and the status bar "Building LOD chains...".
- `EditorView+QuickPreview.swift`, `EditorView.swift`: the same toggle and step for a preview cook, so that a large scene previews with its chains.
- `Package.swift`: the editor target takes the engine's `UntoldEngineMeshCook` product (in upstream develop since #1299).

## Verification

- `RuntimeExportLODChainsTests` (9): the pack manifest beside an output is found and a lone model has none; the Console lines of a pack with chains, of one whose models are all too small, of an empty one, and of models left without a chain, with the task's warning count; a manifest that cannot be read gives one warning and is left as it was; an empty pack is chained without a warning.
- The editor suite on the rebased branch, against engine 0.24.1: 1,315 tests, 1 skipped, 0 failures. SwiftFormat lint of the changed files clean (CI's Swift version).
- End to end, with the editor's own step on a copy of a real pack (ZombiStation's `EDIFICIO_COMPLETO_BLOCKING.untoldpack`, 375 placements of 266 models): 113 chains, 338 level files, 85 MB, the manifest rewritten with 113 `lodChains` entries, in 4 minutes in a debug build; the Console line reads "LOD chains of EDIFICIO_COMPLETO_BLOCKING.untoldpack: 113 of 266 models, 338 level files, 85 MB".

## Limits

- The chains are built in the editor's own process: in a debug build of the editor, a pack the size of the BIM site (4,779 models) takes minutes, where a release build or `untoldengine bake-lods` takes seconds. The Console says so when the build is a debug one, and the Tasks panel shows the progress.
- The toggle is per sheet, like the other cook options; it is not remembered between launches.
- The cook's options (ratios, minimum triangles, pixels per triangle) are the engine's defaults, as in `untoldengine export`; the CLI remains the way to choose others.
