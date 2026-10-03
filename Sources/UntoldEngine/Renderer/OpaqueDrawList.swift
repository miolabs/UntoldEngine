//
//  OpaqueDrawList.swift
//  UntoldEngine
//
//  The opaque draws of a pass in the order they are encoded: draws that share a
//  material follow each other, and within a material those that share a mesh.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import MetalKit
import simd

/// The opaque draws of one pass, ordered so that neighbours share their state.
///
/// A draw sets about twenty things on the encoder before it draws: six vertex streams,
/// six textures, four samplers and several small uniforms. In the order the visible
/// entities come, most draws have a different mesh and every other one a different
/// material from the draw before, so all of it is set again each time. A scene of
/// thousands of parts uses a few hundred materials, and the parts it repeats share
/// their meshes: ordered by material and then by mesh, most draws find the encoder
/// already holding what they need.
///
/// Opaque draws can be encoded in any order (depth decides what shows), so the order
/// is free to serve the encoder. It is the same from one frame and one run to the
/// next: materials and meshes are numbered as the visible list first shows them, and
/// draws that share both keep the order they were added in.
struct OpaqueDrawList {
    /// What the draws of one entity share.
    struct Entity {
        let entityId: EntityID
        let world: WorldTransformComponent
        let deformation: DeformationComponent?
        let hasSkeleton: Bool
        /// Opacity of an entity on a ghost channel; 1 for any other.
        let passthroughAlpha: Float
        let tileRepresentationFade: TileRepresentationFadeComponent?
        let meshFade: MeshFadeComponent?
    }

    /// The meshes an entity draws: its own, or one of the two levels of a LOD fade.
    struct MeshList {
        let entity: Int32
        let meshes: [Mesh]
        let ditherThreshold: Float
        let ditherMode: Float
    }

    /// One submesh to draw: `meshLists[meshList].meshes[mesh].submeshes[submesh]`.
    struct Draw {
        let meshList: Int32
        let mesh: Int32
        let submesh: Int32
    }

    private(set) var entities: [Entity] = []
    private(set) var meshLists: [MeshList] = []
    /// The draws in the order they were added. `order` is the order to encode them in.
    private(set) var draws: [Draw] = []
    /// Material number, mesh number and index into `draws` of every draw, packed so
    /// that sorting the numbers sorts the draws.
    private var keys: [UInt64] = []

    private var materialNumbers: [UInt64: UInt64] = [:]
    private var meshNumbers: [ObjectIdentifier: UInt64] = [:]

    // 20 bits of material, 22 of mesh, 22 of draw index. A number past its bits shares
    // the last one: the draws are then less well ordered, and still all drawn.
    private static let drawIndexBits: UInt64 = 22
    private static let meshBits: UInt64 = 22
    private static let materialBits: UInt64 = 20
    private static let drawIndexMask: UInt64 = (1 << drawIndexBits) - 1
    private static let meshNumberLimit: UInt64 = (1 << meshBits) - 1
    private static let materialNumberLimit: UInt64 = (1 << materialBits) - 1

    init(expectedEntities: Int = 0) {
        entities.reserveCapacity(expectedEntities)
        meshLists.reserveCapacity(expectedEntities)
        draws.reserveCapacity(expectedEntities)
        keys.reserveCapacity(expectedEntities)
        meshNumbers.reserveCapacity(expectedEntities)
    }

    /// Adds an entity and returns its index for `add(meshes:...)`.
    mutating func add(entity: Entity) -> Int32 {
        entities.append(entity)
        return Int32(entities.count - 1)
    }

