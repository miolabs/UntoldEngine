//
//  RenderPasses+InstancedDraws.swift
//  UntoldEngine
//
//  How the opaque pass and the shadow cascades encode the entities they draw instanced.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import Foundation
import Metal
import MetalKit
import simd

extension RenderPasses {
    /// What a pass drew instanced: its groups (one per distinct mesh list), the entities
    /// in them, and the draws they took (one per submesh of a group).
    struct InstancedDrawCounts: Equatable {
        var groups = 0
        var instances = 0
        var draws = 0
    }

    /// The pipeline a pass draws instanced with, next to the `pipeline` it draws single
    /// entities with. Nil when the pass has to draw every entity on its own: instanced
    /// drawing is off, or the renderer was set up without the instanced pipeline.
    static func instancedPipeline(_ type: RenderPipelineType, beside pipeline: RenderPipeline) -> RenderPipeline? {
        guard InstancedDrawing.isEnabled,
              let instanced = PipelineManager.shared.renderPipelinesByType[type],
              instanced.success,
              instanced.pipelineState != nil,
              instanced.rasterSampleCount == pipeline.rasterSampleCount
        else { return nil }
        return instanced
    }

    /// The id of what `component` draws in the table generation of this pass, or
    /// `RenderInstanceKey.notInstanced`. The component remembers it until its meshes change.
    @inline(__always)
    static func instanceKeyID(of component: RenderComponent, generation: UInt32) -> Int32 {
        let key = component.instanceKey
        if key.generation == generation {
            return key.id
        }
        return RenderInstanceKeyTable.shared.resolve(component)
    }

    /// Borrows a buffer for `byteCount` bytes of instance records and has the command
    /// buffer give it back when the GPU is done with the frame.
    private static func borrowInstanceRecords(byteCount: Int, for commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        guard let device = renderInfo.device,
              let borrowed = InstanceRecordBufferPool.shared.borrow(length: byteCount, device: device)
        else {
            handleError(.bufferAllocationFailed, "Instance Records")
            return nil
        }
        let token = borrowed.token
        commandBuffer.addCompletedHandler { _ in
            InstanceRecordBufferPool.shared.giveBack(token)
        }
        return borrowed.buffer
    }

    // MARK: - Opaque pass

