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
    /// A jump in view distance to a neighbour above this, metres, sets the tear mask.
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

/// Turns one eye's depth into its grid: one thread per vertex reads the nearest depth of the
/// vertex's footprint in the texture (so that near silhouettes are kept), unprojects it through
/// the eye's inverse projection and pose into the origin's space, and writes the position, the
/// uv (v = 0 at the top row, as RealityKit samples a `LowLevelTexture`) and the tear mask.
/// Depth 0, the far plane under reverse Z, and anything past the far shell land on the shell,
/// so that the sky and passthrough areas keep a surface.
///
/// The kernel is compiled from source once per device: the engine's prebuilt metallibs stay as
/// they are, and the tests run it on a Mac.
public final class XRGridUnprojectPass: @unchecked Sendable {
    public static let kernelName = "xrGridUnproject"

    /// The kernel. Its `XRGridVertex` is the grid's vertex layout; its uniforms are
    /// `XRGridUnprojectUniforms`.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct XRGridVertex {
        packed_float3 position;   // the origin's space
        packed_float2 uv;         // v = 0 at the texture's top row
        half2 mask;               // x: 1 where the vertex stretches across a depth jump
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
    // The nearest depth (the largest, under reverse Z) over up to 4 x 4 taps across the footprint
    // of a grid vertex in the texture.
    static float nearestDepth(depth2d<float, access::read> depth, float2 uv, constant XRGridUnprojectUniforms &u) {
        float2 size = float2(u.textureSize);
        float2 cell = size / float2(u.gridSize - 1);
        float2 centre = uv * (size - 1.0f);
        uint2 taps = clamp(uint2(ceil(cell)), uint2(1), uint2(4));
        float nearest = 0.0f;
        for (uint j = 0; j < taps.y; ++j) {
            for (uint i = 0; i < taps.x; ++i) {
                float2 offset = (float2(i, j) + 0.5f) / float2(taps) - 0.5f;
                float2 p = clamp(round(centre + offset * cell), float2(0.0f), size - 1.0f);
                nearest = max(nearest, depth.read(uint2(p)));
            }
        }
        return nearest;
    }
    kernel void xrGridUnproject(device XRGridVertex *vertices [[buffer(0)]],
                                constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                depth2d<float, access::read> depth [[texture(0)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 step = 1.0f / float2(u.gridSize - 1);
        float2 uv = float2(gid) * step;
        float3 eye = eyePoint(uv, nearestDepth(depth, uv, u), u);
        float distance = length(eye);
        // The tear mask: a jump in view distance to any of the four neighbours above the threshold.
        float mask = 0.0f;
        const int2 offsets[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
        for (int k = 0; k < 4; ++k) {
            int2 n = int2(gid) + offsets[k];
            if (n.x < 0 || n.y < 0 || n.x >= int(u.gridSize.x) || n.y >= int(u.gridSize.y)) { continue; }
            float2 nuv = float2(n) * step;
            float neighbour = length(eyePoint(nuv, nearestDepth(depth, nuv, u), u));
            if (fabs(neighbour - distance) > u.tearThreshold) { mask = 1.0f; }
        }
        device XRGridVertex &v = vertices[gid.y * u.gridSize.x + gid.x];
        v.position = (u.originFromEye * float4(eye, 1.0f)).xyz;
        v.uv = uv;
        v.mask = half2(half(mask), 0.0h);
    }
    """

    public enum Error: Swift.Error, CustomStringConvertible {
        case kernelMissing

        public var description: String { "the kernel \(XRGridUnprojectPass.kernelName) is not in the compiled library" }
    }

    private let pipeline: MTLComputePipelineState

    /// Compiles the kernel for `device`; throws what the Metal compiler reports.
    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: Self.kernelName) else {
            throw Error.kernelMissing
        }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Encodes one eye's unprojection: `depth` is the eye's depth as the engine left it (reverse
    /// Z), `vertices` the grid's vertex buffer for this frame, `originFromEye` the inverse of the
    /// view matrix the eye was drawn with and `projection` its projection.
    public func encode(
        commandBuffer: MTLCommandBuffer,
        depth: MTLTexture,
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
        encoder.setComputePipelineState(pipeline)
        var uniforms = XRGridUnprojectUniforms(
            originFromEye: originFromEye,
            inverseProjection: simd_inverse(projection),
            gridSize: SIMD2<UInt32>(UInt32(grid.columns), UInt32(grid.rows)),
            textureSize: SIMD2<UInt32>(UInt32(depth.width), UInt32(depth.height)),
            farShell: farShell,
            tearThreshold: tearThreshold
        )
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<XRGridUnprojectUniforms>.stride, index: 1)
        encoder.setTexture(depth, index: 0)
        let width = min(pipeline.threadExecutionWidth, grid.columns)
        let height = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, grid.rows))
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (grid.columns + width - 1) / width,
            height: (grid.rows + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }
}