    /// Adds the submeshes of `meshes` that the opaque pass draws: those with a material
    /// that is not blended (blended ones belong to the transparency pass).
    mutating func add(meshes: [Mesh], ditherThreshold: Float, ditherMode: Float, entity: Int32) {
        let listIndex = Int32(meshLists.count)
        meshLists.append(MeshList(entity: entity, meshes: meshes, ditherThreshold: ditherThreshold, ditherMode: ditherMode))

        for meshIndex in meshes.indices {
            var meshNumber: UInt64?
            for submeshIndex in meshes[meshIndex].submeshes.indices {
                // Read in place: a copy of a Material retains and releases every texture it holds.
                guard let alphaMode = meshes[meshIndex].submeshes[submeshIndex].material?.alphaMode,
                      alphaMode != .blend
                else { continue }

                if meshNumber == nil {
                    meshNumber = number(of: ObjectIdentifier(meshes[meshIndex].metalKitMesh))
                }
                let materialNumber = number(ofMaterialWith: Self.orderingKey(of: meshes[meshIndex].submeshes[submeshIndex]))

                let drawIndex = UInt64(draws.count)
                draws.append(Draw(meshList: listIndex, mesh: Int32(meshIndex), submesh: Int32(submeshIndex)))
                keys.append(
                    (materialNumber << (Self.meshBits + Self.drawIndexBits))
                        | ((meshNumber ?? 0) << Self.drawIndexBits)
                        | min(drawIndex, Self.drawIndexMask)
                )
            }
        }
    }

    /// The indices into `draws` in the order to encode them: by material, then by mesh,
    /// then as they were added.
    func order() -> [Int] {
        guard UInt64(draws.count) <= Self.drawIndexMask + 1 else {
            // More draws than the key has room to number: keep them as they came.
            return Array(draws.indices)
        }
        var sorted = keys
        sorted.sort()
        return sorted.map { Int($0 & Self.drawIndexMask) }
    }

    // MARK: - Numbering

    private mutating func number(of mesh: ObjectIdentifier) -> UInt64 {
        if let number = meshNumbers[mesh] {
            return number
        }
        let number = min(UInt64(meshNumbers.count), Self.meshNumberLimit)
        meshNumbers[mesh] = number
        return number
    }

    private mutating func number(ofMaterialWith orderingKey: UInt64) -> UInt64 {
        if let number = materialNumbers[orderingKey] {
            return number
        }
        let number = min(UInt64(materialNumbers.count), Self.materialNumberLimit)
        materialNumbers[orderingKey] = number
        return number
    }

    /// A number that is the same for two materials that bind the same textures and have
    /// the same main values. It only decides which draws sit next to each other: two
    /// different materials that happen to share it are told apart when they are bound.
    /// The fields are read one by one where they are: a copy of a Material retains and
    /// releases every object it holds.
    @inline(__always)
    private static func orderingKey(of submesh: SubMesh) -> UInt64 {
        var key: UInt64 = 0xCBF2_9CE4_8422_2325
        @inline(__always) func mix(_ value: UInt64) {
            key = (key ^ value) &* 0x0000_0100_0000_01B3
        }
        @inline(__always) func identity(_ texture: MTLTexture?) -> UInt64 {
            texture.map { UInt64(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? 0
        }
        @inline(__always) func bits(_ low: Float?, _ high: Float?) -> UInt64 {
            UInt64(low?.bitPattern ?? 0) | (UInt64(high?.bitPattern ?? 0) << 32)
        }
        mix(identity(submesh.material?.baseColor.texture))
        mix(identity(submesh.material?.normal.texture))
        mix(identity(submesh.material?.roughness.texture))
        mix(identity(submesh.material?.metallic.texture))
        mix(identity(submesh.material?.emissive.texture))
        mix(identity(submesh.material?.height.texture))
        mix(bits(submesh.material?.baseColorValue.x, submesh.material?.baseColorValue.y))
        mix(bits(submesh.material?.baseColorValue.z, submesh.material?.baseColorValue.w))
        mix(bits(submesh.material?.roughnessValue, submesh.material?.metallicValue))
        mix(bits(submesh.material?.emissiveValue.x, submesh.material?.emissiveValue.y))
        mix(bits(submesh.material?.emissiveValue.z, submesh.material?.alphaCutoff))
        return key
    }
}
