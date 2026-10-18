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
    /// Bit 0: the cells keep the fixed diagonal (no per-frame split by depth).
    public var flags: UInt32
    /// How far, in texels, a rim vertex (one whose own centre lies off the near surface) is
    /// pushed outward past the edge texel it was placed on, so that the alpha test of the
    /// filtered texture, not the mesh boundary, draws the silhouette; 0 for none.
    public var skirtTexels: Float

    public init(
        originFromEye: simd_float4x4,
        inverseProjection: simd_float4x4,
        gridSize: SIMD2<UInt32>,
        textureSize: SIMD2<UInt32>,
        farShell: Float,
        tearThreshold: Float,
        skirtTexels: Float = 0
    ) {
        self.originFromEye = originFromEye
        self.inverseProjection = inverseProjection
        self.gridSize = gridSize
        self.textureSize = textureSize
        self.farShell = farShell
        self.tearThreshold = tearThreshold
        flags = 0
        self.skirtTexels = skirtTexels
    }
}

/// Turns one eye's depth into its grid, in two dispatches on the same command buffer. The
/// first, one thread per vertex, reads the nearest depth (the largest, under reverse Z) over
/// the vertex's whole footprint in the texture, the cell about the vertex plus a margin of
/// half a cell, into a scratch buffer of one float4 per vertex, together with the texel the vertex
/// is placed on: the texel nearest the vertex's centre among those on the near side of the
/// footprint's depth jump. Every texel row and column is read by some vertex and adjacent
/// footprints overlap, so a thin feature or an edge between two vertices is caught by one of
/// them; the first vertex outside an object's edge, within a cell of it, always reaches it and
/// lands on the edge texel nearest its centre, so silhouettes are texel-accurate whatever the
/// surface's slope and wherever the edge falls among the cells (with a one-texel margin, a
/// third of the edge's places found no vertex and the boundary fell half a cell inside; with a
/// whole cell, the second vertex outside reached it too and the surface behind lost a band); one on
/// a continuous surface stays at its centre, so the grid stays regular there. The second
/// dispatch reads its own and its eight neighbours' entries from that buffer, places each
/// vertex on its texel (its position unprojected there through the eye's inverse projection
/// and pose into the origin's space, its uv that texel's, v = 0 at the top row as RealityKit
/// samples a `LowLevelTexture`), and writes the tear mask; a rim vertex is pushed outward past
/// its edge texel by the skirt, so that the silhouette seen is the alpha test's crossing of the
/// filtered texture rather than the mesh boundary. A third dispatch writes each cell's two
/// triangles, split along the diagonal that does not cross a depth jump. A vertex at its cell's centre with
/// the footprint's nearest depth, the first rule tried, cut a silhouette up to a cell inside
/// its true edge wherever the surface receded towards the edge (every sphere, the turning
/// cubes' faces), and that cut crawled as the predicted head pose jittered. Depth
/// 0, the far plane under reverse Z, and anything past the far shell land on the shell, so
/// that the sky and passthrough areas keep a surface.
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
    /// The third: each cell's two triangles, split along the diagonal nearer in depth.
    public static let triangulateKernelName = "xrGridTriangulate"

    /// The kernels. Their `XRGridVertex` is the grid's vertex layout; their uniforms are
    /// `XRGridUnprojectUniforms`.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct XRGridVertex {
        packed_float3 position;   // the origin's space
        packed_float2 uv;         // v = 0 at the texture's top row (affine; the fallback material's)
        half2 mask;               // x: 1 on the far side of a depth jump, y: 1 on the near side
        packed_float4 uvw;        // (u, v) times the eye-space depth, that depth, 0: the material divides
    };
    struct XRGridUnprojectUniforms {
        float4x4 originFromEye;
        float4x4 inverseProjection;
        uint2 gridSize;
        uint2 textureSize;
        float farShell;
        float tearThreshold;
        uint flags;
        float skirtTexels;
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
    // The distance in front of the eye, along the vertex's own ray, of a reverse-Z depth: the
    // eye-space point is affine in the depth, so two vectors of the inverse projection do.
    static float zInFront(float d, float4 a, float4 b) {
        float dd = max(d, 1e-6f);
        return -(a.z + dd * b.z) / (a.w + dd * b.w);
    }
    // Pass 1: over the vertex's footprint, the cell about the vertex (half a cell to each side,
    // in texels) plus a margin of half a cell, so that every texel is read by some vertex,
    // adjacent footprints overlap, and the first vertex outside an edge always reaches it: the
    // nearest depth (the largest, under reverse Z), and the
    // texel the vertex is placed on, which is the texel NEAREST THE VERTEX'S CENTRE among those
    // on the near side of the footprint's depth jump (within the tear threshold of the nearest
    // depth, in metres along the vertex's ray). A vertex whose centre lies off an object but
    // whose footprint reaches it lands on the object's edge texel, whatever the surface's
    // slope; one whose centre lies on it, or on any continuous surface, stays at its centre, so
    // the grid stays regular there. Written as (the chosen texel's depth, texel x, texel y, 0).
    // The bounds are taken with a tolerance of a thousandth of a texel, so that a cell edge that
    // lands on a texel is the same texel whichever way the arithmetic rounds.
    kernel void xrGridNearestDepth(device float4 *depths [[buffer(0)]],
                                   constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                   depth2d<float, access::read> depth [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 size = float2(u.textureSize);
        float2 halfCell = size / float2(u.gridSize - 1) * 0.5f;
        float2 centre = float2(gid) * (1.0f / float2(u.gridSize - 1)) * (size - 1.0f);
        // The margin is half a cell, so the footprint reaches a whole cell from the centre: the
        // first vertex outside an edge is within a cell of it and must reach it wherever the edge
        // falls among the cells, and the second must not, or it would leave the surface behind
        // the object for the edge too.
        int2 margin = int2(ceil(halfCell - 1e-3f));
        int2 lo = max(int2(ceil(centre - halfCell - 1e-3f)) - margin, int2(0));
        int2 hi = min(int2(floor(centre + halfCell + 1e-3f)) + margin, int2(u.textureSize) - 1);
        float nearest = 0.0f;
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int x = lo.x; x <= hi.x; ++x) {
                nearest = max(nearest, depth.read(uint2(x, y)));
            }
        }
        float2 centreUV = centre / (size - 1.0f);
        float2 ndc = float2(centreUV.x * 2.0f - 1.0f, 1.0f - centreUV.y * 2.0f);
        float4 a = u.inverseProjection * float4(ndc, 0.0f, 1.0f);
        float4 b = u.inverseProjection * float4(0.0f, 0.0f, 1.0f, 0.0f);
        float nearSideLimit = zInFront(nearest, a, b) + u.tearThreshold;
        float chosen = nearest;
        float2 texel = centre;
        float chosenDistance = 1e30f;
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int x = lo.x; x <= hi.x; ++x) {
                float d = depth.read(uint2(x, y));
                if (zInFront(d, a, b) >= nearSideLimit) { continue; }
                float2 t = float2(x, y);
                float distance = length_squared(t - centre);
                if (distance < chosenDistance) {
                    chosen = d;
                    texel = t;
                    chosenDistance = distance;
                }
            }
        }
        // Hysteresis: the previous frame's texel is kept while this frame's choice lies within
        // a texel of it and the depth there is still on the near side, so that the jitter of
        // the predicted head pose, which moves a silhouette by a fraction of a texel, does not
        // flip the edge between two texels frame after frame; a head that moves takes the edge
        // further than a texel and the new choice is taken.
        float4 previous = depths[gid.y * u.gridSize.x + gid.x];
        float2 kept = previous.yz;
        if (all(kept >= float2(lo)) && all(kept <= float2(hi)) && all(abs(kept - texel) <= 1.0f)) {
            float d = depth.read(uint2(kept));
            if (zInFront(d, a, b) < nearSideLimit) {
                chosen = d;
                texel = kept;
            }
        }
        // A rim vertex: its own centre texel lies off the near surface, so the vertex was pulled
        // onto the surface's edge. Pass 2 pushes it back out by the skirt.
        float2 centreTexel = clamp(round(centre), float2(0.0f), size - 1.0f);
        bool rim = zInFront(depth.read(uint2(centreTexel)), a, b) >= nearSideLimit;
        depths[gid.y * u.gridSize.x + gid.x] = float4(chosen, texel, rim ? 1.0f : 0.0f);
    }
    // Where a vertex is placed: on its texel, or, for a rim vertex, the skirt past it: from the
    // edge texel toward the vertex's own centre (outward, off the surface), by skirtTexels, so
    // that the mesh boundary lies in texels the alpha test discards and the silhouette seen is
    // the 0.5 crossing of the filtered alpha, a continuous position where the engine's
    // anti-aliasing estimated the outside texel, instead of a boundary through rim texels that
    // is quantised to the texel.
    static float2 placedTexel(float4 entry, float2 centre, float2 size, float skirtTexels) {
        float2 t = entry.yz;
        if (entry.w > 0.5f && skirtTexels > 0.0f) {
            float2 away = centre - t;
            float len = length(away);
            if (len > 1e-3f) {
                t = clamp(t + away * (skirtTexels / len), float2(0.0f), size - 1.0f);
            }
        }
        return t;
    }
    // Pass 2: the vertex on the texel its nearest depth came from, and the tear mask from its
    // neighbours' entries.
    kernel void xrGridUnproject(device XRGridVertex *vertices [[buffer(0)]],
                                constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                const device float4 *depths [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 size = float2(u.textureSize);
        float2 texelToUV = 1.0f / (size - 1.0f);
        float2 cellStep = 1.0f / float2(u.gridSize - 1);
        float4 own = depths[gid.y * u.gridSize.x + gid.x];
        float2 centre = float2(gid) * cellStep * (size - 1.0f);
        float2 uv = placedTexel(own, centre, size, u.skirtTexels) * texelToUV;
        float3 eye = eyePoint(uv, own.x, u);
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
            float4 entry = depths[n.y * u.gridSize.x + n.x];
            float neighbour = length(eyePoint(entry.yz * texelToUV, entry.x, u));
            if (distance - neighbour > u.tearThreshold) { farSide = 1.0f; }
            if (neighbour - distance > u.tearThreshold) { nearSide = 1.0f; }
        }
        device XRGridVertex &v = vertices[gid.y * u.gridSize.x + gid.x];
        v.position = (u.originFromEye * float4(eye, 1.0f)).xyz;
        v.uv = uv;
        v.mask = half2(half(farSide), half(nearSide));
        // uv is this vertex's own projection, so uv times its eye-space depth is an affine
        // function of the point: interpolated perspective-correctly by RealityKit and divided per
        // pixel, the texture is read where the engine drew it across every planar triangle,
        // whatever RealityKit's own camera (an affine uv keystones across a tilted cell).
        float ze = -eye.z;
        v.uvw = packed_float4(uv.x * ze, uv.y * ze, ze, 0.0f);
    }
    // Pass 3: the cell's two triangles, split along the diagonal that does not cross a depth
    // jump when the other does (the depths read along the cell's own ray). A silhouette that
    // crosses a cell corner to corner has its two on-edge vertices on one diagonal; with a
    // fixed split half of those cells lost both triangles to the far vertex and the boundary
    // dipped to the next interior vertex. One thread per cell; a (top-left) = row r column c,
    // b = a + 1, c = a + columns, d = c + 1; counter-clockwise as seen from the eye.
    kernel void xrGridTriangulate(device uint *indices [[buffer(0)]],
                                  constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                  const device float4 *depths [[buffer(2)]],
                                  uint2 gid [[thread_position_in_grid]])
    {
        uint2 cells = u.gridSize - 1;
        if (gid.x >= cells.x || gid.y >= cells.y) { return; }
        uint a = gid.y * u.gridSize.x + gid.x;
        uint b = a + 1;
        uint c = a + u.gridSize.x;
        uint d = c + 1;
        float2 centreUV = (float2(gid) + 0.5f) / float2(cells);
        float2 ndc = float2(centreUV.x * 2.0f - 1.0f, 1.0f - centreUV.y * 2.0f);
        float4 ra = u.inverseProjection * float4(ndc, 0.0f, 1.0f);
        float4 rb = u.inverseProjection * float4(0.0f, 0.0f, 1.0f, 0.0f);
        float za = zInFront(depths[a].x, ra, rb);
        float zb = zInFront(depths[b].x, ra, rb);
        float zc = zInFront(depths[c].x, ra, rb);
        float zd = zInFront(depths[d].x, ra, rb);
        device uint *t = indices + (gid.y * cells.x + gid.x) * 6;
        // Only where the default diagonal crosses a depth jump and the other does not: every
        // continuous surface keeps one topology from frame to frame.
        if ((u.flags & 1u) == 0u && fabs(zb - zc) > u.tearThreshold && fabs(za - zd) <= u.tearThreshold) {
            t[0] = a; t[1] = c; t[2] = d;
            t[3] = a; t[4] = d; t[5] = b;
        } else {
            t[0] = a; t[1] = c; t[2] = b;
            t[3] = b; t[4] = c; t[5] = d;
        }
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
    private let triangulatePipeline: MTLComputePipelineState

    /// Compiles the kernels for `device`; throws what the Metal compiler reports.
    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func makePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Error.kernelMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        nearestDepthPipeline = try makePipeline(Self.nearestDepthKernelName)
        pipeline = try makePipeline(Self.kernelName)
        triangulatePipeline = try makePipeline(Self.triangulateKernelName)
    }

    /// The scratch buffer between the two dispatches for one eye's `grid`: one float4 per vertex
    /// (the chosen texel's depth, the texel, 0), private to the GPU. The caller keeps it
    /// across frames (the presenter owns one per eye): the command buffers of one queue run in
    /// order, so a frame's second dispatch reads what its own first one wrote, and the first
    /// dispatch reads the previous frame's entries for its hysteresis.
    public static func makeNearestDepthBuffer(device: MTLDevice, grid: XRPresenterGrid, label: String = "XR grid nearest depth") -> MTLBuffer? {
        let buffer = device.makeBuffer(length: grid.vertexCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate)
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
        indices: MTLBuffer? = nil,
        grid: XRPresenterGrid,
        originFromEye: simd_float4x4,
        projection: simd_float4x4,
        farShell: Float,
        tearThreshold: Float,
        skirtTexels: Float = 0,
        adaptiveDiagonal: Bool = true,
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
            tearThreshold: tearThreshold,
            skirtTexels: skirtTexels
        )
        uniforms.flags = adaptiveDiagonal ? 0 : 1
        encoder.setBytes(&uniforms, length: MemoryLayout<XRGridUnprojectUniforms>.stride, index: 1)

        encoder.setComputePipelineState(nearestDepthPipeline)
        encoder.setBuffer(nearestDepths, offset: 0, index: 0)
        encoder.setTexture(depth, index: 0)
        dispatch(encoder, pipeline: nearestDepthPipeline, columns: grid.columns, rows: grid.rows)
        encoder.memoryBarrier(scope: .buffers)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBuffer(nearestDepths, offset: 0, index: 2)
        dispatch(encoder, pipeline: pipeline, columns: grid.columns, rows: grid.rows)
        // The cells' triangles for this frame, when the presenter hands the index buffer in
        // (nil keeps the mesh's indices as they are: the fixed split).
        if let indices {
            encoder.setComputePipelineState(triangulatePipeline)
            encoder.setBuffer(indices, offset: 0, index: 0)
            encoder.setBuffer(nearestDepths, offset: 0, index: 2)
            dispatch(encoder, pipeline: triangulatePipeline, columns: grid.columns - 1, rows: grid.rows - 1)
        }
        encoder.endEncoding()
    }

    /// One thread per vertex, or per cell.
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, columns: Int, rows: Int) {
        let width = min(pipeline.threadExecutionWidth, columns)
        let height = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, rows))
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (columns + width - 1) / width,
            height: (rows + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
