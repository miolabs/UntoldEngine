# PR 1293: answer to Harold's review of 2026-10-03

Posted on 2026-10-03 (https://github.com/untoldengine/UntoldEngine/pull/1293#issuecomment-5973317910), with the description updated and the branch pushed as `a218b1f2`. Two texts: the comment, and the two parts of the description that changed.

## Comment

Thanks for the review. Everything is addressed in three commits on top, and the branch is rebased onto develop: it conflicted with #1288, in the exporter's tests only.

**Add-on, `bridge.py:207`** (2913d1b9). Confirmed: with a scene of one model and `scene.untoldpack` as the output, the bake failed with `FileNotFoundError` on `scene.untoldpack` after `scene.untold` had been written. The bake now takes the written files from the export's result, and the operator's message names the file that was written.

In the same block I found a second case of the same mistake, which came with #1288: the models of a pack now share one `Textures` folder, and the loop still looked for a folder inside each model's own. With "Bake textures" on, a pack baked nothing and reported "no textures". It is fixed in the same commit: the shared folder is baked once and every model patched, as `export --optimize` does.

The new `test_addon_bridge.py` covers both. It loads `bridge.py` with a stand-in for `bpy` and writes real files through the exporter's own writers. I also ran the add-on's `export_asset` inside Blender on a scene of one cube and one of two, before and after.

**Report and export disagreeing on a height (lines 3301, 3274, 5512)** (b8ce4790). Confirmed, both cases. The second one was in the two scenes I test with: a material of the building (a Bump at Distance 10, fed by a ColorRamp) and one of the site (a Displacement at Scale 1, fed by node math) were reported as too deep when their height was never exportable.

As you suggest there is now one lookup, `material_height`. It returns the height a material is exported with, and the heights read on the way to it that are left out as too deep. `extract_material` exports the first and `analyze_material` reports the second. The copied reset is gone with it, and the default depth is `DEFAULT_HEIGHT_SCALE`.

Checked on both scenes in Blender: none of their 458 materials exports differently, and their reports lose exactly those two lines.

**`principled_transmission` followed twice (line 3344)** (a218b1f2). `principled_transmittance` now takes the answer its caller already has.

**`principled_transmittance` on every object (line 5233)**. I measured it before deciding. On the site (22,741 mesh objects, 34,084 pairs of object and material, 383 materials) the walks for all the pairs take 0.054 s together, 1.6 µs each, in a cook of about 7 minutes. The three extra walks only run for a surface that transmits, and a socket that is not linked costs no graph walk. `extract_material` as a whole is about 0.4 ms per call there. I left it without a cache. If it shows up some day, a cache of `extract_material` per material is where the time is.

**`displacement_method` (line 158)**. Agreed that it reads the intent better than a threshold, and I would do it as a follow-up. Two things to settle there:

- Blender's Scale is a distance in the scene and the engine's depth a share of the texture's width, so a large depth that is meant still has to be converted or capped before it can survive.
- Under "Bump Only" Blender draws no relief at all, only shading. The faithful export for those is a normal map made from the height, not parallax.

In the two scenes both rules give the same result: the chair and the plant are "Bump Only" at 1, and the brushed metal is "Displacement and Bump" at 0.004.

`make testexporter`: 228 pass (20 new against develop).

## Description: what changes

New section before "Verification":

## After review

4. **The report said a height was too deep when the export had not read it.** The material fidelity report looked for Displacement and Bump nodes on its own, apart from the export. A Bump node beside a Displacement that is exported, and a height that comes from a procedural texture, were both reported as left out for their depth. One lookup, `material_height`, now serves both: the export takes the height it returns and the report lists the heights it leaves out.
5. **The add-on's texture bake patched a file that was not written.** With one model and `scene.untoldpack` as the output, the export wrote `scene.untold` and the bake then failed on `scene.untoldpack`. With a pack, whose models share one `Textures` folder since #1288, the bake looked inside each model's folder and baked nothing. The bake now takes the written files from the export's result.
6. The report follows a transmission once.

"Verification", first line replaced by:

- `make testexporter`: 228 pass (20 new). The two pack tests, the two report tests and two of the add-on tests fail without their fix.
- The add-on's `export_asset`, run in Blender on a scene of one cube named `scene.untoldpack` and on a scene of two: before, `FileNotFoundError` and "no textures"; after, both baked and patched.
- None of the 458 materials of the building and of the site exports differently after the review changes.

# Second review, 2026-10-04: a surface that is not a Principled BSDF

Posted on 2026-10-04 (https://github.com/untoldengine/UntoldEngine/pull/1293#discussion_r4178205674), with the description updated and the commit pushed as `b7b6def0`. A reply in the thread of Harold's comment, and two lines of the description.

## Reply

You are right, and thanks for reproducing it: with that gate the finding vanished for a surface that is not a Principled BSDF. Fixed in b7b6def0, with a test on Diffuse, Glass and Emission surfaces.

I did not bring the old line back as it was, though. On such a surface the export has no height at any depth (`extract_material` returns before it looks for one), so "too deep to be a parallax depth" gave a reason that a smaller Scale would not cure. The same Displacement at Scale 0.02 was never reported, and an Emission surface with one counted as supported.

So `material_height` now returns each height it leaves out with why, its depth or its surface, and a Displacement on a surface that is not a Principled BSDF is reported at any depth:

`a height is exported only with a Principled BSDF surface; the relief it gives is not exported`

The Displacement candidate runs without a Principled node, as you suggest, and only the Bump is gated on it. If you prefer the "too deep" wording at Scale 1, I can put it back for that case and keep the line above for the smaller scales.

`make testexporter`: 230 pass. The two scenes export as before, and this commit changes nothing in their reports.

## Description: what changes

Item 4 of "After review" gets one more sentence at its end:

A Displacement on a surface that is not a Principled BSDF, which is exported with no height at any depth, is reported as left out because of its surface.

First line of "Verification":

- `make testexporter`: 230 pass (22 new). The two pack tests, the three report tests and two of the add-on tests fail without their fix.
