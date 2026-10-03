//
//  RenderEntityTable.swift
//  UntoldEngine
//
//  PROTOTYPE (large-scene plan, stage 2): the entities the renderer draws, with the
//  component objects its passes read, so that a pass does not look each of them up
//  again through the ECS for every entity of every frame.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// The render entities of the scene and what the passes need to know about each.
///
/// A row holds the entity's component OBJECTS, not copies of their values: a pass reads
/// a transform, a mesh list or a visibility flag through the row and always sees what
/// is there now. Only the set of rows depends on the ECS, and it changes when a
/// component is assigned or removed or an entity goes: `Scene.structureGeneration`
/// counts those, and `refresh()` rebuilds the rows when it has moved.
final class RenderEntityTable: @unchecked Sendable {
    struct Flags: OptionSet {
        let rawValue: UInt16

        static let gizmo = Flags(rawValue: 1 << 0)
        static let light = Flags(rawValue: 1 << 1)
        static let camera = Flags(rawValue: 1 << 2)
        static let sceneCamera = Flags(rawValue: 1 << 3)
        static let staticBatch = Flags(rawValue: 1 << 4)
        static let meshOccluder = Flags(rawValue: 1 << 5)
        static let meshFade = Flags(rawValue: 1 << 6)
        static let tileRepresentationFade = Flags(rawValue: 1 << 7)
        static let lod = Flags(rawValue: 1 << 8)
        static let deformation = Flags(rawValue: 1 << 9)
        static let skeleton = Flags(rawValue: 1 << 10)

        /// Entities no geometry pass draws: cameras, lights and gizmos.
        static let notGeometry: Flags = [.gizmo, .light, .camera, .sceneCamera]
    }

    struct Row {
        let entityId: EntityID
        let render: RenderComponent
        let world: WorldTransformComponent
        let local: LocalTransformComponent
        /// The entity's channel component, or nil when it takes `fallbackChannels`.
        let channels: EntitySceneChannelsComponent?
        let fallbackChannels: SceneChannel
        let flags: Flags
    }

    static let shared = RenderEntityTable()

    private(set) var rows: [Row] = []
    /// The row of the entity at each entity index, or -1.
    private var rowIndexByEntityIndex: [Int32] = []
    private var builtGeneration: UInt64?

    /// Rebuilds the rows if a component was assigned or removed, or an entity went, since
    /// they were built. While assets are being registered the rows stay as they are:
    /// the frame keeps drawing what it knew, as it does with the visible list.
    func refreshIfNeeded() {
        if AssetLoadingGate.shared.isLoadingAny { return }
        let snapshot = scene
        guard snapshot.structureGeneration != builtGeneration else { return }
        builtGeneration = snapshot.structureGeneration

        let renderId = getComponentId(for: RenderComponent.self)
        let worldId = getComponentId(for: WorldTransformComponent.self)
        let localId = getComponentId(for: LocalTransformComponent.self)
        let channelsId = getComponentId(for: EntitySceneChannelsComponent.self)
        let flagIds: [(Int, Flags)] = [
            (getComponentId(for: GizmoComponent.self), .gizmo),
            (getComponentId(for: LightComponent.self), .light),
            (getComponentId(for: CameraComponent.self), .camera),
            (getComponentId(for: SceneCameraComponent.self), .sceneCamera),
            (getComponentId(for: StaticBatchComponent.self), .staticBatch),
            (getComponentId(for: MeshOccluderComponent.self), .meshOccluder),
            (getComponentId(for: MeshFadeComponent.self), .meshFade),
            (getComponentId(for: TileRepresentationFadeComponent.self), .tileRepresentationFade),
            (getComponentId(for: LODComponent.self), .lod),
            (getComponentId(for: DeformationComponent.self), .deformation),
            (getComponentId(for: SkeletonComponent.self), .skeleton),
        ]

        rows.removeAll(keepingCapacity: true)
        rowIndexByEntityIndex = [Int32](repeating: -1, count: snapshot.entities.count)

        guard let renderPool = snapshot.componentPool[renderId],
              let worldPool = snapshot.componentPool[worldId],
              let localPool = snapshot.componentPool[localId]
        else { return }
        let channelsPool = snapshot.componentPool[channelsId]

        for index in snapshot.entities.indices {
            let entity = snapshot.entities[index]
            if entity.freed || entity.pendingDestroy { continue }
            let mask = entity.mask
            guard mask.test(renderId), mask.test(worldId), mask.test(localId),
                  let renderPointer = renderPool.get(index),
                  let worldPointer = worldPool.get(index),
                  let localPointer = localPool.get(index)
            else { continue }

            var flags: Flags = []
            for (componentId, flag) in flagIds where mask.test(componentId) {
                flags.insert(flag)
            }
            var channels: EntitySceneChannelsComponent?
            if mask.test(channelsId), let pointer = channelsPool?.get(index) {
                channels = pointer.bindMemory(to: EntitySceneChannelsComponent.self, capacity: 1).pointee
            }

            rowIndexByEntityIndex[index] = Int32(rows.count)
            rows.append(Row(
                entityId: entity.entityId,
                render: renderPointer.bindMemory(to: RenderComponent.self, capacity: 1).pointee,
                world: worldPointer.bindMemory(to: WorldTransformComponent.self, capacity: 1).pointee,
                local: localPointer.bindMemory(to: LocalTransformComponent.self, capacity: 1).pointee,
                channels: channels,
                fallbackChannels: channels == nil ? getEntitySceneChannels(entityId: entity.entityId) : [],
                flags: flags
            ))
        }
    }

    /// The row of `entityId`, if it is a render entity the table knows.
    @inline(__always)
    func rowIndex(for entityId: EntityID) -> Int? {
        let entityIndex = Int(getEntityIndex(entityId))
        guard entityIndex < rowIndexByEntityIndex.count else { return nil }
        let rowIndex = Int(rowIndexByEntityIndex[entityIndex])
        guard rowIndex >= 0, rows[rowIndex].entityId == entityId else { return nil }
        return rowIndex
    }
}

/// The render mode of the channels of one entity after another. The entities of a scene
/// are on a handful of channel sets, usually the same as the entity before, so the
/// mode is asked for again only when the channels change.
struct SceneChannelRenderModeMemo {
    private var channels: SceneChannel?
    private var mode = SceneChannelRenderMode.normal

    @inline(__always)
    mutating func mode(of row: RenderEntityTable.Row) -> SceneChannelRenderMode {
        let rowChannels = row.channels?.channels ?? row.fallbackChannels
        if rowChannels != channels {
            channels = rowChannels
            mode = getSceneChannelRenderMode(rowChannels)
        }
        return mode
    }
}

extension SceneChannelRenderMode {
    @inline(__always)
    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }

    @inline(__always)
    var isWireframe: Bool {
        if case .wireframe = self { return true }
        return false
    }
}
