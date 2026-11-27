# Large Scene Rendering (BIM sites, vegetation, repeated props) — Plan

Status: plan, stage 1 built (1a merged, 1b in review, 1c and 1d on local branches). Written 2026-10-02, updated 2026-10-03 (1c and 1d built and measured, see section 3; what the measurements ask of stage 2, see section 4). Companion to [VirtualizedGeometryResearch.md](VirtualizedGeometryResearch.md), whose phases 0–3 become stage 3 here.

Question: how does the engine load and draw a BIM site exported from Blender as it is (no hand-made LODs, no edits in Blender), at interactive frame rates on the Mac and, eventually, on Apple Vision Pro.

## TL;DR

The scene that prompted this (`P23011-PR-GLB-BIM-XXXX-3D-IPYR23-T008.blend`, a 1.2 GB BIM export) loads slowly and renders at about 2 fps on the Mac. Measured on the cooked pack:

| | |
|---|---|
| Placements in the `.untoldpack` | 10,314 (4,583 distinct `.untold` files, after #1288) |
| Triangles if everything is drawn | **349 M** |
| …of which one tree (1.85 M triangles × 175 copies) | **323 M (92.5 %)** |
| Distinct geometry | 7.8 M triangles |
| Mesh draws per frame | 21,575 |
| Entities created on load | 21,638 at least, up to ~32,000 |

Three causes, in order of weight: triangles (one dense tree, placed many times), the number of draws (no GPU instancing, every copy is its own draw), and per-placement loading (every placement parses its file and builds its own GPU buffers). A fourth issue is a correctness bug: the engine sizes its entity storage for 20,000 entities and does not check the limit.

The content cannot be changed: this is what the BIM export produces. So the work is in the cook and in the engine, in three stages, each useful on its own and each a foundation for the next:

1. **Load and run** (weeks): entity limit, one load per distinct file, an automatic LOD chain per distinct mesh, screen-size LOD selection and small-object culling.
2. **One draw per mesh** (weeks): GPU instancing with per-instance culling.
3. **Virtualized geometry** (months): the research note's phases 0–3 (single-pass stereo + foveation, offline cluster DAG, cluster renderer, page streaming).

Where it stands on 2026-10-03: 1a to 1d are built (1a is merged upstream, 1b is in review). The pack loads in 15 s instead of two minutes, and a frame draws 7 to 20 M triangles instead of 190 to 290 M, which takes the GPU from 135–210 ms to 10–23 ms. The frame itself goes from 240–375 ms to 120–160 ms (release build): a little over twice as fast, not ten times, because the frame is now held by the CPU, which walks the 21,576 render entities several times per frame whatever is on screen. That is 6 to 8 frames per second in a release build and about a third of that in a debug build, so the scene is not interactive yet. Stage 1 has done what it can do; the rest of the cost is the subject of stage 2, and section 4 says what the measurements ask of it. A first prototype of stage 2 (same day) brings the same frames to 26–45 ms with identical images.

## 1. The scene, measured

Measured on 2026-10-02 from the `.blend` (Blender 5.2 background scan) and from the pack cooked with #1288.

- 23,165 objects; 22,741 meshes in 11,533 mesh datablocks. 11,916 objects share a datablock with another (linked duplicates): shrubs up to 274 times, architectural members up to 243 times, the tree 198 times.
- 8,466 objects are hidden or render-disabled; the exporter skips them (#1267).
- 289.6 M faces visible in Blender; 4.8 M if each datablock is counted once. After triangulation and material splitting: 349 M triangles placed, 7.8 M distinct.
- Heaviest placed geometry: the tree `Arbolado_real_01` 323 M (1,845.6 k × 175), parked cars 10 M (384 k each, 26 copies), HVAC grilles 2.8 M (127 k × 22), chairs 1.6 M (7.6 k × 213). Everything else together: about 10 M.
- 8,247 meshes have no UV map (only matters for textured materials).

Cook: before #1288 the exporter wrote every copy in full (21 GB and still running after two hours); with #1288 it takes 6 min 37 s and writes 1.9 GB.

## 2. What the engine has today (upstream develop, 2026-10-02)

- **No GPU instancing for meshes.** Every draw goes through `drawIndexedPrimitivesTracked` (`Profiling/RenderStatsCollector.swift`), which has no instance count; the model pass loops over visible entities and issues one draw per submesh (`Renderer/RenderPasses.swift`). Only Gaussian splats draw instanced.
- **Static batching** (`Systems/BatchingSystem.swift`) merges meshes by cell, material and LOD into new world-space buffers. It is off by default, needs `StaticBatchComponent`, and duplicates every copy's vertices into the batch, so it does not help with repetition.
- **LOD** (`Systems/LODSystem.swift`) is per entity, chosen by distance to the bounding-box centre against each level's `maxDistance`. Levels are added by hand (`addLODLevel`, one `.untold` per level). `LODLevel.screenPercentage` exists but is never read. Nothing generates LOD levels; `--file-type lod` only writes a header value.
- **Culling**: per-entity GPU frustum culling and HZB occlusion (`Systems/CullingSystem.swift`). No distance culling for meshes (only shadows stop at 40 m).
- **Entity limit**: `MAX_ENTITIES = 20000` (`Utils/Globals.swift`) sizes the component pools and the culling buffers; `Scene.newEntity` and `ComponentPool.get` do not check it.
- **Pack loading** (`Systems/RegistrationSystem.swift`, `loadEntityFromPack` / `PackLoadDispatcher`): one child entity per manifest entry, each loaded with `setEntityMeshAsync`, which parses the file and builds GPU meshes every time. A URL-keyed, ref-counted `MeshResourceManager` exists but only the out-of-core streaming path and `addLODLevel` use it.
- **Tiled geometry streaming** (`export-untold-tiles` + `GeometryStreamingSystem`) partitions a scene into tiles, merges objects by material inside each tile and bakes their world transforms. That throws away instancing: the 175 trees would be baked into the tiles as 323 M triangles. Its LOD/HLOD generation (Blender Decimate) covers only the building-shell tiers. It helps memory and load time by distance, but not the frame rate near dense areas, so it is not the answer for this content on its own.

## 3. Stage 1 — load and run (cook + engine)

Goal: the scene loads in seconds rather than minutes and runs at interactive rates on the Mac. Each item is its own pull request.

### 1a. Entity limit (engine, bug)

Component pools and culling buffers grow with the scene instead of a fixed 20,000; creating an entity past a hard ceiling fails with a clear error instead of writing past the end of the storage. The scene needs 21,638 to ~32,000 entities.

### 1b. One load per distinct file (engine)

When several pack entries share an `.untold`, the file is parsed and its GPU meshes built once, then shared by every placement (through `MeshResourceManager` or the same idea), released when the last one goes. Load work and GPU memory follow the 4,583 distinct files, not the 10,314 placements; the 175 trees share one set of buffers instead of 175 (each about 110 MB).

### 1c. Automatic LOD chain (cook + engine)

Built on 2026-10-03 with the decisions of section 6 (levels at 50 %, 15 % and 3 % of the triangles for models of 2,000 triangles or more; meshoptimizer; a screen size per level).

- **Cook.** `UntoldMeshLODCooker` (in `UntoldEngineMeshCook`, a library product of the engine package, so the CLI and the editor can both call it) reads each distinct `.untold` of a pack and writes its levels next to it as `<name>_LOD1.untold`, `_LOD2`, `_LOD3`: the same entities, mesh records and materials with fewer triangles. `untoldengine export` runs it for the packs it writes; `untoldengine bake-lods` runs it on a pack that is already cooked, without Blender or the source file. The simplifier is meshoptimizer 1.3, vendored as a C++ target (`Sources/CMeshOptimizer`, the five files the cook uses).
- **The cook is a module of its own.** The `UntoldEngine` module must not import the C++ library. The editor compiles a project's Code Components against the built engine module with its own compiler call, which passes the module map of `CShaderTypes` and nothing else; with the simplifier imported by the engine, that compile fails with "missing required module 'CMeshOptimizer'" (found on 2026-10-03 by running the editor's tests against the engine with 1c). `internal import` does not hide the dependency (the engine is built without library evolution), and `@_implementationOnly import` hides it but raises a warning that the zero-warning check of CI rejects; both checked with Swift 6.3.3 and 6.4. The upstream editor follows the engine's `develop`, so the engine change cannot wait for an editor change. With the cook in `UntoldEngineMeshCook` (the four cook files, which only use public engine API), the engine has no new dependency, an app that only loads packs does not build the simplifier, and a tool that cooks adds one product.
- **Limits the simplifier works within.** A level may deviate by the size of one of its triangles (model diameter / √triangles). Vertices that two meshes of a model share stay in place, so the materials of one surface do not come apart. Texture seams are kept on textured meshes, unless they hold a level more than 25 % above its target. A level that is not at least 15 % smaller than the one before is left out. Skinned, morphing and animation-only models get no chain.
- **Vegetation.** The tree is 86,000 separate leaf cards and 30,000 twig pieces. Edge collapse alone leaves 29 % of the leaf area at 3 % of the triangles, and the canopy shows through. Small detached pieces are therefore collapsed only while they keep their outline, then thinned evenly through space, and the survivors are enlarged to give back the area removed. The leaf area stays the same at every level.
- **Manifest.** `lodChains`, by model path: for each level its file, its triangle count, the simplifier's error and a screen size (the share of the viewport height the model's bounding sphere covers when the level is detailed enough: where its triangles are about 4 pixels each at 1080 lines). A manifest without the key loads as before, and an older engine ignores it.
- **Loader.** The pack loader builds each level once per pack load (the cache of 1b) and gives every entity of a placement an `LODComponent`: level 0 is the model, then the chain. A level's screen size becomes a switch distance for that placement from the model's bounds, the placement's scale and the field of view (1d then reads the size as each frame is drawn). The levels are drawn with the model's materials, and a material edited while one level is on screen stays when another replaces it.
- **Two fixes in the LOD system** that the chains needed: the hysteresis (5 units by default) no longer takes more than a tenth of a level's switch distance (a level that switches closer than 5 units could never be returned to), and the configuration is read once per update instead of four times per entity.

