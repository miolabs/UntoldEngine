# Draft: [Performance] Draw entities that share their meshes and materials as one instanced draw

Branch `feature/instanced_draws`: three commits on upstream develop `c5b514c7` (0.24.1 with #1389), rebased 2026-10-28 after the headset rendering #1359 merged; tip `71ffdae8`. The same code has been in the fork's develop since 2026-10-16 (miolabs/UntoldEngine#77), where every session tests it. OPENED 2026-10-28 as untoldengine/UntoldEngine#1390 on the user's go.

---

## Summary

Stage 2, part 2 of `docs/proposals/LargeSceneRendering.md`. The opaque pass and the shadow cascades encoded every entity on its own, however many of them drew the same thing. They now gather the entities that have nothing of their own in a draw but their transform, and encode each group that draws the same meshes with the same materials as one instanced draw per submesh.

| | Before | After |
|---|---|---|
| 10,000 cubes of one mesh, draws per frame | 11,896 | **10** |
| 10,000 cubes, CPU time per frame | 10.8 ms | **4.9 ms** |
| BIM site (21,576 render entities), overview: draws | 11,926 | **5,223** |
| BIM site, overview: frame (CPU) | 32.9 ms (19.9) | **23.7 ms (13.7)** |
| BIM site, walking between buildings: draws (shadow draws) | 16,452 (11,058) | **7,416 (4,612)** |
| BIM site, walking between buildings: frame (CPU) | 28.4 ms (17.4) | **22.2 ms (12.8)** |
| BIM site, among the trees: frame (CPU) | 42.2 ms (24.1) | **31.4 ms (17.5)** |

Release build, headless at 1920×1080 on an M4 Max, the two builds run in turn, three rounds. The triangles drawn are the same in every view.

**The picture is the same, to the last bits of a few pixels.** The instanced shaders do the arithmetic of the single-entity ones on the same values, and the instanced pipelines use the model pass's own fragment function. The tests draw thirteen scenes both ways and compare the frames: the depth, position, normal and emissive attachments are identical, and what differs is about twenty pixels in a million at silhouettes, mostly by one float16 step, because two vertex functions compiled apart differ in their last bits and the fragment's derivatives amplify that at edge quads. The reference images of the render suite that match exactly on develop still match exactly. What else changes is the order of the draws (single entities, batches, then the groups), so where two surfaces lie exactly on each other the other one may show: in the BIM site that is 0 pixels in three of six views and 16 to 493 of 2,073,600 in the three among the trees.

## Changes

**Finding the groups** (`RenderInstancing.swift`)

- `RenderComponent.instanceKey` is a small number that two components share exactly when their mesh lists send the same things to the GPU: the same Metal meshes and local transforms and, per submesh, the same index data, textures, samplers and material values. `RenderInstanceKeyTable` gives the numbers and compares the descriptions in full, not their hashes.
- Nothing is declared: copies of a pack model, cubes made from one mesh, or two entities given equal materials by hand group by themselves.
- Any change to `renderComponent.mesh` (a material edit, a texture streamed in, a LOD switch) clears the key in the property's `didSet`. An entity whose material is edited leaves its group and joins it again if the material is set back.
- The table starts over once it holds more than 65,536 descriptions, between passes only.

**What is not instanced**

- An entity with something of its own in a draw: a LOD, tile or mesh fade in progress, a skeleton, a deformation. Those take the code that drew them before, unchanged.
- Every entity while a debug colouring (by LOD, by streaming tier) is on.
- Transparent submeshes (the transparency pass sorts them), spot and point light shadows, the wireframe and outline passes.
- `setRendering(.instancedDraws(.disabled))` turns it off; `getInstancedDrawsEnabled()` reads it.

**The draw** (`RenderPasses+InstancedDraws.swift`, `RenderPipeLines.swift`, `modelShader.metal`, `shadowShader.metal`)

- New vertex entry points `vertexModelInstancedShader` and `vertexShadowInstancedShader`, and the pipelines `.modelInstanced`, `.modelInstancedOpaque` and `.shadowInstanced`. The instanced model pipelines use `fragmentModelShader` itself, with the same function constants as the single-entity ones (`makeModelPipeline(instanced:mayDiscard:name:)` builds the four model pipelines together, and rebuilds them with the sample count or the render path); the instanced vertex stage outputs the same `VertexOutModel`, world position and current and previous clip positions included, so the forward path's velocity and lighting are the same either way.
- `vertexModelShader`, `fragmentModelShader`, `vertexShadowShader`, `Uniforms` and `VertexOutModel` keep their contracts: render extensions that draw with them are not affected.
- A record per instance (`ModelInstanceUniform`: the model-view, model, previous model and normal matrices; a model matrix for a shadow) goes into a buffer borrowed from `InstanceRecordBufferPool` and handed back when the frame's command buffer completes. The buffer is bound once per pass and each draw names its first record as its base instance.
- What a group's draws bind is prepared once per component (`InstancedSubmeshDraw`) from `RenderPasses.opaqueMaterialParameters(of:)`, which the single-entity path now fills its parameter block with too, and kept until the meshes change. The opacity of a ghost channel is the draw's, in the material parameters as for a single draw: entities that differ in it are groups of their own.
- A device that cannot start an instanced draw at a base instance (before the A9) gets no instanced pipelines and draws as before. So does a renderer set up with a pipeline list that lacks them.
- The seven prebuilt Metal libraries are rebuilt with `buildkernels.sh`.

## Verification

- `InstancedDrawRenderTests` (16): the frame drawn both ways is the same, to the last bits of a few pixels, with six materials (textures, cut-outs, tiling, emission, metal), meshes with local transforms, a fade among instances, a ghost channel, shadows, loaded models with a skinned one, a pane of glass among the instances, and LOD switches; what makes a group, and that an edited entity leaves and rejoins it.
- `RenderInstanceKeyTests` (9): 38 values that must give another key, 8 that must not, what clears a key, the table's limit, and a check of the fields of `MaterialParametersUniform` against the list the description is made from, which fails when a field is added to one and not the other.
- `InstancedDrawListTests` (10): groups, groups of their own for the opacities of ghost channels, record layout and values, the runs of meshes with their own local transform, the buffer pool.
- `swift test --filter UntoldEngineTests` on the rebased branch (2026-10-28): 1,727 run, 3 skipped. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name.
- The render suite on the rebased branch (2026-10-28): 1,368 run in two halves, 69 skipped as on develop, 0 failures; the reference-image comparisons ran with `compare_psnr.py` itself (Homebrew python with OpenCV and scikit-image).
- Zero warnings in the strict-concurrency build; no new SwiftFormat findings. The engine target compiles for the iOS and visionOS simulators.

## Limits

- The work per entity stays: after this change the walks over the entities (shadow caster selection, LOD selection, the transparency walk) are the largest part of the frame of the BIM site again.
- A mesh that is drawn once is still one draw: 4,400 of the 5,200 draws left in the overview. Those are for batching by material.
- Not tried on a headset. The instanced shaders are in all seven libraries, and the stereo path draws each eye through the same pass.
