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
import UntoldEngine

/// The uniforms of one eye's unprojection, laid out as the kernel's `XRGridUnprojectUniforms`
/// (176 bytes).
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
    /// The rate map's screen size in pixels when the eye was drawn through one (`foveated` is
    /// 1): the space the map's decoder puts physical texels in, which the kernels take to NDC.
    public var screenSize: SIMD2<Float>
    /// The grid's cell in physical texels when foveated: vertex k of a row sits on texel
    /// k × cellTexels, the last on the last texel.
    public var cellTexels: Float
    /// 1 when the eye was drawn through a rate map, whose parameters are bound at buffer 3, 0
    /// for the uniform texture, where the vertices are spread over the texture's extent. The
    /// kernels are specialized on it (`kFoveated`), so it says which of the two was dispatched.
    public var foveated: UInt32

    public init(
        originFromEye: simd_float4x4,
        inverseProjection: simd_float4x4,
        gridSize: SIMD2<UInt32>,
        textureSize: SIMD2<UInt32>,
        farShell: Float,
        tearThreshold: Float,
        skirtTexels: Float = 0,
        screenSize: SIMD2<Float> = .zero,
        cellTexels: Float = 0,
        foveated: Bool = false
    ) {
        self.originFromEye = originFromEye
        self.inverseProjection = inverseProjection
        self.gridSize = gridSize
        self.textureSize = textureSize
        self.farShell = farShell
        self.tearThreshold = tearThreshold
        flags = 0
        self.skirtTexels = skirtTexels
        self.screenSize = screenSize
        self.cellTexels = cellTexels
        self.foveated = foveated ? 1 : 0
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
/// Drawn through a rasterization rate map (`rateMapData`), the texture is the map's physical
/// texels: a vertex sits every `cellTexels` (the cell divides the map's tile, so the vertices
/// lie where the map's mapping of texels to the screen changes slope and the grid interpolates
/// it exactly between them), and wherever a texel becomes a ray — the vertex's own, its
/// neighbours', a cell's — the kernels map the texel's centre to the screen through the map's
/// decoder (`rasterization_rate_map_decoder`, buffer 3), then to NDC by the screen size; the uv
/// written is the texel's centre, so ray, uv and the depth read coincide. Without a map the
/// arithmetic is as it was: the vertices spread over the texture's extent, a texel's uv over
/// `size - 1`.
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
    // Whether the eye was drawn through a rasterization rate map: a function constant, so each
    // kernel is compiled twice and the uniform one is the arithmetic it always was, with no map
    // argument, while the foveated one carries no branch.
    constant bool kFoveated [[function_constant(0)]];
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
        float skirtTexels;
        float2 screenSize;
        float cellTexels;
        uint foveated;
    };
    // The NDC of a texture position (v = 0 at the top row).
    static float2 uvToNDC(float2 uv) {
        return float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    }
    // Where a grid vertex is centred, in texels. Through a rate map, the texture is the map's
    // physical texels and a vertex sits every cellTexels, the last on the last texel: the cell
    // divides the map's tile, so the vertices lie where the map's mapping of texels to the
    // screen changes slope and the grid interpolates it exactly between them. Uniform, the
    // vertices are spread over the texture's extent.
    static float2 vertexCentre(uint2 gid, constant XRGridUnprojectUniforms &u) {
        float2 size = float2(u.textureSize);
        if (kFoveated) {
            return min(float2(gid) * u.cellTexels, size - 1.0f);
        }
        return float2(gid) * (1.0f / float2(u.gridSize - 1)) * (size - 1.0f);
    }
    // Half a cell, in texels.
    static float2 halfCellTexels(constant XRGridUnprojectUniforms &u) {
        if (kFoveated) {
            return float2(u.cellTexels * 0.5f);
        }
        return float2(u.textureSize) / float2(u.gridSize - 1) * 0.5f;
    }
    // The texture coordinate the material samples at a texel: the texel's centre through a
    // rate map, the point its ray goes through; over the texture's extent otherwise.
    static float2 texelToUV(float2 texel, constant XRGridUnprojectUniforms &u) {
        float2 size = float2(u.textureSize);
        if (kFoveated) {
            return (texel + 0.5f) / size;
        }
        return texel * (1.0f / (size - 1.0f));
    }
    // The NDC of the ray through a texel: through the rate map's decoder when the eye was drawn
    // through one (the texel's centre on the map's screen, over the screen), else from the
    // texel's texture coordinate. The map's parameters are read only when foveated.
    static float2 texelToNDC(float2 texel, constant XRGridUnprojectUniforms &u, constant rasterization_rate_map_data *rateMap) {
        if (kFoveated) {
            rasterization_rate_map_decoder decoder(*rateMap);
            return uvToNDC(decoder.map_physical_to_screen_coordinates(texel + 0.5f) / u.screenSize);
        }
        return uvToNDC(texelToUV(texel, u));
    }
    // The eye-space point of a ray, as NDC, at a reverse-Z depth; on the far shell when the
    // depth is the far plane or the point lies beyond the shell.
    static float3 eyePoint(float2 ndc, float depth, constant XRGridUnprojectUniforms &u) {
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
                                   constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                                   depth2d<float, access::read> depth [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 size = float2(u.textureSize);
        float2 halfCell = halfCellTexels(u);
        float2 centre = vertexCentre(gid, u);
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
        // The vertex's own ray: through the map when foveated, else its texture position.
        float2 ndc = kFoveated ? texelToNDC(centre, u, rateMap) : uvToNDC(centre / (size - 1.0f));
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
                                constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.gridSize.x || gid.y >= u.gridSize.y) { return; }
        float2 size = float2(u.textureSize);
        float2 texelToUVScale = 1.0f / (size - 1.0f);
        float4 own = depths[gid.y * u.gridSize.x + gid.x];
        float2 centre = vertexCentre(gid, u);
        float2 placed = placedTexel(own, centre, size, u.skirtTexels);
        // The uv the material samples and the ray: through the map when foveated (the texel's
        // centre), else the texel over the texture's extent and the ray from that uv.
        float2 uv = kFoveated ? (placed + 0.5f) / size : placed * texelToUVScale;
        float2 ndc = kFoveated ? texelToNDC(placed, u, rateMap) : uvToNDC(uv);
        float3 eye = eyePoint(ndc, own.x, u);
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
            float2 neighbourNDC = kFoveated ? texelToNDC(entry.yz, u, rateMap) : uvToNDC(entry.yz * texelToUVScale);
            float neighbour = length(eyePoint(neighbourNDC, entry.x, u));
            if (distance - neighbour > u.tearThreshold) { farSide = 1.0f; }
            if (neighbour - distance > u.tearThreshold) { nearSide = 1.0f; }
        }
        device XRGridVertex &v = vertices[gid.y * u.gridSize.x + gid.x];
        v.position = (u.originFromEye * float4(eye, 1.0f)).xyz;
        v.uv = uv;
        v.mask = half2(half(farSide), half(nearSide));
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
                                  constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                                  uint2 gid [[thread_position_in_grid]])
    {
        uint2 cells = u.gridSize - 1;
        if (gid.x >= cells.x || gid.y >= cells.y) { return; }
        uint a = gid.y * u.gridSize.x + gid.x;
        uint b = a + 1;
        uint c = a + u.gridSize.x;
        uint d = c + 1;
        // The cell's own ray: through its centre texel's place on the map when foveated.
        float2 ndc;
        if (kFoveated) {
            float2 cellCentre = clamp((float2(gid) + 0.5f) * u.cellTexels - 0.5f, float2(0.0f), float2(u.textureSize) - 1.0f);
            ndc = texelToNDC(cellCentre, u, rateMap);
        } else {
            ndc = uvToNDC((float2(gid) + 0.5f) / float2(cells));
        }
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

    /// The three kernels, specialized for one value of `kFoveated`.
    private struct Pipelines {
        let nearestDepth: MTLComputePipelineState
        let unproject: MTLComputePipelineState
        let triangulate: MTLComputePipelineState
    }

    /// The kernels for a uniform eye texture: the arithmetic as it always was.
    private let uniformPipelines: Pipelines
    /// The kernels for an eye drawn through a rate map: texels to rays through its decoder.
    private let foveatedPipelines: Pipelines

    /// Compiles the kernels for `device`, in both specializations; throws what the Metal
    /// compiler reports.
    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func makePipelines(foveated: Bool) throws -> Pipelines {
            var foveated = foveated
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&foveated, type: .bool, index: 0)
            func makePipeline(_ name: String) throws -> MTLComputePipelineState {
                let function = try library.makeFunction(name: name, constantValues: constants)
                return try device.makeComputePipelineState(function: function)
            }
            return try Pipelines(
                nearestDepth: makePipeline(Self.nearestDepthKernelName),
                unproject: makePipeline(Self.kernelName),
                triangulate: makePipeline(Self.triangulateKernelName)
            )
        }
        uniformPipelines = try makePipelines(foveated: false)
        foveatedPipelines = try makePipelines(foveated: true)
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
    /// encoder, a memory barrier between them. `rateMapData` is the rasterization rate map the
    /// eye was drawn through, with the grid's cell in physical texels (`grid` must then be the
    /// map's: `XRPresenterFoveation.grid`); nil, and the eye is a uniform texture.
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
        rateMapData: XRRasterizationRateMapData? = nil,
        cellTexels: Float = 0,
        label: String = "XR grid unproject"
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = label
        let foveated = rateMapData != nil && cellTexels > 0
        var uniforms = XRGridUnprojectUniforms(
            originFromEye: originFromEye,
            inverseProjection: simd_inverse(projection),
            gridSize: SIMD2<UInt32>(UInt32(grid.columns), UInt32(grid.rows)),
            textureSize: SIMD2<UInt32>(UInt32(depth.width), UInt32(depth.height)),
            farShell: farShell,
            tearThreshold: tearThreshold,
            skirtTexels: skirtTexels,
            screenSize: foveated ? rateMapData?.screenSize ?? .zero : .zero,
            cellTexels: foveated ? cellTexels : 0,
            foveated: foveated
        )
        uniforms.flags = adaptiveDiagonal ? 0 : 1
        encoder.setBytes(&uniforms, length: MemoryLayout<XRGridUnprojectUniforms>.stride, index: 1)
        // The kernels specialized for the eye, and the map's parameters for the foveated ones.
        let pipelines = foveated ? foveatedPipelines : uniformPipelines
        if foveated, let rateMapData {
            encoder.setBuffer(rateMapData.buffer, offset: 0, index: 3)
        }

        encoder.setComputePipelineState(pipelines.nearestDepth)
        encoder.setBuffer(nearestDepths, offset: 0, index: 0)
        encoder.setTexture(depth, index: 0)
        dispatch(encoder, pipeline: pipelines.nearestDepth, columns: grid.columns, rows: grid.rows)
        encoder.memoryBarrier(scope: .buffers)

        encoder.setComputePipelineState(pipelines.unproject)
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBuffer(nearestDepths, offset: 0, index: 2)
        dispatch(encoder, pipeline: pipelines.unproject, columns: grid.columns, rows: grid.rows)
        // The cells' triangles for this frame, when the presenter hands the index buffer in
        // (nil keeps the mesh's indices as they are: the fixed split).
        if let indices {
            encoder.setComputePipelineState(pipelines.triangulate)
            encoder.setBuffer(indices, offset: 0, index: 0)
            encoder.setBuffer(nearestDepths, offset: 0, index: 2)
            dispatch(encoder, pipeline: pipelines.triangulate, columns: grid.columns - 1, rows: grid.rows - 1)
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
