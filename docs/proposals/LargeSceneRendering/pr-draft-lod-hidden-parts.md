# Draft: [Bugfix] Keep a model's hidden parts hidden at its coarse LOD levels

Branch `bugfix/lod_nested_shells` (one commit on upstream develop `ec141a06`; the branch kept the name it was cut under). OPENED 2026-10-08 as untoldengine/UntoldEngine#1324. The sheet `lod_hidden_parts.jpg` beside this draft goes to the fork's `docs/proposal_drafts` branch first, and is embedded by its raw URL.

---

## Summary

On a BIM site viewed from a headset, the parked cars grew dark patches with distance: at each coarser level more of the white paint turned black, on the roof, the doors and the bonnet. A model's meshes are simplified one by one, each within the allowance of the level (the size of one of its triangles: 12, 22 and 48 mm for this car at its three levels), and the car is a shell with a lining a short way behind it: the inner skin 0.8 mm under the roof and a centimetre or two behind the doors, the window trims a few millimetres from the pillars. Once the allowance exceeds the gap, the coarse triangles of the two surfaces cross, and the dark part shows through the paint wherever the lining happens to be the finer of the two. A white copy of the car at its coarsest level, with its dark parts hidden, is clean white; with them shown it has the patches.

The cook now sinks what is hidden before each level is simplified. A vertex is hidden when its own side is covered (the rays along its normal and in a cone round it all meet another face of the model) and a seen face of another, solid mesh is in front of it, within three allowances. It is moved away from that face, along the face's normal, by twice the allowance where it touches the face and by less up to the edge of reach: the face may then come in by the allowance and the hidden part go out by it without the two crossing. What is seen from outside is never moved, so what a level draws is the plain simplification of the model; nothing is sunk away from glass, so what is seen through a windscreen or a headlight's lens stays where it is; a sink stops two allowances short of any seen face in its way, so a part between two seen surfaces (a car's inner wing, between the paint and the wheel-well liner) stays between them; and the sinks are averaged over each connected piece before they are applied, so a piece that is hidden in one part and seen in another (the car's inner skin, whose wheel wells show through the arches) bends gradually from the one to the other instead of tearing. A piece that is sunk for the most part is simplified on its own share of its mesh's target, since bent by its sinking it would otherwise keep its triangles and take those of the pieces beside it.

A second, smaller cause: the simplifier keeps the vertices it does not collapse with their normals as they were, so a vertex that stood in a groove or on a crease keeps a sideways normal when the groove is gone and it sits on a span of flat triangles, and shades the span dark. A level now gives such a vertex (its normal more than 30° from the faces around it) the normal of those faces; a hard edge keeps both its normals.

