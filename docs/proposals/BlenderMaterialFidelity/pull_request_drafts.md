# Pull requests as opened

Opened upstream on 2026-10-03, after #1284 merged. Both branches sit on upstream `develop`.

- Engine: untoldengine/UntoldEngine#1292, `bugfix/material_shading`, nine commits.
- Exporter: untoldengine/UntoldEngine#1293, `bugfix/blend_tinted_glass`, three commits.

The images are in this folder (`material_shading_*.jpg`, `blender_export_glass_and_bump.jpg`). The pull requests read them from the fork's `docs/proposal_drafts` branch.

---

# Engine

**Title:** [Bugfix] Shade materials the way their values say: normal maps, emission, reflections

## Summary

A building exported from Blender looked wrong in the engine in ways that were not missing features. Rendering each object alone in Blender (Cycles) and in the engine, with the same camera, environment map and sun, turned up eight defects in how materials are shaded and loaded. Each is fixed in its own commit, with render tests that fail without it. The last commit holds the rebuilt shader libraries and the reference images that change.

## Before and after

Blender on the left, `develop` in the middle, this branch on the right. Same cooked files in both engine columns.

Four test spheres: mirror, rough metal, matte white, black lacquer.

![Test spheres: Blender, engine before, engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/material_shading_spheres.jpg)

Roughness from 0.05 to 1, left to right, on a metal and on white, red and black non-metals, under two environment maps. Before, every metal is a mirror, the polished ones are the darkest, and no non-metal reflects anything.

![Roughness sweep: engine before, engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/material_shading_roughness.jpg)

Objects of the building. The ovens are black enamel (drawn white), the vending machines and the kiosk are brushed metal (drawn as chrome), the kiosk's windows glow.

![Building objects 1: Blender, engine before, engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/material_shading_building_1.jpg)

![Building objects 2: Blender, engine before, engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/material_shading_building_2.jpg)

What still differs in these pictures is not in this pull request: glass (the engine has no transmission), the inside of the ovens and of the vending machines seen through their glass (nothing occludes the environment light), and the frame as a whole, which the engine develops brighter than Blender's Standard view.

## Cause and change, by commit

1. **Normal maps were tilted, and the normal strength was not applied.** A normal stored as RGB was normalized before the remap from [0, 1] to [-1, 1], which shortens it first: a flat texel came out 22° off. `normalScale`, which a `.untold` material carries (Blender's Normal Map Strength), was read and never used. The remap now comes first, and `applyNormalStrength` mixes the map with the surface's own normal. `normalScale` is part of the batching hash.
2. **A black base color was drawn white.** A base color factor of zero counted as "not set". It now does only for a textured material.
3. **Emissive textures were never drawn, and blended materials gave off no light.** The texture was loaded and no pass bound it; the transparency pass added no emission. Both passes now draw the factor times the texture. A material read from a USD file, which has the texture and no factor, gets a white factor. The emissive color and texture are part of the batching hash.
4. **Rough surfaces reflected the environment as sharply as a mirror.** The environment map is filtered once per roughness into its mip levels, and the sampler that reads it had `mip_filter::none`, so level 0 was always read. The environment has its own sampler now; the lookup table keeps the clamped one.
5. **The reflection table was read upside down.** It was written with roughness = 1 − row and read with row = roughness. A polished metal took the share of a rough one (36 % of the environment) and the reverse. The table is now written the way it is read, in the equirect bake and in the XR probe's.
6. **A rough metal keeps the light it bounces more than once.** With 5 fixed, the table's single bounce makes the roughest white metal give back a third of the light. The later bounces are added back (Kulla and Conty's approximation, as Filament applies it), which also keeps rough metals as bright as they have been.
7. **Non-metals did not reflect the environment.** The ambient term was `mix(diffuse, specular, metallic)`. Every surface now reflects (4 % head on for a non-metal, more at a slant, whichever side is seen) and its diffuse part gives up that share, so a white surface gives back all the light of an even environment whatever its finish. The reflection takes F0, as the table expects, not the Fresnel value at the angle of view.
8. **A grayscale color texture was read as linear.** The engine expands a one-channel image to RGBA before loading it, through `MTKTextureLoader.newTexture(cgImage:)`, which ignores `.SRGB`. A mid gray came out 2.3 times as bright as the same gray in three channels. The expanded texture is now an sRGB view; the loader and the texture streaming system share one function for it.

