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
    /// Bit 0: the cells keep the fixed diagonal (no per-frame split by depth). Bit 1: the
    /// nearest-depth dispatch scans every vertex's footprint, taking no block fast path.
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

/// The buffers one eye's unprojection keeps between its dispatches and across frames, made for
/// one grid and one depth size (the rate map's physical size through one): the caller keeps
/// one per eye (the presenter does), and the command buffers of one queue run in order, so a
/// frame's dispatches read what its earlier ones wrote and the nearest-depth dispatch reads the
/// previous frame's entries for its hysteresis. Private to the GPU unless a test asks for
/// shared storage to read them.
public struct XRGridUnprojectScratch {
    /// One float4 per vertex: the chosen texel's depth, the texel, the rim flag.
    public let nearestDepths: MTLBuffer
    /// One float per block of `XRGridUnprojectPass.blockTexels` texels of the depth: the block's
    /// nearest depth, written each frame.
    public let blockNearestDepths: MTLBuffer
    /// The vertices the fast path left to the scan dispatch: a header of
    /// `XRGridUnprojectPass.scanListHeaderLength` bytes (the scan dispatch's indirect
    /// arguments, then their count at `scanListCountOffset`), their indices after it.
    public let scanList: MTLBuffer
    public let grid: XRPresenterGrid
    public let textureSize: SIMD2<Int>

    /// Nil when Metal gives no buffer.
    public init?(device: MTLDevice, grid: XRPresenterGrid, textureSize: SIMD2<Int>, options: MTLResourceOptions = .storageModePrivate, label: String = "XR grid") {
        let blocks = XRGridUnprojectPass.blockCount(textureSize: textureSize)
        guard
            let nearestDepths = device.makeBuffer(length: grid.vertexCount * MemoryLayout<SIMD4<Float>>.stride, options: options),
            let blockNearestDepths = device.makeBuffer(length: blocks.x * blocks.y * MemoryLayout<Float>.stride, options: options),
            let scanList = device.makeBuffer(length: XRGridUnprojectPass.scanListHeaderLength + grid.vertexCount * MemoryLayout<UInt32>.stride, options: options)
        else { return nil }
        nearestDepths.label = "\(label) nearest depth"
        blockNearestDepths.label = "\(label) block nearest depth"
        scanList.label = "\(label) scan list"
        self.nearestDepths = nearestDepths
        self.blockNearestDepths = blockNearestDepths
        self.scanList = scanList
        self.grid = grid
        self.textureSize = textureSize
    }

    /// How many vertices the last frame left to the scan dispatch, read from a shared scan list.
    public var scannedVertexCount: Int {
        Int(scanList.contents().load(fromByteOffset: XRGridUnprojectPass.scanListCountOffset, as: UInt32.self))
    }
}

