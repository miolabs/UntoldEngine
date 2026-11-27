# Ray-Traced Lighting on Metal (Apple Vision Pro first) — Research

Status: research note, written 2026-10-10. Nothing built. Companion to [VirtualizedGeometryResearch.md](VirtualizedGeometryResearch.md) (device table, section 2), [PerformanceMeasurementResearch.md](PerformanceMeasurementResearch.md) (headset budgets and pass timers) and [BlenderMaterialFidelity.md](BlenderMaterialFidelity.md) (what the cook can bake).

Question: can the engine use Metal ray tracing, or path tracing, so that lights look much better than they do now (shadows, bounce light, reflections), on Apple Vision Pro at 90 Hz stereo and on the Mac?

## TL;DR

- **The API is there on every target.** Metal ray tracing has been available on visionOS since 1.0 and the engine already builds and traces acceleration structures, for GPU picking only (`Systems/ScenePickingGPUSystem.swift`, `Shaders/raymodelIntersect.metal`). Nothing in the lighting uses them.
- **The two Vision Pros are different machines for this.** The M2 Vision Pro (Apple8 GPU family) traces rays in software inside the compute shader. The M5 Vision Pro (Apple10) has Apple's third-generation hardware ray tracing, with hardware instance transforms and 1 KB acceleration-structure alignment. Apple's only public software-vs-hardware figure is "up to 4x" (A17 Pro vs A16). There is no published rays-per-second number for either headset, so **stage 0 is a measurement, not a feature**.
- **Full path tracing at 90 Hz stereo is out.** The frame is 11.1 ms for everything and the light scenes already spend 9 ms of GPU time (PerformanceMeasurementResearch, headset run 4). Two eyes at the foveated drawable are about 7 M pixels per frame; one path per pixel with one bounce is 14 M+ rays, plus shading, plus a denoiser. ReSTIR GI at one sample per pixel costs 8.9 ms at 2 MP on an RTX 3090 before denoising. And the one thing that makes 1-spp path tracing viewable, the MetalFX denoised upscaler, is **marked `API_UNAVAILABLE(visionos)` in the visionOS 27 SDK headers** (checked on this machine, see section 2). On the Mac it exists (macOS 26, Apple9+), which is why a non-real-time reference path tracer in the editor is cheap and worth having (stage 4).
- **What fits is hybrid rendering**: keep the deferred TBDR light pass and add a few ray-traced terms, each traced at the foveated resolution, with few rays, accumulated over time, with a shadow-map or IBL fallback when the tier is too low:
  1. **Ray-traced shadows** for the sun and for the lights that have no shadow at all today (only one point light and one spot light can cast a shadow; area lights never do). This is the largest visible gain for the least new machinery.
  2. **Ray-traced ambient occlusion** replacing SSAO (no screen-space halos, no missing occluders off-screen).
  3. **Ray-traced reflections** for metals and glossy surfaces (the engine has no SSR and no reflection probes; reflections are IBL only).
  4. **Diffuse GI through irradiance probes** (DDGI style), updated by a small, fixed ray budget per frame, independent of resolution and shared by both eyes. This is the one GI technique that fits a headset budget, and the same probe storage can be filled offline for static scenes.
- **The highest quality per millisecond for static content is not real-time ray tracing at all**: bake it. Lightmaps or baked irradiance probes from Blender Cycles (the cook already runs Blender) give path-traced lighting at zero runtime ray cost and work on the M2 Vision Pro. The engine has no lightmap or baked-probe path today. Stage 3 builds the probe storage once for both the baked and the dynamic case.
- Recommendation: stage 0 (benchmark, days) → stage 1 (scene BVH + ray-traced shadows, weeks) → stage 2 (AO, reflections) → stage 3 (probe GI, baked and dynamic) → stage 4 (editor reference path tracer on the Mac). Each stage gates on measured per-eye cost on the M5 headset and on an honest decision for the M2.

## 1. What the engine has today (develop, 2026-10-10)

Lighting, as surveyed for this note (paths under `Sources/`):

