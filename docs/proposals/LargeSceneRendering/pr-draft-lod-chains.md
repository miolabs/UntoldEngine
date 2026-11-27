# Draft: [Performance] Automatic LOD chains for the models of a .untoldpack

Branch `feature/pack_lod_chain` (two commits on upstream develop). Opened on 2026-10-03 as untoldengine/UntoldEngine#1299; this file is the description as posted.

---

## Summary

Stage 1c of `docs/proposals/LargeSceneRendering.md`. A scene exported from Blender has no levels of detail, and a pack can place a very dense model hundreds of times: on the BIM site of #1290 one tree of 1.85 M triangles is placed 175 times, 92.5 % of the 349 M triangles of the scene. The cook now writes simplified levels of every model that is detailed enough, and the pack loader registers them on the entities of each placement.

![A model and the three levels the cook writes for it, solid and in wireframe](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/LargeSceneRendering/lod_chain_levels.jpg)

The sheet is a procedural test model (a ground, a boulder and a tree whose canopy is 3,200 separate cards) and the three levels the cook writes for it, drawn at the same size: 197,200 triangles, then 98,598, 32,290 and 7,348. The cook gives each level the screen size from which it is detailed enough, here 58 %, 33 % and 16 % of the height of the screen, so levels 2 and 3 are shown larger than they are in use.

| BIM site pack (10,314 placements, 4,583 files) | Before | After |
|---|---|---|
| Triangles placed, at the finest level | 349 M | 349 M |
| Triangles placed, at the coarsest level | 349 M | **12.6 M** |
| Triangles per frame (six viewpoints) | 187–293 M | **7–21 M** |
| GPU time per frame | 141–220 ms | **11–22 ms** |
| Cook of the chains | | 3.4 s (217 of the 4,583 models, 649 level files, 233 MB) |

Release build, headless at 1920×1080 on an M-series Mac. From the same viewpoints the tree looks the same with and without the chain at 3, 7, 15 and 40 m.

## Changes

**Cook** (`UntoldMeshLODCooker`, `untoldengine bake-lods`, and the last step of `untoldengine export` for a pack unless `--no-lods`):

- Levels at 50 %, 15 % and 3 % of the triangles by default, for models of 2,000 triangles or more, written next to the model as `<name>_LOD<n>.untold`: the same entities, mesh records and materials with fewer triangles.
- A level may deviate by the size of one of its triangles (model diameter / √triangles). Vertices that two meshes of a model share stay in place, so the materials of one surface do not come apart. Texture seams are kept on textured meshes, unless they hold a level more than 25 % above its target.
- A level that is not at least 15 % smaller than the one before is left out. Skinned, morphing and animation-only models get no chain.
- Vegetation: the small detached pieces of an aggregate (leaf cards, twigs) are collapsed only while they keep their outline, then thinned evenly through space, and the survivors are enlarged to give back the area removed. Edge collapse alone leaves 29 % of the tree's leaf area at 3 % of its triangles, and the canopy shows through.
- The manifest records each chain under `lodChains`, with a screen size per level. A manifest without the key loads as before, and an older engine ignores it.
- A level file is recognised by a flag in its header (`UntoldFileFlags.generatedLODLevel`), never by its name: real packs have models named `…_LOD4`.

**The cook is a library of its own, `UntoldEngineMeshCook`**, which the CLI links. The simplifier is meshoptimizer 1.3 (MIT), vendored unmodified as the C++ target `CMeshOptimizer` (the five source files the cook uses). The `UntoldEngine` module does not import it: code compiled against a built engine module without SwiftPM, as the editor compiles a project's Code Components, would otherwise need the module map of the C++ library and fail with "missing required module 'CMeshOptimizer'". An app that only loads packs does not build the simplifier.

**Loader:**

- Each level is built once per pack load (the cache of #1290) and shared by the placements.
- A level's screen size becomes a switch distance per placement, from the model's bounds, the placement's scale and the field of view.
- The levels are drawn with the model's materials, and a material edited or streamed while one level is on screen stays when another takes its place (`LODComponent.levelsShareMaterials`).

**LOD system:**

- The hysteresis takes at most a tenth of a level's switch distance. With the default of 5 units a level that switches closer than that could never be returned to.
- The configuration is read once per update, not four times per entity.

## Verification

- `UntoldMeshLODCookerTests` (26): the levels of a model and their triangle counts, the error limit, locked and protected vertices, aggregates and their area, the level file's tables and header flag, the skip reasons, re-cooking, the manifest, a name that is taken.
- `UntoldPackLODRenderTests` (11): a cooked pack registers its levels on every placement and shares their meshes, switch distances follow the placement's scale, the materials follow the entity from level to level, a pack without chains loads as before.
- `LODSystemTests` (+2) for the hysteresis; `BakeLODsCommandTests` (6) in the CLI package.
- `swift test --filter UntoldEngineTests`: 1583 run. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name.
- The render suite (1208 tests) passes. Its reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have.
- The CLI's tests (18) pass. Zero warnings in the strict-concurrency build; no new SwiftFormat findings in the changed files.
- `UntoldEngine` and `UntoldEngineMeshCook` build and link for the iOS and visionOS simulators. A file that imports `UntoldEngine` compiles against the built module with only the `CShaderTypes` module map, as the editor's component compiler does.

## Limits

- After this change the scene's frame is held by the CPU, not the GPU: 17,600 to 21,500 draws cost more to encode than their triangles cost to draw. That is the subject of the next stages of the plan.
- The tree's last level still has 83,611 triangles (4.5 %): its branches stop simplifying at the error limit. Going lower needs an impostor or cluster LOD, not more levels.
- A scene saved by the editor reloads its placements one by one, not through the pack loader, so neither the shared builds of #1290 nor the chains survive a save and reload yet.
- The editor cooks through `scripts/export-untold`, which writes no chains; until it calls the cooker, run `untoldengine bake-lods` on the pack.