/// Turns one eye's depth into its grid, in a chain of dispatches on the same command buffer. The
/// first stage, one thread per vertex, reads the nearest depth (the largest, under reverse Z) over
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
/// a continuous surface stays at its centre, so the grid stays regular there. The placement
/// dispatch (pass 2) reads its own and its eight neighbours' entries from that buffer, places each
/// vertex on its texel (its position unprojected there through the eye's inverse projection
/// and pose into the origin's space, its uv that texel's, v = 0 at the top row as RealityKit
/// samples a `LowLevelTexture`), and writes the tear mask; a rim vertex is pushed outward past
/// its edge texel by the skirt, so that the silhouette seen is the alpha test's crossing of the
/// filtered texture rather than the mesh boundary. A triangulation dispatch (pass 3) writes each cell's two
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
/// The edge band, the blended second drawing of the grid over the opaque core, has a mesh of
/// its own per eye: its vertices are the core's bytes, which the placement dispatch writes into a
/// second buffer when one is bound (`kEdgeBand`, a function constant, so the kernel without a
/// band is what it always was), and its index buffer a band dispatch (pass 4) writes per frame, one
/// thread per cell: the cell's two triangles, split as the core's are, when any of its four
/// vertices is a rim vertex or carries a tear-mask channel (the cells along silhouettes and
/// depth jumps, where the texture has partly covered texels to blend), else six copies of one
/// index, a pair of degenerate triangles the rasterizer draws nothing for. RealityKit then
/// shades the band's cells alone instead of the whole grid a second time.
///
/// The first stage's footprint scan read some 240 texels per vertex, twice, and was most of
/// the presenter's GPU time on the headset. It is now three dispatches (passes 0 and 1 and
/// pass 1's scan) with the same entries. A block dispatch over the depth alone writes the
/// nearest depth of each 8 × 8 block of texels into a small buffer, the whole depth read once
/// (two texels by two through gather). The vertices' dispatch then takes a fast path: the
/// nearest depth over the blocks that cover the footprint is at least as near as the
/// footprint's own, so a vertex whose centre texel lies within the tear threshold of it lies
/// within the threshold of the footprint's nearest too, and the scan's answer is known without
/// the scan: the centre texel is the near-side texel nearest the centre (the scan's first in
/// case of a tie), the rim flag is off, and the hysteresis holds the previous texel when its
/// depth passes the same test. Where that test fails (a depth jump within two blocks of the
/// vertex) or is inconclusive (the previous texel might pass the footprint's limit but not the
/// blocks'), the vertex is appended to a list, and a scan dispatch over that list alone,
/// dispatched indirectly to its length, runs the footprint scan as it always was, so every
/// entry is what the scan alone would write. The list keeps the scan dense: run inside the
/// vertices' dispatch, a SIMD-group of 32 vertices paid the whole scan whenever one of them
/// needed it, and the few vertices along a scene's silhouettes cost as much as a third of the
/// whole grid's scan. The scan reads the footprint two texels by two through gather as well,
/// sixteen lanes per vertex (a quad-row each, so a short list is not as long as one thread's
/// walk of a footprint), the quads masked to the footprint, the tie between texels at one
/// distance settled by row and column (the first in row order, as the scan in row order kept
/// it). On a Mac the whole chain takes a thirteenth of what it took on scenes of a few objects
/// and a seventh on a checkerboard of jumps every 100 texels.
///
/// The kernels are compiled from source once per device: the engine's prebuilt metallibs stay
/// as they are, and the tests run them on a Mac.
public final class XRGridUnprojectPass: @unchecked Sendable {
    /// Pass 0: each 8 × 8 block's nearest depth into the block buffer, and the scan list reset.
    public static let blockNearestKernelName = "xrGridBlockNearest"
    /// Pass 1: each vertex's entry into the scratch buffer where the blocks settle it, else the
    /// vertex onto the scan list.
    public static let nearestDepthKernelName = "xrGridNearestDepth"
    /// Pass 1's scan: the footprint scan of the listed vertices, their entries.
    public static let scanDepthKernelName = "xrGridScanDepth"
    /// Pass 2: the vertices from the entries.
    public static let kernelName = "xrGridUnproject"
    /// Pass 3: each cell's two triangles, split along the diagonal nearer in depth.
    public static let triangulateKernelName = "xrGridTriangulate"
    /// Pass 4: the edge band's index buffer, the cells along silhouettes and depth jumps.
    public static let edgeBandKernelName = "xrGridEdgeBand"