## What changes on screen

- Scenes lit by an environment: polished metals are brighter, rough metals blurred, non-metals gain a reflection. Twelve reference images are regenerated for this: `BRDFIBL`, `LightPassColor`, `DisplacementMap`, `TransparencyTarget`, `Bloom`, `ChromaticAberration`, `ColorGrading`, `DepthOfField`, `FXAA`, `MSAA`, `SMAA`, `Vignette`.
- Materials with a normal map: the relief is as authored, not leaning.

## Verification

- 25 new render tests: `NormalMapShadingTests` (3), `BaseColorShadingTests` (6), `EmissiveShadingTests` (5), `EnvironmentReflectionShadingTests` (9), and two in `StaticBatchingTest`. The reflection tests light a sphere with an environment of one brightness, so the expected values are exact: a white surface of any finish must give back what a matte white one does.
- The render sweep of the CI job, run locally: 1,155 tests, none failed. `UntoldEngineTests` (1,533), `UntoldComponentKitTests` (59) and the remote stream flythrough pass.
- `swift build` with `-strict-concurrency=complete`: no warnings.
- The shader libraries are built with `buildkernels.sh`.

---

# Exporter

**Title:** [Bugfix] Export glass, and Blender's default bump heights, as they look

## Summary

Three defects in the Blender exporter, found by rendering a building's objects in Blender and in the engine side by side. They follow #1284.

## Before and after

Blender on the left, then the engine drawing the export before and after this pull request. Both engine columns use the shading fixes of #1292, so that the chair's leather and the black glass are judged by what the export says and not by the bugs fixed there.

The chair's Displacement and the plant's Bump were smeared across them as parallax (3). The oven door's frame is black tempered glass (1).

![Chair, plant and oven: Blender, export before, export after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/blender_export_glass_and_bump.jpg)

## Cause and change, by commit

1. **Every transmissive material came out 10 % opaque.** In Blender three things take from what is seen through a transmissive Principled BSDF. The base color tints the light that crosses it: black tempered glass lets none through and is a black mirror, and it was exported as clear as a window. Blender lays the metal over the glass, so a metal lets nothing through whatever its transmission says. A rough surface scatters what crosses it. A scene with 60 imported cars, whose materials all carry a Transmission of 1 (paint, chrome, tyres, plastics: 4,300 objects), came out with the cars all but invisible. The opacity now follows what is seen through the surface: transmission, times what is not metal, times the brightness of the base color, times what is not rough. Clear polished glass keeps 10 %; black glass, metals and fully rough surfaces are opaque. Values that come from a texture count as clear, as no metal and as polished. The material fidelity report says when glass is exported opaque.
2. **`--output scene.untoldpack` removed the pack it wrote.** A scene with several models is written as a `.untoldpack` next to where the single `.untold` would be, and whatever `--output` names is then removed as a stale single-file export. Given the pack's own name, the exporter wrote the manifest, removed it and reported success. An output path that ends in `.untoldpack` now stands for the `.untold` of the same name.
3. **A height left at Blender's default was exported as a parallax depth of 1.** A Displacement Scale and a Bump Distance default to 1, a metre, and under the default "Bump Only" displacement Blender draws the shading of a bump from them. The engine's depth is a share of the texture's width: at 1 the parallax smears the texture across the surface. A height with a Scale or Distance above 0.2 is now left out, and the fidelity report says so. Smaller values export as before.

## Verification

