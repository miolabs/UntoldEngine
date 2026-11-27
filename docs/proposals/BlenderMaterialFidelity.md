# Blender Material Fidelity — Plan

Status: plan, stages 1 and 2 in progress. Written 2026-10-03. Companion to [LargeSceneRendering.md](LargeSceneRendering.md): the same BIM site, the other half of the problem (what it looks like, not how fast it draws).

Question: how do materials built in Blender look in the engine the way they look in Blender, when the source file cannot be edited (no hand baking, no reworked node graphs).

## TL;DR

Measured on the two files this work started from, with the exporter of #1284:

| | BIM site (`…T008.blend`) | Building (`EDIFICIO_COMPLETO_BLOCKING.blend`) |
|---|---|---|
| Materials in use | 309 | 60 |
| Exported exactly | 159 | 56 |
| Lose something | 150 | 4 |

What is lost falls into three groups, which are the three stages of this plan:

1. **Procedural patterns** (cook): noise, bricks, cells and node math drive a Principled input with no image behind it. The exporter writes the socket's stale slider value instead. 87 materials of the BIM site.
2. **Shading the engine does not have** (engine): clear coat (car paint), glass, leaf translucency, anisotropy. Two gaps found on the way: non-metals get no environment reflection, and emissive textures are loaded but never drawn.
3. **View-dependent nodes** (cook + engine): Layer Weight and Fresnel driving a colour. One material in each file.

Stage 1a is built and measured (section 3). An audit of the building against Blender's own render (section 4) found that most of what looked wrong there was not missing features but **eight defects in how the engine shades and loads materials**, and three in the exporter. All eleven are fixed on two branches, with tests; they are the first part of stage 2.

Result of 1a on the BIM site: 87 materials baked in about 2 minutes of a cook that now takes 8 min 47 s (was 6 min 37 s); 62 of them get repeating textures, 16 a value. Blender's own render and a render of the cooked files match for the brick façades, the solar panels, the ducts and the wood furniture.

## 1. What is lost, measured