    /// Encodes the entities the opaque pass gathered in `draws`: one draw per submesh of
    /// each group. The encoder is left on the instanced pipeline.
    @discardableResult
    static func encodeInstancedOpaqueDraws(
        _ draws: inout InstancedDrawList,
        pipeline: RenderPipeline,
        renderEncoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        cameraPosition: simd_float3,
        pomQuality: POMQualityUniform
    ) -> InstancedDrawCounts {
        guard !draws.isEmpty, let pipelineState = pipeline.pipelineState else { return InstancedDrawCounts() }

        draws.layOutRecords()
        let stride = MemoryLayout<ModelInstanceUniform>.stride
        guard let records = borrowInstanceRecords(byteCount: draws.recordCount * stride, for: commandBuffer) else {
            return InstancedDrawCounts()
        }
        draws.writeModelRecords(
            to: records.contents().bindMemory(to: ModelInstanceUniform.self, capacity: draws.recordCount),
            viewMatrix: viewMatrix
        )

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(pipeline.depthState)

        // What the pass shares. The instanced stages take a surface's transform from its
        // record, so the model matrices here are never read.
        var passUniforms = Uniforms()
        passUniforms.projectionMatrix = projectionMatrix
        passUniforms.viewMatrix = viewMatrix
        passUniforms.modelViewMatrix = viewMatrix
        passUniforms.normalMatrix = matrix_identity_float3x3
        passUniforms.modelMatrix = matrix_identity_float4x4
        passUniforms.cameraPosition = cameraPosition
        renderEncoder.setVertexBytes(&passUniforms, length: MemoryLayout<Uniforms>.stride, index: Int(modelPassUniformIndex.rawValue))
        renderEncoder.setFragmentBytes(&passUniforms, length: MemoryLayout<Uniforms>.stride, index: Int(modelPassFragmentUniformIndex.rawValue))
        renderEncoder.setVertexBuffer(records, offset: 0, index: Int(modelPassInstanceIndex.rawValue))
        renderEncoder.setFragmentBuffer(records, offset: 0, index: Int(modelPassFragmentInstanceIndex.rawValue))
        var pomQuality = pomQuality
        renderEncoder.setFragmentBytes(&pomQuality, length: MemoryLayout<POMQualityUniform>.stride, index: Int(modelPassFragmentPOMQualityIndex.rawValue))

        var drawCount = 0
        for groupIndex in draws.groups.indices {
            let group = draws.groups[groupIndex]
            let meshes = draws.groupComponents[groupIndex].mesh

            for meshIndex in meshes.indices {
                var boundStreams = false
                let baseInstance = draws.baseInstance(of: group, meshIndex: meshIndex)

                for submeshIndex in meshes[meshIndex].submeshes.indices {
                    // The material is read where it is: a copy of a Material retains and
                    // releases every texture it holds.
                    guard let alphaMode = meshes[meshIndex].submeshes[submeshIndex].material?.alphaMode,
                          alphaMode != .blend
                    else { continue }

                    if !boundStreams {
                        bindInstancedModelStreams(of: meshes[meshIndex], renderEncoder: renderEncoder)
                        boundStreams = true
                    }
                    bindInstancedMaterial(meshes[meshIndex].submeshes[submeshIndex].material!, renderEncoder: renderEncoder)

                    renderEncoder.drawIndexedPrimitivesTracked(
                        type: meshes[meshIndex].submeshes[submeshIndex].primitiveType,
                        indexCount: meshes[meshIndex].submeshes[submeshIndex].indexCount,
                        indexType: meshes[meshIndex].submeshes[submeshIndex].indexType,
                        indexBuffer: meshes[meshIndex].submeshes[submeshIndex].indexBuffer,
                        indexBufferOffset: meshes[meshIndex].submeshes[submeshIndex].indexBufferOffset,
                        instanceCount: Int(group.instanceCount),
                        baseInstance: baseInstance,
                        category: .opaque
                    )
                    drawCount += 1
                }
            }
        }

        return InstancedDrawCounts(groups: draws.groups.count, instances: draws.instanceCount, draws: drawCount)
    }

    /// The four vertex streams an instanced model draw reads. A mesh drawn instanced has
    /// no skeleton and no deformed copy of its vertices.
    @inline(__always)
    private static func bindInstancedModelStreams(of mesh: borrowing Mesh, renderEncoder: MTLRenderCommandEncoder) {
        let positions = Int(modelPassVerticesIndex.rawValue)
        let normals = Int(modelPassNormalIndex.rawValue)
        let textureCoordinates = Int(modelPassUVIndex.rawValue)
        let tangents = Int(modelPassTangentIndex.rawValue)
        renderEncoder.setVertexBuffer(mesh.vertexBuffers[positions], offset: 0, index: positions)
        renderEncoder.setVertexBuffer(mesh.vertexBuffers[normals], offset: 0, index: normals)
        renderEncoder.setVertexBuffer(mesh.vertexBuffers[textureCoordinates], offset: 0, index: textureCoordinates)
        renderEncoder.setVertexBuffer(mesh.vertexBuffers[tangents], offset: 0, index: tangents)
    }

