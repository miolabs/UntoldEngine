
//
//  RenderResources.swift
//  UntoldEngine
//
//  Created by Harold Serrano on 5/29/23.
//

import Foundation
import MetalKit
import ModelIO
import simd

public struct RenderInfo {
    public var perspectiveSpace = simd_float4x4.init(1.0)
    public var device: MTLDevice!
    public var fence: MTLFence!
    public var library: MTLLibrary!
    public var commandQueue: MTLCommandQueue!
    public var bufferAllocator: MTKMeshBufferAllocator!
    public var textureLoader: MTKTextureLoader!
    public var renderPassDescriptor: MTLRenderPassDescriptor!
    public var offscreenRenderPassDescriptor: MTLRenderPassDescriptor!
    public var postProcessRenderPassDescriptor: MTLRenderPassDescriptor!
    public var shadowRenderPassDescriptor: MTLRenderPassDescriptor!
    public var gizmoRenderPassDescriptor: MTLRenderPassDescriptor!
    public var deferredRenderPassDescriptor: MTLRenderPassDescriptor!
    public var ssaoRenderPassDescriptor: MTLRenderPassDescriptor!
    public var ssaoBlurRenderPassDescriptor: MTLRenderPassDescriptor!
    public var iblOffscreenRenderPassDescriptor: MTLRenderPassDescriptor!
    public var colorPixelFormat: MTLPixelFormat!
    public var depthPixelFormat: MTLPixelFormat!
    public var viewPort: simd_float2!
}

public struct MeshShaderPipeline {
    var depthState: MTLDepthStencilState?
    var pipelineState: MTLRenderPipelineState?
    var passDescriptor: MTLRenderPassDescriptor?
    var uniformSpaceBuffer: MTLBuffer?
    var success: Bool = false
}

public struct BufferResources {
    // Point Lights
    var pointLightBuffer: MTLBuffer?

    // Spot lights
    var spotLightBuffer: MTLBuffer?

    // Area light
    var areaLightBuffer: MTLBuffer?

    var gridUniforms: MTLBuffer?
    var gridVertexBuffer: MTLBuffer?

    var voxelUniforms: MTLBuffer?

    // composite quad
    public var quadVerticesBuffer: MTLBuffer?
    public var quadTexCoordsBuffer: MTLBuffer?
    public var quadIndexBuffer: MTLBuffer?

    // bounding box
    public var boundingBoxBuffer: MTLBuffer?

    // ray tracing uniform
    var rayTracingUniform: MTLBuffer?
    var accumulationBuffer: MTLBuffer?

    // ray model
    public var rayModelInstanceBuffer: MTLBuffer?

    // ssao kernel
    var ssaoKernelBuffer: MTLBuffer?

    // Frustum Plane Buffer
    var visibleCountBuffer: MTLBuffer?
    var visibilityBuffer: MTLBuffer?

    // Frustum Culling reduce-scan
    var reduceScanFlags: MTLBuffer?
    var reduceScanIndices: MTLBuffer?
    var reduceScanBlockSums: MTLBuffer?
    var reduceScanBlockOffsets: MTLBuffer?
}

public struct TripleBufferResources {
    var frustumPlane: TripleBuffer<simd_float4>?
    var entityAABB: TripleBuffer<EntityAABB>?
}

public struct VertexDescriptors {
    public var model: MDLVertexDescriptor!
    public var gizmo: MDLVertexDescriptor!
}

public struct TextureResources {
    var shadowMap: MTLTexture?
    var colorMap: MTLTexture?
    var normalMap: MTLTexture?
    var positionMap: MTLTexture?
    var materialMap: MTLTexture?
    var emissiveMap: MTLTexture?
    public var depthMap: MTLTexture?

    // deferred
    var deferredColorMap: MTLTexture?
    var deferredDepthMap: MTLTexture?

    // ibl
    var environmentTexture: MTLTexture?
    var irradianceMap: MTLTexture?
    var specularMap: MTLTexture?
    var iblBRDFMap: MTLTexture?

    // raytracing dest texture
    var rayTracingDestTexture: MTLTexture?
    var rayTracingPreviousTexture: MTLTexture?
    var rayTracingRandomTexture: MTLTexture?
    var rayTracingDestTextureArray: MTLTexture?
    var rayTracingAccumTexture: [MTLTexture] = []

    // debugger textures

    var tonemapTexture: MTLTexture?
    var blurDebugTextures: MTLTexture?
    var colorGradingTexture: MTLTexture?
    var colorCorrectionTexture: MTLTexture?
    var blurTextureHor: MTLTexture?
    var blurTextureVer: MTLTexture?
    var bloomThresholdTextuture: MTLTexture?
    var bloomCompositeTexture: MTLTexture?
    var vignetteTexture: MTLTexture?
    var chromaticAberrationTexture: MTLTexture?
    var depthOfFieldTexture: MTLTexture?
    var ssaoTexture: MTLTexture?
    var ssaoDepthMap: MTLTexture?
    var ssaoBlurTexture: MTLTexture?
    var ssaoBlurDepthTexture: MTLTexture?

    // Area texture ltc_1
    var areaTextureLTCMag: MTLTexture?
    var areaTextureLTCMat: MTLTexture?

    // Gizmo
    var gizmoColorTexture: MTLTexture?
    var gizmoDepthTexture: MTLTexture?

    // SSAO
    var ssaoNoiseTexture: MTLTexture?
}

public struct AccelStructResources {
    var primitiveAccelerationStructures: [MTLAccelerationStructure] = []
    var instanceTransforms: [MTLPackedFloat4x3] = []
    var accelerationStructIndex: [UInt32] = []
    public var entityIDIndex: [EntityID] = []
    var instanceAccelerationStructure: MTLAccelerationStructure?
    var instanceBuffer: MTLBuffer?
    var mask: [Int32] = []
}
