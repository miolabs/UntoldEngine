# Virtualized Geometry (Nanite-style) on Apple Vision Pro — Research

Status: research only, no implementation. Researched 2026-09-18. Question: can the engine render Unreal Engine 5 "Nanite"-class geometric complexity on Apple Vision Pro, and which parts of the technique are worth building with a small team.

## TL;DR

Nanite is not one trick but six systems stacked on top of each other. Only two of them account for most of the "millions of triangles at fixed cost" effect, and both are buildable on Vision Pro with the tools we already have:

1. **A cluster DAG with continuous per-cluster LOD** (the real invention). Meshes are cut into ~128-triangle clusters, neighbouring clusters are grouped, each group is simplified to half its triangles with the group boundary locked, then re-split into new clusters. Repeating this builds a DAG in which every cluster carries a screen-space error and a parent error, so the GPU can pick, per cluster and per frame, the coarsest cluster whose error is under one pixel. No LOD popping, no cracks, no hand-authored LODs. The offline half of this now exists as a single MIT header (`clusterlod.h`, shipped with meshoptimizer 1.0) that we can call from a C++ SwiftPM target in the CLI/editor bake.
2. **GPU-driven per-cluster culling** (frustum, backface cone, and two-pass occlusion against a hierarchical Z buffer). We already have GPU frustum culling and an HZB compute pass; on Apple GPUs the natural home for this is a Metal object shader feeding a mesh shader, which is supported on every Vision Pro (Apple7 family and later).

The other four systems are where the cost and the platform risk sit, and they can be deferred or skipped:

3. **Software rasterizer in compute** for sub-pixel triangles, writing a **64-bit atomic visibility buffer**. Needs 64-bit atomics. The M2 Vision Pro (Apple8 GPU) does **not** expose them on visionOS (Apple only enables the Apple8 min/max variant on macOS); the M5 Vision Pro (Apple10) has the full set. It also fights foveated rendering: the hardware applies the rasterization rate map for free, a compute rasterizer must emulate it.
4. **Deferred materials** (visibility buffer resolve, one full-screen pass per material). A large change to the material pipeline; gives nothing unless 1–3 are already saturating the frame.
5. **Page streaming** with GPU feedback (128 KB pages, root pages always resident). Worth doing, but as a phase after the cluster renderer works, and building on the mesh streaming we already have.
6. **Bit-packed compression** with GPU-side decompression. Do the cheap part (quantized positions relative to cluster bounds, octahedral normals); skip the custom disk codec.

Recommended path: bake the cluster DAG offline, render clusters through an object/mesh shader pipeline with hardware rasterization only, share one cull/LOD pass across both eyes via vertex amplification, then add page streaming. That is roughly three to four months for one graphics engineer (plus a two-to-three-week prerequisite to move the visionOS renderer to layered stereo with vertex amplification and foveation, which it does not use today), degrades gracefully on the M2 headset, and keeps the door open for the software rasterizer as an M5-only upgrade. The single biggest risk is not GPU code: it is mesh simplification quality, which every independent re-implementation (Bevy, nanite-webgpu, metal-mesh) reports as the hard part.

---

## 1. What Nanite actually does

Primary source: Karis, Stubbe, Wihlidal, "A Deep Dive into Nanite Virtualized Geometry", SIGGRAPH 2021 Advances in Real-Time Rendering (155 pages of slides); plus Karis, "The Journey to Nanite", HPG 2022 keynote. Numbers below are from those talks as quoted by the secondary write-ups in section 7.

### 1.1 Cluster DAG LOD (the core idea)

- Meshes are split into clusters of at most 128 triangles. The cluster is the only unit that is ever culled, streamed, or rendered.
- At each level, clusters are arranged into groups of 8 to 32 neighbouring clusters. Each group is simplified to half its triangle count with the vertices on the group boundary locked, then split into 4 to 16 new clusters. The grouping changes at every level so that a boundary locked at one level gets simplified at the next.
- Because a group's boundary is identical before and after simplification, a coarse cluster can sit next to a fine neighbour without cracks. This is what makes the LOD decision *local*: each cluster can be chosen independently, in parallel, on the GPU.
- Each cluster stores a bounding sphere and an error value (the maximum geometric deviation introduced by its simplification, accumulated so that a parent's error is always larger than any child's). At runtime a cluster is drawn when `parentError > threshold && ownError <= threshold`, with the threshold at about one pixel of projected error. Nothing else has to be traversed or synchronised.
- The tail of the DAG is a single cluster of ~128 triangles per mesh, followed by a pre-rendered imposter (12x12 pixel views from 144 directions, ~40 KB per mesh, always resident) once the object covers fewer than ~12 pixels.