    /// Everything of `material` an instanced opaque draw hands to the encoder: what the
    /// pass binds for an entity it draws on its own, less what belongs to the entity (the
    /// ghost opacity is in the instance's record; an instance has no dither).
    /// `MeshListDescription` lists the same values: keep the two in step.
    @inline(__always)
    private static func bindInstancedMaterial(_ material: borrowing Material, renderEncoder: MTLRenderCommandEncoder) {
        var stScale: Float = material.stScale
        renderEncoder.setFragmentBytes(&stScale, length: MemoryLayout<Float>.stride, index: Int(modelPassFragmentSTScaleIndex.rawValue))

        renderEncoder.setFragmentTexture(material.baseColor.texture, index: Int(modelPassBaseTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(material.baseColor.sampler, index: Int(modelPassBaseSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(material.roughness.texture, index: Int(modelPassRoughnessTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(material.roughness.sampler, index: Int(modelPassMaterialSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(material.metallic.texture, index: Int(modelPassMetallicTextureIndex.rawValue))

        var hasNormal = (material.normal.texture != nil)
        renderEncoder.setFragmentBytes(&hasNormal, length: MemoryLayout<Bool>.stride, index: Int(modelPassFragmentHasNormalTextureIndex.rawValue))
        var normalIsPackedXY = material.normalIsPackedXY
        renderEncoder.setFragmentBytes(&normalIsPackedXY, length: MemoryLayout<Bool>.stride, index: Int(modelPassFragmentNormalIsPackedXYIndex.rawValue))

        var materialParameters = opaqueMaterialParameters(of: material)
        renderEncoder.setFragmentBytes(&materialParameters, length: MemoryLayout<MaterialParametersUniform>.stride, index: Int(modelPassFragmentMaterialParameterIndex.rawValue))

        renderEncoder.setFragmentTexture(material.normal.texture, index: Int(modelPassNormalTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(material.normal.sampler, index: Int(modelPassNormalSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(material.height.texture, index: Int(modelPassHeightTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(material.height.sampler, index: Int(modelPassHeightSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(material.emissive.texture, index: Int(modelPassEmissiveTextureIndex.rawValue))
    }

    // MARK: - Shadow cascades

    /// Encodes the casters a shadow cascade gathered in `draws`: one draw per submesh of
    /// each group. The light's matrix, the depth bias and the viewport are the encoder's
    /// already; it is left on the instanced pipeline.
    @discardableResult
    static func encodeInstancedShadowDraws(
        _ draws: inout InstancedDrawList,
        pipeline: RenderPipeline,
        renderEncoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer
    ) -> InstancedDrawCounts {
        guard !draws.isEmpty, let pipelineState = pipeline.pipelineState else { return InstancedDrawCounts() }

        draws.layOutRecords()
        let stride = MemoryLayout<simd_float4x4>.stride
        guard let records = borrowInstanceRecords(byteCount: draws.recordCount * stride, for: commandBuffer) else {
            return InstancedDrawCounts()
        }
        draws.writeShadowRecords(to: records.contents().bindMemory(to: simd_float4x4.self, capacity: draws.recordCount))

        renderEncoder.setRenderPipelineState(pipelineState)
        if let depthState = pipeline.depthState {
            renderEncoder.setDepthStencilState(depthState)
        }
        renderEncoder.setVertexBuffer(records, offset: 0, index: Int(shadowPassInstanceIndex.rawValue))

        var drawCount = 0
        for groupIndex in draws.groups.indices {
            let group = draws.groups[groupIndex]
            let meshes = draws.groupComponents[groupIndex].mesh

            for meshIndex in meshes.indices where !meshes[meshIndex].submeshes.isEmpty {
                renderEncoder.setVertexBuffer(
                    meshes[meshIndex].vertexBuffers[Int(modelPassVerticesIndex.rawValue)],
                    offset: 0,
                    index: Int(shadowPassModelPositionIndex.rawValue)
                )
                let baseInstance = draws.baseInstance(of: group, meshIndex: meshIndex)

                // Every submesh casts, as when the caster is drawn on its own.
                for submeshIndex in meshes[meshIndex].submeshes.indices {
                    renderEncoder.drawIndexedPrimitivesTracked(
                        type: meshes[meshIndex].submeshes[submeshIndex].primitiveType,
                        indexCount: meshes[meshIndex].submeshes[submeshIndex].indexCount,
                        indexType: meshes[meshIndex].submeshes[submeshIndex].indexType,
                        indexBuffer: meshes[meshIndex].submeshes[submeshIndex].indexBuffer,
                        indexBufferOffset: meshes[meshIndex].submeshes[submeshIndex].indexBufferOffset,
                        instanceCount: Int(group.instanceCount),
                        baseInstance: baseInstance,
                        category: .shadow
                    )
                    drawCount += 1
                }
            }
        }

        return InstancedDrawCounts(groups: draws.groups.count, instances: draws.instanceCount, draws: drawCount)
    }
}