- **Deferred on tile memory, no light culling.** `gBufferPass` runs G-buffer fill and lighting in one encoder (`Renderer/RenderPasses.swift`, `combinedModelLightExecution`); the G-buffer is memoryless and read with framebuffer fetch (albedo rgba8, normal rgba8Snorm, **world position rgba16Float**, material rgba8, emissive rgba8; `Renderer/ColorPipelineConfig.swift:48-52`). `fragmentLightShaderTBDR` (`Shaders/LightShader.metal:718-848`) loops over every point, spot and area light per pixel. Light types: directional, point, spot, area (LTC), plus light portals.
- **Shadows.** Two-cascade CSM at 2048² for the directional light, 16-tap Poisson PCF (not PCSS). One shadow-casting point light (cube map) and one spot light, both 2048. Area lights are never shadowed. Shadow passes run for eye 0 only in XR. No contact or screen-space shadows.
- **Ambient and GI.** Prefiltered 2D equirect IBL (256², rgba16Float) plus BRDF LUT; on visionOS the ARKit environment probes are prefiltered into that IBL (`UntoldEngineXR/XREnvironmentLightingSystem.swift`). SSAO (full and low-res tiers, bilateral blur) is applied in pre-composite to the whole lit colour, direct and indirect alike (`Shaders/preCompShader.metal:50-52`). **No SSR, no reflection probes, no irradiance volumes, no lightmaps, no baked GI.**
- **Ray tracing, already in the tree.** Picking builds one primitive acceleration structure per submesh from the mesh position buffer (float4 positions, MTK index buffers) and one instance acceleration structure (`ScenePickingGPUSystem.swift:410-483`), rebuilt on a dirty signature, no refit, no compaction. `raymodelIntersect.metal` uses `intersector<triangle_data, instancing>`. Gated on `device.supportsRaytracing`. Dead globals from an earlier experiment (`rayTracingPipeline`, `rayTracingAccumTexture`, … in `Utils/Globals.swift` and `Renderer/RenderResources.swift`) are declared and unused.
- **Geometry the rays would hit.** Vertex streams are separate buffers. Skinning is in the vertex shader by default; compute skinning (`Systems/DeformationSystem.swift`) is opt-in and writes deformed position/normal/tangent buffers. **Only compute-skinned meshes have buffers a BVH can be refit from.** GPU instancing lives on `feature/instanced_draws` (LargeSceneRendering stage 2), not on develop.
- **XR path.** CompositorServices `LayerRenderer`, the whole render graph run once per eye into dedicated textures, culling and HZB once per frame. Foveation (rasterization rate maps) is on `feature/xr_foveation` (untoldengine/UntoldEngine#1342, works on device), TAA with rate-map-aware reprojection on `feature/taa` (#1343). No vertex amplification yet. Any per-eye ray-traced pass costs twice unless it is view-independent (probes).
- **Capability checks.** `supportsRaytracing` and `supportsFamily(.apple2)` are the only ones; there is no GPU-family tiering. Deployment targets macOS 14 / iOS 17 / visionOS 2; shaders are Metal 3 era; no Metal 4 anywhere.
- **Profiling.** GPU time is one number per command buffer; per-pass `MTLCounterSampleBuffer` timers are item A2 of PerformanceMeasurementResearch and are needed before any ray-traced pass can be judged.

## 2. What the hardware and the OS give

Checked against the visionOS 27.0 SDK on this machine (Xcode 27.0), Apple's Metal Feature Set Tables (revision shipped with that SDK), the WWDC25 sessions "Go further with Metal 4 games" and "What's new in Metal rendering for immersive apps", and Apple's M5/A19 GPU tech talk.

| Fact | M2 Vision Pro (2024) | M5 Vision Pro (Oct 2025) | Mac (M3/M4/M5) |
|---|---|---|---|
| GPU family | Apple8 | Apple10 | Apple9 / Apple10 |
| `supportsRaytracing` (compute) | yes, **software traversal in the shader** | yes, hardware (3rd gen) | yes, hardware |
| `supportsRaytracingFromRender` (fragment shaders) | yes (Apple6+) | yes | yes |
| Hardware instance transforms, 1 KB AS alignment, HW intersection-function-buffer indexing | no | yes (M5/A19) | M5 only |
| Acceleration structure build options (prefer fast intersection / low memory), intersection function buffers | no (Apple9+) | yes | yes |
| MetalFX denoised upscaler | **unavailable on visionOS** | **unavailable on visionOS** | macOS 26, Apple9+ |
| MetalFX temporal upscaler / frame interpolation | unavailable on visionOS | unavailable on visionOS | yes |
| Metal 4 | visionOS 26 | visionOS 26 | macOS 26 |
| Compositor drawable (foveated) | ≈1920×1824 per eye | same; 10 % more pixels in the fovea, up to 120 Hz | n/a |
| Frame budget | 11.1 ms at 90 Hz, everything included | 11.1 ms (8.3 ms at 120 Hz) | 16.7 ms at 60 Hz |

Evidence and notes:

- `MTLDevice.supportsRaytracing` is documented as visionOS 1.0+; the header carries `API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0))` with no visionOS exclusion. Feature table rows: "Ray tracing in compute pipelines — Apple6", "Ray tracing in render pipelines — Apple6" (footnote 6: not compatible with mesh shading in the same pipeline), "Acceleration structure build options — Apple9", "Intersection function buffers — Apple9", "Address-driven acceleration structure builds — Metal 4, Apple9". Family table: M2-series Apple8, M3/M4 Apple9, M5-series and A19 Apple10.
- **Software vs hardware is not queryable.** `supportsRaytracing` is true on both headsets. Blender's Cycles uses "M3 or newer" as the proxy for hardware traversal; the engine should do the same with `supportsFamily(.apple9)`.
- **MetalFX on visionOS.** In `MetalFX.framework/Headers/MTLFXTemporalDenoisedScaler.h`, `MTLFXTemporalScaler.h`, `MTLFXFrameInterpolator.h` and their `MTL4FX*` twins every class and protocol is wrapped in `#if TARGET_OS_VISION … API_UNAVAILABLE(visionos)`. Only the spatial scaler is available. Apple's own denoiser is therefore a Mac/iOS tool; on the headset the engine must denoise itself (section 5.5).
- **M5 ray tracing (Apple tech talk "Boost your graphics performance with the M5 and A19 GPUs").** "M5 represents the third generation of hardware ray tracing"; instance transforms "are accelerated with dedicated hardware"; intersection function buffer indexing cost "dropped up to 70 % compared to emulation"; acceleration structure alignment "drops from 16 kB to just one kilobyte", so many small objects no longer pay padding. Guidance: keep dynamic objects as separate instances instead of merging geometry; set extended limits only when needed; pick static vs motion instances deliberately. M4 was "a 2X faster ray tracing engine" over M3; M5 claims up to 45 % more in ray-tracing apps over M4.
- **Public performance figures are thin.** Apple's A17 Pro claim is "up to 4x faster than the software-based ray tracing" of the A16. Arm's mobile guidance (Immortalis) is the closest published practice for this class of GPU: hard shadows at ≤1 ray per pixel, mirror reflections at 1 ray per pixel, glossy and soft variants above that, shadows traced at a lower resolution than reflections (800×600 vs 1600×900 in their demo), checkerboard and temporal distribution of rays, and ray-query style hybrid rendering over a full ray-tracing pipeline. Nothing comparable has been published for Vision Pro, and RealityKit itself has no ray-traced reflections (Apple engineer, developer forums, Nov 2025).
- **visionOS 26 Compositor changes that matter here**: `queryDrawables()`, dynamic render quality (only with foveation), progressive immersion stencil. Nothing in that session mentions ray tracing or MetalFX.

## 3. Budget arithmetic

Pixels and rays per frame, two eyes, with the compositor's foveated drawable (the engine's foveation branch renders about 2624×2560 physical texels per eye at quality 1.0 on the M2 headset, roughly 1.9 M per eye after the rate map's coarse periphery; take **2 M shaded pixels per eye, 4 M per frame** as the planning figure):

| Effect | Rays per shaded pixel | Rays per frame (both eyes) | Notes |
|---|---|---|---|
| Sun shadow, hard | 1 | 4 M | replaces two CSM cascades (two depth passes at 2048² today) |
| Sun shadow, soft (temporal) | 1 per frame, jittered in the light's cone | 4 M | needs the TAA-style history |
| Local light shadows, N nearest | 1 per light | 4 M × N | today 1 point + 1 spot are shadowed; everything else is unshadowed |
| AO | 1 short ray | 4 M | replaces SSAO (full-res tier) |
| Reflections, metals and roughness below a threshold | 1 | far less than 4 M | only on reflective pixels, half or quarter resolution |
| Probe GI, 512 probes × 64 rays | 0 | 32 k | view-independent, shared by both eyes, amortised over frames |
| Path tracing, 1 spp, 1 bounce + shadow rays | 3–4 | 12–16 M | plus full material shading at every hit, plus a denoiser the headset does not have |

Costs are unknown until stage 0 runs: the planning assumption from mobile hardware ray tracing (Arm's demos: a deferred 1600×720 scene with ray-traced shadows and reflections at 40–60 fps on an Immortalis GPU) is that **a few million coherent rays per frame are affordable on hardware traversal and a few hundred thousand are not free on software traversal**. Two consequences:

- On the M5 headset, one effect at a time at full foveated resolution, or two or three at half resolution, is the realistic envelope inside a frame that must also render the scene.
- On the M2 headset, per-pixel ray tracing is almost certainly too slow for 90 Hz and should be off by tier; probe GI with tens of thousands of rays per frame is the only runtime ray-traced term worth measuring there, and baked lighting is the real answer.

Rays are not the only cost. Each ray-traced term needs a stored depth and normal to start from (the TBDR G-buffer is memoryless), a history buffer for temporal accumulation, and a denoise pass. Those are full-screen passes, and PerformanceMeasurementResearch measured every full-screen pass on the headset at 0.5 to 1.3 ms per eye. A ray-traced shadow must therefore also **remove** passes (the cascade depth passes, the SSAO chain) to pay for itself.

## 4. Options compared

| Option | Visual gain | M2 Vision Pro | M5 Vision Pro | Mac | Effort | Verdict |
|---|---|---|---|---|---|---|
| A. Real-time path tracing | everything | no | no at 90 Hz stereo | 30 fps-class at 1080p with MetalFX denoiser | months | editor reference mode only (stage 4) |
| B. Hybrid: RT shadows / AO / reflections | large: shadows from every light, no SSAO halos, real reflections | off (tier) | yes, budgeted per effect | yes | weeks per effect | **do, stages 1–2** |
| C. Probe GI (DDGI), rays updating probes | bounce light, colour bleeding, dynamic lights and objects | measure; probably yes at low ray counts | yes | yes | weeks | **do, stage 3** |
| D. Baked lighting (lightmaps or baked probes from Cycles) | path-traced quality for static scenes | yes, free at runtime | yes | yes | weeks (cook + loader + shader) | **do, stage 3**, shares storage with C |
| E. Raster improvements without rays (PCSS, more cascades, shadow atlas for many lights, clustered light culling) | medium | yes | yes | yes | weeks | partly: clustered lights are needed anyway once GI adds probes; the shadow atlas is superseded by B on M5 but is the M2 fallback |

Why B over the common alternatives: screen-space reflections and screen-space shadows fail on exactly the content the engine cares about (BIM interiors where the occluder is behind the camera or off-screen, and a headset where the user's head is the camera and misses are seen immediately). Ray queries from a compute pass have none of those failure modes and the BVH already exists.

## 5. Design for the hybrid path

### 5.1 One scene acceleration structure, shared with picking

Generalise `ScenePickingGPUSystem`'s builder into a `SceneAccelerationStructureSystem`:

- **One primitive acceleration structure per distinct mesh resource**, owned through `MeshResourceManager` (refcounted, built once, compacted when static). This matches LargeSceneRendering stage 1b (one load per distinct file) and stage 2 (instancing): 175 trees are one primitive structure and 175 instances. On M5 the instance transforms are hardware-accelerated, which is Apple's stated reason not to merge geometry.
- **One instance acceleration structure per frame**, rebuilt from the visible-or-shadow-relevant entity set (an instance structure build over a few thousand instances is cheap; refit is cheaper and enough when only transforms change). Instances carry a user ID that resolves to the entity and its material (needed by reflections, section 5.4).
- **Deforming meshes**: compute-skinned meshes refit their primitive structure from the deformed position buffer every frame. Vertex-shader-skinned meshes have no deformed buffer; either exclude them from the scene structure (they receive but do not cast ray-traced effects, the shadow map fallback covers them) or move skinned casters to compute skinning. Decide per stage 1 measurement; expect the second.
- **Build options**: on Apple9+ use "prefer fast intersection" for the static set and the default for refit structures; these flags are per build.
- Picking traces the same structure. The dead `rayTracing*` globals go.

### 5.2 Where the rays run

Two ways to get a ray origin and normal per pixel in this engine:

1. **Trace inside the TBDR light fragment shader** (`supportsRaytracingFromRender`, Apple6+). Position and normal are already in tile memory. No new pass, no stored G-buffer. But the result cannot be denoised or accumulated before it is used, it runs at full rate per pixel, and ray tracing in render pipelines is not compatible with mesh shading in the same pipeline (feature table footnote 6), which VirtualizedGeometryResearch wants later. Good for a hard, one-ray sun shadow; wrong for everything that needs a history.
2. **A compute pass before the light pass**, reading depth and normal (`hzbDepthSource` already stores depth for occlusion culling; add a stored normal target), writing a per-effect texture (shadow visibility per light slot, AO, reflection colour) that the light shader samples instead of the shadow map or SSAO. Resolution per effect is free to choose, rays can be jittered and accumulated, and the pass dispatches over the **rate-mapped physical texture**, decoding texel → screen position with the rate map's decoder (the pattern SSAO and the occlusion culls already use on `feature/xr_foveation`), so foveation reduces the ray count by itself.

Recommendation: option 2 for shadows, AO and reflections; keep option 1 in mind as a cheaper sun-only mode. Reconstruct the ray origin from the stored reverse-Z depth and the projection, not from the rgba16Float world-position attachment (half-float world positions are too coarse for self-intersection-free origins); add a normal-offset bias scaled by pixel footprint.

### 5.3 Shadows (stage 1)

- Sun: one ray per shaded pixel per frame, direction jittered inside the sun's angular radius; accumulate visibility with the TAA machinery from `feature/taa` (history, reprojection through both frames' rate maps, variance clip) to get soft, stable penumbrae. Replaces both cascade passes on tier hardware; the CSM path stays as the fallback and for vertex-skinned casters.
- Local lights: the K nearest or brightest shadow-worthy lights per frame get a ray each (start with K = 4); the shadow uniform tells the light shader which slots carry a ray-traced visibility texture and which fall back to the one point cube map / spot map or to no shadow. Area lights sample a point on the emitter, which gives correct soft area shadows for the first time.
- Mesh translucency and alpha-tested leaves: an opaque-only first version; alpha test through an intersection function later (Apple9+ gets intersection function buffers).

### 5.4 AO and reflections (stage 2)

- AO: one ray, 0.5 to 1 m, cosine-distributed, accumulated temporally; replaces the SSAO chain (three passes) with one trace and the shared denoise. Apply it to the indirect term only, which the TBDR path cannot do today (SSAO multiplies the whole lit colour in pre-composite).
- Reflections: for pixels with metallic above a threshold or roughness below one, one ray in the GGX lobe, half or quarter resolution with a depth-aware upsample. The hit must be shaded: material and textures by instance user ID through an argument buffer of per-instance materials (the engine's bindless groundwork), with a cheap shading model (albedo × direct sun with one shadow ray, plus IBL). Misses fall back to the current IBL specular term, so the image never gets worse than today.

### 5.5 Denoising on the headset

MetalFX's denoiser is not on visionOS, so the engine owns this. A single, small, shared denoiser for scalar signals (visibility, AO) and one for colour (reflections): temporal accumulation with the rate-map-aware reprojection from `feature/taa`, variance-guided spatial blur à la SVGF-lite (two or three à-trous taps), history rejection on depth and normal disocclusion. On macOS 26 with Apple9+, the `MTLFXTemporalDenoisedScaler` path can be offered as an alternative for the reference mode (stage 4), not for parity with the headset.

### 5.6 Probe GI, baked and dynamic (stage 3)

- Storage: an irradiance probe grid (octahedral atlas, DDGI layout, with visibility/depth per probe to stop light leaking) placed around the scene's visible bounds or authored volumes; sampled in `computeIBLContribution` in place of the single equirect irradiance map, blended with the ARKit environment estimate in mixed immersion.
- Dynamic fill: a fixed ray budget per frame (e.g. 512 probes × 64 rays, 32 k rays), traced against the scene structure, shading hits with direct light plus the previous frame's probes (infinite bounce for free), blended with hysteresis. View-independent: one dispatch per frame, both eyes benefit. This is the term that may run on the M2 headset in software; stage 0 says whether 32 k rays fit.
- Baked fill: the cook writes the same atlas from Blender Cycles (bake irradiance at probe positions, or bake lightmaps for static geometry and sample them in the G-buffer pass). Zero runtime ray cost, works everywhere, and it is where BIM-style static scenes get the "a lot better" lighting the question asks for.

### 5.7 Tiering and settings

`RayTracingTier`: `.none` (no `supportsRaytracing`), `.software` (true but below Apple9), `.hardware` (Apple9+). Rendering options per effect (`.rayTracedShadows`, `.rayTracedAO`, `.rayTracedReflections`, `.probeGI(.baked | .dynamic)`) with defaults by tier: hardware on, software off except probe GI, pending stage 0. Every effect keeps today's path as fallback; a scene must look no worse with ray tracing off than it does today.

### 5.8 Stereo and foveation

All per-pixel effects run per eye. The costs in section 3 are already per frame for two eyes, but the branch work matters: ray-traced passes should land after `feature/xr_foveation` (#1342) is merged, so the dispatch is over the rate-mapped texture, and after the per-eye command buffer split from PerformanceMeasurementResearch, so the GPU starts eye 0's rays while eye 1 is encoded. Probe GI is per frame, not per eye.

### 5.9 Metal 4

Not required. Everything above is Metal 3 API, available at the current deployment targets. Metal 4 adds argument tables, the unified compute encoder for structure builds and intersection function buffers (Apple9+, Metal 4 also for address-driven builds); none of it changes what fits in the frame. Revisit when the engine adopts Metal 4 for other reasons.

## 6. Stages and gates

| Stage | What | Gate |
|---|---|---|
| **0. Measure** (days) | Per-pass GPU timers (PerformanceMeasurementResearch A2). An `rt-probe` bench scene: build the scene structure for a Sponza-class scene and the BIM pack, dispatch N coherent shadow rays and N incoherent AO rays at the foveated drawable, and 32 k probe rays, on the M2 headset, the M5 headset and a Mac. Report ms per million rays by tier and the structure build/refit times. | Numbers in this document's section 3 replace the assumptions. Decide M2 defaults. |
| **1. Scene structure + shadows** (weeks) | `SceneAccelerationStructureSystem` shared with picking; refit for compute-skinned meshes; ray-traced sun and K local-light shadows with temporal accumulation; cascade and cube/spot maps as fallback. | On the M5 headset, sun + 4 lights at quality 1.0 ≤ the two cascade passes they replace, image stable under head motion; tiered off on M2. |
| **2. AO + reflections** (weeks) | RTAO replacing SSAO on tier hardware; reflections for metals and glossy with IBL miss fallback; shared denoiser. | AO trace + denoise ≤ the SSAO chain it replaces; reflections ≤ 1 ms per eye at half resolution. |
| **3. Probe GI** (weeks) | Probe atlas storage + sampling in the light shader; baked fill from the cook; dynamic fill with a fixed ray budget. | Baked: lands first, every device. Dynamic: ≤ 1 ms per frame on M5; on M2 by stage 0 numbers. |
| **4. Reference path tracer** (editor, Mac, weeks) | Progressive path tracer over the same scene structure and materials, MetalFX denoised upscaler on macOS 26 / Apple9+, for look-dev and as ground truth for stages 1–3. | Converges to a usable image in seconds on an M3-class Mac; used to validate the real-time terms. |

Stages 1 to 3 each remove an existing pass as they add one; the per-eye GPU minimums and the deadline-miss rate from the headset bench are the judge, as PerformanceMeasurementResearch set out.

## 7. Risks and open questions

- **No measured ray throughput for either headset.** Everything in section 3 is an assumption until stage 0. If the M5 headset's software fallback for incoherent rays is slow, AO and reflections shrink to quarter resolution or go.
- **Thermals.** The headset's GPU already runs the light scenes at the deadline; ray tracing adds sustained load, and the fourth headset run saw the device reach thermal state "fair" within a session. Stage gates must include a 20-minute thermal run, as the budgets table requires.
- **Deforming casters.** Vertex-shader skinning cannot feed a BVH. Moving skinned casters to compute skinning costs a pass per mesh and memory for deformed buffers; or they keep shadow maps only.
- **Denoiser quality without MetalFX.** Temporal denoisers ghost on disocclusion and on moving lights; the headset makes ghosting visible immediately. The TAA work on `feature/taa` is already fighting the same problems (history from the coarse periphery, cleared-depth pixels); the ray-traced terms inherit its fixes and its unknowns.
- **Mixed immersion.** Passthrough has no geometry in the BVH; ray-traced shadows onto the real floor need a scene-mesh proxy (ARKit scene reconstruction) as instances, or stay on the virtual geometry only.
- **Mesh shading.** Ray tracing from render pipelines excludes mesh shading in the same pipeline; the compute-pass design (5.2, option 2) avoids the conflict, which matters for VirtualizedGeometryResearch phases 2–3.
- **Content.** Baked lighting needs UV2 or probe placement from the cook; 8,247 meshes in the BIM scene have no UV map at all (LargeSceneRendering section 1), which argues for probes over lightmaps for that content.

## Sources

- Apple, `MTLDevice.supportsRaytracing` (visionOS 1.0+): https://developer.apple.com/documentation/metal/mtldevice/supportsraytracing
- Apple, `MTLGPUFamily` (apple8 = A15/A16/M2, apple9 = A17/M3/M4): https://developer.apple.com/documentation/metal/mtlgpufamily
- Apple, Metal Feature Set Tables (ray tracing rows, family table incl. M5/A19 = Apple10): https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
- Apple, Support for Metal on Apple devices (Vision Pro: Metal 4 on visionOS 26): https://support.apple.com/102894
- Apple, WWDC25 "Go further with Metal 4 games" (intersection function buffers, build options, MetalFX denoised upscaler inputs): https://developer.apple.com/videos/play/wwdc2025/211/
- Apple, WWDC25 "What's new in Metal rendering for immersive apps" (queryDrawables, dynamic render quality, progressive immersion): https://developer.apple.com/videos/play/wwdc2025/294/
- Apple, WWDC26 "Build real-time neural rendering pipelines with Metal" (MetalFX Denoising, 1 spp guidance): https://developer.apple.com/videos/play/wwdc2026/359/
- Apple, Tech Talk "Boost your graphics performance with the M5 and A19 GPUs" (third-generation ray tracing, instance transforms, 1 KB alignment): https://developer.apple.com/videos/play/tech-talks/111431/
- Apple, WWDC23 "Your guide to Metal ray tracing" (instancing, refit, compaction): https://developer.apple.com/videos/play/wwdc2023/10128
- Apple, WWDC21 "Explore hybrid rendering with Metal ray tracing": https://developer.apple.com/videos/play/wwdc2021/10150
- Apple sample, "Rendering reflections in real time using ray tracing": https://developer.apple.com/documentation/metal/rendering-reflections-in-real-time-using-ray-tracing
- Apple Developer Forums, "Raytracing on the Vision Pro M5" (no RealityKit ray-traced reflections, Nov 2025): https://developer.apple.com/forums/thread/806838
- Apple newsroom via Road to VR, M5 Vision Pro (10-core GPU with hardware ray tracing, 120 Hz, 10 % more pixels): https://www.roadtovr.com/apple-vision-pro-m5-chip-october-22-launch/
- Tom's Guide, A17 Pro "up to 4x faster than software-based ray tracing": https://www.tomsguide.com/news/a17-pro
- Arm, mobile ray tracing best practices (rays per effect, hybrid shadows/reflections, resolution per effect): https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-immortalis-g715-developer-overview and https://dev.vulkan.org/user/pages/09.events/vulkanised-2024/vulkanised-2024-Iago-calvo-lista-arm-2.pdf
- Ouyang et al., "ReSTIR GI: Path Resampling for Real-Time Path Tracing" (8.9 ms at 1080p, 1 spp, RTX 3090): https://research.nvidia.com/publication/2021-06_restir-gi-path-resampling-real-time-path-tracing
- Majercik et al., "Dynamic Diffuse Global Illumination with Ray-Traced Irradiance Fields" (JCGT 2019): https://cim.mcgill.ca/~derek/files/DDGI-lowres.pdf
- Blender, MetalRT default on M3 or newer (software vs hardware proxy): https://devtalk.blender.org/t/cycles-apple-metal-device-feedback/21868?page=22
- Local: visionOS 27.0 SDK headers `Metal.framework/Headers/MTLDevice.h`, `MetalFX.framework/Headers/MTLFXTemporalDenoisedScaler.h` (`API_UNAVAILABLE(visionos)`), checked 2026-10-10.