### 1.2 GPU-driven culling

- Instances are culled first (frustum plus occlusion against the previous frame's HZB, reprojected). Then clusters are culled with a "persistent threads" compute kernel that pops work from a GPU queue seeded with each instance's root, so hierarchy traversal never returns to the CPU.
- Occlusion is two-pass: pass one tests against the previous frame's HZB and rasterises what passes; the HZB is rebuilt from that; pass two retests only the clusters that were rejected and rasterises the newly visible ones. This is what removes almost all overdraw and lets Nanite get away with no depth pre-pass.

### 1.3 Rasterization and the visibility buffer

- Large triangles go through the hardware rasterizer. Clusters whose triangles are small (Karis's threshold is an edge length of roughly 32 pixels) are rasterised by a compute shader, one thread per triangle, 128 threads per cluster. Hardware rasterizers shade in 2x2 pixel quads, so a one-pixel triangle wastes 75 % of the fragment work; the software path is about 3x faster for those. In a captured frame of the UE5 early-access demo, over 90 % of the ~5 million rasterised triangles went through the software path.
- Both paths write a single 64-bit value per pixel with an atomic max: roughly 30 bits of depth in the high bits, then the visible-cluster index and the 7-bit triangle index. Depth in the high bits is what makes one `atomic_max` do the depth test and the ID write together.
- Materials are resolved afterwards: a pass converts the per-pixel material ID into a "material depth", then one full-screen draw per material shades only its pixels using depth-equal testing, reconstructing barycentrics and attributes from the triangle ID. This decouples geometry cost from material cost, and is the reason Nanite has no per-object draw calls at all.

### 1.4 Streaming and compression

- Cluster data is packed into 128 KB pages by spatial locality and LOD level. The page containing the top of each mesh's DAG is always resident. The culling pass writes out which clusters it wanted but did not have; the CPU reads that feedback, loads pages asynchronously, and installs them in a fixed GPU pool. Nothing stalls: until a page arrives, the coarser parent is drawn.
- Vertex data is quantised and bit-packed (positions relative to cluster bounds, normals, UVs), with a separate in-memory format for near-instant decode and an LZ disk format decompressed on the GPU. For the PS5 demo the reported sizes were about 4.6 GB on disk against 26 GB raw.

### 1.5 What Nanite does not do (and neither would ours)

Rigid meshes only (translation, rotation, non-uniform scale), no morph targets, opaque and masked materials only, no MSAA, no forward renderer. Epic's documentation still lists stereo rendering for VR as unsupported, so shipping this on a headset means solving a problem Epic has not shipped a solution for. Nanite is also a fixed cost: culling, rasterising and resolving cost a few milliseconds even for an empty scene, which is fine on a console and a real consideration on a headset with a 11 ms frame.

---

## 2. Vision Pro constraints that shape the design

| Fact | M2 Vision Pro (2024) | M5 Vision Pro (2025) | Source |
|---|---|---|---|
| GPU family | Apple8 (10-core GPU, 16 GB unified, ~100 GB/s) | Apple10 (10-core GPU with HW ray tracing, 16 GB, 153 GB/s) | Apple tech specs, Metal Feature Set Tables (rev. 2026-05-21) |
| Display / refresh | 23 MP total, 90/96/100 Hz | same panels, adds 120 Hz; foveal region ~10 % larger | Apple tech specs |
| Compositor drawable | 1920x1824 per eye (3.5 MP per eye, 7 MP per frame), foveated through a rasterization rate map | same | douevenknow.us, gnikoloff |
| Mesh shading (object + mesh functions) | yes (Apple7+) | yes | Feature tables |
| Indirect mesh draw arguments, ICBs with mesh draws | **no** (Apple9+) | yes | Feature tables |
| Indirect draw/dispatch args, ICBs for classic draws | yes (Apple3+) | yes | Feature tables |
| Vertex amplification (stereo in one draw), max count | yes, 8 | yes, 8 | Feature tables |
| Variable rasterization rate (foveation) | yes (Apple6+) | yes | Feature tables |
| Texture atomics (32-bit) | yes (Apple6+) | yes | Feature tables |
| **64-bit atomics** | **no on visionOS** (footnote 7: Apple8 only has 64-bit min/max, and only on macOS) | yes, full set (Apple9+) | Feature tables |
| Mesh pipeline limits | 16 KB payload, 1024 threadgroups per mesh grid | 16 KB payload, 4,194,303 threadgroups per mesh grid | Feature tables |
| Frame budget | 11.1 ms at 90 Hz for everything, including the system compositor | 8.3 ms at 120 Hz | arithmetic |

Consequences:

- **The software rasterizer is an M5-only feature.** On the M2 headset the only options are (a) hardware rasterization only, or (b) a two-pass 32-bit emulation (atomic-min depth first, then re-rasterise and write IDs where depth matches), which Philip Turner's UE5-on-Metal port measured at 2.5x to 5x the atomic cost. Epic themselves gate Nanite on M2-and-later *Macs* for exactly this reason ("image atomics and forward-progress guarantees" that M1 lacks), and have shipped nothing for iOS or visionOS.
- **Foveation favours the hardware path.** CompositorServices hands us a rasterization rate map per eye; the hardware rasterizer honours it for free. A compute rasterizer knows nothing about it and would have to map every projected vertex through the rate map (`rasterization_rate_map_decoder` in MSL), and later passes must resolve back through it. Also, compute shaders cannot write the compositor's layer textures (they lack `shaderWrite`), so the final resolve is a fragment pass regardless.
- **Stereo is our problem to solve.** Cull and select LOD once per frame using the union of both eye frusta and the nearer eye for the error projection, then draw each surviving cluster twice through vertex amplification (`MTLMeshRenderPipelineDescriptor.maxVertexAmplificationCount = 2`, layered drawable). Depth, HZB and any visibility buffer are per eye (texture array slices).
- **No indirect mesh draws on M2** means the object-shader grid size must come from the CPU (an upper bound such as "resident cluster count"), with the object shader early-exiting. That is fine; the amplification decision (how many mesh threadgroups to launch) is made on the GPU either way.
- **Apple GPUs are tile-based deferred renderers.** The tiler writes post-transform geometry to memory before the fragment pass, so a frame of millions of hardware-rasterised triangles costs bandwidth that an immediate-mode desktop GPU does not pay. This is the strongest argument for *not* aiming at one triangle per pixel on this hardware: the LOD error threshold is the knob that caps the visible triangle count, and it should start at 2 to 4 pixels rather than Nanite's 1. Foveation lowers effective pixel density in the periphery, so measuring the error in rate-map "physical" pixels makes peripheral clusters coarser automatically.

---

## 3. Which pieces to adopt, defer, or skip

| Piece | Verdict for Vision Pro | Why |
|---|---|---|
| Cluster DAG build (offline) | **Adopt first** | The whole benefit comes from here; `clusterlod.h` gives us the algorithm; runs in the bake, not on device. |
| Per-cluster GPU culling + LOD selection | **Adopt** | Object shader: frustum, normal cone, HZB, error test. Reuses the existing HZB. |
| Two-pass occlusion | **Adopt** | Cheap once the HZB exists; the largest overdraw win on a TBDR GPU. |
| Hardware raster through mesh shaders | **Adopt** | Works on both headsets, honours foveation and amplification. |
| Page streaming with GPU feedback | **Adopt, phase 3** | Needed for scenes larger than memory; extends the existing streaming path. |
| Quantised vertex format | **Adopt, cheap** | 16-bit positions in cluster bounds + octahedral normals roughly halves bandwidth. |
| Software rasterizer + 64-bit vis buffer | **Defer, M5 only** | No 64-bit atomics on the M2 headset; conflicts with foveation; large fixed cost at 7 MP. |
| Deferred material resolve | **Defer** | Big change to the material system; only pays off once the rasterizer is the bottleneck. |
| Persistent-threads cull kernel | **Skip** | Object-shader amplification and a small multi-pass expansion cover it; Metal has no forward-progress guarantee to build on. |
| Custom disk codec, virtual shadow maps, imposters | **Skip for now** | Nice-to-haves that each equal a phase of their own. |

---

## 4. Proposed architecture for Untold (phased)

Phase 0 (layered stereo, vertex amplification, foveation in the visionOS renderer) is described at the end of section 6; it is a prerequisite for the stereo design below.

### Phase 1 — Offline cluster DAG bake (3–4 weeks)

- Add a C++ SwiftPM target wrapping meshoptimizer 1.0 plus `demo/clusterlod.h` (both MIT, C API with `extern "C"` so Swift can call it without C++ interop). The package already has C targets (`CShaderTypes`, `UntoldEngineShaderSupport`), so the build plumbing is known.
- Bake step in the CLI / editor: `clodBuild()` produces groups of clusters with bounds, error, parent link and level; `clodBuildHierarchy()` produces a BVH over the groups for instance-level culling. Reference numbers: a 69k-triangle bunny builds 7 levels in ~0.3 s in the Swift `metal-mesh` project; zeux's pipeline processes a 1.6-billion-triangle scene in ~2.5 minutes on 16 threads.
- New asset format: per mesh, a flat cluster table (bounds sphere, error, parent error, vertex/index offsets, material id, level), quantised vertex data, and page boundaries at 128 KB. Root clusters and the BVH in a header that is always loaded.
- Validation tooling: a debug view that colours by cluster and by level, and an automated crack check (render a mesh at mixed levels, compare against the full-resolution render).
- Risk: simplification quality on real content (thin features, UV seams, disconnected shells). Every re-implementation reports meshes that stop simplifying after 6–9 levels; `clusterlod.h` has permissive/sloppy fallbacks and attribute weights for this, and the bake must report when a mesh fails to reach a single root.

### Phase 2 — Runtime cluster renderer, hardware raster (5–8 weeks)

- One object/mesh shader pipeline for all cluster meshes. Object shader (one thread per candidate cluster): instance frustum test, cluster sphere frustum test, normal-cone backface test, HZB occlusion test, LOD test (`parentError > t && ownError <= t` with `t` in physical pixels via the rate map decoder), then `set_threadgroups_per_grid` for the survivors. Mesh shader: decode one cluster (≤128 triangles, ≤ ~128 vertices), emit it for both eyes via `[[amplification_id]]`.
- Frame order: HZB from previous frame → pass 1 draw → HZB rebuild → pass 2 draw of previously occluded clusters → normal lighting/material passes unchanged. The fragment shader stays the current material shader in this phase; the geometry source changes, the shading does not.
- Stereo: single cull/LOD decision per cluster shared by both eyes; per-eye depth and HZB slices.
- Start with the pixel-error threshold at 2–4 px and measure GPU time on device with Metal System Trace; the threshold and the cluster budget per frame are the two tuning knobs.
- Fallback: entities whose mesh has no cluster bake keep the current draw path, so adoption can be per asset.

### Phase 3 — Page streaming (3–4 weeks)

- GPU pool of fixed 128 KB pages; the object shader appends "wanted but missing" cluster ids to a feedback buffer; the CPU reads it a frame later, prioritises by projected error, loads pages asynchronously and patches the cluster table. Missing pages fall back to the resident parent, so there is never a hole, only temporary blur.
- Budget: with 16 GB unified memory a 256–512 MB pool is realistic; the compositor and ARKit take their share.

### Phase 4 (optional, M5 only) — Software rasterizer and visibility buffer (6–10 weeks)

- Compute rasterizer for clusters under the small-triangle threshold, 64-bit `atomic_max` on a per-eye `R32G32Uint`/ulong texture (Apple9+ texture atomics), hardware path writes the same buffer from a fragment shader, then a material resolve. Gate at runtime on `MTLGPUFamily.apple9` or later; M2 headsets keep the phase 2 path.
- Only start this after phase 2 profiling shows primitive throughput or quad overdraw, rather than fragment shading or bandwidth, as the limiting factor.

Rough total for the MVP (phases 1–3): 3 to 4 months of one experienced graphics engineer, plus content work to test simplification on real assets.

---

## 5. Budget sanity check (rough, to be replaced by measurements)

- Pixels: 7.0 MP per frame on Vision Pro versus 2.8 MP in Bevy's published measurement (2240x1260). Bevy's whole virtual-geometry frame, including its material passes, was ~2.8 ms on an RTX 3080, a GPU several times faster than the M2's. Scaling by pixel count and by GPU class puts a full Nanite-style frame (compute raster, 64-bit buffer, resolve) well above 10 ms on the M2 headset. That is why the plan keeps the fixed-cost passes out of phases 1–3 and lets foveation reduce shaded pixels.
- Bandwidth: a 64-bit visibility buffer for both eyes is 56 MB per write; one write plus one read is about 1 ms of the M2's ~100 GB/s. Not fatal, but it is the kind of fixed cost that a hardware-only path avoids entirely.
- Triangles: Nanite's one-pixel target would mean up to ~7 million visible triangles per frame here. With a 2–4 px threshold the visible count drops by roughly 4–16x, which is the range where the hardware rasterizer and the tiler are comfortable. The important property survives: the visible triangle count is bounded by screen size, not by scene size.

---

## 6. What the engine already has (main worktree, 2026-09-18)

Surveyed on the `UntoldEngine` worktree (currently on `feature/morph_format`; `UntoldEngine_vision` is a stale `bugfix/visionOS_device` snapshot with nothing the main tree lacks).

Reusable as-is or with small changes:

- **GPU frustum culling and HZB occlusion culling already exist.** `Systems/CullingSystem.swift` runs a reduce/scan frustum kernel (`Shaders/FrustumCullingCompute.metal`) and builds a depth pyramid plus an occlusion test (`Shaders/HZBCompute.metal`, `buildHZBDepthPyramid` / `executeHZBOcclusionCulling`). Granularity is per-entity AABB, and the visible set is read back to the CPU (`resolvedVisibilityBuffer.contents()`), which is the one thing a cluster pipeline must change: the survivors have to stay on the GPU and feed the draw directly.
- **Streaming with budgets and eviction.** `GeometryStreamingSystem` (+`MeshStreaming`, `+TileStreaming`, `+Eviction`) streams whole meshes and `.tile/.lod/.hlod` files asynchronously under `MemoryBudgetManager` (300 MB geometry, 200 MB textures). A page pool for clusters can sit behind the same budget manager and eviction policy; only the unit changes from "mesh" to "128 KB page".
- **Extensible binary asset container.** The `.untold` format (`AssetFormat/UntoldFormat.swift`) has a chunk table with a reserved plugin range (`>= 0x8000`), per-mesh records with offsets and bounds, LZ4/zstd enum, and 10:10:10:2 packed normals/tangents. A cluster-DAG chunk (cluster table, group errors, page index) fits without breaking existing readers.
- **Offline bake pipeline.** `Tools/UntoldEngineCLI` (`export-tiles`, `--generate-lod`, `--generate-hlod`) and `scripts/tilestreamingpartition.py` already drive Blender for decimated LOD tiers; the cluster bake is a new step in the same tool, replacing Blender decimation for cluster meshes.
- **Render graph with insertion points.** `Systems/GraphBuilder.swift` validates dependencies and offers `RenderStage` anchors; `RenderExtension` (`Renderer/RenderExtensions.swift`) lets an extension register shader libraries, render and compute pipelines, and its own buffers. The cluster renderer could start life as a render extension, in line with the plugin direction the engine is taking.
- **Deferred TBDR G-buffer.** `RenderingSystem.swift` runs G-buffer and lighting in one encoder with memoryless attachments read by framebuffer fetch. A mesh-shader pipeline is still a render pipeline, so it can write the same G-buffer with the same material fragment shaders; phase 2 does not touch lighting.
- **Per-eye XR cull buffers** already exist in `CullingSystem`, and `UntoldEngineXR.swift` has the CompositorServices frame pacing (`predictTiming`, `optimalInputTime`, `queryDrawable`).

Missing entirely (each is a work item in section 4):

- Cluster/meshlet decomposition and the DAG; any screen-space-error LOD. Today's LOD is discrete, per entity, by camera distance (`LODSystem.swift`, thresholds `[50, 100, 200, 500]` in `LODConfig.swift`) and swaps the mesh on the `RenderComponent`; the `LODLevel.screenPercentage` field is serialised but never read.
- Mesh/object shaders (`Renderer/Pipelines/MeshShaderPipeline.swift` is an ordinary render-pipeline holder despite the name), indirect command buffers, indirect draw arguments, GPU-resident draw submission.
- A shared vertex/index pool. Each mesh owns six separate attribute buffers from `MTKMeshBufferAllocator` (`Mesh/Mesh.swift`); `BatchingSystem` merges meshes per material and LOD into shared buffers and is the closest thing to a global pool.
- Visibility buffer and depth pre-pass.
- **Layered stereo, vertex amplification, and foveation.** The visionOS path renders the two eyes as sequential passes with `.dedicated` layout and `isFoveationEnabled = false` in the generated template (`BuildSystem/BuildTemplates.swift`), and there is no rasterization rate map anywhere. The HZB pyramid is built once for both eyes.
- GPU-family tiering. The only runtime capability checks are `supportsFamily(.apple2)` for ASTC and `supportsRaytracing`; mesh shading (`.apple7`) and 64-bit atomics (`.apple9`) gates would be new.

### Phase 0 (prerequisite, 2–3 weeks) — modernise the visionOS renderer

Independent of virtualized geometry, and worth doing first because it changes every number in section 5: switch the layer to `.layered` layout, enable foveation and bind `drawable.rasterizationRateMaps`, and render both eyes in one pass with vertex amplification. Foveation alone removes a large share of shaded pixels, and the single-pass stereo is what lets the cluster pipeline cull and select LOD once per frame. The HZB then needs one slice per eye.

---

## 7. Key references

Talks and articles:
- Karis, Stubbe, Wihlidal, "A Deep Dive into Nanite Virtualized Geometry", SIGGRAPH 2021: https://advances.realtimerendering.com/s2021/Karis_Nanite_SIGGRAPH_Advances_2021_final.pdf
- Karis, "The Journey to Nanite", HPG 2022 keynote: https://www.highperformancegraphics.org/slides22/Journey_to_Nanite.pdf
- Emilio López, "A Macro View of Nanite" (frame capture walk-through): https://www.elopezr.com/a-macro-view-of-nanite/
- Tim Wiegand, "From Navisworks to Nanite" (best plain-language summary of the numbers): https://www.thecandidstartup.org/2023/04/03/nanite-graphics-pipeline.html
- Arseny Kapoulkine, "Billions of triangles in minutes" (the offline pipeline at scale): https://zeux.io/2025/09/30/billions-of-triangles-in-minutes/
- Epic, Nanite documentation (supported features, limitations): https://dev.epicgames.com/documentation/en-us/unreal-engine/nanite-virtualized-geometry-in-unreal-engine
- Epic roadmap card, "Support for Nanite on Apple M2 devices (Beta)": https://portal.productboard.com/epicgames/1-unreal-engine-public-roadmap/c/1151-support-for-nanite-on-apple-m2-devices-beta

Code to study or reuse:
- meshoptimizer 1.0 and `demo/clusterlod.h` (MIT): https://github.com/zeux/meshoptimizer — https://github.com/zeux/meshoptimizer/blob/master/demo/clusterlod.h
- `ximhear/metal-mesh` (Swift, Metal 3 mesh shaders, Nanite-style cluster LOD, 2-pass Hi-Z, iOS 17 / macOS 14, MIT): https://github.com/ximhear/metal-mesh
- Bevy virtual geometry (JMS55), write-ups for 0.14, 0.15, 0.16: https://jms55.github.io/posts/2024-06-09-virtual-geometry-bevy-0-14/ and https://jms55.github.io/posts/2025-03-27-virtual-geometry-bevy-0-16/
- `Scthe/nanite-webgpu` plus the author's post-mortem (simplification and error metrics are the hard part; build the GPU-driven pipeline first): https://github.com/Scthe/nanite-webgpu — https://www.sctheblog.com/blog/nanite-report/
- NVIDIA `vk_lod_clusters` (Vulkan runtime built on `meshopt_clusterlod.h`): https://github.com/nvpro-samples/vk_lod_clusters
- Philip Turner, UE5 Nanite on macOS with 32-bit atomics: https://github.com/philipturner/ue5-nanite-macos

Apple platform:
- Metal Feature Set Tables (GPU families, 64-bit atomics footnote 7, mesh shading limits): https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
- WWDC22 "Transform your geometry with Metal mesh shaders": https://developer.apple.com/videos/play/wwdc2022/10162
- Sample "Adjusting the level of detail using Metal mesh shaders": https://developer.apple.com/documentation/metal/adjusting-the-level-of-detail-using-metal-mesh-shaders
- Warren Moore, "Mesh Shaders and Meshlet Culling in Metal 3": https://metalbyexample.com/mesh-shaders/
- Georgi Nikolov, "Drawing graphics on Apple Vision with the Metal rendering API" (CompositorServices, amplification, foveation): https://github.com/gnikoloff/drawing-graphics-on-apple-vision-with-metal-rendering-api
- visionOS drawable resolution and foveation notes: https://douevenknow.us/post/750217547284086784/apple-vision-pro-has-the-same-effective-resolution
- Apple Vision Pro tech specs (M2 and M5 models): https://support.apple.com/en-us/117810 and https://support.apple.com/en-us/125436

Related to the Gaussian twins plugin:
- "Virtualized 3D Gaussians: Flexible Cluster-based Level-of-Detail System for Real-Time Rendering of Composed Scenes" (the same cluster-DAG idea applied to 3D Gaussian splats): https://arxiv.org/abs/2505.06523
