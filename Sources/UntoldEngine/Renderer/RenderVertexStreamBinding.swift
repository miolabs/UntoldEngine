//
//  RenderVertexStreamBinding.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  RenderVertexStreamBinding.swift
//  UntoldEngine
//
//  Shared per-mesh vertex-stream binding for the model-family and shadow-family
//  render passes.
//

import CShaderTypes
import Metal
import MetalKit
import simd

/// Mesh.metalKitMesh.vertexBuffers is laid out in model-descriptor order
/// (ModelPassBufferIndices 0-5) regardless of which pass consumes it; the
/// shadow pass sources from that same array but binds to its own slots.
/// When the deformation compute pass has produced deformed streams for the
/// mesh (see `DeformationSystem`), those replace the base position, normal,
/// and tangent buffers and vertex-shader skinning is disabled.
extension MTLRenderCommandEncoder {
    func bindModelVertexStreams(mesh: Mesh, entityId: EntityID) {
        bindModelVertexStreams(
            mesh: mesh,
            deformation: getEntityComponent(entityId: entityId, componentType: DeformationComponent.self),
            hasSkeleton: Self.hasSkeleton(mesh: mesh, entityId: entityId)
        )
    }

    /// For a pass that has read the entity's deformation component and knows whether it
    /// has a skeleton: the entity's meshes are then bound without asking the scene again.
    func bindModelVertexStreams(mesh: Mesh, deformation: DeformationComponent?, hasSkeleton: Bool) {
        let deformed = deformedStreams(mesh: mesh, deformation: deformation)
        // Asked once: `vertexBuffers` hands out a new array every time it is read.
        let vertexBuffers = mesh.metalKitMesh.vertexBuffers

        setVertexBuffer(
            deformed?.positions ?? vertexBuffers[Int(modelPassVerticesIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassVerticesIndex.rawValue)
        )
        setVertexBuffer(
            deformed?.normals ?? vertexBuffers[Int(modelPassNormalIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassNormalIndex.rawValue)
        )
        setVertexBuffer(
            vertexBuffers[Int(modelPassUVIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassUVIndex.rawValue)
        )
        setVertexBuffer(
            deformed?.tangents ?? vertexBuffers[Int(modelPassTangentIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassTangentIndex.rawValue)
        )
        setVertexBuffer(
            vertexBuffers[Int(modelPassJointIdIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassJointIdIndex.rawValue)
        )
        setVertexBuffer(
            vertexBuffers[Int(modelPassJointWeightsIndex.rawValue)].buffer,
            offset: 0,
            index: Int(modelPassJointWeightsIndex.rawValue)
        )
        bindJointStreams(
            mesh: mesh,
            hasSkeleton: hasSkeleton,
            skinnedInCompute: deformed != nil,
            hasArmatureIndex: Int(modelPassHasArmature.rawValue),
            jointTransformIndex: Int(modelPassJointTransformIndex.rawValue)
        )
    }

    func bindShadowVertexStreams(mesh: Mesh, entityId: EntityID) {
        bindShadowVertexStreams(
            mesh: mesh,
            deformation: getEntityComponent(entityId: entityId, componentType: DeformationComponent.self),
            hasSkeleton: Self.hasSkeleton(mesh: mesh, entityId: entityId)
        )
    }

    /// See `bindModelVertexStreams(mesh:deformation:hasSkeleton:)`.
    func bindShadowVertexStreams(mesh: Mesh, deformation: DeformationComponent?, hasSkeleton: Bool) {
        let deformed = deformedStreams(mesh: mesh, deformation: deformation)
        let vertexBuffers = mesh.metalKitMesh.vertexBuffers

        setVertexBuffer(
            deformed?.positions ?? vertexBuffers[Int(modelPassVerticesIndex.rawValue)].buffer,
            offset: 0,
            index: Int(shadowPassModelPositionIndex.rawValue)
        )
        setVertexBuffer(
            vertexBuffers[Int(modelPassJointIdIndex.rawValue)].buffer,
            offset: 0,
            index: Int(shadowPassJointIdIndex.rawValue)
        )
        setVertexBuffer(
            vertexBuffers[Int(modelPassJointWeightsIndex.rawValue)].buffer,
            offset: 0,
            index: Int(shadowPassJointWeightsIndex.rawValue)
        )
        bindJointStreams(
            mesh: mesh,
            hasSkeleton: hasSkeleton,
            skinnedInCompute: deformed != nil,
            hasArmatureIndex: Int(shadowPassHasArmature.rawValue),
            jointTransformIndex: Int(shadowPassJointTransformIndex.rawValue)
        )
    }

    /// Deformed streams exist only after the deformation pass has run for
    /// this mesh; until then (or without a DeformationComponent) draws use
    /// the base streams and vertex-shader skinning.
    private func deformedStreams(mesh: Mesh, deformation: DeformationComponent?) -> MeshDeformationBuffers? {
        deformation?.meshDeformations[ObjectIdentifier(mesh.metalKitMesh)]
    }

    /// Whether the mesh can be skinned in the vertex shader: only a mesh with joint
    /// transforms asks whether its entity has a skeleton.
    private static func hasSkeleton(mesh: Mesh, entityId: EntityID) -> Bool {
        mesh.skin?.jointTransformsBuffer != nil
            && getEntityComponent(entityId: entityId, componentType: SkeletonComponent.self) != nil
    }

    private func bindJointStreams(
        mesh: Mesh,
        hasSkeleton: Bool,
        skinnedInCompute: Bool,
        hasArmatureIndex: Int,
        jointTransformIndex: Int
    ) {
        // Only enable armature path when a valid joint transform buffer
        // exists and skinning did not already happen in compute.
        let jointTransformBuffer = mesh.skin?.jointTransformsBuffer
        var hasArmature = !skinnedInCompute
            && hasSkeleton
            && jointTransformBuffer != nil
        setVertexBytes(&hasArmature, length: MemoryLayout<Bool>.stride, index: hasArmatureIndex)

        if hasArmature, let jointTransformBuffer {
            setVertexBuffer(jointTransformBuffer, offset: 0, index: jointTransformIndex)
        } else {
            var identityMatrix = matrix_identity_float4x4
            setVertexBytes(
                &identityMatrix,
                length: MemoryLayout<simd_float4x4>.stride,
                index: jointTransformIndex
            )
        }
    }
}
