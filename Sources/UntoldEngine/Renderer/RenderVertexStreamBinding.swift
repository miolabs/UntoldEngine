
//
//  RenderVertexStreamBinding.swift
//  UntoldEngine
//
//  Shared per-mesh vertex-stream binding for the model-family and shadow-family
//  render passes.
//

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
        bindModelVertexStreams(mesh: mesh, entityId: entityId, hasDeformation: true, hasSkeleton: nil)
    }

    /// `hasDeformation` false and `hasSkeleton` tell what the caller already knows about
    /// the entity's components, so that they are not looked up for every mesh.
    func bindModelVertexStreams(mesh: Mesh, entityId: EntityID, hasDeformation: Bool, hasSkeleton: Bool?) {
        let deformed = hasDeformation ? deformedStreams(mesh: mesh, entityId: entityId) : nil
        // One call: `vertexBuffers` builds an array each time it is asked for.
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
            entityId: entityId,
            skinnedInCompute: deformed != nil,
            hasSkeleton: hasSkeleton,
            hasArmatureIndex: Int(modelPassHasArmature.rawValue),
            jointTransformIndex: Int(modelPassJointTransformIndex.rawValue)
        )
    }

    func bindShadowVertexStreams(mesh: Mesh, entityId: EntityID) {
        bindShadowVertexStreams(mesh: mesh, entityId: entityId, hasDeformation: true, hasSkeleton: nil)
    }

    func bindShadowVertexStreams(mesh: Mesh, entityId: EntityID, hasDeformation: Bool, hasSkeleton: Bool?) {
        let deformed = hasDeformation ? deformedStreams(mesh: mesh, entityId: entityId) : nil
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
            entityId: entityId,
            skinnedInCompute: deformed != nil,
            hasSkeleton: hasSkeleton,
            hasArmatureIndex: Int(shadowPassHasArmature.rawValue),
            jointTransformIndex: Int(shadowPassJointTransformIndex.rawValue)
        )
    }

    /// Deformed streams exist only after the deformation pass has run for
    /// this mesh; until then (or without a DeformationComponent) draws use
    /// the base streams and vertex-shader skinning.
    private func deformedStreams(mesh: Mesh, entityId: EntityID) -> MeshDeformationBuffers? {
        guard let component = getEntityComponent(entityId: entityId, componentType: DeformationComponent.self) else {
            return nil
        }
        return component.meshDeformations[ObjectIdentifier(mesh.metalKitMesh)]
    }

    private func bindJointStreams(
        mesh: Mesh,
        entityId: EntityID,
        skinnedInCompute: Bool,
        hasSkeleton: Bool? = nil,
        hasArmatureIndex: Int,
        jointTransformIndex: Int
    ) {
        // Only enable armature path when a valid joint transform buffer
        // exists and skinning did not already happen in compute.
        let jointTransformBuffer = mesh.skin?.jointTransformsBuffer
        var hasArmature = !skinnedInCompute
            && jointTransformBuffer != nil
            && (hasSkeleton ?? (getEntityComponent(entityId: entityId, componentType: SkeletonComponent.self) != nil))
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
