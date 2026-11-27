# Fork PR draft: Merge the large-scene stage 2 chain for testing (2026-10-15)

Title: Merge the large-scene stage 2 chain for testing: instanced draws, entity walks and pack single batches, rebased onto the headset rendering

Head: sync/large_scene_stage2_1015 (fork develop 10d1fbec + one --no-ff merge of feature/pack_single_batches at 16a2c931). Base: develop.

## Merge commit message

```
Merge feature/pack_single_batches at 16a2c931 (the large-scene stage 2 chain: instanced draws, entity walks, pack single batches), rebased onto the headset rendering

The three local branches of the large-scene plan's stage 2, rebased in order
from upstream develop 1085580c onto this develop (10d1fbec: upstream ebfa68be,
the head of untoldengine/UntoldEngine#1359 and the xr_shader_cost chain), so
that every session tests them with the headset rendering:

- feature/instanced_draws (452c8c40): entities that share their meshes and
  materials drawn as one instanced draw, on the deferred, hybrid and forward
  paths;
- feature/entity_walks (7f3a74af): one shadow walk per frame, LOD through a
  snapshot, the cull gather in place;
- feature/pack_single_batches (16a2c931): six fixes to batching, the parts a pack
  places once batched.

Resolved against the forward path: the instanced model pipelines take the model
pipeline's own fragment function and function constants (there is no instanced
fragment function any more), come with and without the discards like the model
pipelines, and write the velocity of each instance from the previous model
matrix its record carries; the opacity of a ghost channel is the draw's, so
entities that differ in it are in groups of their own; the transparency pass's
gathering, moved before its encoder by the fork, takes the chain's checks there.
The seven Metal libraries are rebuilt.
```

## Body