Results on the BIM pack:

| | |
|---|---|
| Cook | 3.4 s for the whole pack; 217 of the 4,583 models get a chain, 649 level files, 233 MB |
| Triangles placed, all at level 0 / 1 / 2 / 3 | 349 M / 176 M / 54 M / 12.6 M |
| The tree (1,845,603 triangles) | 926,291 / 299,523 / 83,611 |
| Load (release build, headless) | 12.5–13 s / 4.8 GB GPU without chains → 14–15 s / 5.9 GB with them |

Frames, release build, headless at 1920×1080 on the M4 Max, without chains → with chains (two runs each, which agree):

| View | Triangles | GPU time | Whole frame |
|---|---|---|---|
| Overview of the site | 187 M → 7.4 M | 148 → 15–17 ms | 287 → 140 ms |
| Walking between buildings | 216 M → 10.2 M | 141 → 11–17 ms | 245–262 → 110–116 ms |
| Among the trees | 293 M → 20.6 M | 198 → 22 ms | 340–350 → 148–153 ms |
| One tree at 3 m | 237 M → 14.8 M | 192 → 15–20 ms | 348 → 155 ms |
| One tree at 15 m | 244 M → 10.3 M | 192 → 14–17 ms | 349–365 → 160–166 ms |
| One tree at 40 m | 268 M → 10.3 M | 213–220 → 14–17 ms | 368–379 → 158 ms |

In frames rendered from the same viewpoints the tree looks the same with and without the chain at 3, 7, 15 and 40 m.

The GPU work drops about twelve times and stops being the limit. The frame is now held by the CPU: 17,600 to 21,500 draws cost 75 to 135 ms to encode (about 40 ms fixed plus 5 to 7 µs per draw), and update and culling add about 8 ms each; a debug build takes three times as long. A profile shows the time in per-entity bookkeeping in the shadow and model passes (locks, dictionary lookups, retain and release), not in Metal. So after 1c the scene goes from about 3 to about 7 frames per second in a release build, and what decides the frame rate from here is how many entities reach the render loops: 1d and stage 2.

Limits found:

- The tree's last level still has 83,611 triangles (4.5 %), and the 175 trees hold up to 14.6 M of the 7–21 M triangles of a frame. Its branches stop simplifying at the error limit, and an extra level at 0.6 % or 0.1 % thins the canopy visibly at the distance its triangle count calls for. Going lower needs an impostor or stage 3, not more levels. In this pack the tree is placed at 5 % to 52 % of its size (most are about 3.5 m tall).
- A scene saved by the editor reloads its placements one by one, not through the pack loader: neither the shared builds of 1b nor the chains of multi-node models survive a save and reload. To do as its own change (a cache per scene load, and the chain found from the model). Tracked as untoldengine/UntoldEngine#1326 (2026-10-08), together with the screen-size fields of #1322 that the serializer does not write.
- The editor cooks through `scripts/export-untold`, which writes no chains. It needs the `UntoldEngineMeshCook` product and a call to `UntoldMeshLODCooker.cookChains(forPackAt:)` after its export (an editor change, once the engine change is in the editor's engine). Until then: `untoldengine bake-lods`.

### 1d. LOD by screen size and small-object culling (engine)

Built on 2026-10-03 as two changes, because they touch different systems and only the second depends on 1c.

**Small-object culling** (branch `feature/small_object_culling`, cut from upstream/develop, independent of the other items). The loop that gathers the bounds for the frustum cull leaves out every entity whose bounding sphere is under a set number of pixels tall, and the directional, spot and point shadow caster lists leave out the same entities. The size comes from the sphere's radius, its distance to the camera, the projection in use and the height of the viewport. `setRendering(.smallObjectCulling(pixels:))` sets it: 1 pixel by default, 0 draws everything as before. Nothing is culled by size under an orthographic projection, and an entity whose bounds have no size is never culled. One fix came with it: when nothing is left to test, the cull now publishes an empty visible set (it returned early and the frame kept drawing the previous one).

Why it matters here, visible entities by the height of their bounding sphere on a 1080-line viewport:

| View | Visible | Under 2 px | Under 4 px |
|---|---|---|---|
| Overview of the site | 17,783 | 8,974 (50 %) | 15,817 (89 %) |
| One tree at 15 m | 21,300 | 6,029 (28 %) | 9,425 (44 %) |
| Among the trees | 18,220 | 3,706 (20 %) | 5,296 (29 %) |
| Walking between buildings | 5,761 (plus 11,835 shadow draws) | 694 (12 %) | 1,219 (21 %) |

**Selection by screen size** (branch `feature/lod_screen_size`, stacked on 1c). A LOD component can select its level by the size of the entity on screen (`LODComponent.selectsByScreenSize`) instead of the distances fixed at load: each level ends where the entity covers the `screenPercentage` of the next one. The size is read as each LOD pass runs, from the sphere around the entity's bounds under its world scale and from the projection in use, so a placement that is scaled and a zoom keep each level where the model looks as large as when the level was made for it. The size is a share of the viewport height whatever the resolution: a Retina window and the headset draw the same levels as a 1080-line view, and `setLOD(.distanceBias(...))` is the setting for a platform that wants more or less (a first version scaled the switches with the pixel height of the viewport; that was dropped, because it multiplies the triangles on a dense display for detail that is not seen). The placements of a pack select this way; the parts of a model with several nodes carry the radius of the whole model and change level together. The distance of the load stays in `maxDistance` for an orthographic view. `screenPercentage` existed and was never read, so a component selects by it only when told to and scenes that set distances keep them.

Results on the BIM pack, release build, headless at 1920×1080 on the M4 Max, one sequence of runs: without chains → with chains (1c) → with chains and 1-pixel culling (1d):

| View | Draws | Whole frame |
|---|---|---|
| Overview of the site | 17,791 → 17,791 → 11,926 | 290 → 159 → 126 ms |
| Walking between buildings | 17,604 → 17,604 → 16,452 | 240 → 120 → 120 ms |
| Among the trees | 18,725 → 18,698 → 16,447 | 345 → 166 → 157 ms |
| One tree at 3 m | 20,717 → 20,717 → 17,000 | 337 → 185 → 157 ms |
| One tree at 15 m | 21,381 → 21,381 → 17,119 | 353 → 179 → 158 ms |
| One tree at 40 m | 21,482 → 21,482 → 16,892 | 375 → 183 → 153 ms |

By pixel setting (0 / 1 / 2 / 4 pixels, an earlier sequence of runs): overview 141 / 111 / 101 / 69 ms with 17,791 / 11,926 / 8,985 / 2,536 draws; walking 101 / 98 / 100 / 93 ms; among the trees 149 / 136 / 129 / 123 ms; one tree at 15 m 157 / 140 / 130 / 114 ms. The default stays at 1 pixel, where nothing can be seen to go; 2 to 4 pixels is a setting for a scene like this one.

So small-object culling takes a fifth off the frame from above and almost nothing at street level, where what is visible is really there. The selection by screen size changes nothing at the field of view the pack was loaded under, by construction; it is what keeps the switches right under a zoom and for placements that are scaled after the load.

### Where the frame goes after stage 1

A CPU profile of the overview with 1c and 1d (126–132 ms per frame, 11,926 draws, no shadow draw):

| Part of the frame | Share |
|---|---|
| Shadow pass: choosing the casters (fitting the cascades 16 %, one list per cascade 21.5 %) | 38 % |
| Model pass (11,926 draws) | 31.5 % |
| Transparency, wireframe and outline passes (walks that find nothing to draw) | 13 % |
| Gathering the bounds for the cull | 8 % |
| Statistics (debug builds and builds with `ENGINE_STATS_ENABLED`) | 7 % |
| LOD selection | 1.3 % |

Across those passes, 27 % of the frame is `Scene.get`, and 22 % is the lookup of the component's id inside it. Each pass walks every candidate entity and reads four to ten components for it, so the cost follows the 21,576 render entities, not what is on screen: the shadow pass spends 38 % of the frame to conclude that nothing casts a shadow into view.

Three experiments on top of 1d, none of them on a branch:

- **Static batching of the parts without a chain.** The 9,818 render entities that have no LOD chain (the small unique parts) marked static and batched with the engine's own system: 0.2 s to build, 138 MB, 257 batch groups. Frame 126 → 99 ms (overview), 120 → 82 ms (walking), 157 → 122 ms (among the trees), 158 → 117 ms (tree at 15 m); draws 11,900–17,100 → 7,900–10,700; shadow draws at street level 11,058 → 6,649.
- **The component id without the lock and the dictionary** (a prototype: ids published in a fixed table that is read without locking). Frame 126 → 116–119 ms (overview), 120 → 97–107 ms (walking), 157 → 136–141 ms (among the trees); the id lookup falls from 22 % to 6 % of the frame. Replacing only the NSLock with an unfair lock, which is what the fork's performance branch does, stays inside the noise (5 % at most).
- **Shadow casters by their size in shadow-map texels.** At street level the far cascade (5.3 cm texels) holds 11,033 casters: none under 1 texel, 5 % under 2, 12 % under 4, 36 % under 16. A texel-size rule at a conservative threshold would remove little; the shadow draws at street level are objects of real size.

### Found in 1b, and fixed in its review

`MemoryBudgetManager` counted each entity's full mesh and texture bytes, so memory shared between placements was counted once per placement (it was real before 1b, when each placement held its own copy). For this pack the budget reported 52.2 GB against 4.8 GB really allocated, and stood in its eviction state on a machine with a 26 GB geometry budget; under that state geometry streaming holds back its loads and `StreamingRegionManager` destroys the least recently used entities. The review of #1290 asked for it to be fixed there, and it is: an entity is registered by the buffers and textures it holds, and each is counted once while any entity holds it. The budget now reports 3.77 GB for 3.83 GB allocated.

The same review made the image cache single-flight (models that share an image and load at the same time no longer each decode it), which takes the pack from 4.84 GB to 3.83 GB of GPU memory, and made a failed build try once more before every placement of the file falls back.

Still open here: the levels of a LOD chain (1c) are not in the budget at all, only the model's own buffers. With the ledger by allocation they can be added in 1c at no cost per placement.

### What stage 1 gave

Against the scene as it loaded on 2026-10-02 (release build, headless at 1920×1080, M4 Max):

| | Before | After 1a–1d |
|---|---|---|
| Load | 118 s, 57.7 GB of GPU memory | 15 s, 5.9 GB |
| Triangles per frame | 190–290 M | 7–20 M |
| GPU time per frame | 135–210 ms | 10–23 ms |
| Whole frame | 240–375 ms | 120–160 ms |

The triangles were the first of the three causes and they are dealt with. The frame is twice as fast and still far from interactive, because the second cause turned out larger than the plan assumed: not the draws alone, but everything the engine does per entity and per frame.

## 4. Stage 2 — the cost per placement (engine)

The plan for this stage was one draw per mesh. The profile of section 3 asks for more than that: the draws are a third of the frame, and the rest is the passes walking the entities. The cull's gather loop, the fit of the shadow cascades, one shadow list per cascade, the model pass, the transparency, wireframe and outline passes and the statistics each visit the 21,576 render entities, or the 12,000 to 17,000 visible ones, and read their components one by one through the ECS: about 5 µs per entity and frame in all, 100 ms for this scene, whatever is on screen. Instancing alone would remove draws and leave the walks. So the stage has two parts:

1. **A retained table of what is drawn.** One record per placed mesh, in flat arrays: world transform, world bounds, the mesh and its LOD levels, the material, and the flags the passes ask about (casts a shadow, hidden, channel, transparent, selected). It is updated when something changes instead of being derived again from the ECS by every pass of every frame, and the passes read it. The entities stay what they are for the editor (hierarchy, selection, inspector, save); they stop being what the renderer iterates. The hard part is knowing when a record is stale: transforms that systems write directly, visibility flags, material edits. The placements of a pack are the easy case and the one that matters here: the loader can register them as static records, and whatever moves or is edited goes back to the path of today until it settles.
2. **Instanced draws from the table.** Records that share a mesh level and a material are drawn in one call with per-instance transforms; culling (frustum, HZB, size on screen) runs over the table on the GPU and writes the visible instances compactly; each shadow cascade draws from the same table. This takes the draw count from one per placement to about one per distinct visible mesh, and it is the per-instance stage the cluster renderer of stage 3 needs anyway.

Part 1 is what removes the 100 ms; part 2 then takes the draws from thousands to hundreds. Part 1 alone already allows the cull and the shadow lists to run over flat arrays (an estimate, not a measurement: a few hundred microseconds for 21,576 records).

Three smaller things exist today or are cheap, measured in section 3, and none replaces the table:

- **Static batching for the parts without a chain** (20 to 30 % of the frame, 138 MB): the engine's own system, switched on per entity. It fits the 8,579 small unique placements, which instancing does not merge, and it could be a loader policy for packs or an action in the editor. A batched part that is moved needs its cell rebuilt.
- **The component id lookup** (10 to 15 % of the frame, for any scene): it belongs to the performance work that lives on the fork, where the change tried so far (an unfair lock) does not reach the cost.
- **The order of the tests in the shadow lists**: each candidate is looked up six to ten times before the test that rejects most of them (its distance to the cascade). Testing that first is a contained change with the same result.

Decision D3 (2026-10-03): a placement stays a full ECS entity and the renderer reads a table. The editor keeps working as it is, and the entities then cost memory and load time but not frame time.

### Prototype of part 1 (2026-10-03)

A prototype on a scratch branch (`proto/render_entity_table`, on top of everything of stage 1) to see what the table is worth before building it properly.

**How it stays correct.** A row of the table holds the component *objects* of a render entity (render, world and local transform, channels) and flags for the components it has (gizmo, light, camera, static batch, LOD, occluder, fades, skeleton, deformation). It holds no copy of a value: a pass reads the transform, the mesh list or the visibility through the row and sees what is there now. So nothing in a row can go stale except which components the entity has, and that changes in five places of `Scene` only (a component assigned or removed, all removed, an entity marked for destruction or freed). Each bumps `Scene.structureGeneration`; a pass that finds it moved rebuilds the rows (one walk), and not while assets are being registered, when the frame already draws from what it knew.

**What reads it.** The gather loops of the cull, the fit of the shadow cascades, the caster list and the draws of each cascade, the combined model pass, the transparency gather, the wireframe and occluder-shell filters and the statistics audit. With it, what every draw of a pass shares is read once per pass instead of once per draw (camera position, projection, POM quality, debug switches, immersion style, whether batching and LOD fades are on), a scene channel's render mode is asked once per run of entities on the same channels, and a mesh's vertex buffers are asked from MetalKit once per mesh instead of six times.

**Result**, release build, headless at 1920×1080 on the M4 Max, chains baked, 1-pixel culling; whole frame in ms:

| View | Before stage 1 | After 1d | Prototype |
|---|---|---|---|
| Overview of the site | 290 | 126 | 30–32 |
| Walking between buildings | 240 | 115–120 | 26–28 |
| Among the trees | 345 | 157–160 | 41–42 |
| One tree at 3 m | 337 | 157–160 | 42–43 |
| One tree at 15 m | 353 | 158 | 44–45 |
| One tree at 40 m | 375 | 153–160 | 43–44 |

The draws, the triangles and the visible entities are the same numbers as before the prototype, and the images of four of the views are identical pixel for pixel. CPU time per frame is 17 to 28 ms and GPU time 6 to 14 ms: 23 to 37 frames per second, without instancing. Half-way through (only the cull gather and the shadow passes on the table) the frames were 47 to 91 ms.

What is left of the frame's CPU time in the overview: the model pass 59 % (now about 1 µs per draw, a quarter of the frame binding vertex streams), the shadow pass 10 %, transparency 7 % (it scans the materials of every visible entity for blended ones), LOD selection 7 %, outline 5 %, cull gather 5 %.

**What it is not yet.** A prototype: the XR path is untried, the separate model pass, the spot and point shadow lists and the other walkers of the visible list (batching, texture streaming, picking) still go through the ECS, and the rows are refreshed by each pass rather than once per frame. The proper version is to be cut from upstream develop and split into reviewable steps: the per-pass state read once (small, no table), the table with the cull and shadow passes on it, then the draw passes.

### Part 1 as built: a snapshot per pass, no retained table (2026-10-03)

Reading upstream's passes to build the table properly showed a simpler way to the same result, and it is what was built (local branch `feature/render_scene_snapshot`, three commits on upstream develop, not pushed).

**What the cost was.** Not the ECS as such, but how it is asked: every `scene.get` takes the scene lock, copies the scene and looks the component's id up in a locked dictionary, and the passes did that about fifteen times per entity and five more per draw. The entity array and the component storage themselves are cheap to read.

**The design.** A pass builds a `RenderSceneSnapshot` when it starts: one read of the scene, the ids and the storage of the components it uses looked up once. From it, an entity's traits come from its component mask (bit tests), and its component objects from the storage (pointer arithmetic). The snapshot lives for one pass and is thrown away.

**Why not the retained table of the prototype.** The table needs to know when it is stale, and that is where it was fragile: a generation counter in five places of `Scene`, a rule for asset loading, and a cached "default channels" value that depends on the entity's *name* and on the channel prefix registry (found while reading upstream: the prototype's cache of it could go stale on a rename). The engine has had this kind of bug in its one retained render cache (the shadow candidate list has a test that pins a past staleness defect). A snapshot per pass has nothing to invalidate, and it measures within 1 to 3 ms of the table:

| View | After 1d | Snapshot per pass | Retained table (prototype) |
|---|---|---|---|
| Overview of the site | 106–109 | 34–35 | 32–34 |
| Walking between buildings | 93–97 | 30 | 26–29 |
| Among the trees | 131–134 | 43 | 40–42 |
| One tree at 3 m | 133–136 | 43–45 | 42–43 |
| One tree at 15 m | 134–135 | 44–46 | 44–45 |
| One tree at 40 m | 132–137 | 44–45 | 43–44 |