    /// The kernels. Their `XRGridVertex` is the grid's vertex layout; their uniforms are
    /// `XRGridUnprojectUniforms`.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    // Whether the eye was drawn through a rasterization rate map: a function constant, so each
    // kernel is compiled twice and the uniform one is the arithmetic it always was, with no map
    // argument, while the foveated one carries no branch.
    constant bool kFoveated [[function_constant(0)]];
    // Whether pass 2 writes the edge band's vertex buffer too: a function constant, so the
    // kernel without a band is what it always was.
    constant bool kEdgeBand [[function_constant(1)]];
    // The texels along each side of the blocks whose nearest depth the block dispatch writes.
    constant int kBlockTexels = 8;
    // The scan list's header, in uints: the scan dispatch's threadgroups (x, y, z, read by the
    // indirect dispatch), then the count of listed vertices; the listed indices follow. The
    // block dispatch resets the header, the nearest-depth dispatch adds to it.
    constant uint kScanListHeader = 4;
    constant uint kScanListCount = 3;
    // The scan dispatch: kScanLanes threads per listed vertex, a quad-row of the footprint
    // each, in threadgroups of kScanThreadgroupThreads (so a threadgroup scans
    // kScanThreadgroupThreads / kScanLanes vertices). The Swift side dispatches with the same.
    constant uint kScanLanes = 16;
    constant uint kScanThreadgroupThreads = 256;
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
    // How many blocks of kBlockTexels cover the depth along each axis, the last column and row
    // of blocks cut to the texels there.
    static uint2 blockCount(constant XRGridUnprojectUniforms &u) {
        return (u.textureSize + uint(kBlockTexels) - 1u) / uint(kBlockTexels);
    }
    // The block dispatch and the scan read the depth two texels by two through gather, in
    // pixel coordinates: at the corner between four texels, (x + 1, y + 1) for the quad at
    // (x, y), gather returns those four (the footprint bilinear filtering would take there,
    // settled without a tie since x + 0.5 is exact). Past the texture's edge the sampler
    // repeats the edge texel, which leaves a maximum as it is and is masked off by the scan.
    constexpr sampler blockGather(coord::pixel, address::clamp_to_edge, filter::nearest);
    // Pass 0: the nearest depth (the largest, under reverse Z) of each block of
    // kBlockTexels × kBlockTexels texels, one thread per block: sixteen gathers of a quad each,
    // unrolled, their maxima taken four at a time (a read per texel took ten times as long on
    // a Mac). A block at the texture's right or bottom edge reads the edge texels twice and
    // holds the nearest of the texels it has. The whole depth is read once; pass 1 settles
    // most vertices from a few of these instead of their footprints.
    kernel void xrGridBlockNearest(device float *blocks [[buffer(0)]],
                                   constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                   device atomic_uint *scanHeader [[buffer(6)]],
                                   depth2d<float, access::sample> depth [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        // The scan list starts empty each frame, its dispatch at no threadgroups: reset here,
        // before the vertices' dispatch.
        if (gid.x == 0 && gid.y == 0) {
            atomic_store_explicit(&scanHeader[0], 0u, memory_order_relaxed);
            atomic_store_explicit(&scanHeader[1], 1u, memory_order_relaxed);
            atomic_store_explicit(&scanHeader[2], 1u, memory_order_relaxed);
            atomic_store_explicit(&scanHeader[kScanListCount], 0u, memory_order_relaxed);
        }
        uint2 count = blockCount(u);
        if (gid.x >= count.x || gid.y >= count.y) { return; }
        float2 corner = float2(gid * uint(kBlockTexels)) + 1.0f;
        float4 nearest = float4(0.0f);
        for (int j = 0; j < kBlockTexels / 2; ++j) {
            for (int i = 0; i < kBlockTexels / 2; ++i) {
                nearest = max(nearest, depth.gather(blockGather, corner + float2(i * 2, j * 2)));
            }
        }
        blocks[gid.y * count.x + gid.x] = max(max(nearest.x, nearest.y), max(nearest.z, nearest.w));
    }
    // What the vertices' dispatch and the scan dispatch share of a vertex, the same arithmetic
    // in both so that the scan settles a vertex exactly as the fast path would have: its
    // footprint, the cell about the vertex (half a cell to each side, in texels) plus a margin
    // of half a cell, so that every texel is read by some vertex, adjacent footprints overlap,
    // and the first vertex outside an edge always reaches it (the margin is half a cell, so
    // the footprint reaches a whole cell from the centre: the first vertex outside an edge is
    // within a cell of it and must reach it wherever the edge falls among the cells, and the
    // second must not, or it would leave the surface behind the object for the edge too; the
    // bounds are taken with a tolerance of a thousandth of a texel, so that a cell edge that
    // lands on a texel is the same texel whichever way the arithmetic rounds); its own ray, as
    // the two vectors of the inverse projection that give the distance in front of the eye of
    // a depth along it (through the map when foveated, else its texture position); and the
    // texel under its centre, the rim test's.
    struct XRGridVertexFrame {
        float2 centre;
        int2 lo;
        int2 hi;
        float4 a;
        float4 b;
        float2 centreTexel;
    };
    static XRGridVertexFrame vertexFrame(uint2 gid, constant XRGridUnprojectUniforms &u, constant rasterization_rate_map_data *rateMap) {
        XRGridVertexFrame f;
        float2 size = float2(u.textureSize);
        float2 halfCell = halfCellTexels(u);
        f.centre = vertexCentre(gid, u);
        int2 margin = int2(ceil(halfCell - 1e-3f));
        f.lo = max(int2(ceil(f.centre - halfCell - 1e-3f)) - margin, int2(0));
        f.hi = min(int2(floor(f.centre + halfCell + 1e-3f)) + margin, int2(u.textureSize) - 1);
        float2 ndc = kFoveated ? texelToNDC(f.centre, u, rateMap) : uvToNDC(f.centre / (size - 1.0f));
        f.a = u.inverseProjection * float4(ndc, 0.0f, 1.0f);
        f.b = u.inverseProjection * float4(0.0f, 0.0f, 1.0f, 0.0f);
        f.centreTexel = clamp(round(f.centre), float2(0.0f), size - 1.0f);
        return f;
    }
    // Pass 1: each vertex's entry, (the chosen texel's depth, texel x, texel y, the rim flag),
    // where the blocks settle it, else the vertex's index onto the scan list. The entry the
    // scan would write is the nearest depth (the largest, under reverse Z) over the footprint
    // and the texel the vertex is placed on, which is the texel NEAREST THE VERTEX'S CENTRE
    // among those on the near side of the footprint's depth jump (within the tear threshold of
    // the nearest depth, in metres along the vertex's ray): a vertex whose centre lies off an
    // object but whose footprint reaches it lands on the object's edge texel, whatever the
    // surface's slope; one whose centre lies on it, or on any continuous surface, stays at its
    // centre, so the grid stays regular there. The fast path (unless flag bit 1 is set): the
    // nearest depth over the blocks that cover the footprint, a superset of it, is at least as
    // near as the footprint's, so its near-side limit along the vertex's ray is at least as
    // strict. When the texel the scan would choose first among those nearest the centre (the
    // nearest integer texel, the lower one on an exact half, as the scan's row order picks it)
    // and the centre texel of the rim test both pass that stricter limit, the scan's result is
    // known: the first texel is on the near side and nearest of all, the rim is off; the
    // hysteresis keeps the previous texel when it passes the stricter limit too, and leaves
    // the vertex to the scan when it does not, since the footprint's limit might still admit
    // it. So every entry is the scan's. Every thread of a SIMD-group reaches the append, the
    // ones outside the grid with nothing to append, and the group appends with one atomic add;
    // the scan dispatch's threadgroup count follows the count by an atomic max, so the
    // dispatch is as long as the list.
    kernel void xrGridNearestDepth(device float4 *depths [[buffer(0)]],
                                   constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                   constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                                   const device float *blocks [[buffer(5)]],
                                   device atomic_uint *scanHeader [[buffer(6)]],
                                   device uint *scanList [[buffer(7)]],
                                   depth2d<float, access::read> depth [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        bool inGrid = gid.x < u.gridSize.x && gid.y < u.gridSize.y;
        uint index = gid.y * u.gridSize.x + gid.x;
        bool settled = false;
        if (inGrid && (u.flags & 2u) == 0u) {
            XRGridVertexFrame f = vertexFrame(gid, u, rateMap);
            uint2 count = blockCount(u);
            int2 blockLo = f.lo / kBlockTexels;
            int2 blockHi = f.hi / kBlockTexels;
            float superset = 0.0f;
            for (int y = blockLo.y; y <= blockHi.y; ++y) {
                for (int x = blockLo.x; x <= blockHi.x; ++x) {
                    superset = max(superset, blocks[y * count.x + x]);
                }
            }
            float supersetLimit = zInFront(superset, f.a, f.b) + u.tearThreshold;
            int2 first = clamp(int2(ceil(f.centre - 0.5f)), f.lo, f.hi);
            float firstDepth = depth.read(uint2(first));
            if (zInFront(firstDepth, f.a, f.b) < supersetLimit && zInFront(depth.read(uint2(f.centreTexel)), f.a, f.b) < supersetLimit) {
                float chosen = firstDepth;
                float2 texel = float2(first);
                float2 kept = depths[index].yz;
                settled = true;
                if (all(kept >= float2(f.lo)) && all(kept <= float2(f.hi)) && all(abs(kept - texel) <= 1.0f)) {
                    float d = depth.read(uint2(kept));
                    if (zInFront(d, f.a, f.b) < supersetLimit) {
                        chosen = d;
                        texel = kept;
                    } else {
                        settled = false;
                    }
                }
                if (settled) { depths[index] = float4(chosen, texel, 0.0f); }
            }
        }
        uint wants = (inGrid && !settled) ? 1u : 0u;
        uint rank = simd_prefix_exclusive_sum(wants);
        uint total = simd_sum(wants);
        if (total > 0u) {
            uint base = 0u;
            if (simd_is_first()) {
                base = atomic_fetch_add_explicit(&scanHeader[kScanListCount], total, memory_order_relaxed);
                uint verticesPerThreadgroup = kScanThreadgroupThreads / kScanLanes;
                uint threadgroups = (base + total + verticesPerThreadgroup - 1) / verticesPerThreadgroup;
                atomic_fetch_max_explicit(&scanHeader[0], threadgroups, memory_order_relaxed);
            }
            base = simd_broadcast_first(base);
            if (wants != 0u) { scanList[kScanListHeader + base + rank] = index; }
        }
    }
    // A texel of the scan: on the near side, nearer the centre than the texel chosen so far,
    // or as near and earlier in row order (smaller row, then smaller column), it is the one.
    static void considerTexel(float d, int x, int y, bool inFootprint, float nearSideLimit, float4 a, float4 b, float2 centre, thread float &chosen, thread float2 &texel, thread float &chosenDistance) {
        if (!inFootprint || zInFront(d, a, b) >= nearSideLimit) { return; }
        float2 t = float2(x, y);
        float distance = length_squared(t - centre);
        if (distance < chosenDistance || (distance == chosenDistance && (t.y < texel.y || (t.y == texel.y && t.x < texel.x)))) {
            chosen = d;
            texel = t;
            chosenDistance = distance;
        }
    }
    // The scan dispatch: the footprint scan pass 1 left a vertex, kScanLanes threads per listed
    // vertex (the sixteen in one half of a SIMD-group, since the threadgroup is a multiple of
    // the SIMD width and the vertex's slot a multiple of sixteen), each reading one quad-row of
    // the footprint, two texels by two through gather: the quads tile the footprint rounded out
    // to even bounds, the texels outside it masked off (a quad's texels, by component: w at
    // (x, y), z at (x + 1, y), x at (x, y + 1), y at (x + 1, y + 1)); a footprint has at most
    // nine quad-rows, so the other lanes read nothing. One thread per vertex walked the whole
    // footprint in sequence, and a short list's few threads made the dispatch as long as that
    // walk's latency whatever the count. First the nearest depth over the footprint, each
    // lane's maximum folded over the sixteen; then the texel chosen (`considerTexel`, each
    // lane over its row, the sixteen choices folded under the same rule, a total order, so the
    // vertex's texel is the one the scan in row order chose); then, on the first lane, the
    // hysteresis: the previous frame's texel is kept while this frame's choice lies within a
    // texel of it and the depth there is still on the near side, so that the jitter of the
    // predicted head pose, which moves a silhouette by a fraction of a texel, does not flip
    // the edge between two texels frame after frame; a head that moves takes the edge further
    // than a texel and the new choice is taken. A rim vertex: its own centre texel lies off the
    // near surface, so the vertex was pulled onto the surface's edge; pass 2 pushes it back out
    // by the skirt. Dispatched indirectly from the list's header: as many threadgroups as the
    // list fills, the slots of the last one past the count leaving together.
    kernel void xrGridScanDepth(device float4 *depths [[buffer(0)]],
                                constant XRGridUnprojectUniforms &u [[buffer(1)]],
                                constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                                const device uint *scanHeader [[buffer(6)]],
                                const device uint *scanList [[buffer(7)]],
                                depth2d<float, access::sample> depth [[texture(0)]],
                                uint tid [[thread_position_in_grid]])
    {
        uint count = min(scanHeader[kScanListCount], u.gridSize.x * u.gridSize.y);
        uint slot = tid / kScanLanes;
        uint part = tid % kScanLanes;
        if (slot >= count) { return; }
        uint index = scanList[kScanListHeader + slot];
        uint2 gid = uint2(index % u.gridSize.x, index / u.gridSize.x);
        XRGridVertexFrame f = vertexFrame(gid, u, rateMap);
        int2 lo = f.lo;
        int2 hi = f.hi;
        int2 lo2 = lo & ~1;
        int2 hi2 = hi | 1;
        int y = lo2.y + 2 * int(part);
        bool hasRow = y <= hi2.y;
        bool2 rowIn = bool2(y >= lo.y, y + 1 <= hi.y);
        float nearest = 0.0f;
        if (hasRow) {
            for (int x = lo2.x; x <= hi2.x; x += 2) {
                float4 q = depth.gather(blockGather, float2(x + 1, y + 1));
                bool2 columnIn = bool2(x >= lo.x, x + 1 <= hi.x);
                bool4 quadIn = bool4(columnIn.x && rowIn.y, columnIn.y && rowIn.y, columnIn.y && rowIn.x, columnIn.x && rowIn.x);
                q = select(float4(0.0f), q, quadIn);
                nearest = max(nearest, max(max(q.x, q.y), max(q.z, q.w)));
            }
        }
        for (ushort step = kScanLanes / 2; step > 0; step >>= 1) {
            nearest = max(nearest, simd_shuffle_xor(nearest, step));
        }
        float nearSideLimit = zInFront(nearest, f.a, f.b) + u.tearThreshold;
        float chosen = nearest;
        float2 texel = f.centre;
        float chosenDistance = 1e30f;
        if (hasRow) {
            for (int x = lo2.x; x <= hi2.x; x += 2) {
                float4 q = depth.gather(blockGather, float2(x + 1, y + 1));
                bool2 columnIn = bool2(x >= lo.x, x + 1 <= hi.x);
                considerTexel(q.w, x, y, columnIn.x && rowIn.x, nearSideLimit, f.a, f.b, f.centre, chosen, texel, chosenDistance);
                considerTexel(q.z, x + 1, y, columnIn.y && rowIn.x, nearSideLimit, f.a, f.b, f.centre, chosen, texel, chosenDistance);
                considerTexel(q.x, x, y + 1, columnIn.x && rowIn.y, nearSideLimit, f.a, f.b, f.centre, chosen, texel, chosenDistance);
                considerTexel(q.y, x + 1, y + 1, columnIn.y && rowIn.y, nearSideLimit, f.a, f.b, f.centre, chosen, texel, chosenDistance);
            }
        }
        for (ushort step = kScanLanes / 2; step > 0; step >>= 1) {
            float otherChosen = simd_shuffle_xor(chosen, step);
            float2 otherTexel = simd_shuffle_xor(texel, step);
            float otherDistance = simd_shuffle_xor(chosenDistance, step);
            if (otherDistance < chosenDistance || (otherDistance == chosenDistance && (otherTexel.y < texel.y || (otherTexel.y == texel.y && otherTexel.x < texel.x)))) {
                chosen = otherChosen;
                texel = otherTexel;
                chosenDistance = otherDistance;
            }
        }
        if (part != 0) { return; }
        float2 kept = depths[index].yz;
        if (all(kept >= float2(lo)) && all(kept <= float2(hi)) && all(abs(kept - texel) <= 1.0f)) {
            float d = depth.read(uint2(kept));
            if (zInFront(d, f.a, f.b) < nearSideLimit) {
                chosen = d;
                texel = kept;
            }
        }
        bool rim = zInFront(depth.read(uint2(f.centreTexel)), f.a, f.b) >= nearSideLimit;
        depths[index] = float4(chosen, texel, rim ? 1.0f : 0.0f);
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
                                device XRGridVertex *bandVertices [[buffer(4), function_constant(kEdgeBand)]],
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
        // uv is this vertex's own projection, so uv times its eye-space depth is an affine
        // function of the point: interpolated perspective-correctly by RealityKit and divided per
        // pixel, the texture is read where the engine drew it across every planar triangle,
        // whatever RealityKit's own camera (an affine uv keystones across a tilted cell).
        float ze = -eye.z;
        v.uvw = packed_float4(uv.x * ze, uv.y * ze, ze, 0.0f);
        // The edge band's mesh has the same vertices: the same bytes into its own buffer.
        if (kEdgeBand) { bandVertices[gid.y * u.gridSize.x + gid.x] = v; }
    }
    // Whether a cell's two triangles are split along the other diagonal (top-left to
    // bottom-right): only where the default diagonal crosses a depth jump and the other does
    // not (the depths read along the cell's own ray), and never under the fixed-diagonal flag,
    // so every continuous surface keeps one topology from frame to frame. A silhouette that
    // crosses a cell corner to corner has its two on-edge vertices on one diagonal; with a
    // fixed split half of those cells lost both triangles to the far vertex and the boundary
    // dipped to the next interior vertex. a (top-left) = row r column c, b = a + 1,
    // c = a + columns, d = c + 1. The cell's own ray goes through its centre texel's place on
    // the map when foveated.
    static bool splitsTheOtherWay(uint2 gid, uint a, uint b, uint c, uint d, constant XRGridUnprojectUniforms &u, const device float4 *depths, constant rasterization_rate_map_data *rateMap) {
        if ((u.flags & 1u) != 0u) { return false; }
        float2 ndc;
        if (kFoveated) {
            float2 cellCentre = clamp((float2(gid) + 0.5f) * u.cellTexels - 0.5f, float2(0.0f), float2(u.textureSize) - 1.0f);
            ndc = texelToNDC(cellCentre, u, rateMap);
        } else {
            ndc = uvToNDC((float2(gid) + 0.5f) / float2(u.gridSize - 1));
        }
        float4 ra = u.inverseProjection * float4(ndc, 0.0f, 1.0f);
        float4 rb = u.inverseProjection * float4(0.0f, 0.0f, 1.0f, 0.0f);
        float za = zInFront(depths[a].x, ra, rb);
        float zb = zInFront(depths[b].x, ra, rb);
        float zc = zInFront(depths[c].x, ra, rb);
        float zd = zInFront(depths[d].x, ra, rb);
        return fabs(zb - zc) > u.tearThreshold && fabs(za - zd) <= u.tearThreshold;
    }
    // The cell's two triangles at t, counter-clockwise as seen from the eye, split one way or
    // the other.
    static void writeCell(device uint *t, bool otherWay, uint a, uint b, uint c, uint d) {
        if (otherWay) {
            t[0] = a; t[1] = c; t[2] = d;
            t[3] = a; t[4] = d; t[5] = b;
        } else {
            t[0] = a; t[1] = c; t[2] = b;
            t[3] = b; t[4] = c; t[5] = d;
        }
    }
    // Pass 3: the cell's two triangles, split along the diagonal that does not cross a depth
    // jump when the other does. One thread per cell.
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
        device uint *t = indices + (gid.y * cells.x + gid.x) * 6;
        writeCell(t, splitsTheOtherWay(gid, a, b, c, d, u, depths, rateMap), a, b, c, d);
    }
    // Whether a vertex lies along a silhouette or a depth jump: a rim vertex (the scratch
    // entry's flag: its own centre lies off the near surface its footprint reached) or one
    // carrying a tear-mask channel (the near or the far side of a jump).
    static bool alongAnEdge(uint index, const device float4 *depths, const device XRGridVertex *vertices) {
        float2 mask = float2(vertices[index].mask);
        return depths[index].w > 0.5f || mask.x > 0.0f || mask.y > 0.0f;
    }
    // Pass 4: the edge band's index buffer, one thread per cell. The cell's two triangles, split
    // as the core's are, when any of its four vertices lies along an edge: those cells hold
    // every texel a silhouette partly covers (the rim vertex sits past the edge texel, the
    // surface's own vertex next to it inside the surface) and the stretched triangles of a
    // depth jump, which the material discards. Every other cell is six copies of its first
    // index, a pair of degenerate triangles the rasterizer draws nothing for. The mask is read
    // from the core's vertices, written by pass 2 (a barrier between).
    kernel void xrGridEdgeBand(device uint *indices [[buffer(0)]],
                               constant XRGridUnprojectUniforms &u [[buffer(1)]],
                               const device float4 *depths [[buffer(2)]],
                               constant rasterization_rate_map_data *rateMap [[buffer(3), function_constant(kFoveated)]],
                               const device XRGridVertex *vertices [[buffer(4)]],
                               uint2 gid [[thread_position_in_grid]])
    {
        uint2 cells = u.gridSize - 1;
        if (gid.x >= cells.x || gid.y >= cells.y) { return; }
        uint a = gid.y * u.gridSize.x + gid.x;
        uint b = a + 1;
        uint c = a + u.gridSize.x;
        uint d = c + 1;
        device uint *t = indices + (gid.y * cells.x + gid.x) * 6;
        bool along = alongAnEdge(a, depths, vertices) || alongAnEdge(b, depths, vertices) || alongAnEdge(c, depths, vertices) || alongAnEdge(d, depths, vertices);
        if (!along) {
            t[0] = a; t[1] = a; t[2] = a;
            t[3] = a; t[4] = a; t[5] = a;
            return;
        }
        writeCell(t, splitsTheOtherWay(gid, a, b, c, d, u, depths, rateMap), a, b, c, d);
    }
    """

    /// The six kernels, specialized for one value of `kFoveated`; the vertices' one twice, with
    /// and without the edge band's vertex buffer (`kEdgeBand`).
    private struct Pipelines {
        let blockNearest: MTLComputePipelineState
        let nearestDepth: MTLComputePipelineState
        let scanDepth: MTLComputePipelineState
        let unproject: MTLComputePipelineState
        let unprojectWithBand: MTLComputePipelineState
        let triangulate: MTLComputePipelineState
        let edgeBand: MTLComputePipelineState
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
            func makeConstants(edgeBand: Bool) -> MTLFunctionConstantValues {
                var edgeBand = edgeBand
                let constants = MTLFunctionConstantValues()
                constants.setConstantValue(&foveated, type: .bool, index: 0)
                constants.setConstantValue(&edgeBand, type: .bool, index: 1)
                return constants
            }
            let constants = makeConstants(edgeBand: false)
            let bandConstants = makeConstants(edgeBand: true)
            func makePipeline(_ name: String, _ constants: MTLFunctionConstantValues) throws -> MTLComputePipelineState {
                let function = try library.makeFunction(name: name, constantValues: constants)
                return try device.makeComputePipelineState(function: function)
            }
            return try Pipelines(
                blockNearest: makePipeline(Self.blockNearestKernelName, constants),
                nearestDepth: makePipeline(Self.nearestDepthKernelName, constants),
                scanDepth: makePipeline(Self.scanDepthKernelName, constants),
                unproject: makePipeline(Self.kernelName, constants),
                unprojectWithBand: makePipeline(Self.kernelName, bandConstants),
                triangulate: makePipeline(Self.triangulateKernelName, constants),
                edgeBand: makePipeline(Self.edgeBandKernelName, constants)
            )
        }
        uniformPipelines = try makePipelines(foveated: false)
        foveatedPipelines = try makePipelines(foveated: true)
    }

    /// The texels along each side of the blocks whose nearest depth the block dispatch writes
    /// (the kernels' `kBlockTexels`).
    public static let blockTexels = 8

    /// How many blocks of `blockTexels` cover a depth texture of `textureSize` along each axis,
    /// the last column and row of blocks cut to the texels there.
    public static func blockCount(textureSize: SIMD2<Int>) -> SIMD2<Int> {
        (textureSize &+ (blockTexels - 1)) / blockTexels
    }

    /// The scan list's header in bytes (the kernels' `kScanListHeader` uints): the scan
    /// dispatch's threadgroups (three `UInt32`, its indirect arguments), then the count of
    /// listed vertices.
    public static let scanListHeaderLength = 16
    /// Where the count of listed vertices lies in the header.
    public static let scanListCountOffset = 12
    /// The scan dispatch's threads per threadgroup (the kernels' `kScanThreadgroupThreads`,
    /// `kScanLanes` of them per listed vertex).
    static let scanThreadgroupThreads = 256

    /// Threads per threadgroup at most: the grid then spreads over the GPU's cores evenly
    /// (groups of 1024 made 64 of the headset's grid, each waiting for its slowest row).
    static let threadsPerThreadgroup = 256

    /// Encodes one eye's unprojection: `depth` is the eye's depth as the engine left it (reverse
    /// Z), `scratch` the eye's scratch buffers, made for this depth's size and the grid
    /// (`XRGridUnprojectScratch`), `vertices` the grid's vertex buffer for this frame,
    /// `originFromEye` the inverse of the view matrix the eye was drawn with and `projection`
    /// its projection. The dispatches go into one compute encoder, memory barriers between
    /// them. `indices` is the grid's index buffer for this frame, split by the depth (nil keeps
    /// the mesh's). `bandVertices` and `bandIndices` are the edge band's mesh for this frame:
    /// its vertices get the grid's bytes, its indices the cells along silhouettes and depth
    /// jumps, every other cell degenerate (nil for no band). `rateMapData` is the rasterization
    /// rate map the eye was drawn through, with the grid's cell in physical texels (the scratch's
    /// grid must then be the map's: `XRPresenterFoveation.grid`); nil, and the eye is a uniform
    /// texture. `fastPath` false sends every vertex to the scan dispatch, as the nearest-depth
    /// dispatch scanned them all before it had the blocks (the same entries, for a test to
    /// compare against). A scratch made for another size than the depth's encodes nothing.
    public func encode(
        commandBuffer: MTLCommandBuffer,
        depth: MTLTexture,
        scratch: XRGridUnprojectScratch,
        vertices: MTLBuffer,
        indices: MTLBuffer? = nil,
        bandVertices: MTLBuffer? = nil,
        bandIndices: MTLBuffer? = nil,
        originFromEye: simd_float4x4,
        projection: simd_float4x4,
        farShell: Float,
        tearThreshold: Float,
        skirtTexels: Float = 0,
        adaptiveDiagonal: Bool = true,
        rateMapData: XRRasterizationRateMapData? = nil,
        cellTexels: Float = 0,
        fastPath: Bool = true,
        label: String = "XR grid unproject"
    ) {
        let textureSize = SIMD2<Int>(depth.width, depth.height)
        guard scratch.textureSize == textureSize else {
            assertionFailure("the unprojection's scratch was made for a depth of \(scratch.textureSize), not \(textureSize)")
            return
        }
        // Timed with the engine's passes when the GPU pass timing is on.
        guard let encoder = GPUPassTiming.shared.makeComputeEncoder(commandBuffer, label) else { return }
        encoder.label = label
        let grid = scratch.grid
        let foveated = rateMapData != nil && cellTexels > 0
        let blocks = Self.blockCount(textureSize: textureSize)
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
        uniforms.flags = (adaptiveDiagonal ? 0 : 1) | (fastPath ? 0 : 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<XRGridUnprojectUniforms>.stride, index: 1)
        // The kernels specialized for the eye, and the map's parameters for the foveated ones.
        let pipelines = foveated ? foveatedPipelines : uniformPipelines
        if foveated, let rateMapData {
            encoder.setBuffer(rateMapData.buffer, offset: 0, index: 3)
        }
        encoder.setTexture(depth, index: 0)
        let nearestDepths = scratch.nearestDepths
        // The scan list twice: its count, atomic, and its indices past the header.
        encoder.setBuffer(scratch.scanList, offset: 0, index: 6)
        encoder.setBuffer(scratch.scanList, offset: 0, index: 7)

        // Each block's nearest depth, the whole depth read once, and the scan list emptied.
        encoder.setComputePipelineState(pipelines.blockNearest)
        encoder.setBuffer(scratch.blockNearestDepths, offset: 0, index: 0)
        dispatch(encoder, pipeline: pipelines.blockNearest, columns: blocks.x, rows: blocks.y)
        encoder.memoryBarrier(scope: .buffers)

        // The vertices the blocks settle, and the list of the rest.
        encoder.setComputePipelineState(pipelines.nearestDepth)
        encoder.setBuffer(nearestDepths, offset: 0, index: 0)
        encoder.setBuffer(scratch.blockNearestDepths, offset: 0, index: 5)
        dispatch(encoder, pipeline: pipelines.nearestDepth, columns: grid.columns, rows: grid.rows)
        encoder.memoryBarrier(scope: .buffers)

        // The footprint scan of the listed vertices: as many threadgroups as the list fills,
        // from its header.
        encoder.setComputePipelineState(pipelines.scanDepth)
        encoder.dispatchThreadgroups(indirectBuffer: scratch.scanList, indirectBufferOffset: 0, threadsPerThreadgroup: MTLSize(width: Self.scanThreadgroupThreads, height: 1, depth: 1))
        encoder.memoryBarrier(scope: .buffers)

        // The vertices, and the edge band's copy of them when its buffer is handed in.
        let unproject = bandVertices == nil ? pipelines.unproject : pipelines.unprojectWithBand
        encoder.setComputePipelineState(unproject)
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBuffer(nearestDepths, offset: 0, index: 2)
        if let bandVertices {
            encoder.setBuffer(bandVertices, offset: 0, index: 4)
        }
        dispatch(encoder, pipeline: unproject, columns: grid.columns, rows: grid.rows)
        // The cells' triangles for this frame, when the presenter hands the index buffer in
        // (nil keeps the mesh's indices as they are: the fixed split).
        if let indices {
            encoder.setComputePipelineState(pipelines.triangulate)
            encoder.setBuffer(indices, offset: 0, index: 0)
            encoder.setBuffer(nearestDepths, offset: 0, index: 2)
            dispatch(encoder, pipeline: pipelines.triangulate, columns: grid.columns - 1, rows: grid.rows - 1)
        }
        // The band's cells, from the vertices' tear mask and the rim flags: after the vertices.
        if let bandIndices {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines.edgeBand)
            encoder.setBuffer(bandIndices, offset: 0, index: 0)
            encoder.setBuffer(nearestDepths, offset: 0, index: 2)
            encoder.setBuffer(vertices, offset: 0, index: 4)
            dispatch(encoder, pipeline: pipelines.edgeBand, columns: grid.columns - 1, rows: grid.rows - 1)
        }
        encoder.endEncoding()
    }

    /// One thread per vertex, or per cell.
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, columns: Int, rows: Int) {
        let width = min(pipeline.threadExecutionWidth, columns)
        let height = max(1, min(min(pipeline.maxTotalThreadsPerThreadgroup, Self.threadsPerThreadgroup) / width, rows))
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (columns + width - 1) / width,
            height: (rows + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
