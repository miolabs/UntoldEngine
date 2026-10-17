//
//  XRGridUnprojectPass.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import simd

/// The uniforms of one eye's unprojection, laid out as the kernel's `XRGridUnprojectUniforms`
/// (160 bytes).
public struct XRGridUnprojectUniforms {
    /// The eye's pose in the origin's space: the inverse of the view matrix the eye was drawn with.
    public var originFromEye: simd_float4x4
    /// The inverse of the projection the eye was drawn with.
    public var inverseProjection: simd_float4x4
    /// Vertices per row, and rows.
    public var gridSize: SIMD2<UInt32>
    /// The depth texture's size in pixels.
    public var textureSize: SIMD2<UInt32>
    /// Where rays that hit nothing end, metres from the eye.
    public var farShell: Float
    /// A difference in view distance to a neighbour above this, metres, is a depth jump: the
    /// vertex is marked as its far side, or its near side, in the tear mask.
    public var tearThreshold: Float
    public var flags: UInt32
    public var padding: UInt32

    public init(
        originFromEye: simd_float4x4,
        inverseProjection: simd_float4x4,
        gridSize: SIMD2<UInt32>,
        textureSize: SIMD2<UInt32>,
        farShell: Float,
        tearThreshold: Float
    ) {
        self.originFromEye = originFromEye
        self.inverseProjection = inverseProjection
        self.gridSize = gridSize
        self.textureSize = textureSize
        self.farShell = farShell
        self.tearThreshold = tearThreshold
        flags = 0
        padding = 0
    }
}

/// Turns one eye's depth into its grid, in two dispatches on the same command buffer. The
/// first, one thread per vertex, reads the nearest depth (the largest, under reverse Z) over
/// the vertex's whole footprint in the texture, the cell about the vertex plus a one-texel
/// margin, into a scratch buffer of one float per vertex: every texel row and column is read
/// by some vertex and adjacent footprints overlap, so a thin feature or an edge between two
/// vertices is caught by one of them, and near silhouettes are kept. The second reads its own
/// and its eight neighbours' depths from that buffer, unprojects through the eye's inverse
/// projection and pose into the origin's space, and writes the position, the uv (v = 0 at the
/// top row, as RealityKit samples a `LowLevelTexture`) and the tear mask. Depth 0, the far
/// plane under reverse Z, and anything past the far shell land on the shell, so that the sky
/// and passthrough areas keep a surface.
///
/// The tear mask has two channels: x is 1 on the FAR side of a depth jump (a vertex further from
/// the eye than a neighbour by more than the threshold), y is 1 on its NEAR side. A triangle
/// that stretches from an object to what lies behind it has both: x rises from 0 at the object
/// to 1 behind it and y falls the other way, so the material can discard it wherever both are
/// above zero, while a triangle of the object's own surface (x = 0) and one of the far surface
/// (y = 0) are kept whole, up to the jump.
///
/// The kernels are compiled from source once per device: the engine's prebuilt metallibs stay
/// as they are, and the tests run them on a Mac.
public final class XRGridUnprojectPass: @unchecked Sendable {
    /// The first dispatch: each vertex's nearest depth into the scratch buffer.
    public static let nearestDepthKernelName = "xrGridNearestDepth"
    /// The second: the vertices from the scratch buffer.
    public static let kernelName = "xrGridUnproject"

