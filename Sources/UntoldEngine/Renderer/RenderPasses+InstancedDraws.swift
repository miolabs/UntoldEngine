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
            let component = draws.groupComponents[groupIndex]
            let meshes = component.mesh

            // What the group's draws bind is prepared once per component, not per frame.
            let submeshDraws: [InstancedSubmeshDraw]
            if let prepared = component.instancedSubmeshDraws {
                submeshDraws = prepared
            } else {
                submeshDraws = InstancedSubmeshDraw.draws(of: meshes)
                component.instancedSubmeshDraws = submeshDraws
            }

            var boundMesh: Int32 = -1
            var baseInstance = 0
            for drawIndex in submeshDraws.indices {
                let meshIndex = submeshDraws[drawIndex].meshIndex
                if meshIndex != boundMesh {
                    bindInstancedModelStreams(of: meshes, meshIndex: Int(meshIndex), renderEncoder: renderEncoder)
                    baseInstance = draws.baseInstance(of: group, meshIndex: Int(meshIndex))
                    boundMesh = meshIndex
                }
                bindMaterial(of: submeshDraws, drawIndex, renderEncoder: renderEncoder)

                renderEncoder.drawIndexedPrimitivesTracked(
                    type: submeshDraws[drawIndex].primitiveType,
                    indexCount: submeshDraws[drawIndex].indexCount,
                    indexType: submeshDraws[drawIndex].indexType,
                    indexBuffer: submeshDraws[drawIndex].indexBuffer,
                    indexBufferOffset: submeshDraws[drawIndex].indexBufferOffset,
                    instanceCount: Int(group.instanceCount),
                    baseInstance: baseInstance,
                    category: .opaque
                )
            }
            drawCount += submeshDraws.count
        }

        return InstancedDrawCounts(groups: draws.groups.count, instances: draws.instanceCount, draws: drawCount)
    }

    /// The four vertex streams an instanced model draw reads. A mesh drawn instanced has
    /// no skeleton and no deformed copy of its vertices.
    @inline(__always)
    private static func bindInstancedModelStreams(of meshes: [Mesh], meshIndex: Int, renderEncoder: MTLRenderCommandEncoder) {
        let positions = Int(modelPassVerticesIndex.rawValue)
        let normals = Int(modelPassNormalIndex.rawValue)
        let textureCoordinates = Int(modelPassUVIndex.rawValue)
        let tangents = Int(modelPassTangentIndex.rawValue)
        renderEncoder.setVertexBuffer(meshes[meshIndex].vertexBuffers[positions], offset: 0, index: positions)
        renderEncoder.setVertexBuffer(meshes[meshIndex].vertexBuffers[normals], offset: 0, index: normals)
        renderEncoder.setVertexBuffer(meshes[meshIndex].vertexBuffers[textureCoordinates], offset: 0, index: textureCoordinates)
        renderEncoder.setVertexBuffer(meshes[meshIndex].vertexBuffers[tangents], offset: 0, index: tangents)
    }

    /// Hands the encoder the material of `draws[index]`: what the pass binds for an
    /// entity it draws on its own, less what belongs to the entity (the ghost opacity is
    /// in the instance's record; an instance has no dither). The values are read where
    /// they are, without a copy of the draw.
    @inline(__always)
    private static func bindMaterial(of draws: [InstancedSubmeshDraw], _ index: Int, renderEncoder: MTLRenderCommandEncoder) {
        var stScale = draws[index].stScale
        renderEncoder.setFragmentBytes(&stScale, length: MemoryLayout<Float>.stride, index: Int(modelPassFragmentSTScaleIndex.rawValue))

        renderEncoder.setFragmentTexture(draws[index].baseColorTexture, index: Int(modelPassBaseTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(draws[index].baseColorSampler, index: Int(modelPassBaseSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(draws[index].roughnessTexture, index: Int(modelPassRoughnessTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(draws[index].materialSampler, index: Int(modelPassMaterialSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(draws[index].metallicTexture, index: Int(modelPassMetallicTextureIndex.rawValue))

        var hasNormal = draws[index].hasNormal
        renderEncoder.setFragmentBytes(&hasNormal, length: MemoryLayout<Bool>.stride, index: Int(modelPassFragmentHasNormalTextureIndex.rawValue))
        var normalIsPackedXY = draws[index].normalIsPackedXY
        renderEncoder.setFragmentBytes(&normalIsPackedXY, length: MemoryLayout<Bool>.stride, index: Int(modelPassFragmentNormalIsPackedXYIndex.rawValue))

        var materialParameters = draws[index].parameters
        renderEncoder.setFragmentBytes(&materialParameters, length: MemoryLayout<MaterialParametersUniform>.stride, index: Int(modelPassFragmentMaterialParameterIndex.rawValue))

        renderEncoder.setFragmentTexture(draws[index].normalTexture, index: Int(modelPassNormalTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(draws[index].normalSampler, index: Int(modelPassNormalSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(draws[index].heightTexture, index: Int(modelPassHeightTextureIndex.rawValue))
        renderEncoder.setFragmentSamplerState(draws[index].heightSampler, index: Int(modelPassHeightSamplerIndex.rawValue))
        renderEncoder.setFragmentTexture(draws[index].emissiveTexture, index: Int(modelPassEmissiveTextureIndex.rawValue))
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
