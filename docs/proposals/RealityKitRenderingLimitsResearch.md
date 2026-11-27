# What plain RealityKit cannot do on visionOS (vs. Metal through Compositor Services) — validated research

Status: research for a post. Checked 2026-10-30 against Apple's documentation (availability read from developer.apple.com), WWDC25/WWDC26 transcripts, and Apple engineers' answers on the developer forums. Every claim carries its source; "unverified" marks the few things not confirmed.

Companion: `SpatialPersonasResearch.md` (2026-10-16) covers the Personas side in depth.

## TL;DR (safe to publish)

1. **Custom Metal shaders on RealityKit entities do not exist on visionOS.** `CustomMaterial` is iOS 15+/iPadOS/macOS 12+/tvOS 26+ only; visionOS is absent from its availability. Apple (Vision Pro Engineer, April 2025): "visionOS does not support custom shaders in RealityKit … Compositor Services does support custom shaders, but is not compatible with RealityKit." The only material you can author on visionOS is `ShaderGraphMaterial` (MaterialX 1.38 graphs from Reality Composer Pro) plus the built-ins (PBR, Unlit, Video, Occlusion).
2. **Post-processing does not exist on visionOS.** `PostProcessEffect` / the `customPostProcessing` API is iOS 26, iPadOS 26, macOS 26, tvOS 26; the type it hangs off (`RealityViewCameraContent`) has no visionOS availability at all, and the visionOS `RealityViewContent` has no post-process hook. WWDC25 session 287: "This API is supported on iOS, iPadOS, macOS, and tvOS." So no bloom, color grading, DOF, motion blur, vignette, or any full-screen pass.
3. **No access to the frame.** Shader Graph has no scene-depth or scene-color node (the RealityKit node list has "Surface Screen Position" and "Blurred Background", nothing that reads the depth or color buffer). Screen-space techniques (SSR, SSAO, soft particles, depth-based fog or outlines, refraction of the scene) are therefore not possible.
4. **No control of the render pipeline.** Resolution, foveation, MSAA, pixel formats, stencil, blend state, render targets, pass order and frame pacing are all the system's. Compositor Services hands you the drawable's `colorTextures`, `depthTextures`, `rasterizationRateMaps`, `views`, `deviceAnchor`, `frameTiming` and you encode whatever you want.
5. **visionOS 27's `LowLevelRenderer` does add Metal surface shaders and geometry modifiers, but off-screen only.** Apple (June 2026): "User-authored Metal surface shaders are supported with LowLevelRenderer on visionOS … intended for use in offscreen draws / exclusive rendering use cases such as through CompositorServices." Composition with RealityView content is "presenting LowLevelRenderer's output to a LowLevelTexture, sampled from a RealityKit mesh via ShaderGraphMaterial", with depth "approximated". It does not put custom shaders on RealityView entities.
6. **The trade is Personas.** Apple (July and September 2025): "personas are not available while displaying content with Compositor Services" and "both technologies cannot be used in the same immersive space." Full Metal means no Spatial Personas; Spatial Personas mean RealityKit's materials. Unchanged in visionOS 27.

## 1. Material and shading

| Capability | Metal / Compositor Services | RealityKit on visionOS | Source |
|---|---|---|---|
| Arbitrary vertex/fragment shaders | yes | **no** | `CustomMaterial` availability: iOS 15, iPadOS 15, Mac Catalyst 15, macOS 12, tvOS 26 — no visionOS. Forum 778674 (Apple, Apr 2025). |
| Node-based materials | n/a | `ShaderGraphMaterial` (visionOS 1+), MaterialX 1.38 + RealityKit nodes; loadable from `.usda`/MaterialX data | `ShaderGraphMaterial` docs; ShaderGraph docs |
| Vertex displacement | yes | yes, via the Shader Graph "Geometry Modifier" output (node graph only) | ShaderGraph RealityKit node list |
| Lighting model | anything | pick a surface node: PBR, Unlit, Hair, Occlusion, Shadow-Receiving Occlusion; RCP 3 (27) adds subsurface scattering | ShaderGraph RealityKit node list; WWDC26 287 |
| Scene depth / scene color in a shader | yes | **no node for it** | ShaderGraph RealityKit node list |
| Stereo-aware shading | yes (per view) | "Camera Index Switch" node only | ShaderGraph RealityKit node list |
| Wireframe | yes | `triangleFillMode = .lines` | `ShaderGraphMaterial.triangleFillMode` (visionOS 1) |
| Depth read/write toggles | yes | `readsDepth` / `writesDepth` on `ShaderGraphMaterial` | docs |
| Per-instance custom data | yes | **no on visionOS**: `MeshInstancesComponent` (26) takes transforms; the per-instance `LowLevelBuffer → CustomMaterial` path is "On iOS, iPadOS, macOS, and tvOS" | WWDC25 287 transcript |
| Procedural geometry/textures from compute | yes | yes: `LowLevelMesh` and `LowLevelTexture` (visionOS 2) are writable by your compute kernels; RealityKit still shades them with its materials | docs availability |
| Blend modes beyond opaque/alpha | yes | unverified (not checked) | — |