    /// The kernels. Their `XRGridVertex` is the grid's vertex layout; their uniforms are
    /// `XRGridUnprojectUniforms`.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct XRGridVertex {
        packed_float3 position;   // the origin's space
        packed_float2 uv;         // v = 0 at the texture's top row
        half2 mask;               // x: 1 on the far side of a depth jump, y: 1 on the near side
    };
    struct XRGridUnprojectUniforms {
        float4x4 originFromEye;
        float4x4 inverseProjection;
        uint2 gridSize;
        uint2 textureSize;
        float farShell;
        float tearThreshold;
        uint flags;
        uint padding;
    };
    // The eye-space point of a texture position at a reverse-Z depth; on the far shell when the
    // depth is the far plane or the point lies beyond the shell.
    static float3 eyePoint(float2 uv, float depth, constant XRGridUnprojectUniforms &u) {
        float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
        float4 eye = u.inverseProjection * float4(ndc, max(depth, 1e-6f), 1.0f);
        float3 p = eye.xyz / eye.w;
        float distance = length(p);
        if (depth <= 0.0f || distance > u.farShell) {
            p = p * (u.farShell / max(distance, 1e-6f));
        }
        return p;
    }
    // Pass 1: the nearest depth (the largest, under reverse Z) over the vertex's footprint, the
    // cell about the vertex (half a cell to each side, in texels) plus a one-texel margin, so
    // that every texel is read by some vertex and adjacent footprints overlap. The bounds are
    // taken with a tolerance of a thousandth of a texel, so that a cell edge that lands on a
    // texel is the same texel whichever way the arithmetic rounds.
    kernel void xrGridNearestDepth(device float *depths [[buffer(0)]],
                                   constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                   depth2d<float, access::read> depth [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 size = float2(u.textureSize);
        float2 halfCell = size / float2(u.gridSize - 1) * 0.5f;
        float2 centre = float2(gid) * (1.0f / float2(u.gridSize - 1)) * (size - 1.0f);
        int2 lo = max(int2(ceil(centre - halfCell - 1e-3f)) - 1, int2(0));
        int2 hi = min(int2(floor(centre + halfCell + 1e-3f)) + 1, int2(u.textureSize) - 1);
        float nearest = 0.0f;
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int x = lo.x; x <= hi.x; ++x) {
                nearest = max(nearest, depth.read(uint2(x, y)));
            }
        }
        depths[gid.y * u.gridSize.x + gid.x] = nearest;
    }
    // Pass 2: the vertex from its own and its neighbours' nearest depths.
    kernel void xrGridUnproject(device XRGridVertex *vertices [[buffer(0)]],
                                constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                const device float *depths [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 step = 1.0f / float2(u.gridSize - 1);
        float2 uv = float2(gid) * step;
        float3 eye = eyePoint(uv, depths[gid.y * u.gridSize.x + gid.x], u);
        float distance = length(eye);
        // The tear mask against the eight neighbours: x when this vertex is further from the eye
        // than a neighbour by more than the threshold, y when it is nearer by that much. The
        // diagonals count too: a cell's triangles share its diagonal, and a jump along that
        // diagonal alone would otherwise leave a stretched edge unmarked.
        float farSide = 0.0f;
        float nearSide = 0.0f;
        const int2 offsets[8] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1), int2(1, 1), int2(1, -1), int2(-1, 1), int2(-1, -1) };
        for (int k = 0; k < 8; ++k) {
            int2 n = int2(gid) + offsets[k];
            if (n.x < 0 || n.y < 0 || n.x >= int(u.gridSize.x) || n.y >= int(u.gridSize.y)) { continue; }
            float2 nuv = float2(n) * step;
            float neighbour = length(eyePoint(nuv, depths[n.y * u.gridSize.x + n.x], u));
            if (distance - neighbour > u.tearThreshold) { farSide = 1.0f; }
            if (neighbour - distance > u.tearThreshold) { nearSide = 1.0f; }
        }
        device XRGridVertex &v = vertices[gid.y * u.gridSize.x + gid.x];
        v.position = (u.originFromEye * float4(eye, 1.0f)).xyz;
        v.uv = uv;
        v.mask = half2(half(farSide), half(nearSide));
    }
    """

    public enum Error: Swift.Error, CustomStringConvertible {
        case kernelMissing(String)

        public var description: String {
            switch self {
            case let .kernelMissing(name): return "the kernel \(name) is not in the compiled library"
            }
        }
    }

    private let nearestDepthPipeline: MTLComputePipelineState
    private let pipeline: MTLComputePipelineState

    /// Compiles the kernels for `device`; throws what the Metal compiler reports.
    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func makePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Error.kernelMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        nearestDepthPipeline = try makePipeline(Self.nearestDepthKernelName)
        pipeline = try makePipeline(Self.kernelName)
    }

    /// The scratch buffer between the two dispatches for one eye's `grid`: one float per vertex,
    /// private to the GPU. The caller keeps it across frames (the presenter owns one per eye):
    /// the command buffers of one queue run in order, so a frame's second dispatch reads what
    /// its own first one wrote.
    public static func makeNearestDepthBuffer(device: MTLDevice, grid: XRPresenterGrid, label: String = "XR grid nearest depth") -> MTLBuffer? {
        let buffer = device.makeBuffer(length: grid.vertexCount * MemoryLayout<Float>.stride, options: .storageModePrivate)
        buffer?.label = label
        return buffer
    }

    /// Encodes one eye's unprojection: `depth` is the eye's depth as the engine left it (reverse
    /// Z), `nearestDepths` the eye's scratch buffer (`makeNearestDepthBuffer`), `vertices` the
    /// grid's vertex buffer for this frame, `originFromEye` the inverse of the view matrix the
    /// eye was drawn with and `projection` its projection. Both dispatches go into one compute
    /// encoder, a memory barrier between them.
    public func encode(
        commandBuffer: MTLCommandBuffer,
        depth: MTLTexture,
        nearestDepths: MTLBuffer,
        vertices: MTLBuffer,
        grid: XRPresenterGrid,
        originFromEye: simd_float4x4,
        projection: simd_float4x4,
        farShell: Float,
        tearThreshold: Float,
        label: String = "XR grid unproject"
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = label
        var uniforms = XRGridUnprojectUniforms(
            originFromEye: originFromEye,
            inverseProjection: simd_inverse(projection),
            gridSize: SIMD2<UInt32>(UInt32(grid.columns), UInt32(grid.rows)),
            textureSize: SIMD2<UInt32>(UInt32(depth.width), UInt32(depth.height)),
            farShell: farShell,
            tearThreshold: tearThreshold
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<XRGridUnprojectUniforms>.stride, index: 1)

        encoder.setComputePipelineState(nearestDepthPipeline)
        encoder.setBuffer(nearestDepths, offset: 0, index: 0)
        encoder.setTexture(depth, index: 0)
        dispatch(encoder, pipeline: nearestDepthPipeline, grid: grid)
        encoder.memoryBarrier(scope: .buffers)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBuffer(nearestDepths, offset: 0, index: 2)
        dispatch(encoder, pipeline: pipeline, grid: grid)
        encoder.endEncoding()
    }

    /// One thread per vertex.
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, grid: XRPresenterGrid) {
        let width = min(pipeline.threadExecutionWidth, grid.columns)
        let height = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, grid.rows))
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (grid.columns + width - 1) / width,
            height: (grid.rows + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