Merges the large-scene stage 2 chain, rebased onto this develop (`10d1fbec`: upstream develop `ebfa68be`, the head of untoldengine/UntoldEngine#1359 and the `xr_shader_cost` chain of #73–#75), so that every session tests it together with the headset rendering. The chain was local only until now, on upstream develop `1085580c`; the upstream pull requests come after this, one per branch.

**The chain, in order (each rebased onto the previous):**

- `feature/instanced_draws` at `452c8c40` (3 commits): entities that share their meshes and materials are encoded as one instanced draw, in the opaque pass and the shadow cascades.
- `feature/entity_walks` at `7f3a74af` (6 commits): one walk of the scene per frame for the directional shadows, LOD selection through a snapshot, the streaming update narrowed, the cull gather without an array per entity, a flag for blended submeshes.
- `feature/pack_single_batches` at `16a2c931` (10 commits): six fixes to batching (a batched entity's lone mesh, materials that differ in clear coat/sheen/tints, a batch built in the background, a static entity that no batch draws, one that moves or loses its mark, a hidden entity), batching in the background the static entities placed to stay, and the parts a pack places once marked static.

**What was resolved** (13 hunks against the forward path, plus the seven metallibs):

- `modelShader.metal`: the headset turned `fragmentModelShader` into a function-constant-driven stage (`kModelMayDiscard`, `kModelIndirectInGBuffer`, `kModelLitInGBuffer`; the lit and velocity attachments; the world position and the clip positions from the vertex stage). The instanced path no longer has a fragment function of its own: `vertexModelInstancedShader` hands the fragment stage the same `VertexOutModel` as `vertexModelShader`, computed by the same arithmetic (the world position, the clip positions of this frame and the previous one for the velocity), and the instanced pipelines are built with `fragmentModelShader` itself and the same function constants. So a group shades as a single draw does on the deferred, hybrid and forward paths, and the lighting inputs the forward pass binds once per pass serve both.
- The opacity of a ghost channel used to travel in the instance record and be read by the instanced fragment stage; it is now the draw's, in the material parameters as for a single draw, and entities that differ in it are in groups of their own (`InstancedDrawList` groups by key and opacity). The record (`ModelInstanceUniform`) carries the model-view, model and normal matrices and the model matrix of the previous frame; the opaque pass takes the latter from `ObjectMotion` as it does for a single draw, so a moving instance writes its own velocity for the temporal resolve.
- `RenderPipeLines.swift` / `RenderPipelineType.swift` / `RenderInitializer.swift`: one `makeModelPipeline(instanced:mayDiscard:name:)` builds the four model pipelines (`.model`, `.modelOpaque`, `.modelInstanced`, `.modelInstancedOpaque`), all rebuilt together when the sample count or the render path changes; the opaque pass picks the instanced pipeline without discards for a group whose material never needs them, as it does per single draw, and counts it in `opaqueDrawsPlain`.
- `ShaderTypes.h`: the headset's fragment buffer indices kept, the chain's `modelPassFragmentInstanceIndex` dropped (the fragment stage binds nothing per instance), `modelPassInstanceIndex` and `shadowPassInstanceIndex` kept.
- `RenderPasses.swift`: the opaque pass's per-fragment lighting bindings and the instanced draw list set-up both stay; the transparency pass's gathering was moved before its encoder by the fork (#75: no pass for a frame with nothing transparent), so the chain's two changes to it (`hasBlendedSubmeshes` asked first, marked before batched) were applied there.
- `EngineSettingsAPI.swift` and `docs/API/UsingEngineAPI.md`: both sides' settings.
- The metallibs were rebuilt with `make compile-shaders` (`.metalsource.sha256` included).

**One finding on the way:** with the fragment stage shared, the instanced and the single way of drawing still differ in the last bits of a few pixels (about 20 of a million in the test scenes). The G-buffer attachments (position, normal, emissive, depth) are identical at their own precision; the vertex stages, compiled apart, differ in the last bits of what they hand the fragment stage, and the derivatives the fragment stage takes (the texture footprint, the specular anti-aliasing) turn that into a visible difference at a quad or two along the silhouettes. The picture tests now hold the two ways to the last bits (a channel difference beyond 0.004 counts, at most 0.01 % of the covered pixels may show one). The claim "the same pixel for pixel" of the instancing commit is reworded accordingly.

**Verified** (Xcode 27.0 / Swift 6.4, on the chain's tip `16a2c931`):

- `swift build`, and the seven metallibs rebuilt (`make compile-shaders`).
- Core suite, `swift test --disable-swift-testing --filter UntoldEngineTests`: 1,755 tests, 2 skipped, 1 failure, `ExternalRenderExtensionPackageTests` (the checkout folder is not named `UntoldEngine`; the known folder-name failure, unrelated to the change).
- Render classes with `CI=true UNTOLD_PSNR_THRESHOLD=33.5`, filter `InstancedDrawListTests|RenderInstanceKeyTests|InstancedDrawRenderTests|DirectionalShadowWalkTests|BlendedSubmeshFlagTests|StaticBatchMembershipTests|UntoldPackStaticPartsTests|HybridRenderPathTests|TemporalAntiAliasingTests|OpaqueHiddenSurfaceRemovalTests|Shadow|Batch|Culling|LOD|Streaming`: 384 render tests, 16 skipped, 0 failures (among them InstancedDrawRenderTests 16, with the hybrid and forward path scenes and the velocity of a moving instance; HybridRenderPathTests 5; TemporalAntiAliasingTests 6; OpaqueHiddenSurfaceRemovalTests 5; DirectionalShadowWalkTests 4; BlendedSubmeshFlagTests 2; StaticBatchMembershipTests 17; UntoldPackStaticPartsTests 7; InstancedDrawListTests 10; RenderInstanceKeyTests 9). The same filter also runs two core tests of `LODSystemTests` after `EngineSettingsAPITests` in one process, where `testSetLODUpdatesSharedConfig` leaves the LOD defaults changed and they fail; alone, and in the core run, they pass (a test-isolation matter of the existing tests, not of the chain).
- The same render classes on `feature/entity_walks` before the batches were rebased on it: 291 tests, 10 skipped, 0 failures.
- `make strict-concurrency-check` (a clean strict build with `MAX_UNIQUE_CONCURRENCY_WARNINGS=0`): build pass, 0 warning sites.
- SwiftFormat lint of every Swift file the chain changes: only the pre-existing `wrapIfStatementBodies` findings of the local 0.62.1.

The `keep/*_pre_1015` branches hold the three tips as they were on upstream develop, until the upstream pull requests are out.
