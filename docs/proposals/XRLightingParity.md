# XR Lighting Parity: an engine object beside a RealityKit object in the same room (study)

Status: study, with a Mac render test and no engine change. Written 2026-10-27 against the fork's `develop` (`b2571c37`) and the RealityKit presenter branches (`feature/xr_realitykit_presenter` at `d414627c`, arcade `feature/realitykit_presenter_example` at `822ee1d`). The render test is `Tests/UntoldEngineRenderTests/XRLightingParityLimbTests.swift` on the branch `test/xr_lighting_parity_limb` (cut from `upstream/develop` at `93bc8068`); its readings are quoted throughout and were taken on an Apple M4 Max.

The question. On 2026-10-27 the RealityKit presenter example stood a RealityKit sphere (`SimpleMaterial`, roughness 0.2, radius 6 cm, 1.6 m away) beside the engine's sphere of the same size and roughness, both in the same room. The engine sphere showed a sunlit white top and a blue-grey bottom where the RealityKit sphere was an even pale grey, and along the engine sphere's lower edge, straight below it, sparse pale neutral pixels (luma 150 to 164 against the wall's 129 and the sphere's 78 just inside, colour about (158, 159, 166)) that the RealityKit sphere did not have. Turning the example's "Room light estimate" switch off changed nothing, raising the roughness to 0.6 and 0.9 changed nothing, and lowering the sun from 3 to 0.5 diluted them. The reading at the time: the limb's Fresnel reflection of the engine's environment standing out against a bottom the authored sun leaves in shadow, a lighting-parity question. This study reads the engine's XR lighting path, compares it with what Apple documents of RealityKit's, explains the two observations with numbers, and says what the engine and the example should do.

## TL;DR

1. **The engine sphere in the example is not lit by the room at all.** The engine's runtime lighting mode starts as `.staticIBL` and nothing in the presenter example or in the XR runtime selects `.realWorldEstimate`, so the ARKit light estimation provider never starts and no room probe is ever published. The example's "Room light estimate" switch drives `setXRLightingContribution` (1 or 0), a factor that only multiplies the estimate, which is not in use: the switch is a no-op, which is why it changed nothing. What lights the sphere is the authored sun (strength 3, straight above) and the engine's bundled default environment, `teatro_massimo_2k.hdr` (the default `hdrURL`, baked at start-up whatever the platform), applied as diffuse irradiance alone at the default ambient of 0.4: with `applyIBL` false, the engine keeps the irradiance term and drops the reflection term. That picture is an evening sky over a square (mean radiance (0.38, 0.50, 0.78), blue), and its floor over pi is (0.12, 0.16, 0.22): at 0.4 that is the blue-grey bottom. The Mac test reproduces the device's reading to the pixel: bottom 0.075 linear, (0.060, 0.076, 0.108), which the display encodes as 78 of 255, the capture's 78; top 1.34, which the tone map and the display make white.
2. **The RealityKit sphere is lit by the room because RealityKit lights every lit material with ARKit's environment probe plus a system image light, with no set-up and no authored light in the example's RealityKit content.** Its body is the room's light times its colour, even all round, as Apple describes it. The two spheres differ in body because one is lit by a bundled picture and a strong authored sun, the other by the room: a scene choice and an engine default, not a shading difference.
3. **The engine's environment term needs no occlusion or Fresnel clamp.** Under an even room the engine's white glossy sphere is the room all over, limb included (0.500 everywhere, the lowest fully covered edge texel 1.000 to 1.003 times the surface two texels in): what the limb reflects it does not scatter, and the two shares sum to one. The RealityKit control sphere's colour gives a faint Fresnel rim of 8 % on average and 12 % at most, the same physics RealityKit's physically based material has. A rim that stands out is a scene's contrast (a sun from above over a dark bottom), not the term's.
4. **The pale specks are not a lighting term.** No environment reflection is active in the example (point 1), and the sun's own reflection at the bottom limb is nothing (the normal faces away from it). What the Mac can produce at a dark bottom limb is one thing only: the presenter branch's back-face rule, which decides on the interpolated normal and turns a limb normal a hair past 90 degrees round into the sun; with it, 13 of 47 partly covered edge texels on the bottom arc are 1.5 to 9 times the surface beside them, with the face rule of upstream `#1359` none (the sibling measurement of 2026-10-27 found the same 13 of 47). The presenter branch carries the centroid fix but not the face rule. The Mac never produces a fully covered bright texel under either rule, so if the device still shows them with the centroid fix in force, what is left is the device's own raster and sampling of the rim, outside lighting. The face rule is the right change for the presenter branch either way (section 5.6).
5. **Recommended default for a game on visionOS:** in a mixed immersion the room estimate as the sole indirect light (`.realWorldEstimate`), no bundled picture, the authored lights scaled to the room's level (the example's sun at 0 for the comparison, at most 0.5 as a key light), the estimate's scale no longer multiplied by the scene's `ambientIntensity`, and a neutral fallback while no estimate has arrived. The costs are in section 5; the prefilter of one estimate took 10 to 12 ms of GPU on the M4 Max.

