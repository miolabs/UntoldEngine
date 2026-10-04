# Static Batching System

UntoldEngine supports two batching modes in practice:

| Mode | Use for |
|---|---|
| Manual batch generation | Always-resident static content |
| Runtime cell-based batching | Tiled streaming scenes |

## Manual Batching for Always-Resident Content

Mark loaded entities as static, enable batching, then build the initial artifacts.

```swift
let cube1 = createEntity()
setEntityMesh(entityId: cube1, filename: "cube", withExtension: "untold")
translateTo(entityId: cube1, position: simd_float3(0, 0, 0))
setEntityStaticBatchComponent(entityId: cube1)

let cube2 = createEntity()
setEntityMesh(entityId: cube2, filename: "cube", withExtension: "untold")
translateTo(entityId: cube2, position: simd_float3(2, 0, 0))
setEntityStaticBatchComponent(entityId: cube2)

setBatching(.enabled(true))
generateBatches()
```

For async loading, mark entities static in the completion block:

```swift
let building = createEntity()

setEntityMeshAsync(entityId: building, filename: "office_building", withExtension: "untold") { success in
    guard success else { return }
    setEntityStaticBatchComponent(entityId: building)
    setBatching(.enabled(true))
    generateBatches()
}
```

To add static content to a scene that is already running, tell the batching system about the new entities instead of rebuilding everything. Their cells are built in the background over the next frames, and each entity is drawn by itself until its batch is ready:

```swift
setEntityMeshAsync(entityId: crate, filename: "crate", withExtension: "untold") { success in
    guard success else { return }
    setEntityStaticBatchComponent(entityId: crate)
    BatchingSystem.shared.notifyStaticEntitiesPlaced([crate])
}
```

Pass the entities that draw a mesh: the entity itself for a model of one node, as here, and its descendants that have a `RenderComponent` for a model of several. Entities without the mark are skipped, and the call does nothing while batching is disabled.

## Static Entities That Move

A batch holds its entities where they stood when it was built. You do not have to unmark an entity before moving it:

- An entity moved with the transform functions leaves its batch before the next frame is drawn, together with every descendant that moves with it. Its neighbours go back to one draw each until their cell is rebuilt.
- It keeps its mark. Thirty frames after it stops, it is batched again where it stands.
- An entity that never stops moving stays out of batching. It costs nothing more than an unmarked entity, but it gains nothing either, so do not mark what moves all the time.
- An entity that is destroyed, or that loses its mark, leaves its batch the same way.

To move a whole scene without touching its batches, move the scene root instead (see [Transform System](UsingTransformSystem.md)).

## Shadows

An entity in a batch casts through its batch. A marked entity that no batch took (it is alone with its material in its cell) casts its own shadow, from the sun and from spot and point lights. The one exception is a streamed tile that has just come in: its entities cast nothing for the few frames until their batch is built.

## Runtime Batching in Tiled Scenes

For tiled scenes, the flow is different:

```swift
let sceneRoot = createEntity()
setEntityName(entityId: sceneRoot, name: "city")

setEntityStreamScene(entityId: sceneRoot, manifest: "city", withExtension: "json") { success in
    setSceneReady(success)
}
```

In this mode:

- `setEntityStreamScene(...)` registers tiled-scene entities with batching automatically
- full-load tiles and OCC sub-mesh uploads notify batching through internal residency events
- per-tile LOD and HLOD representations can also participate when enabled

You do **not** call `generateBatches()` every time a tile loads. The batching system rebuilds dirty cells incrementally based on residency changes.

## Streamed vs Non-Streamed Scenes

For tiled/streamed scenes, the engine manages static batching automatically. When a tile finishes loading, the engine assigns a `StaticBatchComponent` to all of its entities and schedules an incremental batch rebuild for only the spatial cells affected by that tile. This happens internally on a background queue via the engine's `tick()` loop.

Do **not** call `generateBatches()` for streamed scenes. That function performs a full global rebuild — it queries every entity in the scene simultaneously, merges entities from different tiles into shared batch groups, and allocates all GPU buffers synchronously on the render thread. This overrides the engine's incremental system and causes a noticeable stall.

For streamed scenes, only call `setBatching(.enabled(true))` after the scene loads. The engine handles the rest:

```swift
setEntityStreamScene(entityId: sceneRoot, manifest: "city", withExtension: "json") { success in
    setBatching(.enabled(true))
    setSceneReady(success)
}
```

For non-streamed scenes (single `.untold`), call `setEntityStaticBatchComponent`, `generateBatches()`, and `setBatching(.enabled(true))` as normal. Material updates such as opacity automatically notify batching, but if you want a deterministic manual rebuild in an always-resident scene, wrap the edit with `setBatching(.enabled(false))` before and `generateBatches()` + `setBatching(.enabled(true))` after. Do not use this pattern in streamed scenes:

```swift
// Non-streamed only — do not use this pattern in tiled/streamed scenes
setBatching(.enabled(false))
updateMaterialOpacity(entityId: prop, opacity: 0.5)
generateBatches()
setBatching(.enabled(true))
```

## Core APIs

### `setEntityStaticBatchHierarchy(entityId:)`

Marks an entity hierarchy as eligible for batching.

```swift
setEntityStaticBatchHierarchy(entityId: entity)
```

The older `setEntityStaticBatchComponent(entityId:)` name remains available as a
backward-compatible alias.

### `removeEntityStaticBatchComponent(entityId:)`

Removes static batching tags from the entity hierarchy.

```swift
removeEntityStaticBatchComponent(entityId: entity)
```

### `setBatching(_:)`

Configures runtime batching.

```swift
setBatching(.enabled(true))
setBatching(.cellSize(32.0))
setBatching(.maxDirtyCellsPerTick(8))
setBatching(.visibilityGatedBuild(true))
setBatching(.backgroundArtifactBuild(true))
```

### `BatchingSystem.shared.notifyStaticEntitiesPlaced(_:)`

Hands marked entities that are loaded and in place to the batching system. Their cells are built in the background, without waiting to be seen and without the per-cell size limits of streamed tiles.

```swift
BatchingSystem.shared.notifyStaticEntitiesPlaced(entities)
```

### `generateBatches()`

Builds batch artifacts for the currently marked static entities. This is mainly for always-resident/manual workflows.

```swift
generateBatches()
```

### `clearSceneBatches()`

Clears all generated batch artifacts.

```swift
clearSceneBatches()
```

## Good Candidates

- environment geometry
- buildings and structures
- terrain chunks
- furniture and static props

## Poor Candidates

- characters and NPCs
- vehicles
- projectiles
- animated or skinned meshes
- objects that move frequently

## Notes for the New Architecture

- The batching system is now cell-based and visibility-gated.
- Tile streaming and batching are tightly integrated; residency events are no longer the old per-entity event storm for full-load tiles.
- `TileLODTagComponent` lets batching treat per-tile LODs and HLODs as distinct LOD groups even though they are not entity-level `LODComponent` assets.
- Scene channels separate context geometry from selectable geometry. Entities marked `.preserveIdentity` are excluded from batching, and batch groups are separated by channel mask so channel visibility can be toggled without rebuilding batches.

For architectural details, see [Batching System](../Architecture/batchingSystem.md).