## 2. Effects and frame-level work

| Capability | Metal / Compositor Services | RealityKit on visionOS | Source |
|---|---|---|---|
| Post-process passes (bloom, grading, DOF, blur…) | yes | **no**: `PostProcessEffect` is iOS/iPadOS/macOS/tvOS 26; `RealityViewCameraContent` not on visionOS | docs availability; WWDC25 287 |
| Custom render targets / multi-pass | yes | **no** (except `RealityRenderer` to an off-screen texture, visionOS 1+, and `LowLevelRenderer`, 27, both outside the RealityView) | docs |
| MSAA / resolution / foveation control | yes (`rasterizationRateMaps`, dynamic render quality in 26) | system-managed | Compositor Services `Drawable` docs; WWDC25 294 |
| Stencil | yes | no API | `LowLevelRenderer.Configuration` exposes `stencilAttachmentPixelFormat` only for the off-screen renderer |
| Particles | your own | `ParticleEmitterComponent` (visionOS 1+), fixed feature set | docs |
| Real-world occlusion of virtual content | your own (you have no passthrough pixels either) | `EnvironmentBlendingComponent` (visionOS 26), static objects only, always drawn behind other virtual content | docs; WWDC25 287 |
| Gaussian splats | your own | `GaussianSplatComponent` (27); "doesn't use developer-visible shaders", unlit, Apple7 GPU | docs |
| Cloth | your own | `ClothSimulationComponent` (iOS 27, visionOS 27) | docs |
| Lights and shadows | your own | Directional/Point/Spot (visionOS 2), `DynamicLightShadowComponent` (2), `GroundingShadowComponent` (1), IBL / `VirtualEnvironmentProbeComponent` (2), `SpotLightComponent.ProjectiveTexture` (27, Apple6 GPU), `SurroundingsLight` lighting the real room (macOS 27, visionOS 27) | docs |
| Spatial photos / scenes | your own | `ImagePresentationComponent` (visionOS 26) | docs |

## 3. visionOS 27 `LowLevelRenderer`: what it is and is not

- Availability: iOS 27, iPadOS 27, tvOS 27, visionOS 27 (docs). It "encodes draw calls for a collection of mesh instances into a Metal command buffer"; it "manages camera constants, per-instance transforms, MSAA resolve, tonemapping, and optional color gamut conversion. You are responsible for creating and committing the Metal command buffer."
- `LowLevelRenderContext` (27) exposes `makeSurfaceShader`, `makeSimpleSurfaceShader`, `makeGeometryModifier`, `makeRenderPipelineState`, `makeArgumentTable`, and `makeShaderGraphFunctions` (Shader Graph compiled to Metal functions). Lighting functions offered: image-based and unlit (`LowLevelRenderContextLighting`).
- `RenderState.encoder` gives the `MTLRenderCommandEncoder` "to issue custom Metal commands between draws".
- `Output` supports `rasterizationRateMap`, `renderTargetArrayLength` (stereo), viewports, scissor; `Configuration` supports color/depth/stencil pixel formats and `rasterSampleCount`.
- Apple engineer, forum 831767 (June 2026): "The surface shader API on LowLevelRenderer's makeSurfaceShader conforms to the same shader API surface as CustomMaterial." "Both stereo rendering and rasterization rate maps are supported features on LowLevelRenderer.output, so interoperability with CompositorServices API is an intended use case." "LowLevelRenderer / LowLevelRenderContextStandalone is intended for use in offscreen draws / exclusive rendering use cases such as through CompositorServices."
- Consequence for the post: in 27 you can run CustomMaterial-style Metal shaders on visionOS, but only in a renderer you drive yourself (Compositor Services, or off-screen to a `LowLevelTexture` shown on a RealityKit mesh). Entities inside a `RealityView` still take Shader Graph only. No WWDC26 session covers it (sessions 287 and 279 do not mention it).