- `make testexporter`: 210 pass (11 new). The two pack tests fail without the fix.
- On the building: `TEMPERED GLASS` (black, transmission 1) exports opaque; `West_Elm_tex` (Displacement Scale 1) and `Plant_Banan` (Bump Distance 1) export without a height texture and are listed in the report; `Brushed used metal silver` (Scale 0.004) keeps its height. Cooking with `--output EDIFICIO.untoldpack` leaves the pack in place.
- On the site with the cars: window glass exports 17 % opaque, tinted car windows 77 %, the cars' paint, chrome and tyres 81 to 100 %.

---

# Material bake

Opened 2026-10-05 as untoldengine/UntoldEngine#1307 (head `b74fc9ad`), MERGED 2026-10-07 (`e8ed7ad4`) with no review comments.

**Title:** [Feature] Bake procedural Blender materials into repeating textures

## Summary

A Principled input driven by procedural nodes (a Noise or Brick texture, node math, a Bump from a procedural height) has no image to export. It was written as a plain value, which is not what Blender shows once the socket is linked: brick walls, solar cells and galvanised steel came out as plain white surfaces.

The command-line export now bakes such inputs with Cycles, once per material, into textures that repeat. On a site model with 393 materials, 87 are baked in two minutes.

## Before and after

Blender (Cycles), then the cook before and the cook with the bake. The two right columns are rendered in Blender from the cooked files (their meshes, texture coordinates and material records), with the same camera and light: brick piers of a façade, a solar panel, a duct of galvanised steel.

![Brick piers, a solar panel and a duct: Blender, the cook before, the cook with the bake](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/material_bake_blender_before_after.jpg)

## How it works

