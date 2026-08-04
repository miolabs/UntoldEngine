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
    var skinDQSPipeline = ComputePipeline()
    var skinDDMPipeline = ComputePipeline()
    var dualQuatPalettePipeline = ComputePipeline()

    /// Per-skin dual-quaternion palettes, rebuilt on the GPU each frame from
    /// the joint matrix palette. Keyed by mesh identity.
    private var dqsPalettes: [ObjectIdentifier: MTLBuffer] = [:]

    /// Direct Delta Mush bakes, shared across entities that render the same
    /// mesh. Guarded by `ddmLock`: the bake runs on a background queue while
    /// the render thread keeps encoding LBS frames.
    private enum DDMBakeState {
        case building
        case ready(MTLBuffer)
    }

    private var ddmOmegaStates: [ObjectIdentifier: DDMBakeState] = [:]
    private let ddmLock = NSLock()
    private let ddmBakeQueue = DispatchQueue(label: "com.untoldengine.ddm-bake", qos: .utility)

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
        createComputePipeline(
            into: &skinDQSPipeline,
            device: device,
            library: library,
            functionName: "deformSkinDQS",
            pipelineName: "Deformation Skin DQS pipe"
        )
        createComputePipeline(
            into: &skinDDMPipeline,
            device: device,
            library: library,
            functionName: "deformSkinDDM",
            pipelineName: "Deformation Skin DDM pipe"
        )
        createComputePipeline(
            into: &dualQuatPalettePipeline,
            device: device,
            library: library,
            functionName: "deformDualQuatPalette",
            pipelineName: "Deformation DualQuat Palette pipe"
        )
    }

    static let executeDeformationPass: RenderPasses.RenderPassExecution = { commandBuffer in
        DeformationSystem.shared.encode(commandBuffer)
    }

    func encode(_ commandBuffer: MTLCommandBuffer) {
        guard skinLBSPipeline.success else { return }

        let entities = queryEntities(with: [
            DeformationComponent.self, SkeletonComponent.self, RenderComponent.self,
        ])
        guard !entities.isEmpty else { return }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            handleError(.renderPassCreationFailed, "Deformation Pass")
            return
        }
        encoder.label = "Deformation Pass"

        for entityId in entities {
            guard let deformationComponent = scene.get(component: DeformationComponent.self, for: entityId),
                  let renderComponent = scene.get(component: RenderComponent.self, for: entityId)
            else { continue }

            for mesh in renderComponent.mesh {
                guard let jointTransformBuffer = mesh.skin?.jointTransformsBuffer else { continue }
                guard let buffers = deformedBuffers(
                    for: mesh, in: deformationComponent, device: commandBuffer.device
                ) else { continue }

                switch effectiveMode(for: deformationComponent, mesh: mesh, device: commandBuffer.device) {
                case .lbs:
                    guard let pipeline = skinLBSPipeline.pipelineState else { continue }
                    encoder.setComputePipelineState(pipeline)
                    encodeSkin(
                        encoder: encoder, pipeline: pipeline, mesh: mesh,
                        jointTransformBuffer: jointTransformBuffer, omegaBuffer: nil, output: buffers
                    )
                case .dqs:
                    guard let skinPipeline = skinDQSPipeline.pipelineState,
                          let palettePipeline = dualQuatPalettePipeline.pipelineState,
                          let palette = dqsPalette(for: mesh, jointTransformBuffer: jointTransformBuffer, device: commandBuffer.device)
                    else { continue }
                    encodeDualQuatPalette(
                        encoder: encoder, pipeline: palettePipeline,
                        jointTransformBuffer: jointTransformBuffer, palette: palette
                    )
                    encoder.setComputePipelineState(skinPipeline)
                    encodeSkin(
                        encoder: encoder, pipeline: skinPipeline, mesh: mesh,
                        jointTransformBuffer: palette, omegaBuffer: nil, output: buffers
                    )
                case .ddm:
                    guard let pipeline = skinDDMPipeline.pipelineState,
                          let omegas = readyDDMOmegas(for: mesh)
                    else { continue }
                    encoder.setComputePipelineState(pipeline)
                    encodeSkin(
                        encoder: encoder, pipeline: pipeline, mesh: mesh,
                        jointTransformBuffer: jointTransformBuffer, omegaBuffer: omegas, output: buffers
                    )
                }
            }
        }

        encoder.endEncoding()
    }

    // MARK: - Mode resolution

    /// DDM needs its background bake; until it completes (or if the bake
    /// pipeline is unavailable) the mesh skins with LBS so the character
    /// never disappears or hitches.
    private func effectiveMode(
        for component: DeformationComponent,
        mesh: Mesh,
        device: MTLDevice
    ) -> SkinningMode {
        switch component.skinningMode {
        case .lbs, .dqs:
            return component.skinningMode
        case .ddm:
            guard skinDDMPipeline.success else { return .lbs }
            let key = ObjectIdentifier(mesh.metalKitMesh)
            ddmLock.lock()
            let state = ddmOmegaStates[key]
            ddmLock.unlock()
            switch state {
            case .ready:
                return .ddm
            case .building:
                return .lbs
            case nil:
                startDDMBake(for: mesh, key: key, device: device)
                return .lbs
            }
        }
    }

    private func readyDDMOmegas(for mesh: Mesh) -> MTLBuffer? {
        ddmLock.lock()
        defer { ddmLock.unlock() }
        if case let .ready(buffer) = ddmOmegaStates[ObjectIdentifier(mesh.metalKitMesh)] {
            return buffer
        }
        return nil
    }

    /// Snapshots the mesh's CPU-visible vertex streams on the caller's thread
    /// and bakes the omega field in the background.
    private func startDDMBake(for mesh: Mesh, key: ObjectIdentifier, device: MTLDevice) {
        let vertexCount = mesh.metalKitMesh.vertexCount
        let vertexBuffers = mesh.metalKitMesh.vertexBuffers

        func snapshot<T>(_ slot: ModelPassBufferIndices, as _: T.Type) -> [T] {
            let buffer = vertexBuffers[Int(slot.rawValue)].buffer
            let pointer = buffer.contents().bindMemory(to: T.self, capacity: vertexCount)
            return Array(UnsafeBufferPointer(start: pointer, count: vertexCount))
        }

        var triangleIndices: [UInt32] = []
        for submesh in mesh.submeshes {
            let metalSubmesh = submesh.metalKitSubmesh
            guard metalSubmesh.primitiveType == .triangle else { continue }
            let indexBuffer = metalSubmesh.indexBuffer
            let raw = indexBuffer.buffer.contents().advanced(by: indexBuffer.offset)
            switch metalSubmesh.indexType {
            case .uint16:
                let pointer = raw.bindMemory(to: UInt16.self, capacity: metalSubmesh.indexCount)
                triangleIndices.append(contentsOf: UnsafeBufferPointer(start: pointer, count: metalSubmesh.indexCount).map(UInt32.init))
            case .uint32:
                let pointer = raw.bindMemory(to: UInt32.self, capacity: metalSubmesh.indexCount)
                triangleIndices.append(contentsOf: UnsafeBufferPointer(start: pointer, count: metalSubmesh.indexCount))
            @unknown default:
                continue
            }
        }

        let input = DDMPrecomputeInput(
            positions: snapshot(modelPassVerticesIndex, as: simd_float4.self),
            jointIndices: snapshot(modelPassJointIdIndex, as: simd_ushort4.self),
            jointWeights: snapshot(modelPassJointWeightsIndex, as: simd_float4.self),
            triangleIndices: triangleIndices
        )

        ddmLock.lock()
        ddmOmegaStates[key] = .building
        ddmLock.unlock()

        let meshName = mesh.name
        ddmBakeQueue.async { [weak self] in
            guard let self else { return }
            let entries = DDMPrecompute.bakeOmegas(input: input)
            let length = entries.count * MemoryLayout<DDMOmegaEntry>.stride
            let buffer = entries.withUnsafeBytes { bytes -> MTLBuffer? in
                guard let baseAddress = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: baseAddress, length: length, options: .storageModeShared)
            }
            ddmLock.lock()
            if let buffer {
                buffer.label = "\(meshName) DDM omegas"
                ddmOmegaStates[key] = .ready(buffer)
            } else {
                ddmOmegaStates[key] = nil
            }
            ddmLock.unlock()
            Logger.log(message: "DDM bake finished for mesh \(meshName) (\(input.positions.count) vertices)")
        }
    }

    // MARK: - Palette + dispatch helpers

    private func dqsPalette(
        for mesh: Mesh,
        jointTransformBuffer: MTLBuffer,
        device: MTLDevice
    ) -> MTLBuffer? {
        let key = ObjectIdentifier(mesh.metalKitMesh)
        let jointCount = jointTransformBuffer.length / MemoryLayout<simd_float4x4>.stride
        let length = jointCount * MemoryLayout<JointDualQuat>.stride
        if let existing = dqsPalettes[key], existing.length >= length {
            return existing
        }
        guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
            return nil
        }
        buffer.label = "\(mesh.name) dual-quat palette"
        dqsPalettes[key] = buffer
        return buffer
    }

    private func encodeDualQuatPalette(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        jointTransformBuffer: MTLBuffer,
        palette: MTLBuffer
    ) {
        let jointCount = jointTransformBuffer.length / MemoryLayout<simd_float4x4>.stride
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(jointTransformBuffer, offset: 0, index: Int(dualQuatPaletteJointTransformIndex.rawValue))
        encoder.setBuffer(palette, offset: 0, index: Int(dualQuatPaletteOutIndex.rawValue))
        var params = DualQuatPaletteParams(jointCount: UInt32(jointCount))
        encoder.setBytes(
            &params,
            length: MemoryLayout<DualQuatPaletteParams>.stride,
            index: Int(dualQuatPaletteParamsIndex.rawValue)
        )
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreadgroups(
            MTLSize(width: (jointCount + width - 1) / width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
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

    private func encodeSkin(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        mesh: Mesh,
        jointTransformBuffer: MTLBuffer,
        omegaBuffer: MTLBuffer?,
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
        if let omegaBuffer {
            encoder.setBuffer(omegaBuffer, offset: 0, index: Int(deformationPassOmegaIndex.rawValue))
        }
        encoder.setBuffer(output.positions, offset: 0, index: Int(deformationPassOutPositionIndex.rawValue))
        encoder.setBuffer(output.normals, offset: 0, index: Int(deformationPassOutNormalIndex.rawValue))
        encoder.setBuffer(output.tangents, offset: 0, index: Int(deformationPassOutTangentIndex.rawValue))

        var params = DeformationPassParams(vertexCount: UInt32(output.vertexCount))
        encoder.setBytes(
            &params,
            length: MemoryLayout<DeformationPassParams>.stride,
            index: Int(deformationPassParamsIndex.rawValue)
        )

        let width = pipeline.threadExecutionWidth
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