(Whole frame in ms; the three builds run in turn, three rounds, same conditions as the tables above. The machine was busier than for the earlier tables, hence the lower "after 1d" column.) Culling gather 7.5–8.7 → 1.5–1.7 ms, encoding 69–117 → 17–28 ms, update unchanged at about 6 ms, GPU 7–14 ms.

**What reads it.** Everything the prototype converted, plus what it had left out: the separate model pass, the spot and point shadow lists, the shadow candidate cache rebuild and the wireframe passes. The XR path uses the same passes; the engine builds for the visionOS and iOS simulators.

**Same picture.** Draws, triangles and visible counts are identical. Five of the six views are identical pixel for pixel; the sixth differs in 98 pixels where two coplanar surfaces z-fight and the draw order decides (the order used to follow a hash set and now follows the entity indices, so it no longer changes between runs). The engine's reference-image tests give the same PSNR to four decimals as upstream (25 comparisons, run with a stand-in for the comparison script, which needs Python packages this Mac lacks).

**Tests.** 20 unit tests for the snapshot (what it finds, its traits, that its components are the scene's objects, walks against the scene query, channels by component and by name) and 9 render tests that pin the per-entity decisions of the opaque pass (hidden and wireframe channels, ids that are gone, tile and mesh fades, meshes on light, camera and gizmo entities). The 9 render tests also pass on upstream as it is.

**What is left of part 1.** The update phase (about 6 ms: LOD selection, transforms, streaming ticks) still asks `scene` per entity; LOD selection is the next candidate for the same treatment.

**Measured again on 2026-10-07**, after the branch was rebased onto upstream develop `4ae99ca2` (which has small-object culling, the Metal buffers, the LOD chains, the component release fixes and glass), against that develop, three alternating rounds: overview 128–207 → 39–43 ms (CPU 120–207 → 24–25), walking 113–119 → 29–31 ms, among the trees 146–167 → 48–51 ms, one tree at 3 / 15 / 40 m 150–157 / 152–159 / 150–156 → 46–50 / 48–53 / 45–50 ms; the same draws (12,735 to 18,182), shadow draws, triangles and visible counts in every view. These are the numbers of the pull request.

### What part 2 has to work with (measured 2026-10-03)

With part 1 in, the frame's CPU time in the overview (21 ms) is: the opaque pass 55 % (binding a mesh's vertex streams 23 %, the draw calls 13.5 %, material textures, samplers and parameters 9 %), the shadow pass 14 % (choosing the casters 7 %, fitting the cascades 5 %) although the view draws no shadow, LOD selection 6 %, the transparency gather 6 % (it scans every visible entity's materials for blended ones), geometry streaming 5 %. What is left is about 1 µs per draw, so the lever is the number of draws.

The visible opaque draws by mesh and material:

| View | Draws | Distinct meshes | Meshes drawn twice or more | Draws of those | Distinct materials |
|---|---|---|---|---|---|
| Overview of the site | 11,918 | 4,628 | 513 | 7,803 | 160 |
| Walking between buildings | 5,386 | 2,182 | 540 | 3,744 | 139 |
| Among the trees | 15,994 | 6,397 | 681 | 10,278 | 191 |
| One tree at 15 m | 17,038 | 6,570 | 726 | 11,194 | 194 |

- **Instancing** (one draw per distinct mesh) takes 61 % of the draws: in the overview 7,803 draws become 513. The other 4,115 draws are meshes placed once, which instancing does not help.
- **The meshes placed once** share 160 to 194 materials among all the visible draws. Merged by material (what the engine's static batching does, as a policy of the pack loader for the parts that do not move) they become a few hundred draws. The experiment of section 3 measured 138 MB and 257 groups for the 9,818 parts without a chain.
- **In the order the draws come today**, the material changes 6,411 times in the overview and the mesh 10,673 times. Sorting the opaque draws by material and mesh and binding only what changed needs no shader change and no new data: an estimate of a fifth off the CPU time, from the shares above.

So part 2 is two things, not one: instanced draws for what repeats and batches for what does not, about 700 draws in place of 12,000 in the overview. Sorting with state reuse is a smaller step that could come first.

### Sorting was tried and gave nothing; what a draw really costs (2026-10-03)

The sorted opaque pass was built (branch `feature/opaque_draw_order`, kept as an experiment): draws gathered, ordered by material and then by mesh with numbers given in first-seen order, and encoded binding only what changed. It works (its tests and the render tests pass, the same picture) and it removes nearly all the texture, sampler and vertex-stream calls. The frame did not get faster: CPU 23.2–23.9 ms against 23.2–24.8 ms in the overview, a little slower in the tree views.

The profile says why. The Metal state calls that sorting saves were never the cost (about 7 % in all). What a draw costs is:

- **asking MetalKit for what it binds**: `MTKMesh.vertexBuffers` builds an array and each element answers through Objective-C (14–23 % of the frame), and five more properties of `MTKSubmesh` per draw (10–14 %);
- **copies of `Material`, `SubMesh` and `Mesh`**: large structs with twenty-odd references each, retained and released on every copy. The sorted pass copied them more than the loop it replaced (4 % → 20 %), which ate what it saved.

So the step that pays is to read the MetalKit objects once, when a mesh is made. That is built on `feature/mesh_metal_buffers` (one commit on upstream develop, independent of everything else here): a `Mesh` keeps its Metal vertex buffers and a `SubMesh` its index data, and every pass draws from those.

| View | Snapshot per pass | + Metal buffers read once |
|---|---|---|
| Overview of the site | 35–38 (CPU 22.8–24.5) | 29–31 (CPU 17.8–18.1) |
| Walking between buildings | 31–35 (CPU 19.9–21.6) | 25–28 (CPU 16.0–16.1) |
| Among the trees | 44–49 (CPU 28.8–30.1) | 37–38 (CPU 22.3–22.5) |
| One tree at 3 m | 45–50 (CPU 29.6–31.9) | 38–39 (CPU 23.0–23.3) |
| One tree at 15 m | 48–56 (CPU 29.8–34.9) | 38–39 (CPU 23.5–23.6) |
| One tree at 40 m | 46–52 (CPU 29.9–33.6) | 37–41 (CPU 22.9–23.8) |

(Whole frame in ms, the two builds run in turn, three rounds.) About 5.5 ms per frame, 0.45 µs per draw; on upstream alone, a scene of 10,000 cubes goes from 66 to 61 ms of CPU time.

What this says about the rest: sorting is not worth doing until a material is cheap to copy or to compare (one reference in place of twenty), and the per-draw cost that remains is that copying plus the draw call itself. The number of draws is still the lever: instancing and batching, as above.

### Part 2: instanced draws, the design (2026-10-03)

Placements that draw the same meshes with the same materials become one draw with an instance count. Each instance takes its transform from a buffer that the pass writes once.

**What to expect, measured before building.** A profile of the overview on the build with the snapshot and the Metal buffers (20.8 ms of CPU per frame, newest cook):

| Where the CPU time goes | Share of the frame |
|---|---|
| Opaque pass | 45 %: the draw call 14.4, binding the vertex streams 11.2, textures, samplers and uniform bytes 6.4, copies of `Mesh` 2.3, the rest per entity |
| Shadow pass | 16.7 %, of which choosing the casters 8.6 (this view draws no shadow) |
| LOD selection | 8.8 % |
| Transparency pass (a walk that finds nothing to draw) | 7.4 % |
| Cull gather | 6.4 % |
| Streaming update | 5.6 % |

| View | Opaque draws | As instanced draws | Shadow draws |
|---|---|---|---|
| Overview of the site | 11,918 | 5,215 (−56 %) | 0 |
| Walking between buildings | 5,382 | 2,792 (−48 %) | 11,058 |
| Among the trees | 15,986 | 6,970 (−56 %) | 445 |
| One tree at 15 m | 17,030 | 7,254 (−57 %) | 73 |

In every view the placements that share a mesh also share their materials (counting by mesh and material gives the same number as counting by mesh).

So in the overview instancing removes a little over half of the roughly 42 % that is per-draw work in the opaque pass, and adds a small cost per instance (finding its group, writing its record): **about a fifth off the CPU time, around 4 ms of 21.** When I proposed this step I quoted the fall in the number of draws (61 % with the earlier cook); the gain in time is this smaller figure, because the work per entity stays. Walking between the buildings two thirds of the draws are shadow draws, so the shadow cascades are instanced as well. The 4,400 meshes that are drawn once are not helped: they are the case for batching by material (section 3).

**What is drawn as an instance.** An entity is plain when nothing about its draw is its own: no LOD fade running, no tile or mesh fade, no skin, morph targets or deformation, no debug colouring. Plain entities are grouped by what they draw, groups of one included. Every other entity is drawn alone, by the code that draws it today.

**How a group is found.** `RenderComponent` caches a small number that two components share exactly when their mesh lists hold the same Metal meshes, the same local transforms and, for each submesh, the same values and textures that the pass sends to the GPU. The number comes from a table that compares that description in full, not a hash of it, so two different materials never end up in one group. Any change to `renderComponent.mesh` (a material edit, a texture streamed in, a LOD switch) clears the cached number in the property's `didSet`; it is looked up again the next time the entity is drawn. Nothing has to be declared: the copies of a pack model, 10,000 cubes made from one mesh, or two entities given equal materials by hand group by themselves, and an entity whose material is edited leaves its group by itself.

**The draw.** New shader entry points `vertexModelInstancedShader`, `fragmentModelInstancedShader` and `vertexShadowInstancedShader`, and two pipelines made from them. A record per instance (model-view, model and normal matrices and the ghost opacity, 192 bytes; one matrix, 64 bytes, for a shadow instance) goes into a buffer taken from a pool and given back when the frame's command buffer completes. The buffer is bound once per pass and each draw names its first record as the base instance. The body of the fragment shader moves into a function that both entry points call, so both paths shade with the same code. The entry points that exist, `Uniforms`, `VertexOutModel` and the model pipeline stay as they are: a render extension that uses `vertexModelShader` is not touched.

**Not in this step.** Transparent draws (they are sorted back to front), spot and point light shadows, the wireframe and outline passes. A setting turns the instanced path off.

**What it costs.** The engine's seven prebuilt Metal libraries are rebuilt (`buildkernels.sh`, as #1292 did). The order of the draws changes (the entities drawn alone, then the groups in the order their first instance comes), which can change which of two exactly coplanar surfaces shows.

**How it is verified.** Tests that draw one scene with the path on and off and compare the pictures (each material property, a fade running among instances, a skinned entity, shadows); tests of the table (equal content shares a number, each property that must split a group does, a change clears the number); the BIM views side by side; the usual suites.

**Where it goes.** The branch stacks on small-object culling, the snapshot and the Metal buffers: it rewrites the same loops and reads `Mesh.vertexBuffers`. Its pull request follows theirs.

### Part 2 as built: instanced draws (2026-10-04)

Built on the local branch `feature/instanced_draws` (worktree `UntoldEngine-instancing`), stacked on small-object culling, the snapshot and the Metal buffers. It follows the design above, with two things learnt on the way:

- **Whether a mesh is skinned is asked of the entity, not of the mesh.** Every mesh carries a skin object, used or not, so the mesh list cannot say. The pass draws an entity with a skeleton or a deformation on its own, and every other one instanced.
- **What a draw binds is prepared once per component, not per frame.** The first version read the material at every draw, and the profile showed a copy of the material each time (a tenth of the CPU frame). Now a component that stands for its group keeps the values and textures its draws bind (`InstancedSubmeshDraw`) until its meshes change; the encoder binds from that, and the description that decides whether two materials are the same is made from the same values. That also removes the per-draw material work for the groups of one, which is why the gain is larger than predicted.

Measured by alternating the two builds, three rounds each (whole frame in ms, CPU in brackets; the machine was busy):

| View | Snapshot + Metal buffers | + instanced draws | Draws |
|---|---|---|---|
| Overview of the site | 32.9 (CPU 19.0–20.8) | 23.7 (CPU 13.0–14.5) | 11,926 → 5,223 |
| Walking between buildings | 28.4 (CPU 16.6–18.1) | 22.2 (CPU 11.9–13.6) | 16,452 → 7,416 (shadow draws 11,058 → 4,612) |
| Among the trees | 42.2 (CPU 23.2–24.9) | 31.4 (CPU 16.2–18.8) | 16,447 → 7,341 |
| One tree at 3 m | 42.4 (CPU 24.2–26.2) | 30.3 (CPU 16.0–17.3) | 17,000 → 7,344 |
| One tree at 15 m | 44.2 (CPU 24.7–26.3) | 31.1 (CPU 16.4–17.0) | 17,119 → 7,340 |
| One tree at 40 m | 45.0 (CPU 24.6–28.9) | 30.0 (CPU 16.2–18.6) | 16,892 → 7,192 |

**Frames are 22 to 33 % shorter and the CPU time about 30 % lower** (6 ms of 20 in the overview), against the fifth I predicted; the triangles drawn are the same in every view. The GPU also takes less (8 ms against 12 in the overview): fewer draws to set up.

**The picture.** With the instanced path switched off, the new build draws all six views exactly as the old one (0 pixels differ): the shader change is exact. Switched on, the overview, the walking view and the tree at 40 m are identical, and the three views among the trees differ in 16 to 493 pixels of 2,073,600, among the leaf cards, nearly all by under 8/255. That is the order of the draws: where two surfaces lie exactly on each other, the one drawn last shows, and the order changed. (The walking view has a pair of coplanar surfaces whose 98 pixels come out one way or the other from run to run with one and the same build, before instancing too: it depends on the order the two parts were loaded in. Every image of that view matches one of the two.) In scenes without coplanar surfaces the two ways give the same frame pixel for pixel, which is what the tests check: 12 scenes (materials, textures, cut-outs, local transforms, a fade among instances, a ghost channel, shadows, loaded models with a skinned one, LOD switches).

**Verified.** 29 new tests: the frame drawn both ways; what makes two components share a key, value by value, and what clears a key; the layout and the values of the records; the buffer pool. The core suite (1,585, only the folder-name failure, which passes from a checkout named `UntoldEngine`), the render suite (1,172 pass, 69 skipped as upstream; the eleven reference images that match exactly on upstream still match exactly with the instanced path on), the zero-warning guardrail and the lint. The seven shader libraries are rebuilt with the package's deployment targets. A synthetic scene for the pull request: 10,000 cubes go from 11,896 draws to 10 and from 10.8 to 4.9 ms of CPU per frame. The pull request text is drafted in `LargeSceneRendering/pr-draft-instanced-draws.md`.

**Committed** as three commits on `feature/instanced_draws`: `24325157` the shaders, `be71eab4` the rebuilt libraries, `d15100e4` the engine side with its tests and documentation.

**What the frame is made of now** (overview, 13.7 ms of CPU): the opaque pass 31 % (its instanced draws 27 %: the draw calls 10, textures and vertex streams 6), the shadow pass 21 % with nothing to draw (choosing the casters 11, fitting the cascades 8), LOD selection 10 %, the cull gather 9 %, the transparency walk 8 %, the streaming update 8 %. The draw calls are no longer the largest item: the walks over the entities are, again. The 4,400 meshes drawn once are still 4,400 draws.

### The walks over the entities (2026-10-04)

Chosen by the user after instancing ("Entity walks"). Built on the local branch `feature/entity_walks` (worktree `UntoldEngine-walks`), on top of instancing and of the LOD branches (`int/walks_base`), as five changes that each remove a walk or make it cheap, without changing what is drawn:

| Change | What it was | What it is now |
|---|---|---|
| Directional shadows | One walk of every entity to fit the cascades and one more per cascade to choose its casters; the fit made the light-space box of every entity | One walk a frame for both; each cascade tests the casters by their stored boxes; the fit makes a light-space box only for casters near a cascade |
| Transparency pass | Every visible entity's meshes and materials copied and searched for a blended submesh, every frame | The render component remembers the answer until its meshes change |
| LOD selection | Three questions to the scene per entity with levels | One snapshot of the scene |
| Streaming update | Six passes over every entity within 500 units, asking the scene twice each, in a scene where nothing streams | The query is narrowed once to the entities that stream or are tiles |
| Cull gather | The world box of every entity made twice and an array made per entity | Made once, appended in place |

Measured by alternating the two builds, three rounds each (whole frame in ms, CPU in brackets):

| View | Instanced draws | + the walks |
|---|---|---|
| Overview of the site | 22.6 (CPU 13.9–14.4) | 17.5 (CPU 8.4–9.4) |
| Walking between buildings | 21.7 (CPU 12.0–13.4) | 18.1 (CPU 8.7–9.6) |
| Among the trees | 30.1 (CPU 16.6–17.4) | 24.5 (CPU 10.5–11.3) |
| One tree at 3 m | 30.5 (CPU 16.9–17.8) | 24.7 (CPU 10.9–11.4) |
| One tree at 15 m | 30.9 (CPU 17.1–17.7) | 25.3 (CPU 11.0–11.8) |
| One tree at 40 m | 30.8 (CPU 16.9–17.8) | 22.8 (CPU 10.8–11.5) |

**The CPU time of a frame falls by about a third again (14 to 9 ms in the overview), and the frames by 17 to 26 %.** Draws, shadow draws and triangles are the same, and so are the pictures: the six views match the instanced build pixel for pixel (the walking view up to the run-to-run pair noted above). 10,000 cubes: 4.8 to 2.7 ms of CPU per frame.

Since the start of stage 2 the frames of these views went from 93–137 ms to 17.5–25 ms (the earlier figure is from the cook of that day, a few hundred draws lighter). In the overview the GPU (8 ms) is now as large as the CPU (9 ms).

**Verified.** New tests: the cascades the pass fits equal those the shadow system fits on its own; a caster made or switched after a frame casts or stops in the next; what does not cast still shapes the cascades; the blended-submesh answer follows the materials and the transparency pass draws by it. The core suite (1,627, only the folder-name failure), the render suite (1,193 pass, 69 skipped as upstream, the known timing flake of the paging test passed on a rerun), the same reference-image scores as before, the zero-warning guardrail and the lint.

**What the frame is made of now** (overview, 8.7 ms of CPU): the instanced draws 43 % (5,215 draw calls), the shadow walk 12 %, the cull gather 10 %, LOD selection 6 %, the rest small. What is left to gain on the CPU is mostly the number of draws: the 4,400 meshes drawn once (batching by material). The walks that remain could share one gather per frame, for about a millisecond more.

### Part 3: batches for the parts placed once, the design (2026-10-04)

Chosen by the user after the fourth try-out ("huge improvements, its about 60 fps and some times goes below 50"). The dips are the views with the most on screen, among the trees: 17,000 visible entities, and 6,200 of the 7,250 opaque draws are meshes that appear once, which instancing cannot merge.

The engine already has static batching: entities marked static are merged by material into a few vertex buffers per 32 m cell, and each merged group is one draw. What is missing is the decision of what to mark. Nobody marks the parts of a pack, so a scene exported from a BIM tool gets nothing of it.

**Measured before building**, with the existing system and the parts marked by a scratch test (walks build, release, headless 1080p, two rounds; the machine was busy):

| | No batching | Parts placed once, without a LOD chain | Every part without a LOD chain |
|---|---|---|---|
| Parts merged | | 4,227 into 213 groups | 9,660 into 296 groups |
| Memory, build time | | 50 MB, 0.2 s | 148 MB, 0.3 s |
| Draws, one tree at 15 m | 7,340 | 4,222 | 3,903 |
| Frame (CPU), one tree at 15 m | 27.4 ms (13.4) | 22.3 ms (12.0) | 21.0 ms (10.6) |
| Frame (CPU), one tree at 40 m | 25.7 ms (13.0) | 22.7 ms (11.4) | 20.1 ms (10.5) |
| Frame (CPU), among the trees | 30.2 ms (13.0) | 27.0 ms (11.7) | 25.7 ms (10.8) |
| Frame (CPU), walking | 20.1 ms (11.2) | 18.1 ms (9.2) | 15.7 ms (8.2) |
| Frame (CPU), overview | 19.3 ms (10.4) | 17.9 ms (10.3) | 17.2 ms (9.0) |

So the parts placed once give 2 to 5 ms a frame for 50 MB; the GPU gains as much as the CPU, since it has 3,000 fewer draws to set up. Batching the repeated small parts as well gives 1 to 2 ms more for another 100 MB of copies of meshes that instancing already draws once: not taken. The 3,600 draws that stay in the tree views are the nodes of the models that have a LOD chain; they change level one by one, so they cannot be merged at run time. Merging them per level is a job for the cook (below).

**What is built.**

- **The pack loader marks the parts.** An entity of a placement whose model file is placed once in the pack, and has no LOD chain, gets the `StaticBatchComponent` that the editor's Static toggle gives. `setBatching(.packSinglePlacements(false))` turns the marking off.
- **The batches are built when the pack has loaded**, if batching is enabled (`setBatching(.enabled(true))`, as today; it stays off by default in the engine, and the editor turns it on). With batching off the marks do nothing, and a later `generateBatches()` uses them.
- **A part that is moved or destroyed leaves its batch.** A batch holds the vertices of its parts where they stood. Today an entity moved through the transform functions stays where it was in its batch, and the editor works around it by unmarking the entity and rebuilding every batch. The engine now does it: a batched entity that moves loses its mark (it has shown it is not static) and its cell is rebuilt without it. That makes marking by default safe.
- **Asking whether an entity is in a batch gets cheap.** Every pass asks it of every visible entity through a dictionary (7 % of the CPU frame with batches on). Only a marked entity can be in one, and the mark is a bit in the snapshot the pass already has.

**What changes in the picture.** Not pixel for pixel the same, unlike instancing. In the six views that is 0 to 1,500 pixels of 2,073,600, and in one view 15,000 pixels that differ by 1 or 2 of 255. (The causes were guessed here before building; what was measured afterwards is in "Part 3 as built".)

**Not in this step.** The parts with LOD chains; the transparent ones (batching never took them); a scene saved by the editor and loaded again, which does not go through the pack loader. For the chained models the next idea is to merge a model's nodes by material in its simplified levels when the cook writes them: far models, where most entities are, would be a handful of draws each.

**How it is verified.** Tests of the marking (placed once and no chain, the setting, a pack without chains), of the build at load, of a moved and a destroyed part, and of the cheap check; the frame with and without batches in the existing batching tests; the BIM views; the usual suites.

### Part 3 as built: batches for the parts placed once (2026-10-04)

Ten commits on the local branch `feature/pack_single_batches` (worktree `UntoldEngine-batches`, on top of `feature/entity_walks`, tip `f772587c`, not pushed).

**Two things changed from the design above, both because of what the code around it does.**

- **The batches are not built with `generateBatches()` when the pack is in.** That call rebuilds every batch of the scene inside the call: a second pack would rebuild the first, and in a streamed scene it builds every loaded tile at once. And the editor, when it drops a pack at a point, moves the pack's root right after the load, which would have thrown the build away. Instead the loader hands its marked parts to the batching system (`notifyStaticEntitiesPlaced`), which builds their cells in its per-frame tick, on its background queue and within its per-tick budgets, but without the two gates it applies to streamed tiles: it does not wait for a cell to be seen, and it does not skip a cell over the per-cell size limits (the densest cell of the BIM is 9.7 MB against a limit of 8 MB). There is no hitch: the BIM's 38 cells are built over the 22 frames after the load.
- **A part that moves does not lose its mark.** It leaves its batch before the next frame is drawn, and 30 frames after it stops it is batched again where it stands. The same goes for parts moved with their parent, which is how a whole pack is moved. A part that keeps moving simply stays out. Unmarking and destroying take a part out at once.

**Six defects of the existing batching system, found on the way and fixed, each with a test that fails without the fix.** They apply to any static entity, not only to a pack.

| Defect | Seen as |
|---|---|
| A mesh alone with its material is left to its entity, but an entity that is in a batch for another mesh is not drawn by itself | An entity with two materials, one shared and one of its own: the second mesh was not drawn at all |
| The key that decides which meshes are merged left out clear coat, sheen, the tints, subsurface and anisotropy | Two materials alike in the rest were merged and drawn with the values of one |
| The tick returned early before applying the builds that had finished | The last cell of a scene that then stood still was never batched (one cell and 17 parts of the BIM) |
| The shadow passes skipped every marked entity, in a batch or not | A marked entity that no batch took cast no shadow from the sun, spot or point lights (146 parts of the BIM) |
| Nothing told the batching system that an entity moved, lost its mark or was destroyed | It went on being drawn by its batch, at its old place |
| A batch drew all of its entities and cast for all of them, whatever their `isVisible` and `castsShadow` | An entity hidden in the editor stayed on screen; one told not to cast went on casting |

The fourth keeps what the old rule was for: an entity of a streamed tile still casts nothing during the frames in which its batch is on its way. The sixth was found when preparing the try-out: the editor hides an entity by clearing `isVisible` on its render component, which now tells the batching system; the entity leaves its batch and comes back when it is shown again. Entities that cast no shadow are not kept out of batching for it: `castsShadow` is part of what groups them, so they get batches of their own, which the shadow passes skip.

**Measured on the BIM** (release, headless 1080p, three rounds alternating with the walks build; the machine was busy, the user's editor running beside it). The loader marks 4,373 of the 21,576 parts; 4,227 end up in 213 batches in 38 cells, 37 MB; 146 are alone with their material in their cell and go on drawing themselves.

| View | Walks build: frame (CPU) | With the batches: frame (CPU) | Draws |
|---|---|---|---|
| Overview | 19.6 ms (9.9–10.9) | 18.2 ms (9.2–9.7) | 5,223 → 3,460 |
| Walking | 19.5 ms (9.7–11.2) | 18.1 ms (8.7–9.0) | 7,416 → 4,511 |
| Among the trees | 31.3 ms (12.5–12.6) | 26.8 ms (9.8–11.2) | 7,341 → 4,206 |
| One tree at 3 m | 29.3 ms (12.6–13.3) | 24.8 ms (10.5–11.1) | 7,344 → 4,175 |
| One tree at 15 m | 25.9 ms (12.7–13.0) | 20.8 ms (10.3–11.7) | 7,340 → 4,236 |
| One tree at 40 m | 25.5 ms (12.3–13.1) | 21.8 ms (10.4–11.3) | 7,192 → 4,177 |

With batching off, the new build draws the same frames as the walks build, pixel for pixel, in the same time.

**The picture, as measured.** Three of the six views are the same pixel for pixel. The other three:

- Walking, 682 pixels: a pair of coplanar parts at the foot of a wall is drawn in the other order. It is not a shadow: with every caster switched off the strip stays.
- One tree at 3 m, 15,057 pixels, most by 1 or 2 of 255 (143 by more than 8): the faint self-shadows of the leaves are gone. The cascades are fitted to the boxes of the batches, which are larger than the boxes of their parts, so the first cascade covers 30.3 m in depth where it covered 24.2 m, and the depth bias grows with it. With the sun's shadows off, the frame with batches and the frame without are identical.
- Overview, 35 pixels: not looked into.

Every opaque mesh of every batched part is in a batch: the index counts of both add up to 1,127,142.

**Try-out.** A fifth build, `Untold/BimTryout/stage2-batches` (local, not pushed): the engine branch `try/large_scene_stage2_batches` (tip `61348dda`) is the fourth try-out's branch with this one merged, and the editor copy turns batching on at start and no longer unmarks and rebuilds when an entity is moved. On that branch (which also has the glass and the procedural bake), batching off against on: frames 21.4/19.6/31.1/30.9/29.7/26.3 ms → 19.5/16.0/28.5/25.9/22.7/22.7 ms in one round on the final code (24.7/21.1/34.2/32.0/31.8/30.8 → 20.8/18.2/30.5/29.0/24.8/24.9 in two rounds an hour earlier, with the machine busier); 4,289 parts marked (glass is left out), 4,143 in 208 batches; the picture differs as on the feature branch. Not yet tried by the user.

**What is left.**

- The editor has to turn batching on for any of this to show (`setBatching(.enabled(true))`; it is off by default in the engine). Its Static Batching panel does it by hand today: Enable Batching, then Generate Batches, which works on a pack loaded before, since the marks are there.
- The editor's own workaround for moved entities (unmark, then rebuild every batch) is no longer needed and now costs a full rebuild when a part of a pack is moved: an editor change, after the engine one.
- A scene saved by the editor and loaded again keeps the marks, node by node, but nobody hands the parts to the batching system: it needs `generateBatches()`. This goes with the reload of a pack through shared builds and chains.
- The 3,600 draws of the nodes of chained models: merging them per level in the cook, as above.
- The fit of the cascades to batch boxes could use the boxes of the parts instead for the cells of placed entities, at the cost of a box per batched part and frame; not worth it for what is lost.

### Found in the headset check (2026-10-07)

The Blender-import session built a Vision Pro try-out on `try/large_scene_stage2_batches` (plus the per-eye draft #1285 and its glass commits) and passed on two findings from the user's session in the headset.

**Entities vanish while the camera flies with the keys** (trees, among the first to be noticed) and come back when it stops; moving the head does not do it. The cause is upstream's occlusion test: `executeHZBOcclusionCulling` projects the current frame's bounds with the current camera into the depth pyramid built at the end of the previous frame, from the previous camera, with a fixed depth bias (0.02) as its only tolerance. Whatever moved on screen since is tested against the wrong texels: when the step reveals what a near surface covered (rising above the ground, backing away from a wall, strafing past a trunk), the old near depth stands where the far object now projects, and the object is declared occluded. The head does not trigger it in the preview because head movement moves the headset's origin, not the camera entity the cull reads. Measured on the Mac path at first with the published visible list, which turned out to lag the cull by a frame or two, so those first numbers (1,747 and 3,089 entities lost) were the view changing over the last steps, not the test. Measured again from the cull's own counts (`HZBDebugMonitor`, the cull of the last step's frame against the cull at the same place once the pyramid comes from there; `tools/ZZHzbMotion.swift`): in the open, with steps of 0.1 to 1.0 units a frame in four directions from three viewpoints, the stale test drops nothing measurable, because the kernel's bias (0.02 in reverse-Z depth) lets only an occluder within about 5 units of the camera hide anything, and a far entity moves a fraction of a pixel per step; inside a tree's canopy (the grove view stands 6 units up, among the leaves) the near leaves uncover something new at every step, and what they uncover shows one frame late: rising 0.1 a frame keeps 12,669 of 26,806 candidates while moving against 17,357 at rest, strafing 0.3 a frame 17,468 against 19,017. The preview is where the wrong camera showed: its loop culls with the camera entity's head-centre view, renders both eyes and builds the pyramid from the last eye's depth, so the test's camera never matched the pyramid's, and each frame's step is larger (two eyes per frame; flight speed 1 is 6 units a second).

The fix, built the same day on `bugfix/hzb_occlusion_reprojection` (`12dab7a2`): the pyramid records the camera it was built from and the test projects with it (an object whose old projection falls off screen is kept, as the kernel already does for a box it cannot project), and skip the test for a frame in which the camera moved more than a threshold; in the Vision Pro preview the pyramid and the test have to be per eye, with the eye's matrices, which is the editor's loop. A small bugfix pull request from upstream develop; it touches the two culling gathers the snapshot branch rewrites, so one of the two needs a small rebase after the other. The user decides whether and when.

**Dark patches on the white paint of the parked cars** that grow with the distance (close: clean; middle: some; far: many; the user says it is not new). Measured here with the pack of 2026-10-03: the patches show on the Mac too, without the sun's shadows as with them, and on the snapshot branch, which has neither instancing nor batching, so neither the shadows nor the two draw paths make them. They follow the LOD level: with every parked car forced to level 0 the white cars behind the first one are clean; forced to level 3 the same cars, in the same frame, carry the patches (`tools/ZZCarLevels.swift`, 54 cars, 3,942 LOD components). The cause is in the cook: a car is one model of many meshes, and its dark interior shell runs a few centimetres behind the paint. Each mesh is simplified on its own within the level's error allowance (the model's diameter over the square root of its triangles: for this car, 384,363 triangles and about 4.5 m, 7 mm at level 1, 18 mm at level 2 and 36 mm at level 3), so at the coarser levels the skin and the shell each drift by more than the gap between them and the shell shows through the paint. Not the shadows, not instancing or batching (the Mac shows it without any of them), not the normals (measured sound by the import session).

Built on 2026-10-08 as the cook rule `UntoldMeshLODHiddenParts` (branch `bugfix/lod_nested_shells`, draft `LargeSceneRendering/pr-draft-lod-hidden-parts.md`, sheet `lod_hidden_parts.jpg`), after the user chose to sink the hidden part: a vertex whose own side is covered (the rays along its normal and in a cone round it all meet another face of the model) and that lies behind a seen, solid face of another mesh within three allowances is moved away from that face, by twice the allowance where it touches it and less up to the edge of reach; what is seen never moves, nothing is sunk away from glass, a sink stops two allowances short of any seen face in its way, the sinks are averaged over each connected piece (the car's inner skin is one piece whose wheel wells show through the arches, and would tear where the sunk part meets the seen one), and a piece sunk for the most part is simplified on its own share of its mesh's target (bent, it would otherwise keep its triangles and take the rest of the mesh's: that is how the first versions turned the small flecks into black polygons the size of a door). With it the pack cooks in 21 s instead of 6, the coarsest levels hold 3.4 % more triangles (the car's 15,516 → 16,182) and the cars are clean at every level on the Mac; the cause was measured, not guessed: a white copy of the car at its coarsest level is clean with the dark parts hidden and mottled with them shown, and the dark inner skin lies 0.8 mm under the roof. The allowances above were computed from the car's length; the cook's are from its bounding diagonal, 12, 22 and 48 mm. The headset check of the fix is still to be done, and a chain re-bake follows it. Opened as untoldengine/UntoldEngine#1324 on 2026-10-08 and merged on 2026-10-10.


## 5. Stage 3 — virtualized geometry

The research note's phases, unchanged in substance: phase 0 (layered stereo, vertex amplification and foveation on visionOS), phase 1 (offline cluster DAG per distinct mesh with meshoptimizer `clusterlod.h`, run by the cook), phase 2 (object/mesh-shader cluster renderer with hardware raster, one cull for both eyes), phase 3 (page streaming). Stage 1's LOD chains then become the fallback for content the cluster path does not take (skinned and morphing meshes). The cook side is affordable here: the cluster bake runs once per distinct mesh, 7.8 M triangles for this scene.

## 6. Decisions

- D1. LOD chain ratios and switch points (stage 1c). Decided 2026-10-03: fixed ratios of 50 %, 15 % and 3 % for models of 2,000 triangles or more, and a screen size per level in the manifest that the loader turns into a distance per placement. The ratios, the minimum and the pixels per triangle are options of the cook.
- D2. Simplifier. Decided 2026-10-03: meshoptimizer now (it is also the library stage 3 needs), as a C++ target of the engine package.
- D3. Placement representation for stage 2 (see section 4). Decided 2026-10-03: a placement stays an ECS entity, and the renderer reads a retained table of what is drawn instead of walking the entities every frame; instanced draws come after. The stopgaps measured in section 3 (static batching of the parts without a chain, the order of the shadow tests) are not taken first. As built the same day: entities stay, and each pass reads them through a snapshot it takes when it starts, which gives the table's speed without a cache to keep in step (section 4, "Part 1 as built").
- D4. Whether tiled streaming should learn to keep instances (reference a shared file per tile instead of baking copies), to combine it with this plan for sites larger than memory.
- D5. Distant vegetation (found in 1c): accept about 84,000 triangles per far tree until stage 3, or add impostors (a few textured quads per tree) as a last level.
- D6. Small-object culling (1d): the default is 1 pixel, for every scene. Whether the editor should offer the setting, and a larger value for scenes like this one (2 to 4 pixels take 10 to 50 % off the frame from above).

## 7. Progress

| Item | State |
|---|---|
| #1288 — write repeated models once in a pack | Merged upstream on 2026-10-03 |
| 1a. Entity limit | Merged upstream on 2026-10-03 (#1289) |
| 1b. One load per distinct file | Merged upstream on 2026-10-03 (#1290): BIM pack load 118 s / 57.7 GB GPU → 20 s / 3.8 GB, with the review's four fixes (the memory budget counts shared buffers once, the image cache is single-flight, a failed build is tried once more, the build cache keeps named states inside an unfair lock) |
| 1c. Automatic LOD chain | Merged upstream on 2026-10-04 (#1299): the cook in its own module `UntoldEngineMeshCook`, `untoldengine bake-lods`; GPU time per frame 135–210 ms → 10–23 ms. Its comparison image is on the fork's `docs/proposal_drafts` branch and beside this plan in `LargeSceneRendering/` |
| 1d. Small-object culling | Merged upstream on 2026-10-04 (#1297), default 1 px |
| 1d. LOD selection by screen size | Merged upstream on 2026-10-08 (#1322, `6446393c`), with the stereo point of its review fixed first (`08956144`: in stereo the reach comes from the larger of the two eyes' projections, none until an eye has been rendered); comparison sheet `lod_screen_size.jpg` |
| Try-out on the real scene | Three builds under `Untold/BimTryout` (local, not pushed). Stage 1 (1a–1d) and the stage 2 prototype were tried on 2026-10-03 with the chains baked into the pack of the game project: with the prototype "i can move at normal speed, which was not possible before". The third (`stage2-latest`) adds what the user asked for next: the newest editor (`5dcc078`) and the cook and material branches of the import session (#1288, #1292, #1293, the procedural material bake, glass), and its editor builds the chains after a cook. Checked before the hand-over: the BIM file cooked with its scripts in 9.5 min (4,779 model files), chains for 274 models in 5 s, load 17–21 s and 6.3 GB of GPU memory (4.9 GB with the earlier cook: the baked textures), frames 7–12 % above the earlier cook's on the same engine (809 more draws from the material splits): 32–56 ms on a busy machine |
| Try-out with instancing and the walks | Fourth build, `Untold/BimTryout/stage2-walks` (local, not pushed), handed over on 2026-10-04 and started in the Terminal panel: the engine branch `try/large_scene_stage2_walks` is everything of this plan (LOD chains, screen size, culling, snapshot, Metal buffers, instanced draws, the walks) with the import session's procedural bake, its exporter as in `stage2-latest`, and glass; the editor is `5dcc078` with the chains built after a cook. Instanced draws were taught about glass there (a pane goes to the transparency pass and casts no shadow). Checked before the hand-over: engine core suite 1,630 and editor suite 1,160 with no failure, 98 render tests around glass, instancing and shadows, and the BIM views at 18.5–27 ms a frame (1–2 ms above the branch without glass: its panes are 1,450 more transparent draws). **The user's verdict the same day: "huge improvements, its about 60 fps and some times goes below 50".** The dips are the views with the most entities on screen (among the trees: 17,000 visible, 9,200 draws, 13 ms of CPU and 10 ms of GPU in the headless measure; the editor's own passes and a larger viewport take it past the 16.6 ms of a 60 Hz frame). 6,200 of the 7,250 opaque draws there are meshes placed once, which instancing cannot merge |
| Scene reload through shared builds and chains | Done upstream by Harold on 2026-10-24 (#1386: `LODData` serializes the screen-size fields, one build cache across a reload, a multi-node model's chain re-derived from its pack); issue #1326 closed |
| Editor: build the chains after its cook | Built on 2026-10-16 on the editor branch `feature/cook_lod_chains` (worktree `UntoldEditor-lodcook`): a "Build LOD chains" toggle, on by default, in the Cook sheet and the Quick Preview sheet; after a cook that wrote a `.untoldpack` the editor builds the chains in place through `UntoldEngineMeshCook`, with the progress in the Tasks panel and the report in the Console; a failure is a warning, not a failed cook. In the editor fork since 2026-10-16 (miolabs/UntoldEditor#31). Rebased onto upstream develop `5f58ca3` (0.24.1) on 2026-10-28 (`563e5c0`). Opened upstream on 2026-10-28 as untoldengine/UntoldEditor#193 |
| Stage 2, part 1 | Merged upstream on 2026-10-08 (#1321): the passes read the scene through a snapshot per pass; BIM frames 93–137 ms → 30–46 ms, same picture, within 1–3 ms of the retained-table prototype (section 4); the snapshot reads components through `ComponentPool.component(at:as:)` |
| Stage 2, Metal buffers read once | Merged upstream on 2026-10-04 (#1298): 5.5 ms per frame off the BIM scene |
| Stage 2, sorted opaque draws | Tried on `feature/opaque_draw_order`, no gain measured (section 4); kept as an experiment, not for a pull request |
| Stage 2, the walks over the entities | Built, tested and committed on the local branch `feature/entity_walks` (2026-10-04): one shadow walk a frame, the transparency answer remembered, LOD selection through a snapshot, the streaming update narrowed, the cull gather in place. BIM frames 22–31 ms → 17.5–25 ms, CPU about a third lower, the same pictures (section 4, "The walks over the entities"). In the fork since 2026-10-16 (#77). Rebased onto the rebased instancing on 2026-10-28 (`90a06d92`, six commits; the blended-submesh check placed at upstream's transparency gathering). Its pull request follows instancing |
| Stage 2, batches for the parts placed once | Chosen by the user on 2026-10-04. Built, tested and committed on the local branch `feature/pack_single_batches` (2026-10-04): six fixes to the existing batching system, background batching for entities placed to stay, and the pack loader's marking. BIM: 4,227 parts in 213 batches for 37 MB, frames 19.5–31.3 ms → 18.1–26.8 ms, draws 7,340 → 4,236 (section 4, "Part 3 as built"). Shows only with batching enabled in the editor. In the fork since 2026-10-16 (#77). Rebased onto the rebased walks on 2026-10-28 (`c33fe170`, ten commits). Its pull request follows the walks |
| Stage 2, part 2 (instanced draws) | Built, tested and committed on the local branch `feature/instanced_draws` (2026-10-04): BIM frames 28–45 ms → 22–31 ms, CPU about 30 % lower, the same triangles (section 4, "Part 2 as built"). Rebased onto the fork's develop with the headset rendering on 2026-10-15 (the instanced pipelines take the model pass's own fragment function and constants; the ghost opacity groups; the record carries the previous model matrix for the velocity) and merged there for testing on 2026-10-16 (miolabs/UntoldEngine#77). Rebased onto upstream develop `c5b514c7` on 2026-10-28 after #1359 merged (`71ffdae8`, three commits; the metallibs rebuilt). Opened upstream on 2026-10-28 as untoldengine/UntoldEngine#1390 (render suite 1,368 / 69 skipped / 0 failures, core 1,727 / 3 skipped / the checkout-name failure only, guardrail 0, lint clean) |
| Occlusion test from the pyramid's camera (headset finding) | Merged upstream on 2026-10-08 (#1323, `12dab7a2`): the pyramid records the camera it was built from, the test projects with it and skips after a step past 0.5 units; six tests; confirmed by the user in the Vision Pro preview on 2026-10-07 (`BimTryout/hzbfix`): the trees no longer vanish while flying |
| Hidden parts kept hidden at the coarse levels (headset finding) | Built on 2026-10-08 as the cook rule `UntoldMeshLODHiddenParts` (branch `bugfix/lod_nested_shells`, draft `LargeSceneRendering/pr-draft-lod-hidden-parts.md`, sheet `lod_hidden_parts.jpg`): a hidden vertex behind a seen face is sunk by up to twice the allowance, feathered over its piece; on the site's pack the cook takes 21 s instead of 6 and the cars are clean at every level. Merged upstream on 2026-10-10 (#1324, `c33fca81`), after a rebase over #1322 and a fix of CI's lint and guardrail findings. Not yet tried in the headset: the pack has to be baked again with the merged CLI first |
| Stage 3 | Research done (see the companion note) |

## Appendix: how the numbers were measured

The frame numbers of 1c come from the same kind of scratch test, extended: after the load it places a camera at each of a list of viewpoints, lets the LOD selection settle for six frames, then draws ten frames waiting for the GPU after each, and prints the median frame time, the engine's own timings (`EngineStatsMonitor`: update, culling, encode, GPU execution) and the draw statistics (`RenderStatsCollector`: triangles, draws). It runs as a release build with the statistics compiled in: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DENGINE_STATS_ENABLED --filter BimPackBenchmark`, in a detached worktree that also has #1289 merged (the scene has 24,162 entities). The pack is a copy outside the game project, baked with `untoldengine bake-lods`; the same folder serves a manifest with chains and one without. CPU times vary by ±30 % between runs on this machine; the triangle counts and the GPU times are stable. For 1d the same test takes the pixel setting of the small-object culling from the environment, can mark the entities without a chain static and batch them, and can spin on one viewpoint while `sample <pid>` takes a CPU profile.

### Load

A scratch XCTest, not committed, dropped into `Tests/UntoldEngineRenderTests` of a detached worktree and run with `/usr/bin/swift test --filter BimPackLoadBenchmark` (headless, the pack loaded from the game project, read-only). It prints one `BIMBENCH` line: load time, GPU memory the load allocated, entities and render entities.

```swift
@testable import UntoldEngine
import XCTest

final class BimPackLoadBenchmark: BaseRenderSetup {
    override func initializeAssets() {}

    func testLoadBimPack() async throws {
        LoadingSystem.shared.resourceURLFn = getResourceURL
        let pack = "/Users/godshadow/Projects/Tests/Test GS/Sources/Test GS/GameData/Models/P23011-PR-GLB-BIM-XXXX-3D-IPYR23-T008"
        let device = try XCTUnwrap(renderInfo.device)
        let before = device.currentAllocatedSize
        let rootId = createEntity()
        let start = CFAbsoluteTimeGetCurrent()
        let expectation = expectation(description: "pack")
        setEntityMeshAsync(entityId: rootId, filename: pack, withExtension: "untoldpack") { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 3600)
        let seconds = CFAbsoluteTimeGetCurrent() - start
        let gpuMB = Double(device.currentAllocatedSize - before) / 1_048_576
        let entities = scene.getAllEntities().count
        let renderEntities = scene.getAllEntities().filter { hasComponent(entityId: $0, componentType: RenderComponent.self) }.count
        print("BIMBENCH seconds=\(String(format: "%.1f", seconds)) gpuMB=\(String(format: "%.0f", gpuMB)) entities=\(entities) render=\(renderEntities)")
    }
}
```