## 1. How the engine lights a frame on the headset

### 1.1 The modes and the store

`RuntimeEnvironmentLightingStore` (`Sources/UntoldEngine/Renderer/RuntimeEnvironmentLighting.swift`) holds the mode, `RuntimeEnvironmentLightingMode`: `.authoredOnly` (no environment term at all), `.staticIBL` (the engine's static environment, the one `hdrURL` names, under the global `applyIBL` switch), and `.realWorldEstimate` (the room probe). The mode starts as `.staticIBL`. A game sets it through `setRendering(.environment(.lightingMode(...)))`, or on the headset through `UntoldEngineXR.setXRLightingMode`; the store notifies the XR runtime, which enables or disables `XREnvironmentLightingSystem` and restarts the ARKit providers with the light estimation provider added. BedroomTwin and CoolWater select `.realWorldEstimate` in their scene set-up; the viewer selects it from its settings; the presenter example selects nothing.

Every frame the renderer resolves the environment once (`resolveCurrentEnvironmentLighting`): under `.realWorldEstimate` with a valid estimate it hands the shader the estimate's irradiance, specular and BRDF maps with `applyIBL` true and an ambient of `ambientIntensity × intensityScale × realWorldLightingContribution`; under `.staticIBL` the static maps with the global `applyIBL` and the plain `ambientIntensity`; under `.authoredOnly` the static maps with `applyIBL` false. The defaults that matter: `applyIBL` false, `ambientIntensity` 0.4, `hdrURL` `teatro_massimo_2k.hdr`, `realWorldLightingContribution` 1 (`Utils/Globals.swift`).

A detail that decides the example's picture: `applyIBL` false does not switch the static environment off. In the shader (`computeIBLParts`, `Shaders/LightShader.metal`) the branch keeps the diffuse term, the irradiance map times the base colour, and zeroes the specular term. So every scene that sets nothing is lit by the bundled picture's irradiance at 0.4, on the Mac and on the headset alike, and the render test harness notes the same ("ambient is on by default, irradiance of teatro_massimo even with applyIBL false").

### 1.2 The room estimate

`XREnvironmentLightingSystem` (`Sources/UntoldEngineXR/XREnvironmentLightingSystem.swift`, identical on `develop` and the presenter branch) takes ARKit's `EnvironmentLightEstimationProvider` (visionOS 2 and later; Apple: "a source of live data about lighting information in the environment"; the anchor "is always positioned at the location of the Vision Pro device"). Each `EnvironmentProbeAnchor` brings a cube texture (the device hands over rgba16Float, 8 texels a face, with mips) and `cameraScaleReference`, which Apple defines as "the camera scale reference of a pixel with rgb value [1,1,1] in the environment texture", there "to translate the local brightness from the current environment texture to the absolute brightness range from the camera". The system:

- accepts a probe at most every 0.5 s (`minimumProbeUpdateInterval`), keeping the newest one waiting;
- reads it back (mip 0 for the texels, the last mip for the per-face luminance and the tint: the average colour over its luminance, clamped to 0.25 to 2.5 per channel);
- turns the probe into a target and moves the shown probe towards it with a time constant of 3 s (`lightingSmoothingTimeConstant`), re-uploading a blend cube and re-prefiltering it every 0.1 s while the transition runs, so an exposure step becomes a fade;
- sets the intensity scale to `cameraScaleReference / 1000` (clamped to 64). The white point 1000 is the code's calibration "against RealityKit's lighting of the same object in the same room (a dartboard's white segments matched the passthrough's whites at a reference of 19016 with a scale of about 19)";
- prefilters (`executeXRIBLCubePreFilterPass`, `Shaders/iblPreFilterShaders.metal`): the probe's first nine spherical harmonics from 1024 Fibonacci directions, the irradiance map from them (Ramamoorthi and Hanrahan's weights, stored over pi), six specular levels of 256 by 256 (level 0 the probe itself, roughness under 0.25 by 128 importance samples, the rougher levels by the GGX lobe over the same 1024 directions), and the BRDF lookup table; the maps' directions are turned so that the probe's ceiling lights what faces up;
- publishes the set (double-buffered, A and B) with its scale and tint, and the renderer picks it up on the next resolve.