- **What is baked.** A pattern laid out by object coordinates or by world positions becomes one set of repeating textures per material: base color, occlusion-roughness-metallic and normal. Anything else (a pattern on UV, generated or camera coordinates, or image textures in the same material) keeps the mesh's UVs and exports the value the input averages to.
- **The swatch.** The material is baked on a flat plane that faces the way most of its surface does.
- **The tile.** A coarse bake finds where to cut: a whole number of periods for bricks, tiles and cells (found from the pattern's edges, so bricks of random colors count), 2 m for noise, with a band along the cut blended so that it repeats without a seam. Each image is baked at the size its detail needs, up to 1024 texels.
- **The texture coordinates.** The meshes that use a baked material get coordinates projected from their positions, so they need no UV map. A flat face is mapped in its own plane, without stretch; a smooth surface along the nearest axis.
- **Patterns laid out in the world.** A mesh placed once is mapped from world positions, so the pattern continues from one object to the next as in Blender. Copies of one mesh share one mapping at the pattern's world size, and stay one model in a pack.

`--no-material-bake` switches it off; `--material-bake-size` and `--material-bake-tile` set the texture size and the longest tile. It is on in the command-line export, which `untoldengine export` and the editor's Cook run. The tile pipeline and the Blender add-on's export do not bake.

## On the site model

| | Before | With the bake |
|---|---|---|
| Materials baked | 0 | 87, in 118 s |
| Cook | 7 min 15 s | 9 min 24 s |
| Textures | 128 | 242 |
| Model files | 4,589 | 4,779 |
| Meshes | 8,202 | 8,642 |
| Size on disk | 842 MB | 937 MB |

Both cooks ran side by side on a busy machine, so the times are slower than a cook alone. The meshes go up because a pattern laid out in the world maps a mesh by where it stands: some copies that shared a model no longer do.

## Verification

- `make testexporter`: 267 pass (37 new).
- `scripts/tests/blender/material_bake_checks.py`, run in Blender (9 checks): tiles cut at whole bricks, noise that repeats without a seam, and the projected coordinates: what Blender shows on a mesh through them is what the baked texture holds.
- The site model cooks with it from the command line, as the editor's Cook runs it; the comparison above is from that cook.

## Notes

- One swatch per material: a material used on walls and on floors is baked for the facing most of its surface has. A pattern that depends on the facing looks right on that one.
- A pattern on UV, generated or camera coordinates exports its average, not a texture.
- The bake needs Cycles and numpy, which Blender ships with. Without them the export goes on without baking.

# Glass

Opened 2026-10-05 as untoldengine/UntoldEngine#1308 (head `ac76c84d`), approved by Harold and MERGED 2026-10-07 (`da580ee2`), ten minutes after #1307 and without a rebase.

**Title:** [Feature] Glass: a material's transmission shows what is behind it and keeps its reflections

## Summary

Glass exported from Blender was stood in for by a blended surface (#1284, #1293). A surface that is a tenth there shows a tenth of its reflections and of its glow, and covers what is behind it with a lit film of its own color: windows came out as milky panes without a sheen, and tinted glass as paint.

A material now has a transmission. Glass shows what is behind it, tinted by its base color, and keeps its reflections and its glow whole. The exporter writes Blender's Transmission Weight into it.

## Before and after

Blender (Cycles), then the engine before and after, with the same camera, environment and sun.

From a site model: a parked car, a wall of double glazing, and a window of frosted channel glass. The car's paints, tyres and plastics carry a stray Transmission of 1 and came out as blended surfaces, drawn without depth; they are solid now, and its windows are glass.

![A car, a glazed wall and a frosted window: Blender, the engine before, the engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/glass_site_blender_before_after.jpg)

Six panes in front of a striped wall: window glass, solar control glass, channel glass (a roughness of 0.25), a car window, a red lens and black tempered glass.

![Six panes of glass: Blender, the engine before, the engine after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/glass_panes_blender_before_after.jpg)

The third pane is the one that still differs: Blender blurs the wall behind it, and the engine blurs nothing (see Notes).

## Changes

**The material**

- `UntoldMaterialRecordV1.transmissionFactor`, from 0 (a solid surface) to 1, kept in the record's second reserved word. Every file written before leaves that word at zero, which reads as no transmission, so there is no new format version.
- `Material.transmission`, read and set with `getMaterialTransmission` and `updateMaterialTransmission`, and kept in a saved scene.
- A material that lets light through is drawn in the transparency pass whatever its alpha mode (`Material.hasTransparency`). One that is all metal or frosted lets nothing through and stays a solid surface, with its depth, its shadow and its batch (`Material.transmitsLight`).

**The transparency pass**

For each pixel the fragment shader now gives the blender two values: the light the surface adds, and the share of what is already there that it lets through, for each of red, green and blue.

- Glass adds its reflections and its glow whole, and scatters none of the light that falls on it.
- It lets through what it does not reflect, by the lookup table the reflections use, so glass seen at a slant is a mirror. In an even light a clear glass sphere is not to be seen: the test holds to 0.07 %.
- The base color tints what crosses it by its square root at each face, so a pane seen through its two faces shows its base color. This is what Blender does: a gray of 0.25 lets 0.50 through one plane and 0.25 through a thin box (measured in Cycles).
- Nothing is bent or blurred behind glass. Rough glass shows less of what is behind it (all of it up to a roughness of 0.05, none from 0.5) and glows with the light that comes from behind it instead: the environment straight through the glass, blurred, and the sun on its far side.
- The alpha stays what it was, how much of the surface is there. A blended material without transmission draws as before: no reference image changes.

The pass's pipeline blends with two sources to keep the three shares (`PipelineBlendMode.premultipliedOverFilteredDestination`). Where that pipeline cannot be created, and in the simulator, it falls back to premultiplied alpha: tinted glass then darkens what is behind it by the brightness of its color and does not color it.

The triangles of a mesh are drawn in the order they come, so the far side of a frosted or dark pane could come out over its near side. Glass is drawn in two goes, its faces turned away from the viewer and then the ones turned towards the viewer, each lit on the side the viewer sees.

Glass casts no shadow: the shadow passes leave it out, so the sun reaches what is behind a window. A blended material still casts the shadow of a solid one.

**The exporter**

- A Principled BSDF's Transmission Weight exports as the material's transmission, and the surface whole. The stand-in opacity of #1293 is gone.
- A surface through which under 5 % of what is behind it would show exports as a solid one (its transmission, the brightness of its base color, its metallic share and its roughness counted). Black glass is the black mirror it is in Blender. On the site model, the seventeen paints, chromes, tyres and plastics of the cars that were blended come out solid, and the cars' windows and about a thousand window panes as glass.
- The material fidelity report lists the surfaces kept solid, rough glass, and a transmission the exporter cannot follow. Plain glass is no longer an approximation and is not listed.

## Verification

- 17 new render tests (`GlassShadingTests`): a wall seen through a pane at the share its two faces let through; the tint for each color; the fallback pipeline; alpha and transmission together; black glass equal to a black solid pixel by pixel; a clear and a half frosted sphere invisible in an even light; frosted glass lit from behind and from the front; no shadow behind glass; the glow; roughness, metal and a transmission of a half; the material functions and a saved scene.
- 3 new format tests: the factor through the reader and the runtime loader, a file without it, values out of range.
- The CI render sweep locally: 1,216 tests pass. `UntoldEngineTests` (1,627) and `UntoldComponentKitTests` pass, the strict-concurrency build has no warnings.
- `make testexporter`: 233 pass.
- Blending with two sources and the fallback both run under Metal's API validation.

## Notes

- No refraction: a flat pane looks as it does in Blender; through a thick or curved piece of glass the view is not distorted.
- Frosted glass is a stand-in. Its glow reads the environment, not the scene, so an object right behind it does not show in the glow (the third pane above). Blurring what is behind glass takes a copy of the scene color, which the pass does not have.
- The index of refraction is not read: glass reflects 4 % head on, as an index of 1.5 gives.
- Glass writes no depth and is left out of static batches, like the blended materials.
- Files cooked before keep their stand-in opacity until they are cooked again.

---

# Object-linked material slots

Opened upstream on 2026-10-07 as untoldengine/UntoldEngine#1320 (branch `bugfix/object_linked_material_slots`, one commit on upstream develop `ec141a06`).

**Title:** [Bugfix] Export the material a slot linked to the object shows, not the mesh's default

## Summary

A multi-material object is split into one mesh per material before export. The split took each piece's material from the mesh data, so a material slot linked to the object (Blender's slot link set to Object) exported the mesh's default material instead of the one the object shows in the viewport. An IFC import gives hundreds of objects one shared mesh and links each one's own material over it: in the BIM site 771 of 811 object-linked slots differ from their mesh's material. Every classroom chair came out with the red material its shared mesh holds in that slot, where Blender shows wood.

## Before and after

The chair of the BIM classroom, rendered by Cycles: Blender's object, the cook before this change, the cook with it. The cooked columns are renders of the cooked files with their materials and textures.

![The chair: Blender, cook before, cook with the fix](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/chair_material_slot_blender_before_after.jpg)

## Cause and change

- `split_blender_objects_by_material` built each fragment's mesh with `mesh.materials[mat_idx]`, the mesh data's material; `_separate_rigged_object_by_material` did the same for the pieces of a rigged object. `mesh_object_material` already honoured object-linked slots, but only single-material objects reached it with their original slots.
- Both paths now go through `slot_material(obj, mesh, index)`: the object's slot first (its material is the one Blender resolves, object or data link), the mesh data only for what the slots do not cover. A rigged piece keeps the slot links of its source, so after its one material is placed in the mesh data its slots are set back to the data link.
- Linked duplicates with different object materials were already kept apart by the share key (it includes the slot materials per object), so they now export their own materials.

## Verification

- `scripts/tests/blender/material_slot_checks.py` (new, needs Blender): the plain split of a two-slot cube with an object-linked slot, two linked duplicates with their own object materials, the export preparation path, and a rigged object (Armature modifier); all four pass.
- `python3 -m unittest discover -s scripts/tests -t .`: 270 tests; `texture_write_checks.py` 7 and `material_bake_checks.py` 9 in Blender.
- The BIM site cooked again with this change from the editor: the chairs show their wood, as the user confirmed.

Documented in `docs/API/UsingTheExporter.md` and `scripts/tests/README.md`.

---

# Glass: depth against frames, the seen side, depth in a headset

Opened upstream on 2026-10-10 as untoldengine/UntoldEngine#1331 (branch `bugfix/glass_depth_and_faces`, worktree `UntoldEngine-glassdepth`, one commit `eef96d17` on upstream develop `1085580c`); from the headset checks of 2026-10-07 on the try-out.

**Title:** [Bugfix] Glass keeps its place against its frame and in a headset

## Summary

Three things seen on the Vision Pro with the BIM site, and one that followed from them:

- A pane modelled into its frame shares a plane with the frame, and the two fought for depth along the pane's edges at every move of the head: glass now draws a hair behind where it is, so the frame wins wherever they coincide. On a Mac the same fight shows as a noisy edge when the camera moves.
- The side of a pane the viewer sees was decided from the smooth shading normal, which bends at a pane's edges, so an edge pixel could count as the far side for one eye and the near side for the other: it is decided from the face itself now, with the vertex normal only choosing which way the face points.
- The shading normal of a pane now always faces the viewer, whichever of the two goes draws the face.
- In a headset the compositor reprojects each pixel by the depth it finds. A pane that mostly shows itself (dark, frosted) now writes its depth, so its tint and reflections stay on the pane; a clear pane leaves the depth of what is seen through it, which is what the eye follows. Before, every pane was reprojected with the depth of what was behind it, and the dark car windows flickered.

## Before and after

![A pane and a block in one plane: before and with the change](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/BlenderMaterialFidelity/glass_frame_depth_before_after.jpg)

## Cause and change

- `RenderPasses` transparency pass: glass draws with `setDepthBias` of 4 units of depth resolution and 2 per unit of slope, away from the viewer under either depth convention; other blended draws reset it. In XR stereo mode outside passthrough, a glass draw whose material `paneShowsItself` uses the pass's depth-writing state (the one passthrough already uses for every transparent draw), the others the pass's own state.
- `Material.paneShowsItself`: less than half of the light crosses the pane, from coverage, transmission, the clear share by roughness (the shader's smoothstep between `GLASS_CLEAR_UP_TO_ROUGHNESS` and `GLASS_FROSTED_FROM_ROUGHNESS`) and what a non-metal of that base colour lets cross.
- `TransparencyShader.metal`: the far/near decision uses the derivative (face) normal aligned to the vertex normal, falling back to the shading normal for a degenerate face; the shading normal is turned to face the viewer whenever a two-go draw is on.

## Verification

- `GlassShadingTests`: 19 tests, the 17 of #1308 unchanged plus two new ones. `testAPaneInThePlaneOfASolidSurfaceShowsTheSolidSurface`: a glowing block whose near face lies in the plane of the glass cube's near face shows the block in every pixel of a 24-pixel window; with the bias set to zero it fails on the mean colour and on single pixels. `testAPaneWritesItsDepthInAHeadsetWhenItMostlyShowsItself`: clear window glass no, smoked car glass yes, frosted yes, a pane half there by its alpha no, light grey glass at half transmission yes.
- `swift test --filter UntoldEngineTests`: 1,692 passed, 2 skipped (the external render extension package test aside, which needs a checkout named `UntoldEngine`); `UntoldComponentKitTests` 59 tests.
- Strict-concurrency build: 0 warnings. `xcodebuild -scheme UntoldEngine -destination 'generic/platform=visionOS Simulator'`: build succeeded. SwiftFormat lint of the changed files: clean.
- On the Vision Pro, before this branch, on the try-out it comes from: the door edges of the BIM site stopped fighting their frames with the bias; the dark car windows stopped flickering with the depth rule; what is seen through clear glass stayed in place.