![A roof over a dark lining and a dark shell inside a white one, at their coarsest level, before and after](https://github.com/miolabs/UntoldEngine/raw/docs/proposal_drafts/docs/proposals/LargeSceneRendering/lod_hidden_parts.jpg)

The sheet is two test models (the cook's own test suite builds them): a wavy roof of 28,800 triangles with a dark lining 12 mm under it, and a sphere of 57,600 triangles with a dark one 15 mm inside it, each cooked by `untoldengine bake-lods` on develop and on this branch and drawn at its coarsest level (3 % of the triangles) from the same camera.

## What it changes on the BIM site

The pack of the site (4,779 models, 274 of them with chains, 809 level files), cooked by the release CLI on an M4 Max:

| | develop | this branch |
|---|---|---|
| Cook | 6 s | 21 s |
| Triangles of all models at their coarsest level | 352,248 | 364,182 (+3.4 %) |
| The parked car, levels 1 / 2 / 3 (of 384,363) | 192,578 / 59,928 / 15,516 | 192,923 / 60,026 / 16,176 |
| The car's `error` per level | 0.0118 / 0.0216 / 0.0484 | the same |

The cost is the rays: every vertex within reach of another solid mesh casts one along its normal and, when that one is blocked, eight more in a cone round it. The levels' errors do not change (they measure the simplification, not the sinking), and what is drawn at the coarsest level has 3 % more triangles: a sunk piece bends, and collapses a little less readily than it did flat.

At the coarsest level the white cars of the site, which were mottled black all over, are clean, and the dark car, which showed the light interior through its paint, is too; the cars' wheel wells, headlights and trims look as they did (the well liners recede a few centimetres behind the arches). A try-out in the headset is still to be done; this was judged from renders on the Mac at the same levels.

## Changes

- **`UntoldMeshLODHiddenParts`** (new): the model's triangles on a grid (`ModelGrid`: faces near a point, rays through the cells, the nearest face along a ray); which vertices have a solid mesh within reach; which of those are seen (the ray along the normal and a cone of eight at 60°, with a tolerance at the triangles' edges so that a lining offset from its surface, whose rays pass through the surface's vertices, still counts as covered); for each covered vertex, up to three seen faces it lies behind, each facing its own way (the face's nearest point in front of the vertex within 45°: a vertex beside a face is not behind it, nor one under a face farther round a curved shell than the one that covers it). A vertex two meshes share is sunk only when it is hidden in both, from the faces of neither, so that their border stays closed. Glass (a material that transmits, or whose base colour is not opaque) covers but is never sunk from. Aggregates (`UntoldLODMeshParts.clutterIndices`) take no part. `sunk(_:allowance:)` gives the meshes with the hidden vertices moved for one level: the sinks, averaged over each piece in eight passes with the seen vertices held still, each cut short two allowances before the first seen face in its way; every vertex at a position moves with it, so the position remap and the seams hold.
- **`UntoldMeshLODCooker.cookChain`**: finds the hidden parts once per model, simplifies each level from the sunk meshes, and tells the simplifier which pieces are sunk for the most part. The level's `error` stays the simplifier's.
- **`UntoldMeshLODSimplifier`**: `level(of:parts:ratio:errorLimit:sunkPieces:)` simplifies the sunk pieces and the rest as two bodies, each towards its own share of the target. `settleNormals` replaces, after a level is compacted, the normal of a vertex more than 30° from the area-weighted normal of its faces, and keeps its tangent in the surface; per vertex, not per position, so hard edges keep their normals, and with the faces' normal turned to the side of the vertex's own, since a mesh wound the other way round (a mirrored part) has its faces' cross products pointing in.
- Documented in `docs/API/UsingLODSystem.md` and `docs/API/UsingUntoldEngineCLI.md`.

## Verification

- `UntoldMeshLODCookerTests` (+16, 42 in all): a shell 2 % inside another stays inside it at every level while the outer shell is, bit for bit, what it is with nothing hidden behind it; a hidden vertex is sunk twice the allowance behind the face in front of it, its vertex record with it, and not at all when out of reach; a ball on a floor moves neither; only a sheet whose own side is covered is sunk (the same sheet facing the open is not); a part in a corner moves away from every face of it; a vertex two hidden meshes share is sunk the same way in both; a sheet a millimetre under a curved roof stays under it at every level; a part behind glass stays; a part between two seen surfaces stays between them, an allowance short of each; a lining half under a roof sinks where it is covered and bends to where it is not; a sunk piece collapses about as readily as an unsunk one and takes nothing from the pieces beside it, and one that cannot collapse at all leaves them their share; the faces a point is behind and the rays that escape; a vertex kept from a groove takes the normal of its faces; a box keeps its hard edges' normals at every level; a sphere wound the other way round keeps its normals pointing out.
- With the sinking taken out, seven of those tests fail; with the averaging taken out, the half-covered lining tears and its test fails; with the separate shares taken out, the uncollapsible piece's test fails; with the normals left as they were, the groove test fails, and with the faces' normal not turned to the vertex's side, the wound sphere's. The rest pass each time.
- `swift test --filter UntoldEngineTests`: 1,660 run, 12 skipped. The only failure is `ExternalRenderExtensionPackageTests`, which fails locally whenever the checkout folder is not named `UntoldEngine`; it passes from a checkout with that name. `UntoldPackLODRenderTests` (11) pass; the CLI package's tests (18) pass.
- The render suite: 1,250 run, 69 skipped as on develop, no failures; its reference-image comparisons ran with a stand-in for `compare_psnr.py` that does the same arithmetic without OpenCV and scikit-image, which this machine does not have.
- Zero warnings in the strict-concurrency build (`scripts/strict-concurrency-guardrails.sh` with `MAX_UNIQUE_CONCURRENCY_WARNINGS=0`); no SwiftFormat findings in the changed files.

## Limits

- What a sink does to a part is invisible by construction only from outside; a part that is also seen from inside the model (through its windows) moves there: a car's dashboard and seats go down and in by the allowance at the coarse levels, a few pixels at the distances those levels are drawn.
- A piece hidden in one part and seen in another bends between the two over a few rings of vertices; where the seen part meets the hidden one there is a step of up to half the sink, inside the model.
- The rays treat the model's own faces as the only cover: a lining with nothing below it in a model with no floor is seen from below, and stays.
- The cook takes three and a half times as long on this site (21 s for 4,779 models).
