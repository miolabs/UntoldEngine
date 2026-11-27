# Draft: [Performance] The render passes read the scene through a snapshot

Branch `feature/render_scene_snapshot` (three commits on upstream develop, rebased on 2026-10-07 after #1297, #1298, #1299 and the component release fixes merged). OPENED 2026-10-08 as untoldengine/UntoldEngine#1321.

---

## Summary

Stage 2, part 1 of `docs/proposals/LargeSceneRendering.md`. Every render pass walked the scene's entities through the ECS: for each of them, whether it exists, which of a dozen components it has, and the render and transform components themselves, each question taking the scene lock, copying the scene and looking a component id up (about 140 lock acquisitions per entity per frame, counted in #1294). On a scene of 21,576 render entities that walk, not the GPU, held the frame. A pass now takes one snapshot of the scene when it starts (one read of the scene, the component ids and the component storage looked up once) and answers every question about an entity from it.

| BIM site, 21,576 render entities with LOD chains, frame (CPU) | Before | After |
|---|---|---|
| Overview, 12,735 draws | 128–207 ms (120–207) | **39–43 ms (24–25)** |
| Walking between the buildings, 16,026 draws, 10,419 of them shadows | 113–119 ms (101–107) | **29–31 ms (19–21)** |
| Among the trees, 17,350 draws | 146–167 ms (134–149) | **48–51 ms (30–31)** |
| One tree at 3 m, 18,042 draws | 150–157 ms (139–148) | **46–50 ms (30–33)** |
| One tree at 15 m, 18,182 draws | 152–159 ms (142–154) | **48–53 ms (31–32)** |
| One tree at 40 m, 17,958 draws | 150–156 ms (137–146) | **45–50 ms (30–32)** |

Release build, headless at 1920×1080 on an M4 Max, the two builds (develop `4ae99ca2` and this branch) run in turn, three rounds each, the range over the rounds. The draws, shadow draws, triangles and visible counts are the same in every view. The GPU takes 7 to 14 ms of those frames: what is left is still the CPU, now mostly the draws themselves.

**The picture does not change.** The snapshot hands out the scene's own component objects, so a pass reads the same values it read before. What changes is the order in which a pass meets the entities: the index order of the scene instead of the order of a hash set, so the draw order is the same from frame to frame and run to run, and where two surfaces lie exactly on each other the other one may now show. The render tests draw their scenes through the old and the new walks and compare the frames pixel for pixel; the reference images of the suite that matched exactly on develop still match exactly.

## Changes

**`RenderSceneSnapshot`** (new, `Renderer/RenderSceneSnapshot.swift`)

- Built from one read of `scene`: the entities alive at that moment with their component masks, the ids of the components the passes ask about, and the component pools. `entity(_:)` answers for an id (nil once the entity is gone, pending destruction or replaced at its index); `forEachEntity(with:)` walks the entities that have a set of traits in index order.
- `Entity.traits` is an `OptionSet` read from the mask, so a pass tests bits where it asked the scene for each component in turn: render, world and local transform, gizmo, light, camera, scene camera, scene channels, static batch, mesh occluder, mesh fade, tile representation fade, LOD, deformation, skeleton, tile LOD tag.
- `drawComponents(of:)` and the per-component accessors read through `ComponentPool.component(at:as:)`, the read the component release fix (#1300, #1302, #1313) asks of a reader that holds a pool of its own; the pool copies a snapshot holds keep the release of a departed component back until the pass ends.
- Scene channels: the channel component when the entity has one, else the live `getEntitySceneChannels` (default channels depend on the entity's name and the prefix registry, which cannot be cached). `SceneChannelRenderModeMemo` asks a channel set's render mode once per run of equal sets.

**The passes**

- The two culling gathers (`executeFrustumCulling`, `executeReduceScanFrustumCulling`) and the three shadow caster lists (cascades, spot, point) walk the snapshot; the shadow draw loops receive a `ShadowCaster` that carries the components the selection already read. `ShadowSystem.collectEntityShadowCasterBounds` likewise.
- The model pass (`combinedModelLightExecution`), the transparency pass and the wireframe and occluder-shell passes read it. `OpaquePassState` holds what a pass reads once (view, projection, camera position, POM quality, the batching, LOD-fade, ghost and debug switches) where every draw read it.
- `bindModelVertexStreams` / `bindShadowVertexStreams` gain `(mesh:deformation:hasSkeleton:)` overloads for a pass that has the components in hand; the `(mesh:entityId:)` forms stay for render extensions.
- The unreachable error branches of the cull loops (`.noRenderComponent`, `.noWorldTransformComponent` for an entity the query had just matched) are gone.
- Documented in `docs/Architecture/renderingSystem.md` ("How a Pass Reads the Scene").

## Verification

- `RenderSceneSnapshotTests` (20): an entity of the scene is found, and one waiting to be destroyed, destroyed, replaced at its index or past the scene's entities is not; the traits agree with `hasComponent` for every entity; the draw and the optional components are the scene's own objects, and a value changed after the snapshot shows through it; the walk visits what the scene query returns, and every live entity when asked for no trait; scene channels come from the channel component or from the entity's name; the render mode memo.
- `RenderPassEntityStateTests` (9): what the passes make of an entity, read off the frame: one on a hidden channel (by component, or by its name) is not drawn and comes back; one on a wireframe channel leaves the solid pass; one waiting to be destroyed is skipped though still listed as visible, as is an id that was never an entity and an entity without a render component; a tile representation fade dithers the entity in each direction and a mesh fade wins over it; a mesh on a light, camera or gizmo entity is not drawn.
- `swift test --filter UntoldEngineTests`: 1,646 run. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name.
- The render suite: 1,190 pass, 69 are skipped as on develop. Its 22 reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have: 14 match their reference exactly, the lowest of the others is at 68 dB against thresholds of 11 to 30.
- Zero warnings in the strict-concurrency build (`scripts/strict-concurrency-guardrails.sh` with `MAX_UNIQUE_CONCURRENCY_WARNINGS=0`); no new SwiftFormat findings in the changed files.

## Limits

- The work per draw stays: after this change the opaque pass is the largest part of the frame of the BIM site (vertex stream binding and the draw calls), which the instanced draws of the next stage take on.
- The XR path (the reduce-scan cull, the stereo passes) is converted but not tried on a headset.
