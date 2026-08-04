//
//  DeformationSystem.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import Foundation
import Metal
import simd

/// Encodes the per-frame deformation compute pass: skins the meshes of every
/// entity carrying a `DeformationComponent` into per-mesh deformed
/// position/normal/tangent buffers, which the render passes bind in place of
/// the base vertex streams (see `RenderVertexStreamBinding`). Runs as the
/// `"deformation"` render-graph node ahead of the shadow pass, on the same
/// command buffer as the rest of the frame, so no extra synchronization is
/// needed.
final class DeformationSystem: @unchecked Sendable {
    static let shared = DeformationSystem()

    var skinLBSPipeline = ComputePipeline()

    private init() {}

    func initComputePipelines() {
        guard let device = renderInfo.device, let library = renderInfo.library else {
            handleError(.metalDeviceNotFound)
            return
        }
        createComputePipeline(
            into: &skinLBSPipeline,
            device: device,
            library: library,
            functionName: "deformSkinLBS",
            pipelineName: "Deformation Skin LBS pipe"
        )
    }

    static let executeDeformationPass: RenderPasses.RenderPassExecution = { commandBuffer in
        DeformationSystem.shared.encode(commandBuffer)
    }

    func encode(_ commandBuffer: MTLCommandBuffer) {
        guard let pipelineState = skinLBSPipeline.pipelineState, skinLBSPipeline.success else {
            return
        }

        let entities = queryEntities(with: [
            DeformationComponent.self, SkeletonComponent.self, RenderComponent.self,
        ])
        guard !entities.isEmpty else { return }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            handleError(.renderPassCreationFailed, "Deformation Pass")
            return
        }
        encoder.label = "Deformation Pass"
        encoder.setComputePipelineState(pipelineState)

        for entityId in entities {
            guard let deformationComponent = scene.get(component: DeformationComponent.self, for: entityId),
                  let renderComponent = scene.get(component: RenderComponent.self, for: entityId)
            else { continue }

            for mesh in renderComponent.mesh {
                guard let jointTransformBuffer = mesh.skin?.jointTransformsBuffer else { continue }
                guard let buffers = deformedBuffers(
                    for: mesh, in: deformationComponent, device: commandBuffer.device
                ) else { continue }

                encodeSkinLBS(
                    encoder: encoder,
                    mesh: mesh,
                    jointTransformBuffer: jointTransformBuffer,
                    output: buffers
                )
            }
        }

        encoder.endEncoding()
    }

    /// Returns the deformed-stream buffers for `mesh`, allocating them on
    /// first use. Allocation failure leaves the entry nil so draws stay on the
    /// legacy vertex-shader path.
    private func deformedBuffers(
        for mesh: Mesh,
        in component: DeformationComponent,
        device: MTLDevice
    ) -> MeshDeformationBuffers? {
        let key = ObjectIdentifier(mesh.metalKitMesh)
        if let existing = component.meshDeformations[key] {
            return existing
        }
        guard let buffers = MeshDeformationBuffers(
            device: device,
            vertexCount: mesh.metalKitMesh.vertexCount,
            label: mesh.name
        ) else {
            Logger.logWarning(message: "Failed to allocate deformation buffers for mesh \(mesh.name)")
            return nil
        }
        component.meshDeformations[key] = buffers
        return buffers
    }

    private func encodeSkinLBS(
        encoder: MTLComputeCommandEncoder,
        mesh: Mesh,
        jointTransformBuffer: MTLBuffer,
        output: MeshDeformationBuffers
    ) {
        let vertexBuffers = mesh.metalKitMesh.vertexBuffers

        encoder.setBuffer(
            vertexBuffers[Int(modelPassVerticesIndex.rawValue)].buffer,
            offset: 0, index: Int(deformationPassInPositionIndex.rawValue)
        )
        encoder.setBuffer(
            vertexBuffers[Int(modelPassNormalIndex.rawValue)].buffer,
            offset: 0, index: Int(deformationPassInNormalIndex.rawValue)
        )
        encoder.setBuffer(
            vertexBuffers[Int(modelPassTangentIndex.rawValue)].buffer,
            offset: 0, index: Int(deformationPassInTangentIndex.rawValue)
        )
        encoder.setBuffer(
            vertexBuffers[Int(modelPassJointIdIndex.rawValue)].buffer,
            offset: 0, index: Int(deformationPassJointIdIndex.rawValue)
        )
        encoder.setBuffer(
            vertexBuffers[Int(modelPassJointWeightsIndex.rawValue)].buffer,
            offset: 0, index: Int(deformationPassJointWeightsIndex.rawValue)
        )
        encoder.setBuffer(
            jointTransformBuffer,
            offset: 0, index: Int(deformationPassJointTransformIndex.rawValue)
        )
        encoder.setBuffer(output.positions, offset: 0, index: Int(deformationPassOutPositionIndex.rawValue))
        encoder.setBuffer(output.normals, offset: 0, index: Int(deformationPassOutNormalIndex.rawValue))
        encoder.setBuffer(output.tangents, offset: 0, index: Int(deformationPassOutTangentIndex.rawValue))

        var params = DeformationPassParams(vertexCount: UInt32(output.vertexCount))
        encoder.setBytes(
            &params,
            length: MemoryLayout<DeformationPassParams>.stride,
            index: Int(deformationPassParamsIndex.rawValue)
        )

        guard let pipelineState = skinLBSPipeline.pipelineState else { return }
        let width = pipelineState.threadExecutionWidth
        let threadgroups = MTLSize(
            width: (output.vertexCount + width - 1) / width, height: 1, depth: 1
        )
        encoder.dispatchThreadgroups(
            threadgroups,
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }
}

/// Opts `entityId` into the deformation compute pass with the given skinning
/// mode. Like `setEntityAnimations`, the component is applied to the
/// skeleton-carrying entities resolved from `entityId` (hierarchical assets
/// keep their skeleton on a child entity).
public func setEntityDeformation(entityId: EntityID, skinningMode: SkinningMode = .lbs) {
    guard scene.exists(entityId) else { return }
    for targetEntityId in resolveAnimationBindingTargetEntities(entityId: entityId) {
        guard scene.get(component: SkeletonComponent.self, for: targetEntityId) != nil,
              let component = scene.assign(to: targetEntityId, component: DeformationComponent.self)
        else { continue }
        component.skinningMode = skinningMode
    }
}

/// Returns `entityId` (and its resolved skeleton entities) to the legacy
/// vertex-shader skinning path.
public func removeEntityDeformation(entityId: EntityID) {
    guard scene.exists(entityId) else { return }
    for targetEntityId in resolveAnimationBindingTargetEntities(entityId: entityId) {
        guard let component = scene.get(component: DeformationComponent.self, for: targetEntityId) else {
            continue
        }
        component.cleanUp()
        scene.remove(component: DeformationComponent.self, from: targetEntityId)
    }
}
