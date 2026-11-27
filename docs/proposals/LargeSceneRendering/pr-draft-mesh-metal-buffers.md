# Draft: [Performance] Read a mesh's Metal buffers from MetalKit once

Branch `feature/mesh_metal_buffers` (one commit on upstream develop, independent of the other branches). Opened on 2026-10-03 as untoldengine/UntoldEngine#1298; this file is the description as posted.

---

## Summary

Every draw asked MetalKit for what it binds:

- the vertex buffers of the mesh: `MTKMesh.vertexBuffers` builds a new array each time it is read, and each of its elements answers through Objective-C;
- the primitive type, index count, index type, index buffer and offset of the submesh.

That is about a dozen Objective-C calls and an array per draw, in every pass that draws meshes. A `Mesh` now keeps the Metal buffers of its MetalKit mesh, and a `SubMesh` the index data of its MetalKit submesh, both read when they are made.

| 10,000 cubes, 11,896 draws with their shadows | Before | After |
|---|---|---|
| CPU time per frame | 65.6–66.6 ms | **60.6–61.5 ms** |

Release build on an M-series Mac, the two builds run in turn, three rounds. The saving is about 0.4 µs per draw whatever else the frame costs, so its share grows as the rest of the frame gets cheaper: on a BIM site of 21,576 render entities, on a local build where the passes no longer look every entity up through the scene (not upstream yet), the same change takes the frame's CPU time from 23 ms to 18 ms.

## Changes

- **`Mesh.vertexBuffers`**: the `MTLBuffer`s of `metalKitMesh.vertexBuffers`, in the same order, set in the one initializer that makes the `MTKMesh`.
- **`SubMesh.primitiveType`, `indexCount`, `indexType`, `indexBuffer`, `indexBufferOffset`**: read from `metalKitSubmesh` in its initializers.
- Neither can go out of date: `metalKitMesh` and `metalKitSubmesh` are constants, and copies of a `Mesh` share the same buffers as before.
- The draw sites read them: the model, shadow (cascades, spot, point), transparency, wireframe and occluder shell passes in `RenderPasses.swift`, `bindModelVertexStreams` / `bindShadowVertexStreams`, the model surface of render extensions, and the tile statistics.
- Code that runs when a mesh is built or picked, not per draw (batching, picking, deformation set-up, memory accounting), still asks MetalKit.

Nothing that is drawn changes.

## Verification

- `MeshMetalBuffersTests` (3): for primitives and for a loaded `.untold` model, the kept vertex buffers are the buffers MetalKit reports, in order, and every submesh's index data equals its MetalKit submesh's; a copy of a mesh shares the buffers.
- `swift test --filter UntoldEngineTests`: 1555 run. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name (it builds a render extension package against the changed model surface).
- The render suite (1200 tests) passes. Its reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have.
- Zero warnings in the strict-concurrency build; no new SwiftFormat findings in the changed files.