## 4. The other side: what Compositor Services gives up

- **Spatial Personas**: "There is no way to use persona apart from a SharePlay experience." / "personas are not available while displaying content with Compositor Services." (Apple, forum 791591, Jul–Sep 2025; same sentence in 801420.) Nothing in visionOS 26 or 27 changes this.
- **RealityKit in the same space**: "both technologies cannot be used in the same immersive space" (Apple, forum 766378). No ECS, no `HoverEffectComponent`, no RealityKit physics/collision in a Metal space.
- What Metal did gain in 26 (WWDC25 294): tracking-areas texture for system hover highlighting (8-bit, "up to 255 concurrent interactive objects"), dynamic render quality ("only possible if foveation is enabled"), progressive immersion ("only works with the layered layout"), macOS `RemoteImmersiveSpace` (full and progressive only), Metal 4 template. In 27 the framework interface did not change (see SpatialPersonasResearch.md §1).

## 5. Claims to avoid or correct

- "Apple blocks custom shaders on visionOS for privacy / out-of-process rendering": not stated anywhere by Apple. Engineers only say it is unsupported and ask for Feedback.
- "Use CustomMaterial through Shader Graph nodes": false; `CustomMaterial` is not on visionOS and Shader Graph has no custom-code node.
- "LowLevelMesh lets you run your shaders in RealityKit": false; it is a vertex/index buffer RealityKit shades with its own materials.
- "visionOS 27 brings custom shaders to RealityKit": only true for `LowLevelRenderer`, which is off-screen/exclusive; say it that way.
- Unverified, do not state without checking: Shader Graph blend modes; reported 27 additions from third parties (lightmaps, soft shadows, LOD controls, navmesh) from session 279, which was not read for this research.

## Sources

- CustomMaterial: https://developer.apple.com/documentation/realitykit/custommaterial
- ShaderGraphMaterial: https://developer.apple.com/documentation/realitykit/shadergraphmaterial
- Shader Graph RealityKit nodes: https://developer.apple.com/documentation/shadergraph/realitykit
- PostProcessEffect: https://developer.apple.com/documentation/realitykit/postprocesseffect
- RealityViewCameraContent: https://developer.apple.com/documentation/realitykit/realityviewcameracontent
- LowLevelRenderer: https://developer.apple.com/documentation/realitykit/lowlevelrenderer
- LowLevelRenderContext: https://developer.apple.com/documentation/realitykit/lowlevelrendercontext
- LowLevelMesh / LowLevelTexture / MeshInstancesComponent / EnvironmentBlendingComponent / GaussianSplatComponent / ClothSimulationComponent / SpotLightComponent.ProjectiveTexture / SpotLightComponent.SurroundingsLight: same documentation root
- Compositor Services Drawable: https://developer.apple.com/documentation/compositorservices/layerrenderer/drawable
- WWDC25 287 What's new in RealityKit: https://developer.apple.com/videos/play/wwdc2025/287/
- WWDC25 294 What's new in Metal rendering for immersive apps: https://developer.apple.com/videos/play/wwdc2025/294/
- WWDC26 287 Build next-generation experiences with visionOS 27: https://developer.apple.com/videos/play/wwdc2026/287/
- Forum 778674 (custom shaders unsupported, Apr 2025): https://developer.apple.com/forums/thread/778674
- Forum 831767 (LowLevelRenderer on visionOS, Jun 2026): https://developer.apple.com/forums/thread/831767
- Forum 791591 / 801420 / 766378 (Personas and Compositor Services): https://developer.apple.com/forums/thread/791591 , https://developer.apple.com/forums/thread/801420 , https://developer.apple.com/forums/thread/766378