Cost: on the M4 Max one prefilter is 10 to 12 ms of GPU time (the test's reading of `executeXRIBLCubePreFilterPass`, which the quadrature at 256 by 256 over five levels dominates); on the headset it will be more and is not measured here (`XREnvironmentLightingDiagnostics.lastPrefilterDurationMs` reports it). At rest that is one prefilter every 0.5 s at most; during a transition it is ten a second for about three time constants, a frame's worth of GPU each on the headset.

### 1.3 The portal lights

`LightPortalSystem` and `LightingSystem` turn scene-channel light portals (windows) into two-sided area lights: their colour the estimate's tint when the portal asks for the real-world tint, their intensity scaled by `intensityScale × realWorldLightingContribution`, with a near-source suppression radius of 0.15 to 0.5 m. They exist only under `.realWorldEstimate` with a valid estimate; otherwise their scale is 0 and the diagnostics carry the reason. The example has no portals; the sun's light does not pass through them.

### 1.4 The authored lights

A directional light's radiance is its strength times its colour, without further scaling: a white matte surface facing it shows `strength / pi`, so the example's sun of 3 gives 0.955 on top of whatever the environment adds. `createDirLight` aims a new light straight up (elevation 90) and makes it active only when none is; the engine itself creates one at strength 1 at start-up (`UntoldRenderer.create`), which the example's sun replaces. The shader's direct term (`computeDirectLighting`, `computeBRDF` in `Shaders/ShadersUtils.metal`) is Lambert over pi plus Cook-Torrance GGX with Schlick's Fresnel and Schlick-GGX visibility (`k = alpha / 2`), both times the cascaded shadow.

### 1.5 How the model shader consumes the environment

On the forward path the headset takes, the model fragment shader folds the indirect light into the emissive attachment and adds the direct light over it (`emissiveWithIndirect`, `litWithDirect` in `Shaders/modelShader.metal`). The environment term (`computeIBLParts`):

- `NoV = min(|N · V|, 1)`: the angle to the surface whichever side is seen;
- the lookup table gives `(A, B)` at `(NoV, roughness)`; the single-bounce reflectance is `R1 = F0 · A + B`, with `F0 = mix(0.04, baseColor, metallic)`;
- diffuse = irradiance(N) × baseColor × (1 − R1) × (1 − metallic);
- specular = prefiltered(reflect(−V, N), level = roughness × 5) × R1 × (1 + F0 (1 / (A + B) − 1)), the last factor Kulla and Conty's multi-bounce compensation;
- the sum is multiplied by the resolved ambient (section 1.1).

There is no specular occlusion, no horizon fade and no ambient occlusion on this term. At grazing incidence the table's `B` rises towards the surface's grazing reflectance (about 0.4 at roughness 0.2, 1 for a mirror) and the diffuse share falls by the same amount: the term conserves energy, which is what the even-room measurement shows (section 3.2). Two more rules touch a limb: the specular anti-aliasing widens the roughness where the normal turns fast within a pixel (up to a kernel roughness of 0.18, Kaplanyan's rule), which only affects the sun's highlight; and the back-face rule, which since upstream `#1359` (`a9ceb401`) decides on the face from the position's screen derivatives, and before it decided on the interpolated normal. The presenter branch still has the old rule (it does not contain `021480a8`), together with the centroid fix of `#1389` (`27a1b85a`), which keeps the attributes inside the covered samples under MSAA.

### 1.6 The look pass

The engine's default tone map is ACES (`TonemapParams`); a `.none` operator exists, documented for a mixed-immersion space "where the passthrough sets the display's response and the compositor applies it to the scene as well" (measured on a dartboard: "whites at 87 of 255 against the room's 113 for the same object" under the filmic curve). The presenter example does not select it, so its sphere is ACES-mapped. Since `8554445e` (on the presenter branch) the look pass grades the colour over its coverage, so a partly covered rim texel is no longer graded premultiplied.

## 2. What RealityKit does on visionOS

From Apple's documentation and sessions (links at the end):

- The probe and the system light, added. WWDC23 "Explore rendering for spatial computing": "There are two main components to an IBL: an Environment probe texture that is provided by ARKit and is specific to the physical space in the room", and "The system IBL texture adds extra highlights to ensure that your content looks great in any environment. The two components are added together to produce the combined IBL texture." The probe is the same ARKit estimate the engine reads, taken at the device.
- No set-up. An Apple engineer on the developer forums: "By default, all entities with a material that responds to light, respond to environment lighting. In other words it 'just works' when you add the entity to a RealityView's content." The `VirtualEnvironmentProbeComponent` page: "In visionOS, ARKit automatically provides the environment lighting for the shared space." WWDC23 "Build great games for spatial computing": "RealityKit will sample the actual lighting in the player's room and apply that same lighting to the objects you render."
- The knobs. `EnvironmentLightingConfigurationComponent.environmentLightingWeight` (visionOS 2): 1 is the full probe, 0 none, and WWDC24 uses it to fade an object between the room's light and a portal's. `ImageBasedLightComponent` replaces the system light with the app's own, scaled by `2^intensityExponent`. Authored lights (directional, point, spot) exist and add to the probe; the example's RealityKit content has none.
- The material. `SimpleMaterial` "responds to both real and virtual lighting" with colour, roughness and metallic only, no specular or clear-coat controls; `PhysicallyBasedMaterial` is the full set. Apple describes the model as "a physically based lighting model with typical parameters such as roughness, specular, and metallic": the same family as the engine's, with Fresnel at grazing incidence as any such model has.
- Tone mapping. "Tone mapping is a transformation that RealityKit applies by default to the color output of a material" (`applyPostProcessToneMap` turns it off).

So the control sphere's body is the room's irradiance times its colour (sRGB (0.70, 0.78, 0.92), linear (0.45, 0.57, 0.83)), plus the system light's highlights, tone-mapped by RealityKit, with nothing from above but the room's ceiling: even all round, a pale grey-blue close to the wall's brightness.

## 3. The two observations, with numbers

The Mac test draws the example's sphere (white, roughness 0.2, 32 by 16 segments, radius 6 cm at (0, 1.45, −1.6)) from an eye at (0, 1.5, 0) through the presenter's frustum into its eye texture (1920 by 1824), on the forward path under 4x MSAA, and reads the resolved lit colour before the look pass: linear, the coverage in alpha. It reads the body near the top and near the bottom of the centre column, and along the bottom arc the lowest fully covered texel of every column against the texel two rows in, and the lowest partly covered texel against it.

| lighting | top | bottom (colour) | top / bottom | lowest full texel / two in | partly covered edge texel / two in |
|---|---|---|---|---|---|
| the example as the device has it: sun 3 above, bundled picture at 0.4, no reflection (face rule) | 1.343 | 0.075 (0.060, 0.076, 0.108) | 18.0 | 0.94 mean, 1.04 max | 0.97 mean, 1.35 max |
| the same with the old back-face rule (the presenter branch's) | 1.343 | 0.075 | 18.0 | 0.94 mean, 1.04 max | 2.32 mean, 9.05 max, 13 of 47 over 1.5 |
| the same, sun 0.5 | 0.627 | 0.074 | 8.4 | as above | as above |
| even room of 0.5 through the estimate path, white, no sun | 0.500 | 0.500 | 1.00 | 1.001 mean, 1.003 max | 1.004 mean, 1.007 max |
| even room of 0.5, the control sphere's colour, no sun | 0.301 | 0.302 | 1.00 | 1.078 mean, 1.123 max | 1.078 mean, 1.155 max |
| even room of 0.5, the control's colour, sun 3 | 0.787 | 0.302 | 2.6 | 1.078 mean | 1.078 mean |
| even room of 0.5, the control's colour, sun 0.5 | 0.382 | 0.302 | 1.27 | 1.078 mean | 1.078 mean |

### 3.1 The body: sunlit white top, blue-grey bottom

The bottom is the bundled picture's floor. The engine's irradiance of `teatro_massimo_2k.hdr` for a normal facing down, times the white base colour and the ambient of 0.4, measures (0.060, 0.076, 0.108) linear, luminance 0.075. ACES maps 0.075 to 0.083 and the sRGB encode to 79 of 255; without a tone map, 77. The capture read 78 just inside the sphere's bottom. The colour is the picture's: an evening sky over a square, blue, so the bottom is a blue-grey, not the room's beige. The top is the sun's 0.955 plus the picture's sky over pi at 0.4 (about (0.25, 0.37, 0.62)): 1.34, which ACES brings to about 0.86 and the display to white. Eighteen to one between the top and the bottom.

The sun at 0.5 leaves the bottom where it was (0.074) and takes the top to 0.627: the "dilution" is the contrast falling from eighteen to one to eight to one, with nothing at the bottom changed.

The RealityKit sphere has no sun and no picture: its top and bottom are the room's ceiling and the room's floor times its colour, the floor and the walls a little darker than the ceiling in a lit room, which is the even pale grey.

Which part is which. The sun is a scene choice (the example's). The blue bottom is an engine default: the bundled picture is the engine's environment on every platform unless a scene sets another or a game selects a mode, and it leaks exactly when the estimate is not on, which in the example is always. With the estimate on, the static picture is used only as the fallback while no valid estimate has been published (section 5.4). RealityKit's own choice is the probe plus the system light with no authored light, and its tone map.

### 3.2 The rim

What the environment term does at a limb. Under an even room through the estimate path (a cube of 0.5 on every face, prefiltered as the headset's probe is, published as `.realWorldEstimate` at scale 1 with the ambient at 1), the white glossy sphere reads 0.500 at the top, the centre and the bottom, and its lowest fully covered edge texels read 1.000 to 1.003 times the surface two texels in: the limb reflects the room instead of scattering it, and the two add up to the room. With the control sphere's colour the body is 0.30 (the matte value 0.28 and a touch of reflection) and the lowest full edge texel 1.08 times the surface on average, 1.12 at most: the Fresnel rim, the room reflected over the colour, a few percent. RealityKit's material has the same term, so its sphere carries the same faint rim, invisible against a body of the same brightness. There is no excess to occlude and no Fresnel to clamp.

What the specks are not. In the example no environment reflection is active (section 1.1), so a reflection of the room at the limb cannot be their source, whatever the roughness; and the room estimate's switch was a no-op, so its reading was bound to be "nothing changed". The sun's own reflection at the bottom limb is zero in the shader to its clamps (the bottom normal faces away from the sun).

What the Mac can produce. With the old back-face rule, the presenter branch's, 13 of the 47 partly covered edge texels on the bottom arc are 1.5 to 9 times the surface beside them, in the sunlit top's colour: the interpolated normal, extrapolated past the limb at the pixel centre, passes 90 degrees from the viewer and the rule turns it into the sun. With the face rule none is over 1.5 (the largest 1.35 is the plain extrapolation, which the centroid fix brings to 1.06 as the sibling measurement found). The sun at 0.5 dims those texels by the same sixth as the top, the roughness does not touch them, and the room estimate's switch cannot: every reading of the day fits this mechanism. The fully covered edge texels are never over 1.04 times the surface under either rule: the strip of turned normals is a fraction of a texel wide, and a fully covered texel's centre never lies in it.

What the Mac cannot say. The presenter branch has the centroid fix, which on the Mac removes the old rule's bright texels, and the device still showed the specks with it in force and with the edge band off. If they are fully covered texels on the device, the Mac has no mechanism for them under any of the three lighting configurations tried; what remains is the device's rendering of the rim (its foveated raster of the engine's target, the eye texture's mips and RealityKit's filtering of it, the alpha cut), which is the presenter's domain. If they are partly covered texels that the cut lets through at the display's scale, the old rule is enough. The one change that discriminates and is right regardless is the face rule on the presenter branch (section 5.6); the control reading after it is the sphere's bottom with the sun at 3 and the estimate on.

## 4. What a game on visionOS should get by default

The engine's defaults were set for a desktop scene: a bundled picture as the environment, a sun at strength 1, an ambient of 0.4, ACES. A mixed-immersion space is a different place: the room is the environment, the passthrough sets the display's response, and the object has to sit beside real things and beside RealityKit's. The default a visionOS game should get:

1. The room estimate as the sole indirect light in a mixed immersion (`.realWorldEstimate`), with no bundled picture under it and a neutral fallback until the first estimate arrives.
2. Authored lights expressed against the room's level, not against a desktop sun. A sun of 3 is ten times the room; one of 0.3 to 0.5 is a key light that reads as the room's brightest direction.
3. The estimate's scale independent of the scene's `ambientIntensity`.
4. The tone map a per-space choice, with `.none` the documented one for mixed immersion.
5. The face rule for the back-face decision (already upstream).

## 5. The remedies, with costs

### 5.1 The example and the mode (no engine change)

The example should select the estimate and set its sun against it:

```swift
// ExampleScene.start, after the sun is made (or setRendering(.environment(.lightingMode(.realWorldEstimate)))):
xr.setXRLightingMode(.realWorldEstimate)
setLight(entityId: sun, .strength(0))      // parity with the control sphere; 0.5 as the key-light option
```

and its "Room light estimate" switch should move the mode, `.realWorldEstimate` against `.staticIBL`, which is what "lit by its sun and sky alone, as on the Mac" means; the contribution factor only scales an estimate that is in use. With the estimate on, the engine sphere's body is the room times white (brighter than the control sphere's, whose colour is 0.56 in luminance; a white control, or the engine sphere in the control's colour, compares like with like), its rim the same few percent, and a sun of 0.5 lifts its top by a quarter over its bottom (the even-room row: 1.27). Cost: the provider and the prefilter (section 1.2), 10 to 12 ms of GPU per estimate on the Mac, at most two a second at rest and ten a second through a transition; `lastPrefilterDurationMs` on the device is the number to read first.

### 5.2 The engine's default mode on visionOS

Proposal: when the XR runtime starts in a mixed immersion and the game has not chosen a mode, the runtime selects `.realWorldEstimate` (one line in `initUntoldXR`, guarded by a "chosen" flag on the store, as `adoptXRRenderPathUnlessChosen` does for the render path); a full immersion keeps `.staticIBL`. Cost: the provider and the prefilter for every mixed-immersion game that sets nothing, and a behaviour change for games that relied on the picture (none known: BedroomTwin, CoolWater and the viewer select the estimate themselves). Decision D1.

### 5.3 The estimate's scale and `ambientIntensity`

The resolve multiplies the estimate by `ambientIntensity`, a scene value that defaults to 0.4 and that a scene file sets to anything. The white point of 1000 was calibrated with whatever ambient the dartboard scene had; a scene authored at an ambient of 1 shows the room two and a half times too bright, one at 0.2 half as bright. Proposal: under `.realWorldEstimate` the resolve uses `intensityScale × realWorldLightingContribution` alone and leaves `ambientIntensity` to the static environment, with the white point re-read once on the device (a white matte surface facing the ceiling against the passthrough's white). Cost: one line and one headset reading; the dartboard calibration has to be redone if its scene did not run at 0.4. Decision D2, open question Q1.

### 5.4 The fallback

Under `.realWorldEstimate` with no valid estimate (before the first probe, after a probe anchor is removed, when the prefilter fails) the resolve falls back to the static environment with the global `applyIBL`: the bundled picture's irradiance at the ambient, the blue bottom of section 3.1, for the seconds until the estimate arrives and for as long as it is missing. Proposal: the fallback is a neutral grey ambient (one value, the last published scale or a small constant), or `.authoredOnly`'s nothing, never the bundled picture; and the engine's default `hdrURL` on visionOS is empty, so that a game that sets no environment is not lit by a square in Palermo. Cost: none at run time; a behaviour change for visionOS scenes that showed the picture's irradiance without knowing. Decision D3.

### 5.5 Specular occlusion, horizon fade, a Fresnel clamp

Not recommended. The term conserves energy at the limb (section 3.2); a clamp or an occlusion would make the engine's glossy objects darker at their edges than RealityKit's beside them. Horizon fade and AO-driven specular occlusion have their uses for concave geometry under a bright sky, and would be an option with a cost of a few instructions per fragment, but they are not what the day's observation asks for.

### 5.6 The face rule on the presenter branch

The presenter branch should take the face rule of `#1359`: cherry-pick `a9ceb401` (`bugfix/backface_flip_face_normal`) and rebuild the kernels, or merge upstream `develop`, which brings it with everything since `#1367`. It removes the only limb-brightening mechanism the Mac shows, and it is the rule the engine ships. The headset reading after it: the sphere's bottom with the sun at 3 and the estimate on, beside the control sphere; specks gone closes the thread, specks remaining hands it to the presenter's raster (section 3.2).

### 5.7 The tone map in mixed immersion

The example should try `.none` (`setRendering(.tonemapOperator(.none))`), which the engine documents for mixed immersion from the dartboard measurement, against ACES, with the control sphere beside: RealityKit tone-maps its content by default, so the two whites will not agree under both; which one agrees is a headset reading. Open question Q2.

### 5.8 What was not built

No shader or runtime change was made: the only small change that was clearly right (the face rule) already exists upstream and belongs to the presenter branch's next merge, and the others (5.2 to 5.4) change defaults, which is the user's call. The render test is committed on `test/xr_lighting_parity_limb` as the guard for sections 3.1 and 3.2: the example's lighting as the device has it (the top the sun's, the bottom the picture's floor, no fully or partly covered edge texel over 1.5 times the surface), the weaker sun's shares, the white furnace under an even room (the body at the room's radiance, the limb within 12 % of it), and the coloured sphere's rim (2 to 25 % over the body) with the sun's contrast over the room.

## 6. Decisions

- D1. Default mode on visionOS in a mixed immersion: `.realWorldEstimate` unless the game chose. Proposed, not decided.
- D2. The estimate's scale without `ambientIntensity`. Proposed, not decided.
- D3. The fallback under `.realWorldEstimate` and the default `hdrURL` on visionOS. Proposed, not decided.
- D4. The example sets the estimate and a sun of 0 (0.5 as an option), its switch moves the mode. Recommended to the presenter session.
- D5. No specular occlusion or Fresnel clamp. Decided by the measurement.
- D6. The face rule onto the presenter branch. Recommended; the device decides whether it closes the specks.

## 7. Open questions

- Q1. At what `ambientIntensity` was the white point of 1000 calibrated (the dartboard scene)? If not 0.4, the calibration and the proposal of 5.3 need one headset reading each.
- Q2. ACES or `.none` for a mixed-immersion space beside RealityKit content: the control sphere's whites against the engine sphere's under both.
- Q3. The prefilter's cost on the device (`lastPrefilterDurationMs`), and whether the transition's 0.1 s step should lengthen or the quadrature shrink for the rougher levels.
- Q4. If the specks survive the face rule and the estimate on the device: are they fully covered texels of the eye texture (read the texture, not the display), and what of the presenter's raster makes them?

## Sources

- Apple, `EnvironmentProbeAnchor` and `cameraScaleReference` (ARKit, visionOS 2): https://developer.apple.com/documentation/arkit/environmentprobeanchor
- Apple, `EnvironmentLightEstimationProvider`: https://developer.apple.com/documentation/arkit/environmentlightestimationprovider
- Apple, `VirtualEnvironmentProbeComponent` ("In visionOS, ARKit automatically provides the environment lighting for the shared space"): https://developer.apple.com/documentation/realitykit/virtualenvironmentprobecomponent
- Apple, `EnvironmentLightingConfigurationComponent`: https://developer.apple.com/documentation/realitykit/environmentlightingconfigurationcomponent
- Apple, `ImageBasedLightComponent.intensityExponent`: https://developer.apple.com/documentation/realitykit/imagebasedlightcomponent/intensityexponent
- Apple, `SimpleMaterial`: https://developer.apple.com/documentation/realitykit/simplematerial
- WWDC23 10095, Explore rendering for spatial computing: https://developer.apple.com/videos/play/wwdc2023/10095/
- WWDC23 10096, Build great games for spatial computing: https://developer.apple.com/videos/play/wwdc2023/10096/
- WWDC24 10103, Discover RealityKit APIs for iOS, macOS and visionOS: https://developer.apple.com/videos/play/wwdc2024/10103/
- Apple Developer Forums, thread 774882 (an Apple engineer on lit materials responding to environment lighting by default): https://developer.apple.com/forums/thread/774882