A read-only Blender scan (the exporter's own `filter_scene_objects_for_export` and `analyze_material`, weighted by how many exported objects use each material) on 2026-10-03.

BIM site, by what the node graph uses ("uses" = objects × materials):

| Lost | Materials | Uses |
|---|---|---|
| Noise Texture | 90 | 5,514 |
| Math / Mix / Map Range on top | 26–43 each | 4,500–5,100 |
| Object or world-position coordinates (no UV map involved) | 56 + 25 | 4,346 + 4,776 |
| Glass (transmission written as a see-through surface) | 30 | 2,900 |
| Voronoi, White Noise, Brick | 8, 2, 6 | 1,464, 1,411, 112 |
| Leaf subsurface | 13 | 4,041 |
| Clear coat | 32 | 1,930 |
| Anisotropy | 3 | 1,172 |
| Thin film | 1 | 144 |

How the 149 non-exact materials of the BIM site are built:

- 69 materials (7,430 uses): procedural textures on **object coordinates or world positions**, no image. 31 of them also read the surface normal (dirt on top faces, bricks that turn with the wall).
- 27 materials (2,930 uses): only the Principled BSDF itself is approximated (glass).
- 51 materials (440 uses): patterns on UV or generated coordinates, image textures mixed with node math, the tree.
- 8,756 of the 10,976 uses are on **meshes with no UV map**: a classic bake into each mesh's UVs is not possible, and unwrapping 4,583 distinct models would need thousands of textures.

What the exporter writes for a linked input with no image today: the value `evaluate_socket_facing` can compute from constants, otherwise the socket's own slider, which Blender ignores once the socket is linked. Solar cells export as the default grey, galvanised steel as a non-metal.

The building loses little: METAL.001 (Layer Weight, already exported as seen straight on), two glass materials, one steel with coat, sheen and a Tangent node.

Not lost in either file: instancers, hair, object types the exporter does not convert, lights and cameras (written to their own chunks).

## 2. What the engine has today (upstream develop, 2026-10-03)

- **Opaque shading is deferred.** `fragmentModelShader` fills a G-buffer (albedo, world normal, world position, material = roughness/metallic/two debug channels, emissive); `fragmentLightShaderTBDR` lights it (`Shaders/modelShader.metal`, `Shaders/LightShader.metal`). The BRDF is `computeBRDF` in `Shaders/ShadersUtils.metal`: GGX, Smith-Schlick, Schlick Fresnel with `f0 = mix(0.04, albedo, metallic)`, Lambert diffuse.
- **Material fields with no shader behind them.** `MaterialParametersUniform` (`CShaderTypes/ShaderTypes.h`) carries `specular`, `specularTint`, `subsurface`, `anisotropic`, `sheen`, `sheenTint`, `clearCoat`, `clearCoatGloss`, `ior`. Swift fills them on every draw; no `.metal` file reads them. `Material(runtimeMaterial:)` (the `.untold` path) never sets them.
- **Non-metals get no environment reflection.** `computeIBLContribution` ends with `ambient = mix(diffuse, specular, metallic)`: at metallic 0 the specular image-based lighting is dropped altogether. Fixed on `bugfix/material_shading` (section 4).
- **Emissive textures are loaded and never drawn.** The G-buffer's emissive target takes the material's constant factor only; no pass binds the texture. Fixed on the same branch, with six more defects the audit found.
- **The environment lights the scene at its own exposure.** `calibratedIBLHalfData` scales the map that lights the scene so that its average brightness is 0.35 (1.36 times for the default `teatro_massimo` map, 8 times for the night map), while the background shows the map as it is. `ambientIntensity` (0.4 by default) scales it again. A scene lit by a Blender world at strength 1 is therefore not lit the same; to compare, the audit used `ambientIntensity = 1 / 1.356`.
- **No occlusion of the environment light.** SSAO is off in the tile-based path, and nothing else shades the inside of a box: the inside of an oven or of a vending machine, seen through its glass, is as bright as its outside.
- **The picture is developed differently.** Against Blender's Standard view transform the engine shows the same environment map about 1.5 times brighter in the middle tones (measured on the pavement behind the test spheres) and compresses the highlights instead of clipping them: a saturated emissive orange or lavender comes out paler, a white surface in the sun a light gray. A material that matches Blender's therefore still looks brighter and flatter in the engine's frame.
- **Transparency** is a forward pass over the lit image: same BRDF and lights, premultiplied alpha, sorted per entity. No refraction, no transmission, no copy of the scene colour.
- **The `.untold` material record** (108 bytes, format 4) has `flags` (only the two alpha-mode bits are read) and a second reserved word that is always 0. The reader takes the record size from the format version, so new fields need either the reserved word or format 5.
- **Vertex colours and the second UV map** are in the file but dropped at GPU upload.
- **Material samplers repeat**, with mipmaps and 16× anisotropy: a tiling texture needs nothing new.
- **Shaders ship as prebuilt metallibs** (`buildkernels.sh`), one per platform: every shader change rebuilds them.
- **In XR both eyes shade from the head centre**; #1285 (draft) gives each eye its own position.

## 3. Stage 1 — procedural patterns in the cook

Goal: a material built from procedural nodes looks in the engine like it does in Blender, on meshes with or without UVs, without giving up the sharing of repeated models (#1288, #1290).

### 1a. Swatch bake and projected UVs (built, see Progress)

The cook bakes each such material once, with Cycles, on a flat **swatch**: what the material shows on a plane, cut so that it repeats. Every mesh that uses the material gets texture coordinates **projected from its positions**. One texture set per material then serves every mesh.

- **Which inputs:** Base Color, Roughness, Metallic and Normal, when linked with no image texture behind them. An input that turns out to be one value all over (node math on constants) is written as that value, which replaces the stale slider.
- **Which materials get textures:** those whose pattern is laid out by object coordinates or world positions. Anything else (UV, generated or camera coordinates, images in the same material) keeps its UVs and takes the swatch's average.
- **Which way the swatch faces:** the way most of the material's surface faces, in the object or in the world depending on what the graph reads. A brick material written for walls is baked on a wall.
- **The tile:** a coarse bake finds how long a tile to cut. A pattern with a period (bricks, solar cells, paving) is cut at a whole number of periods, found from the pattern's edges so that bricks of random colours still count; a pattern with none (noise) is cut at 2 m. A band along the cut fades into the pixels that continue the far edge, keeping contrast.
- **Size:** each image is baked at the size its detail needs, up to 1024 texels, and halved while that does not change it.
- **Projection:** a flat face is mapped in its own plane, without stretch: level faces by (x, y), walls level along the wall and up. Smooth surfaces are mapped along the nearest axis. Whole repeats are taken off face by face, because UVs are stored as half floats.
- **World-laid patterns:** a mesh placed once is mapped from its world positions, exactly as in Blender, so bricks run on from one wall to the next. Copies of one mesh share one mapping in their own space, at the pattern's world size, so they remain one model.

Options: `--no-material-bake`, `--material-bake-size`, `--material-bake-tile`. On by default in the command-line export, which the editor's Cook runs. The tile pipeline and the Blender add-on's export do not bake yet (1f).

Measured on the BIM site (2026-10-03, this Mac):

| | Before | With the bake |
|---|---|---|
| Cook time | 6 min 37 s | 8 min 47 s (bake: 119 s for 87 materials) |
| Model files | 4,583 | 4,778 |
| Materials with a stale slider instead of their pattern | 87 | 9 (bump too faint to keep, or a pattern on UVs with only a normal to bake) |
| Baked textures | — | 114: 58 at 1024, 40 at 64, 16 in between; 130 MB of PNG |
| Texture memory, uncompressed with mipmaps | — | about 317 MB (ASTC through `--optimize` takes it to a fraction) |

Of the 87: 62 get repeating textures, 16 a value only, 8 tiles are cut at a period (bricks, roof tiles, paving, solar cells).

How it was checked:

- Unit tests for the tiling and the projection (240 exporter tests), and nine checks that run in Blender: a wall's own material baked through the projected UVs is the tile the bake wrote, for bricks and for noise, in object and in world space.
- Side-by-side renders, Cycles in Blender against a Cycles render of the cooked `.untold` files with their textures, same camera and light: a clinker brick wall, a solar panel, a duct, a wood cabinet and a brick façade of 67,000 faces. Brick size, bond and position, the cells' grid on the panel, the duct's panel joints and the wood grain's direction all match.
  Three of the pairs, Blender on the left: [stage1a_blender_left_cooked_right.png](BlenderMaterialFidelity/stage1a_blender_left_cooked_right.png).
- A scratch engine render test drew three of the cooked models (brick wall, solar panel, duct) with the textures in place.

Known approximations, each a later item:

- One swatch per material: faces that look another way show the same pattern (bricks on a wall's top, no dirt gradient between top and sides).
- A 3D pattern is sampled on one plane through the origin.
- The tile repeats (every 1–2 m).
- Edge wear from Pointiness and anything else that needs the real geometry is not there on a swatch.

### 1b. One swatch per facing

For materials that read the normal or lay a flat pattern out in space (31 + the brick materials): bake top, side and underside, and split the mesh's faces between them. Costs up to three draws for those meshes, so only where the swatches really differ.

### 1c. Patterns on UV and generated coordinates

About 20 materials. UV: bake the pattern over the 0–1 square and keep the mesh's UVs. Generated: project by position inside each mesh's bounding box. Today these take the average.

### 1d. Images mixed with procedural nodes

28 materials (88 uses): a label image under a noise roughness, for example. Needs a bake into the mesh's own UVs, per mesh. Small in these files; later.

### 1e. Emission and alpha

Procedural emission and alpha are left as they are. Emission also needs 2b.

### 1f. The tile pipeline and the Blender add-on

`export-tiles` exports a scene in many pieces through the same extraction: the bake has to run once for the whole scene before it is partitioned, so a pattern continues across tiles. The add-on's export runs inside an interactive Blender, where the bake has not been tried. Both are off until done.

### 1g. Bump to normal map

A Bump node, or a Displacement under Blender's default "Bump Only" setting, shades a relief and moves nothing. The cook should turn that height into a normal map (merged with the material's own, if it has one) at the texel size the mesh gives it. Today a shallow height exports as parallax depth and a deep one is left out (section 4.1, defect 10): three materials in the building.

## 4. Stage 2 — shading the engine does not have

### 4.1 The audit: Blender against the engine, object by object (done)

Method. Nine objects of the building and four test spheres (mirror, rough metal, matte white, black lacquer), each rendered alone twice: by Cycles in Blender, and by the engine from the cooked `.untold`, with the same camera, the same environment map (`teatro_massimo_2k.hdr`, Blender's lookup turned 90° about Z to match) and the same sun (strength 3). The engine side is a render test that reads the cameras Blender wrote, with `ambientIntensity` set to take the engine's exposure scale back out (section 2). Three columns below: Blender, the engine before (upstream develop), and after (the engine fixes, and for the building a cook with the exporter fixes too).

- Spheres: [stage2_spheres_blender_before_after.png](BlenderMaterialFidelity/stage2_spheres_blender_before_after.png)
- Building: [1](BlenderMaterialFidelity/stage2_building1_blender_before_after.png) (ovens, sign, vending machines), [2](BlenderMaterialFidelity/stage2_building2_blender_before_after.png) (kiosk, screen, plant), [3](BlenderMaterialFidelity/stage2_building3_blender_before_after.png) (chair, cooktop, jar)
- Roughness from 0.05 to 1 on metal, white, red and black, engine before and after: [stage2_roughness_sweep_before_after.png](BlenderMaterialFidelity/stage2_roughness_sweep_before_after.png)
- The two pull requests as opened (#1292, #1293): [pull_request_drafts.md](BlenderMaterialFidelity/pull_request_drafts.md). Their images (`material_shading_*.jpg`, `blender_export_glass_and_bump.jpg`) are on the fork's `docs/proposal_drafts` branch.

What it found in the engine, all fixed in #1292 (`bugfix/material_shading`: eight commits, each with render tests that fail without it):

| # | Defect | What it did | Seen on |
|---|---|---|---|
| 1 | A normal map stored as RGB was normalised before the remap to [-1, 1] | Every normal tilted about 22°; a flat map lit a face a third brighter | Every material with a PNG or JPEG normal map |
| 2 | The material's normal strength was read from the file and never used | A map meant at 10 % or 50 % applied in full | Brushed metal (0.5, 265 uses), glass (0.1) |
| 3 | A base colour of black counted as "not set" and was drawn white | Black objects came out white | The oven, the black lacquer sphere |
| 4 | Emissive textures were loaded and never bound; blended materials gave off no light at all | A lit sign showed a flat colour; lit see-through panels were unlit | The sign, the kiosk's windows |
| 5 | The sampler that reads the environment's roughness levels had no mip filter | Every surface reflected the sharpest level: rough metal looked like chrome | Every metal |
| 6 | The table of how much a surface reflects was written with its roughness rows upside down | Polished metal reflected 36 % of the environment, rough metal all of it | Every metal |
| 7 | Non-metals reflected none of the environment, and the reflection took the Fresnel value at the view angle where the table expects the value head on. A surface seen from behind counted as seen edge on | Polished plastic, lacquer and glass were matte; a black one was unlit | Every non-metal |
| 8 | A grayscale colour texture was loaded through a MetalKit call that ignores the sRGB option | A grey base colour was read as linear values, 2.3 times too bright | Brushed metal's base colour (265 uses) |

With 6 fixed, a rough metal would lose the light it bounces more than once (the table counts one bounce): the roughest white metal gave back a third. The same branch adds the later bounces back (Kulla and Conty's approximation, as Filament applies it), so a white surface of any roughness, metal or not, gives back all the light of an even environment. That is what the tests check: they light a sphere with an environment of one brightness and compare it with a matte white one.

Also on that branch: the emissive colour and texture, and the normal strength, are now part of what tells two materials apart for batching.

What it found in the exporter, fixed in #1293 (`bugfix/blend_tinted_glass`):

| # | Defect | What it did | Seen on |
|---|---|---|---|
| 9 | Every transmissive material kept 10 % opacity, whatever its colour, metal or roughness | Black tempered glass, a black mirror in Blender, came out as clear as a window. In the BIM site, the 60 cars carry a stray Transmission of 1 on all 20 of their materials (paint, chrome, tyres, plastics: 4,300 uses) and came out all but invisible | The oven doors; the cars of the BIM site |
| 10 | A Displacement Scale or Bump Distance left at Blender's default of 1 was carried over as the depth of parallax mapping | The texture smeared across the surface | The chairs (5), the banana plants (3) |
| 11 | `--output scene.untoldpack` wrote the pack, then removed it as a stale single-file export | The export reported success and left no manifest | Found while cooking for the audit |

What still differs after the fixes, and why:

- **Glass.** The opacity now follows what is seen through the surface (transmission × not metal × brightness of the base colour × not rough): the BIM site's window glass comes out 17 % opaque, its tinted car windows 77 %, frosted U-glass 36 %, black glass and metals opaque. But a blended surface still scales its reflections and its glow by its opacity, and is lit as a diffuse surface of its colour, so clear glass shows a sixth of its reflections and tinted glass looks painted. Needs 2d.
- **Inside of things seen through glass** is too bright (no occlusion, section 2): the enamel inside the oven reflects the sky as if the oven had no walls.
- **Bright saturated colours** are paler (tone curve), and everything lit by the environment is 1.36 times brighter than in Blender unless `ambientIntensity` takes the exposure scale back out (section 2).
- **Bump relief** from a Bump node or a "Bump Only" Displacement is not exported when its height is too deep for parallax (10). Turning it into a normal map is a cook item (1g).
- **Rough metals under a lamp** are darker than in Blender: the later bounces are added for the environment only, not for direct lights (2g).
- **Coat** (the oven's steel and enamel) and **Layer Weight** are stages 2c and 3.

### 4.2 Features

Each item is an engine pull request with the exporter writing the values it needs. Order by what the two files show.

- **2a. Environment reflection on non-metals.** Done in 4.1 (defect 7). It changes the look of every scene lit by an environment: a non-metal gains a reflection of 4 % head on, more at a slant, and gives up the same share of its diffuse light.
- **2b. Emissive textures.** Done in 4.1 (defect 4).
- **2c. Clear coat** (32 materials, 1,930 uses: the cars). A second specular lobe over the base: coat weight and roughness in the material record, one more G-buffer channel pair (the material target has two debug-only channels).
- **2d. Glass** (30 materials, 2,900 uses). Built (see Progress). A material has a transmission, from 0 to 1: Blender's Transmission Weight, written in the free word of the material record (no new format version; a file without it reads as no transmission). The transparency pass draws such a material with its reflections and its glow whole and none of the light that falls on it scattered, and filters what is behind it by the base colour, each of red, green and blue on its own (blending with two sources, with premultiplied alpha as the fallback). What was learnt building it:
  - Blender tints by the square root of the base colour at each face of a pane (measured in Cycles: a gray of 0.25 lets 0.50 through one plane and 0.25 through a thin box), so that a pane shows its base colour. The engine does the same.
  - What glass reflects it does not let through, by the same lookup table the reflections use: in an even light a clear glass sphere is not to be seen (the test holds to 0.07 %).
  - Nothing is bent or blurred behind glass. Rough glass shows less of what is behind it (all of it up to a roughness of 0.05, none from 0.5) and glows with the light that comes from behind it: the environment straight through the glass, blurred, and the sun on the far side. A film lit from the front, the first attempt, made a frosted window white where Blender shows it gray. The glow reads the environment and not the scene, so an object right behind frosted glass does not show in it. Refraction and blur from a copy of the scene colour stay for later.
  - A surface through which next to nothing would show (under 5 %: dark, metal or rough) is exported solid, and the engine keeps a fully metal or frosted one solid by itself: it keeps its depth, its shadow and its batch. On the BIM site the cars' seventeen paints, chromes, tyres and plastics with a stray Transmission of 1 come out solid this way (they were blended, and drawn without depth: a wheel showed its brake through its tyre), and the cars' windows and about a thousand window panes as glass.
  - The triangles of a mesh are drawn in the order they come: the far side of a frosted or dark pane came out over its near side. Glass is drawn in two goes, far faces then near faces, each lit on the side the viewer sees.
  - See-through surfaces cast full shadows in this engine (the shadow passes draw every submesh). Glass is now left out of them, so the sun reaches what is behind a window; a blended material still casts the shadow of a solid one.
  - Glass writes no depth and is not batched, like the blended materials.
- **2e. Leaves** (13 materials, 4,041 uses, plus the tree). Light through the leaf: a wrap term and back lighting from the subsurface weight and colour.
- **2f. Anisotropy** (3 materials, 1,172 uses: brushed aluminium). Needs tangents in the G-buffer; last.
- **2g. Later bounces for direct lights.** The reflection table is at hand in the light pass: one lookup per pixel scales the highlights of every lamp the way 4.1 scales the environment's. Up to three times brighter highlights on the roughest metals, so it needs the maintainers' eye.

Format: coat, transmission and subsurface need new material fields. One reserved word is free in format 4; more than that means format 5, which the reader must then accept alongside 4.

## 5. Stage 3 — view-dependent nodes at run time

Layer Weight and Fresnel feeding a colour or a roughness (METAL.001, the tree's leaves). Today the cook exports what the surface shows straight on. To follow the view: the cook evaluates the graph at several view angles and writes a small table per material; the shader looks it up by the angle between normal and view, per pixel, and per eye in XR once #1285 is in. Low priority: two materials.

## 6. Decisions

- D1. Bake on by default (cost: a few seconds per material at cook time) or opt-in.
- D2. Default texture size: 1024 (about 2 mm per texel on a 2 m tile) or 512.
- D3. Copies of a mesh with a world-laid pattern: share one mapping (as built) or keep Blender's exact mapping and give up the sharing.
- D4. Stage 2 order after the audit: glass (2d) or clear coat (2c) first. **Decided 2026-10-03: glass first.**
- D5. Material record: reserved word or format 5.
- D6. Decided 2026-10-03: the engine fixes are one pull request (#1292), with the comparison images in its description.
- D7. Height that is not a parallax depth (defect 10): leave out above a scale of 0.2, as built, or leave out whenever Blender itself only shades it (every Bump node, every "Bump Only" Displacement). The second is closer to Blender and takes parallax away from materials that have it today.
- D8. Whether the engine should light with the environment at the exposure of the picture (section 2), or the exporter should write the scale that undoes it.

**D9 (decided 2026-10-07): the sky and the sun belong to the scene, not to a cooked file.** A cook never writes a world, a sky or a sun into the scene: several files imported into one scene would each bring their own. Blender's world is at most an asset to offer through an explicit action (render a procedural sky or copy an HDR into the project's HDR folder, report the sun's height and direction), and the user assigns it to the scene or not. The editor's scene environment and its Directional Light stay the single source.


## 7. Progress

| Item | State |
|---|---|
| #1284 — colour nodes, transparency, glass approximation | Merged (2026-10-03) |
| #1288 — repeated pack models written once | Merged (2026-10-03) |
| #1285 — per-eye shading in XR | Merged 2026-10-10 after the Vision Pro check (reflections painted on without it, at their depth with it) |
| 1a. Swatch bake and projected UVs | Merged: #1307 (2026-10-07, `e8ed7ad4`). 267 exporter tests, 9 checks in Blender, the site cooks with it |
| 1b–1g | Planned |
| 4.1 Audit: eight engine defects | Merged: #1292 (2026-10-03) |
| 4.1 Audit: three exporter defects | Merged: #1293 (2026-10-04), after two rounds of review fixes |
| 2a, 2b | Done with the audit |
| 2d-b. Glass against its frame and in a headset | In review: untoldengine/UntoldEngine#1331 (opened 2026-10-10, `eef96d17`): depth bias for glass draws, the seen side from the face, the shading normal facing the viewer, depth written in a headset by `Material.paneShowsItself`; 2 new glass tests, image on `docs/proposal_drafts` |
| 2i. Object-linked material slots | Built 2026-10-07: a split multi-material object exported the mesh's default material, not the object's slot (771 overrides in the site, the chairs' red seats); Merged: #1320 (2026-10-08; Harold's comment answered with `53fa93d3`: one slot lookup, `_slot_material`), 4 Blender checks, comparison image on `docs/proposal_drafts` |
| 2d. Glass | Merged: #1308 (2026-10-07, `da580ee2`, approved by Harold; merged after #1307 without a rebase, and the merged exporter is right: 270 tests, the 7 + 9 Blender checks and upstream CI pass on develop). Tried by eye on the site in a try-out editor (2026-10-03) |
| 2c, 2e–2g | Planned |
| Stage 3 | Planned |
| Fork | Engine fork synced with upstream on 2026-10-10 (miolabs/UntoldEngine#72, develop `100434f3`): it has everything merged above, the slot fix and the per-eye shading included; the editor and arcade forks synced the same day |
