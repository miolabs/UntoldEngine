//
//  XRRealityKitPresenterTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import RealityKit
import simd
@testable import UntoldEngine
@testable import UntoldEngineXR
@testable import UntoldEngineXRRealityKit
import XCTest

// MARK: - The grid

/// The grid's topology and its initial vertices, without Metal.
final class XRPresenterGridTests: XCTestCase {
    func test_theIndices_makeTwoTrianglesPerCell_withinTheVertices() {
        let grid = XRPresenterGrid(columns: 5, rows: 4)
        let indices = grid.indices()

        XCTAssertEqual(grid.vertexCount, 20)
        XCTAssertEqual(indices.count, grid.indexCount)
        XCTAssertEqual(indices.count, 4 * 3 * 6)
        XCTAssertEqual(indices.max(), UInt32(grid.vertexCount - 1), "the last vertex is used")
        XCTAssertEqual(Set(indices).count, grid.vertexCount, "every vertex is used")
        // The first cell: the top-left vertex, the one below it, the one to its right; then the
        // other triangle, both counter-clockwise with y up and the first row at the top.
        XCTAssertEqual(Array(indices[0 ..< 6]), [0, 5, 1, 1, 5, 6])
    }

    func test_theInitialVertices_lieOnAPlaneAhead_withTheUVUnflipped() {
        let grid = XRPresenterGrid(columns: 3, rows: 3)
        let bytes = grid.initialVertexBytes()
        XCTAssertEqual(bytes.count, 9 * XRPresenterGrid.vertexStride)

        func vertex(_ index: Int) -> (position: SIMD3<Float>, uv: SIMD2<Float>) {
            bytes.withUnsafeBytes { raw in
                let base = index * XRPresenterGrid.vertexStride
                let position = SIMD3<Float>(
                    raw.load(fromByteOffset: base, as: Float.self),
                    raw.load(fromByteOffset: base + 4, as: Float.self),
                    raw.load(fromByteOffset: base + 8, as: Float.self)
                )
                let uv = SIMD2<Float>(
                    raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset, as: Float.self),
                    raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset + 4, as: Float.self)
                )
                return (position, uv)
            }
        }
        let topLeft = vertex(0)
        let bottomRight = vertex(8)
        XCTAssertEqual(topLeft.uv, SIMD2<Float>(0, 0), "the first row is the top of the texture")
        XCTAssertEqual(bottomRight.uv, SIMD2<Float>(1, 1))
        XCTAssertEqual(topLeft.position.z, -2)
        XCTAssertGreaterThan(topLeft.position.y, bottomRight.position.y, "the first row is higher")
        XCTAssertLessThan(topLeft.position.x, bottomRight.position.x)
    }

    func test_theProjection_mapsTheFrustumToClipSpace_underReverseZ() {
        let tangents = SIMD4<Float>(1.2, 0.8, 0.9, 1.1)
        let near: Float = 0.1
        let far: Float = 500
        let projection = XRPresenterProjection.reverseZ(tangents: tangents, near: near, far: far)

        func ndc(_ eye: SIMD3<Float>) -> SIMD3<Float> {
            let clip = projection * SIMD4<Float>(eye, 1)
            return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        }
        // The frustum's edges at a distance of 2 m land on the clip cube's faces.
        XCTAssertEqual(ndc(SIMD3<Float>(-tangents.x * 2, 0, -2)).x, -1, accuracy: 1e-5, "left")
        XCTAssertEqual(ndc(SIMD3<Float>(tangents.y * 2, 0, -2)).x, 1, accuracy: 1e-5, "right")
        XCTAssertEqual(ndc(SIMD3<Float>(0, tangents.z * 2, -2)).y, 1, accuracy: 1e-5, "up")
        XCTAssertEqual(ndc(SIMD3<Float>(0, -tangents.w * 2, -2)).y, -1, accuracy: 1e-5, "down")
        // Reverse Z: the near plane at 1, the far plane at 0, in between decreasing.
        XCTAssertEqual(ndc(SIMD3<Float>(0, 0, -near)).z, 1, accuracy: 1e-5)
        XCTAssertEqual(ndc(SIMD3<Float>(0, 0, -far)).z, 0, accuracy: 1e-5)
        XCTAssertGreaterThan(ndc(SIMD3<Float>(0, 0, -1)).z, ndc(SIMD3<Float>(0, 0, -10)).z)
    }
}

// MARK: - The mailbox

final class XRTicketMailboxTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    private func ticket(_ serial: UInt64) throws -> XRPresenterTicket {
        try XRPresenterTicket(serial: serial, commandBuffer: XCTUnwrap(queue.makeCommandBuffer()), colorTextures: [], gridBuffers: [], postedAt: CACurrentMediaTime())
    }

    func test_oneSlot_aSecondPostWaitsForTheTake() throws {
        let mailbox = XRTicketMailbox()
        XCTAssertFalse(mailbox.hasPending)

        XCTAssertTrue(try mailbox.post(ticket(1)))
        XCTAssertTrue(mailbox.hasPending)
        XCTAssertFalse(try mailbox.post(ticket(2)), "the slot is taken: the caller counts a drop")

        XCTAssertEqual(mailbox.take()?.serial, 1)
        XCTAssertFalse(mailbox.hasPending)
        XCTAssertTrue(try mailbox.post(ticket(3)))
        XCTAssertEqual(mailbox.take()?.serial, 3)
    }

    func test_takeBlocksUntilAPost_andEndsWithTheClose() throws {
        let mailbox = XRTicketMailbox()
        let taken = expectation(description: "a ticket was taken")
        let ended = expectation(description: "the take returned nil after the close")
        let thread = Thread {
            if mailbox.take()?.serial == 7 { taken.fulfill() }
            if mailbox.take() == nil { ended.fulfill() }
        }
        thread.start()

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(try mailbox.post(ticket(7)))
        wait(for: [taken], timeout: 2)

        mailbox.close()
        wait(for: [ended], timeout: 2)
        XCTAssertTrue(mailbox.isClosed)
        XCTAssertFalse(try mailbox.post(ticket(8)), "nothing is posted once closed")
        XCTAssertNil(mailbox.take())
    }

    func test_closingOnAPendingTicket_commitsItsCommandBuffer() throws {
        let mailbox = XRTicketMailbox()
        let pending = try ticket(1)
        XCTAssertTrue(mailbox.post(pending))
        XCTAssertEqual(pending.commandBuffer.status, .notEnqueued)

        mailbox.close()

        pending.commandBuffer.waitUntilCompleted()
        XCTAssertEqual(pending.commandBuffer.status, .completed, "RealityKit's bookkeeping of the replace calls completes")
    }
}

// MARK: - The unprojection kernel

/// The kernel against a reference of the test's own: a synthetic depth of two planes and a hole.
final class XRGridUnprojectTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    /// The depth the test draws: the left half a plane 2 m ahead, the right half one 5 m ahead,
    /// a disc in the middle that sees nothing (depth 0, the far plane).
    private static let nearPlaneDistance: Float = 2
    private static let farPlaneDistance: Float = 5
    private static let holeRadius: Float = 0.2

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    /// The reverse-Z depth of a point at `distance` straight ahead.
    private func depth(ofDistance distance: Float, projection: simd_float4x4) -> Float {
        let clip = projection * SIMD4<Float>(0, 0, -distance, 1)
        return clip.z / clip.w
    }

    /// A one-texel line over the synthetic depth: the texel column and the texel row at `depth`
    /// (reverse Z), either -1 for none.
    private struct Line {
        var column: Int32 = -1
        var row: Int32 = -1
        var depth: Float = 0
    }

    /// What the synthetic depth holds at a texel, without a line: the fragment shader's rule, at
    /// the texel's centre.
    private func syntheticDepth(texel: SIMD2<Int>, textureSize: SIMD2<Int>, projection: simd_float4x4) -> Float {
        let uv = (SIMD2<Float>(Float(texel.x), Float(texel.y)) + 0.5) / SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let centred = uv - SIMD2<Float>(0.5, 0.5)
        if simd_length(centred) < Self.holeRadius { return 0 }
        return depth(ofDistance: uv.x < 0.5 ? Self.nearPlaneDistance : Self.farPlaneDistance, projection: projection)
    }

    /// The fragment shader's `Depths`.
    private struct DepthsUniforms {
        var near: Float
        var far: Float
        var holeRadius: Float
        var line: Float
        var lineAt: SIMD2<Int32>
        var padding = SIMD2<Int32>(0, 0)
    }

    private var depthPipeline: (pipeline: MTLRenderPipelineState, depthStencil: MTLDepthStencilState)?

    /// The pass that draws the synthetic depth, a fragment shader writing the depth: made once
    /// per test.
    private func makeDepthPipeline() throws -> (pipeline: MTLRenderPipelineState, depthStencil: MTLDepthStencilState) {
        if let depthPipeline { return depthPipeline }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        struct Depths { float near; float far; float holeRadius; float line; int2 lineAt; int2 padding; };
        vertex V fullscreen(uint id [[vertex_id]]) {
            float2 ndc = float2((id == 2) ? 3.0f : -1.0f, (id == 1) ? 3.0f : -1.0f);
            V out; out.position = float4(ndc, 0, 1); out.uv = float2(ndc.x * 0.5f + 0.5f, 1.0f - (ndc.y * 0.5f + 0.5f));
            return out;
        }
        struct Out { float depth [[depth(any)]]; };
        fragment Out depths(V in [[stage_in]], constant Depths &d [[buffer(0)]]) {
            Out out;
            int2 texel = int2(in.position.xy);
            float2 centred = in.uv - 0.5f;
            if (texel.x == d.lineAt.x || texel.y == d.lineAt.y) { out.depth = d.line; }
            else if (length(centred) < d.holeRadius) { out.depth = 0.0f; }
            else { out.depth = in.uv.x < 0.5f ? d.near : d.far; }
            return out;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "depths")
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .always
        depthStencilDescriptor.isDepthWriteEnabled = true
        let depthStencil = try XCTUnwrap(device.makeDepthStencilState(descriptor: depthStencilDescriptor))
        depthPipeline = (pipeline, depthStencil)
        return (pipeline, depthStencil)
    }

    private func makeDepthTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Draws the synthetic depth, and `line` over it, into `texture`.
    private func drawDepth(into texture: MTLTexture, projection: simd_float4x4, line: Line = Line()) throws {
        let (pipeline, depthStencil) = try makeDepthPipeline()
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthStencil)
        var depths = DepthsUniforms(
            near: depth(ofDistance: Self.nearPlaneDistance, projection: projection),
            far: depth(ofDistance: Self.farPlaneDistance, projection: projection),
            holeRadius: Self.holeRadius,
            line: line.depth,
            lineAt: SIMD2<Int32>(line.column, line.row)
        )
        encoder.setFragmentBytes(&depths, length: MemoryLayout<DepthsUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The kernel's `eyePoint`, in Swift, of a texture position.
    private func referenceEyePoint(uv: SIMD2<Float>, depth: Float, inverseProjection: simd_float4x4, farShell: Float) -> SIMD3<Float> {
        referenceEyePoint(ndc: SIMD2<Float>(uv.x * 2 - 1, 1 - uv.y * 2), depth: depth, inverseProjection: inverseProjection, farShell: farShell)
    }

    /// The kernel's `eyePoint`, in Swift, of a ray.
    private func referenceEyePoint(ndc: SIMD2<Float>, depth: Float, inverseProjection: simd_float4x4, farShell: Float) -> SIMD3<Float> {
        let eye = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, max(depth, 1e-6), 1)
        var point = SIMD3<Float>(eye.x, eye.y, eye.z) / eye.w
        let distance = simd_length(point)
        if depth <= 0 || distance > farShell {
            point = point * (farShell / max(distance, 1e-6))
        }
        return point
    }

    /// A rasterization rate map the kernel works through, for the references: the grid's cell in
    /// physical texels, and the map's own mapping (Metal's, on the CPU) of a texel's centre to
    /// its place on the screen, as NDC.
    private struct ReferenceMap {
        let rateMap: MTLRasterizationRateMap
        let cellTexels: Float

        var screenSize: SIMD2<Float> {
            SIMD2<Float>(Float(rateMap.screenSize.width), Float(rateMap.screenSize.height))
        }

        func ndc(ofTexel texel: SIMD2<Float>) -> SIMD2<Float> {
            let screen = rateMap.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: texel.x + 0.5, y: texel.y + 0.5), layer: 0)
            let uv = SIMD2<Float>(screen.x, screen.y) / screenSize
            return SIMD2<Float>(uv.x * 2 - 1, 1 - uv.y * 2)
        }
    }

    /// Where the kernel centres a grid vertex, in texels: on the knots of the map's tiles when
    /// there is one, else spread over the texture's extent.
    private func referenceCentre(column: Int, row: Int, grid: XRPresenterGrid, textureSize: SIMD2<Int>, map: ReferenceMap?) -> SIMD2<Float> {
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        if let map {
            return simd_min(SIMD2<Float>(Float(column), Float(row)) * map.cellTexels, size - 1)
        }
        let cells = SIMD2<Float>(Float(grid.columns - 1), Float(grid.rows - 1))
        return SIMD2<Float>(Float(column), Float(row)) * (1 / cells) * (size - 1)
    }

    /// The kernel's ray of a texel, as NDC: through the map, or from its texture position.
    private func referenceNDC(ofTexel texel: SIMD2<Float>, textureSize: SIMD2<Int>, map: ReferenceMap?) -> SIMD2<Float> {
        if let map { return map.ndc(ofTexel: texel) }
        let uv = texel / SIMD2<Float>(Float(textureSize.x - 1), Float(textureSize.y - 1))
        return SIMD2<Float>(uv.x * 2 - 1, 1 - uv.y * 2)
    }

    /// The kernel's footprint of a grid vertex, in Swift: the texels of the cell about the vertex
    /// plus a margin of half a cell, `lo ... hi` on each axis, clamped to the texture.
    private func referenceFootprint(column: Int, row: Int, grid: XRPresenterGrid, textureSize: SIMD2<Int>, map: ReferenceMap? = nil) -> (lo: SIMD2<Int>, hi: SIMD2<Int>) {
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let cells = SIMD2<Float>(Float(grid.columns - 1), Float(grid.rows - 1))
        let halfCell = map.map { SIMD2<Float>(repeating: $0.cellTexels * 0.5) } ?? size / cells * 0.5
        let centre = referenceCentre(column: column, row: row, grid: grid, textureSize: textureSize, map: map)
        let margin = SIMD2<Int>(Int(ceil(halfCell.x - 1e-3)), Int(ceil(halfCell.y - 1e-3)))
        let lo = SIMD2<Int>(Int(ceil(centre.x - halfCell.x - 1e-3)) - margin.x, Int(ceil(centre.y - halfCell.y - 1e-3)) - margin.y)
        let hi = SIMD2<Int>(Int(floor(centre.x + halfCell.x + 1e-3)) + margin.x, Int(floor(centre.y + halfCell.y + 1e-3)) + margin.y)
        return (simd_max(lo, SIMD2<Int>(0, 0)), simd_min(hi, textureSize &- 1))
    }

    /// The kernel's first dispatch, in Swift, over the synthetic depth: the nearest depth over the
    /// footprint of a grid vertex, and the texel the vertex is placed on, the one nearest the
    /// vertex's centre among those on the near side of the footprint's depth jump (within the
    /// tear threshold of the nearest depth, in metres along the vertex's ray), with that texel's
    /// depth.
    private func referenceNearestDepth(column: Int, row: Int, grid: XRPresenterGrid, textureSize: SIMD2<Int>, projection: simd_float4x4, tearThreshold: Float, line: Line = Line(), skirtTexels: Float = 0, map: ReferenceMap? = nil, depthOfTexel: ((SIMD2<Int>) -> Float)? = nil) -> (depth: Float, texel: SIMD2<Float>, rim: Bool, placed: SIMD2<Float>) {
        let (lo, hi) = referenceFootprint(column: column, row: row, grid: grid, textureSize: textureSize, map: map)
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let centre = referenceCentre(column: column, row: row, grid: grid, textureSize: textureSize, map: map)
        func depthAt(_ x: Int, _ y: Int) -> Float {
            if let depthOfTexel { return depthOfTexel(SIMD2<Int>(x, y)) }
            if Int32(x) == line.column || Int32(y) == line.row { return line.depth }
            return syntheticDepth(texel: SIMD2<Int>(x, y), textureSize: textureSize, projection: projection)
        }
        var nearest: Float = 0
        for y in lo.y ... hi.y {
            for x in lo.x ... hi.x {
                nearest = max(nearest, depthAt(x, y))
            }
        }
        let ndc = referenceNDC(ofTexel: centre, textureSize: textureSize, map: map)
        let inverseProjection = simd_inverse(projection)
        let a = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
        let b = inverseProjection * SIMD4<Float>(0, 0, 1, 0)
        func zInFront(_ d: Float) -> Float {
            let dd = max(d, 1e-6)
            return -(a.z + dd * b.z) / (a.w + dd * b.w)
        }
        let nearSideLimit = zInFront(nearest) + tearThreshold
        var chosen = nearest
        var texel = centre
        var chosenDistance = Float.greatestFiniteMagnitude
        for y in lo.y ... hi.y {
            for x in lo.x ... hi.x {
                let d = depthAt(x, y)
                if zInFront(d) >= nearSideLimit { continue }
                let t = SIMD2<Float>(Float(x), Float(y))
                let distance = simd_length_squared(t - centre)
                if distance < chosenDistance {
                    chosen = d
                    texel = t
                    chosenDistance = distance
                }
            }
        }
        // The rim flag: the texel under the vertex's own centre lies off the near surface. The
        // placed texel: the skirt past the edge texel, toward the centre, for a rim vertex.
        let centreTexel = simd_clamp(centre.rounded(.toNearestOrEven), SIMD2<Float>(0, 0), size - 1)
        let rim = zInFront(depthAt(Int(centreTexel.x), Int(centreTexel.y))) >= nearSideLimit
        var placed = texel
        if rim, skirtTexels > 0 {
            let away = centre - texel
            let length = simd_length(away)
            if length > 1e-3 {
                placed = simd_clamp(texel + away * (skirtTexels / length), SIMD2<Float>(0, 0), size - 1)
            }
        }
        return (chosen, texel, rim, placed)
    }

    /// The uv the kernel writes for a texel: v = 0 at the top row; the texel's centre over the
    /// size through a map, the texel over the extent otherwise.
    private func uvOfTexel(_ texel: SIMD2<Float>, textureSize: SIMD2<Int>, map: ReferenceMap? = nil) -> SIMD2<Float> {
        if map != nil {
            return (texel + 0.5) / SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        }
        return texel / SIMD2<Float>(Float(textureSize.x - 1), Float(textureSize.y - 1))
    }

    private struct Vertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
        /// The tear mask's x: the far side of a depth jump.
        var mask: Float
        /// The tear mask's y: the near side.
        var nearSide: Float
        /// The projective uv: (u, v) times the eye-space depth, that depth, 0.
        var uvw: SIMD4<Float>
    }

    /// The texture position of a grid vertex of the 33 × 25 grid the kernel test uses.
    private func uvOf(column: Int, row: Int) -> SIMD2<Float> {
        SIMD2<Float>(Float(column) / 32, Float(row) / 24)
    }

    private func readVertices(_ buffer: MTLBuffer, grid: XRPresenterGrid) -> [Vertex] {
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        return (0 ..< grid.vertexCount).map { index in
            let base = index * XRPresenterGrid.vertexStride
            let position = SIMD3<Float>(
                raw.load(fromByteOffset: base, as: Float.self),
                raw.load(fromByteOffset: base + 4, as: Float.self),
                raw.load(fromByteOffset: base + 8, as: Float.self)
            )
            let uv = SIMD2<Float>(
                raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset, as: Float.self),
                raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset + 4, as: Float.self)
            )
            let mask = Float(raw.load(fromByteOffset: base + XRPresenterGrid.maskOffset, as: Float16.self))
            let nearSide = Float(raw.load(fromByteOffset: base + XRPresenterGrid.maskOffset + 2, as: Float16.self))
            let uvw = SIMD4<Float>(
                raw.load(fromByteOffset: base + XRPresenterGrid.uvwOffset, as: Float.self),
                raw.load(fromByteOffset: base + XRPresenterGrid.uvwOffset + 4, as: Float.self),
                raw.load(fromByteOffset: base + XRPresenterGrid.uvwOffset + 8, as: Float.self),
                raw.load(fromByteOffset: base + XRPresenterGrid.uvwOffset + 12, as: Float.self)
            )
            return Vertex(position: position, uv: uv, mask: mask, nearSide: nearSide, uvw: uvw)
        }
    }

    private func readNearestDepths(_ buffer: MTLBuffer, grid: XRPresenterGrid) -> [(depth: Float, texel: SIMD2<Float>, rim: Bool)] {
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        return (0 ..< grid.vertexCount).map {
            let entry = raw.load(fromByteOffset: $0 * MemoryLayout<SIMD4<Float>>.stride, as: SIMD4<Float>.self)
            return (entry.x, SIMD2<Float>(entry.y, entry.z), entry.w > 0.5)
        }
    }

    /// The scratch buffer of the two dispatches, readable by the test.
    private func makeNearestDepthBuffer(grid: XRPresenterGrid) throws -> MTLBuffer {
        try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
    }

    func test_theKernel_placesTheVertices_asTheReferenceDoes() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        // The jumps here are 3 m (the seam) and 45 m (the hole). The threshold stays above the
        // distance a diagonal step covers on the oblique far plane at this coarse grid's corner
        // (0.56 m), which is no tear, and under the 1 m between the line of the next test and
        // the near plane.
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let nearestDepths = try makeNearestDepthBuffer(grid: grid)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        // The eye one metre up and half a metre to the right of the origin, looking straight ahead.
        let originFromEye = matrix4x4Translation(0.5, 1, 0)

        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, nearestDepths: nearestDepths, vertices: vertices, grid: grid, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let result = readVertices(vertices, grid: grid)
        let nearest = readNearestDepths(nearestDepths, grid: grid)
        let inverseProjection = simd_inverse(projection)
        // The projective uv of every vertex: its uv times its own eye-space depth, which is the
        // depth of its position seen from the eye (affine in the point, so RealityKit's
        // interpolation reproduces the engine's projection across each triangle).
        let eyeFromOrigin = simd_inverse(originFromEye)
        for vertex in result {
            let eyeSpace = simd_mul(eyeFromOrigin, SIMD4<Float>(vertex.position, 1))
            XCTAssertEqual(vertex.uvw.z, -eyeSpace.z, accuracy: 1e-3 * max(1, -eyeSpace.z), "the projective uv's depth is the vertex's eye-space depth")
            XCTAssertEqual(vertex.uvw.x, vertex.uv.x * vertex.uvw.z, accuracy: 1e-4 * max(1, vertex.uvw.z), "u times the depth")
            XCTAssertEqual(vertex.uvw.y, vertex.uv.y * vertex.uvw.z, accuracy: 1e-4 * max(1, vertex.uvw.z), "v times the depth")
            XCTAssertEqual(vertex.uvw.w, 0)
        }
        let nearDepth = depth(ofDistance: Self.nearPlaneDistance, projection: projection)
        let farDepth = depth(ofDistance: Self.farPlaneDistance, projection: projection)
        var nearPlane = 0, farPlane = 0, shell = 0, tears = 0, rims = 0
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                let uv = SIMD2<Float>(Float(column) / Float(grid.columns - 1), Float(row) / Float(grid.rows - 1))
                let vertex = result[row * grid.columns + column]

                let (sampled, texel, rim, placed) = referenceNearestDepth(column: column, row: row, grid: grid, textureSize: textureSize, projection: projection, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels)
                let entry = nearest[row * grid.columns + column]
                XCTAssertEqual(entry.depth, sampled, accuracy: 1e-6, "the first dispatch's nearest depth of vertex \(column),\(row)")
                XCTAssertEqual(entry.texel, texel, "the texel the nearest depth of vertex \(column),\(row) was read at")
                XCTAssertEqual(entry.rim, rim, "the rim flag of vertex \(column),\(row)")
                if rim { rims += 1 }
                // The vertex sits on that texel, or on the skirt past it for a rim vertex: its uv is
                // the placed texel's (v = 0 at the top row, unflipped), within its footprint.
                let texelUV = uvOfTexel(placed, textureSize: textureSize)
                XCTAssertEqual(vertex.uv.x, texelUV.x, accuracy: 1e-5, "u of vertex \(column),\(row)")
                XCTAssertEqual(vertex.uv.y, texelUV.y, accuracy: 1e-5, "v of vertex \(column),\(row)")
                let reachUV = SIMD2<Float>(1 / Float(grid.columns - 1), 1 / Float(grid.rows - 1)) + (1.5 + configuration.skirtTexels) / SIMD2<Float>(Float(textureSize.x - 1), Float(textureSize.y - 1))
                XCTAssertLessThanOrEqual(abs(vertex.uv.x - uv.x), reachUV.x, "vertex \(column),\(row) stays within its footprint")
                XCTAssertLessThanOrEqual(abs(vertex.uv.y - uv.y), reachUV.y, "vertex \(column),\(row) stays within its footprint")
                let eye = referenceEyePoint(uv: texelUV, depth: sampled, inverseProjection: inverseProjection, farShell: configuration.farShellMetres)
                let expected = originFromEye * SIMD4<Float>(eye, 1)
                let tolerance: Float = sampled <= 0 ? 0.05 : 0.01
                XCTAssertEqual(vertex.position.x, expected.x, accuracy: tolerance, "x of vertex \(column),\(row)")
                XCTAssertEqual(vertex.position.y, expected.y, accuracy: tolerance, "y of vertex \(column),\(row)")
                XCTAssertEqual(vertex.position.z, expected.z, accuracy: tolerance, "z of vertex \(column),\(row)")

                // Where the vertex lies, in the eye's own terms: the plane its footprint's nearest
                // depth belongs to, or the shell.
                let eyeDistance = simd_length(eye)
                if sampled <= 0 {
                    shell += 1
                    XCTAssertEqual(eyeDistance, configuration.farShellMetres, accuracy: 0.01, "a vertex that sees nothing lies on the shell")
                } else if abs(sampled - nearDepth) < 1e-6 {
                    nearPlane += 1
                    XCTAssertEqual(-eye.z, Self.nearPlaneDistance, accuracy: 0.01, "the near plane, two metres ahead")
                    XCTAssertLessThanOrEqual(uv.x, 0.5, "the near plane is the left half, to the seam")
                } else {
                    farPlane += 1
                    XCTAssertEqual(sampled, farDepth, accuracy: 1e-6)
                    XCTAssertEqual(-eye.z, Self.farPlaneDistance, accuracy: 0.02, "the far plane, five metres ahead")
                    XCTAssertGreaterThan(uv.x, 0.5, "the far plane is the right half")
                }
                if vertex.mask > 0.5 { tears += 1 }
            }
        }
        XCTAssertGreaterThan(nearPlane, 200)
        XCTAssertGreaterThan(farPlane, 200)
        XCTAssertGreaterThan(shell, 20, "the hole sees the shell")
        XCTAssertGreaterThan(rims, 10, "the vertices just off the planes' seam and around the hole are rim vertices")
        // The far-side mask on the far side of the two planes' seam and on the shell around the
        // hole, the near-side mask across from it, nothing inside the planes.
        XCTAssertGreaterThan(tears, 20)
        XCTAssertLessThan(tears, grid.vertexCount / 4)
        let insideNearPlane = result[12 * grid.columns + 3]
        XCTAssertEqual(insideNearPlane.mask, 0, "no tear inside a plane")
        XCTAssertEqual(insideNearPlane.nearSide, 0)
        let onTheSeam = result[2 * grid.columns + 16]
        let pastTheSeam = result[2 * grid.columns + 17]
        XCTAssertEqual(onTheSeam.mask, 0, "the near plane's side of the seam is not the far side")
        XCTAssertEqual(onTheSeam.nearSide, 1, "the near plane's side of the seam is the near side")
        XCTAssertEqual(pastTheSeam.mask, 1, "the far plane's side of the seam is the far side")
        XCTAssertEqual(pastTheSeam.nearSide, 0)
        XCTAssertEqual(result[2 * grid.columns + 18].mask, 0, "one column further the far plane is flat again")
        XCTAssertEqual(result[2 * grid.columns + 15].nearSide, 0, "one column before the seam the near plane is flat")
        // The seam column's footprint straddles both planes: the nearer one wins, so that a
        // near silhouette is kept whole.
        XCTAssertEqual(onTheSeam.position.z, -Self.nearPlaneDistance, accuracy: 0.01, "the seam column lies on the near plane")
        XCTAssertEqual(pastTheSeam.position.z, -Self.farPlaneDistance, accuracy: 0.02, "the column past the seam lies on the far plane")
        // The hole: the plane's vertices at its rim stay at 0, the shell's vertices inside are
        // marked, and a vertex at the hole's centre, with shell all around it, is not.
        let centre = result[12 * grid.columns + 16]
        XCTAssertEqual(simd_length(SIMD3<Float>(centre.position.x - 0.5, centre.position.y - 1, centre.position.z)), configuration.farShellMetres, accuracy: 0.05, "the hole's centre lies on the shell")
        for (column, row) in [(16, 12), (16, 11), (16, 13), (15, 12), (17, 12)] {
            XCTAssertEqual(result[row * grid.columns + column].mask, 0, "no tear around the hole's centre (\(column),\(row))")
            XCTAssertEqual(result[row * grid.columns + column].nearSide, 0, "no tear around the hole's centre (\(column),\(row))")
        }
        // Every far-side mark is either on the shell (the hole's rim, seen from inside) or in
        // the far plane's column past the seam; every near-side mark is on a plane, at the
        // hole's rim or in the near plane's seam column; the shell never carries a near-side mark.
        var farSideOnTheShell = 0, farSidePastTheSeam = 0, nearSideAtTheHole = 0, nearSideAtTheSeam = 0
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                let vertex = result[row * grid.columns + column]
                let eyeDistance = simd_length(SIMD3<Float>(vertex.position.x - 0.5, vertex.position.y - 1, vertex.position.z))
                let onTheShell = eyeDistance > configuration.farShellMetres - 0.1
                if vertex.mask > 0.5 {
                    if onTheShell {
                        farSideOnTheShell += 1
                    } else {
                        farSidePastTheSeam += 1
                        XCTAssertEqual(column, 17, "a far-side mark off the shell is the far plane's side of the seam (\(column),\(row))")
                    }
                }
                if vertex.nearSide > 0.5 {
                    XCTAssertFalse(onTheShell, "the shell is never the near side (\(column),\(row))")
                    if column == 16, abs(uvOf(column: column, row: row).y - 0.5) > Self.holeRadius + 0.1 {
                        nearSideAtTheSeam += 1
                    } else {
                        nearSideAtTheHole += 1
                        XCTAssertLessThan(simd_length(uvOf(column: column, row: row) - SIMD2<Float>(0.5, 0.5)), Self.holeRadius + 0.1, "a near-side mark off the seam is at the hole's rim (\(column),\(row))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(farSideOnTheShell, 10, "the shell's vertices along the hole's rim are the far side")
        XCTAssertGreaterThan(farSidePastTheSeam, 10, "the far plane's column past the seam is the far side")
        XCTAssertEqual(farSideOnTheShell + farSidePastTheSeam, tears)
        XCTAssertGreaterThan(nearSideAtTheHole, 10, "the planes' vertices along the hole's rim are the near side")
        XCTAssertGreaterThanOrEqual(nearSideAtTheSeam, 10, "the near plane's seam column is the near side: its ten rows away from the hole")
    }

    /// A one-texel feature between two grid vertices is caught by one of them. By the rule: the
    /// footprints along a row take in every texel column and neighbouring ones overlap, and the
    /// same down a column. By the kernel: a one-texel line at each texel column and each texel
    /// row of the texture, nearer than anything else, pulls one of the two vertices it lies
    /// between onto its depth, and the first dispatch reads it at exactly the vertices whose
    /// footprint holds the line's column or row.
    func test_aOneTexelFeature_betweenTwoGridVertices_isCaughtByOneOfThem() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection

        var columnCovered = [Bool](repeating: false, count: textureSize.x)
        var previous: (lo: SIMD2<Int>, hi: SIMD2<Int>)?
        for column in 0 ..< grid.columns {
            let footprint = referenceFootprint(column: column, row: 0, grid: grid, textureSize: textureSize)
            for x in footprint.lo.x ... footprint.hi.x { columnCovered[x] = true }
            if let previous { XCTAssertLessThanOrEqual(footprint.lo.x, previous.hi.x, "the footprints of columns \(column - 1) and \(column) overlap") }
            previous = footprint
        }
        XCTAssertFalse(columnCovered.contains(false), "every texel column is in some vertex's footprint")
        var rowCovered = [Bool](repeating: false, count: textureSize.y)
        previous = nil
        for row in 0 ..< grid.rows {
            let footprint = referenceFootprint(column: 0, row: row, grid: grid, textureSize: textureSize)
            for y in footprint.lo.y ... footprint.hi.y { rowCovered[y] = true }
            if let previous { XCTAssertLessThanOrEqual(footprint.lo.y, previous.hi.y, "the footprints of rows \(row - 1) and \(row) overlap") }
            previous = footprint
        }
        XCTAssertFalse(rowCovered.contains(false), "every texel row is in some vertex's footprint")

        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        let nearestDepths = try makeNearestDepthBuffer(grid: grid)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let pass = try XRGridUnprojectPass(device: device)
        let lineDistance: Float = 1
        let lineDepth = depth(ofDistance: lineDistance, projection: projection)
        // Without a line, the reference per vertex; with one, a vertex reads the line's depth
        // (the largest there is) exactly when its footprint holds the line's column or row.
        let footprints = (0 ..< grid.vertexCount).map { referenceFootprint(column: $0 % grid.columns, row: $0 / grid.columns, grid: grid, textureSize: textureSize) }
        let withoutALine = (0 ..< grid.vertexCount).map { referenceNearestDepth(column: $0 % grid.columns, row: $0 / grid.columns, grid: grid, textureSize: textureSize, projection: projection, tearThreshold: configuration.tearThresholdMetres).depth }
        // The skirt would move a vertex that caught the line off it; this test places vertices on the line.
        func vertexBefore(texel: Int, vertices: Int, texels: Int) -> Int {
            // The vertex at or before the texel along an axis: the line lies between it and the next.
            min(vertices - 2, Int(Float(texel) * Float(vertices - 1) / Float(texels - 1)))
        }
        for texel in 0 ..< max(textureSize.x, textureSize.y) {
            let line = Line(column: texel < textureSize.x ? Int32(texel) : -1, row: texel < textureSize.y ? Int32(texel) : -1, depth: lineDepth)
            try drawDepth(into: depthTexture, projection: projection, line: line)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, nearestDepths: nearestDepths, vertices: vertices, grid: grid, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let nearest = readNearestDepths(nearestDepths, grid: grid)
            let result = readVertices(vertices, grid: grid)

            for index in 0 ..< grid.vertexCount {
                let footprint = footprints[index]
                let holdsTheLine = (footprint.lo.x ... footprint.hi.x).contains(Int(line.column)) || (footprint.lo.y ... footprint.hi.y).contains(Int(line.row))
                let expected = holdsTheLine ? lineDepth : withoutALine[index]
                XCTAssertEqual(nearest[index].depth, expected, accuracy: 1e-6, "line at texel \(texel): the depth of vertex \(index % grid.columns),\(index / grid.columns)")
            }
            // The vertical line, checked on a grid row whose footprint the horizontal line misses.
            if line.column >= 0 {
                let row = texel < textureSize.y / 2 ? grid.rows - 4 : 3
                let before = vertexBefore(texel: texel, vertices: grid.columns, texels: textureSize.x)
                let caught = [before, before + 1].first { abs(nearest[row * grid.columns + $0].depth - lineDepth) < 1e-6 }
                XCTAssertNotNil(caught, "the one-texel column \(texel) lies between vertices \(before) and \(before + 1) of row \(row): one of them catches it")
                if let caught {
                    XCTAssertEqual(-result[row * grid.columns + caught].position.z, lineDistance, accuracy: 0.01, "the vertex that caught column \(texel) is placed on the line")
                }
            }
            // The horizontal line, checked on a grid column whose footprint the vertical line misses.
            if line.row >= 0 {
                let column = texel < textureSize.x / 2 ? grid.columns - 4 : 3
                let before = vertexBefore(texel: texel, vertices: grid.rows, texels: textureSize.y)
                let caught = [before, before + 1].first { abs(nearest[$0 * grid.columns + column].depth - lineDepth) < 1e-6 }
                XCTAssertNotNil(caught, "the one-texel row \(texel) lies between vertices \(before) and \(before + 1) of column \(column): one of them catches it")
                if let caught {
                    XCTAssertEqual(-result[caught * grid.columns + column].position.z, lineDistance, accuracy: 0.01, "the vertex that caught row \(texel) is placed on the line")
                }
            }
        }
    }

    /// Every cell is split along the fixed diagonal (top-right to bottom-left) unless that one
    /// crosses a depth jump and the other does not: on the two planes and the hole, each cell
    /// of the index buffer holds either the fixed pair of triangles or the other, by that rule
    /// on the first dispatch's depths read along the cell's own ray; both pairs are wound
    /// counter-clockwise; and the cells of the hole's rim use both splits.
    func test_eachCell_isSplitAlongTheDiagonalNearerInDepth() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let nearestDepths = try makeNearestDepthBuffer(grid: grid)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let indices = try XCTUnwrap(device.makeBuffer(length: grid.indexCount * MemoryLayout<UInt32>.stride, options: .storageModeShared))

        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, nearestDepths: nearestDepths, vertices: vertices, indices: indices, grid: grid, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let entries = readNearestDepths(nearestDepths, grid: grid)
        let raw = UnsafeRawBufferPointer(start: indices.contents(), count: indices.length)
        let written = (0 ..< grid.indexCount).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self) }
        let inverseProjection = simd_inverse(projection)
        var fixedSplits = 0, otherSplits = 0, rimFixed = 0, rimOther = 0
        for row in 0 ..< grid.rows - 1 {
            for column in 0 ..< grid.columns - 1 {
                let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                let centreUV = SIMD2<Float>((Float(column) + 0.5) / Float(grid.columns - 1), (Float(row) + 0.5) / Float(grid.rows - 1))
                let ndc = SIMD2<Float>(centreUV.x * 2 - 1, 1 - centreUV.y * 2)
                let ra = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
                let rb = inverseProjection * SIMD4<Float>(0, 0, 1, 0)
                func z(_ index: UInt32) -> Float {
                    let dd = max(entries[Int(index)].depth, 1e-6)
                    return -(ra.z + dd * rb.z) / (ra.w + dd * rb.w)
                }
                let threshold = configuration.tearThresholdMetres
                let other = abs(z(b) - z(c)) > threshold && abs(z(a) - z(d)) <= threshold
                let cell = (row * (grid.columns - 1) + column) * 6
                let triangles = Array(written[cell ..< cell + 6])
                let expected: [UInt32] = other ? [a, c, d, a, d, b] : [a, c, b, b, c, d]
                XCTAssertEqual(triangles, expected, "cell \(column),\(row) is split along the diagonal nearer in depth")
                if other { otherSplits += 1 } else { fixedSplits += 1 }
                // The hole's rim: cells whose centre lies within a cell of the hole's edge.
                let fromHole = simd_length(centreUV - SIMD2<Float>(0.5, 0.5))
                if abs(fromHole - Self.holeRadius) < 0.04 {
                    if other { rimOther += 1 } else { rimFixed += 1 }
                }
            }
        }
        XCTAssertGreaterThan(fixedSplits, 500, "most cells lie inside a plane or the shell and keep the fixed split")
        XCTAssertGreaterThan(otherSplits, 5, "some cells of the rim need the other diagonal")
        XCTAssertGreaterThan(rimOther, 2, "the rim uses the other split where the edge runs corner to corner that way")
        XCTAssertGreaterThan(rimFixed, 2, "and the fixed split where it runs the other way")
        func signedArea(_ p: UInt32, _ q: UInt32, _ r: UInt32) -> Float {
            func at(_ i: UInt32) -> SIMD2<Float> { SIMD2<Float>(Float(Int(i) % grid.columns), -Float(Int(i) / grid.columns)) }
            let u = at(q) - at(p), v = at(r) - at(p)
            return u.x * v.y - u.y * v.x
        }
        for cell in stride(from: 0, to: grid.indexCount, by: 3) {
            XCTAssertGreaterThan(signedArea(written[cell], written[cell + 1], written[cell + 2]), 0, "triangle at index \(cell) is counter-clockwise")
        }
    }

    func test_theUniforms_haveTheKernelsLayout() {
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.stride, 176)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.inverseProjection), 64)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.gridSize), 128)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.textureSize), 136)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.farShell), 144)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.flags), 152)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.skirtTexels), 156)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.screenSize), 160)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.cellTexels), 168)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.foveated), 172)
        let uniform = XRGridUnprojectUniforms(originFromEye: matrix_identity_float4x4, inverseProjection: matrix_identity_float4x4, gridSize: [2, 2], textureSize: [8, 8], farShell: 1, tearThreshold: 1)
        XCTAssertEqual(uniform.foveated, 0, "no map by default")
        XCTAssertEqual(uniform.cellTexels, 0)
    }

    // MARK: - Through a rasterization rate map

    /// The presenter's map for `configuration`, or a skip where the GPU has none.
    private func makeFoveation(_ configuration: XRRealityKitPresenterConfiguration) throws -> XRPresenterFoveation {
        guard device.supportsRasterizationRateMap(layerCount: 1) else {
            throw XCTSkip("this GPU has no rasterization rate maps")
        }
        return try XCTUnwrap(XRPresenterFoveation.make(device: device, configuration: configuration), "the device makes the presenter's map")
    }

    private var depthCopyPipeline: (pipeline: MTLRenderPipelineState, depthStencil: MTLDepthStencilState)?

    /// A pass that writes a texture of depths, one per texel, into a depth texture: made once
    /// per test.
    private func makeDepthCopyPipeline() throws -> (pipeline: MTLRenderPipelineState, depthStencil: MTLDepthStencilState) {
        if let depthCopyPipeline { return depthCopyPipeline }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; };
        vertex V fullscreen(uint id [[vertex_id]]) {
            V out; out.position = float4((id == 2) ? 3.0f : -1.0f, (id == 1) ? 3.0f : -1.0f, 0, 1);
            return out;
        }
        struct Out { float depth [[depth(any)]]; };
        fragment Out copyDepth(V in [[stage_in]], texture2d<float, access::read> depths [[texture(0)]]) {
            Out out; out.depth = depths.read(uint2(in.position.xy)).x;
            return out;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "copyDepth")
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .always
        depthStencilDescriptor.isDepthWriteEnabled = true
        let depthStencil = try XCTUnwrap(device.makeDepthStencilState(descriptor: depthStencilDescriptor))
        depthCopyPipeline = (pipeline, depthStencil)
        return (pipeline, depthStencil)
    }

    /// Draws `depths`, one per texel row by row, into `texture`.
    private func drawDepths(_ depths: [Float], into texture: MTLTexture) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        depths.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: texture.width * MemoryLayout<Float>.stride)
        }
        let (pipeline, depthStencil) = try makeDepthCopyPipeline()
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthStencil)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The equi-angular profile: 1 at the centre of view, 1 / (1 + x²) at a tangent of x,
    /// symmetric, the same number of samples whatever the tangents.
    func test_theEquiAngularProfile_isOneAtTheCentre_andFallsWithTheTangent() {
        let rates = XRPresenterFoveation.rates(of: .equiAngular, from: 1.3, to: 1.3, samples: 64)
        XCTAssertEqual(rates.count, 64)
        XCTAssertEqual(rates[31], rates[32], accuracy: 1e-6, "symmetric about the centre")
        XCTAssertGreaterThan(rates[31], 0.999, "1 at the centre of view")
        let edgeTangent: Float = -1.3 + 0.5 / 64 * 2.6
        XCTAssertEqual(rates[0], 1 / (1 + edgeTangent * edgeTangent), accuracy: 1e-6, "the edge sample's rate is the profile at its centre")
        XCTAssertEqual(rates[0], rates[63], accuracy: 1e-6)
        XCTAssertTrue(zip(rates[0 ..< 31], rates[1 ..< 32]).allSatisfy { $0 < $1 }, "rising to the centre")
        let asymmetric = XRPresenterFoveation.rates(of: .equiAngular, from: 1.15, to: 1.30, samples: 64)
        XCTAssertGreaterThan(asymmetric[0], asymmetric[63], "the nearer edge is drawn denser")
        XCTAssertEqual(XRPresenterFoveation.rates(of: .none, from: 1.3, to: 1.3, samples: 4), [1, 1, 1, 1])
        XCTAssertEqual(XRPresenterFoveation.vertexCount(over: 1920, cell: 8), 241)
        XCTAssertEqual(XRPresenterFoveation.vertexCount(over: 1823, cell: 8), 229, "a vertex on the last texel when the cells do not divide")
    }

    /// The shipped profile at the shipped budget: the physical size never exceeds the budget
    /// (Metal rounds rates up; a profile edit can never silently cost GPU), the centre of view
    /// is denser, the cell divides the map's tile, the map's edges are the screen's, and the
    /// grid's linear interpolation of the map between two vertices meets the map at the cell's
    /// midpoint, since the mapping changes slope only at the tile boundaries the vertices sit on.
    func test_theShippedMap_fitsTheBudget_andTheGridInterpolatesItWithinACell() throws {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.foveation = .equiAngular
        let foveation = try makeFoveation(configuration)
        let budget = configuration.textureSize
        let physical = foveation.physicalSize
        let screen = foveation.screenSize
        print("XR presenter rate map on this Mac: \(foveation)")

        XCTAssertEqual(foveation.budget, budget)
        XCTAssertLessThanOrEqual(physical.x, budget.x, "the physical width is within the budget")
        XCTAssertLessThanOrEqual(physical.y, budget.y, "the physical height is within the budget")
        XCTAssertLessThanOrEqual(physical.x * physical.y, Int(1.05 * Double(budget.x * budget.y)), "no more pixels than the uniform frame")
        XCTAssertGreaterThan(physical.x * physical.y, Int(0.9 * Double(budget.x * budget.y)), "and nearly all of them")
        XCTAssertGreaterThanOrEqual(foveation.screenScale.x, 1.25, "the centre of view is denser than the uniform frame: \(foveation.screenScale)")
        XCTAssertGreaterThanOrEqual(foveation.screenScale.y, 1.2)
        XCTAssertEqual(foveation.granularity.x % foveation.cellTexels, 0, "the cell divides the tile")
        XCTAssertEqual(foveation.granularity.y % foveation.cellTexels, 0)
        XCTAssertEqual(foveation.cellTexels, configuration.foveatedCellTexels)
        XCTAssertEqual(foveation.grid.columns, (physical.x + foveation.cellTexels - 1) / foveation.cellTexels + 1)
        XCTAssertEqual(foveation.grid.rows, (physical.y + foveation.cellTexels - 1) / foveation.cellTexels + 1)
        XCTAssertEqual(foveation.frame.viewport.width, Double(screen.x), "the eyes' viewport is the map's screen")
        XCTAssertEqual(foveation.frame.viewport.height, Double(screen.y))
        XCTAssertEqual(foveation.rateMapData.screenSize, SIMD2<Float>(Float(screen.x), Float(screen.y)))
        XCTAssertEqual(foveation.rateMapData.physicalSize, SIMD2<Float>(Float(physical.x), Float(physical.y)))
        XCTAssertTrue(foveation.rateMap.screenSize.width == screen.x && foveation.rateMap.physicalSize(layer: 0).width == physical.x)

        let rateMap = foveation.rateMap
        func screenOf(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let point = rateMap.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: x, y: y), layer: 0)
            return SIMD2<Float>(point.x, point.y)
        }
        let origin = screenOf(0, 0)
        let farCorner = screenOf(Float(physical.x), Float(physical.y))
        XCTAssertEqual(origin.x, 0, accuracy: 0.05, "the map's origin is the screen's")
        XCTAssertEqual(origin.y, 0, accuracy: 0.05)
        XCTAssertEqual(farCorner.x, Float(screen.x), accuracy: 0.05, "the map's far corner is the screen's")
        XCTAssertEqual(farCorner.y, Float(screen.y), accuracy: 0.05)
        // The centre of view is drawn at the full rate: a texel there is a screen pixel.
        let centre = screenOf(Float(physical.x / 2) + 0.5, Float(physical.y / 2) + 0.5)
        let next = screenOf(Float(physical.x / 2) + 1.5, Float(physical.y / 2) + 1.5)
        XCTAssertEqual(next.x - centre.x, 1, accuracy: 0.02, "one screen pixel per texel at the centre of view")
        XCTAssertEqual(next.y - centre.y, 1, accuracy: 0.02)
        let edge = screenOf(0.5, Float(physical.y / 2) + 0.5)
        let nextEdge = screenOf(1.5, Float(physical.y / 2) + 0.5)
        XCTAssertGreaterThan(nextEdge.x - edge.x, 2, "a texel at the edge covers more than two screen pixels")

        // Between two vertices of a row or a column, the map at the cell's midpoint against the
        // mean of the map at the vertices.
        let cell = Float(foveation.cellTexels)
        var worst: Float = 0
        for row in [0, physical.y / 3, physical.y / 2, physical.y - 1] {
            let y = Float(row) + 0.5
            var x: Float = 0
            while x + cell <= Float(physical.x - 1) {
                let interpolated = (screenOf(x + 0.5, y).x + screenOf(x + cell + 0.5, y).x) / 2
                worst = max(worst, abs(interpolated - screenOf(x + cell / 2 + 0.5, y).x))
                x += cell
            }
        }
        for column in [0, physical.x / 3, physical.x / 2, physical.x - 1] {
            let x = Float(column) + 0.5
            var y: Float = 0
            while y + cell <= Float(physical.y - 1) {
                let interpolated = (screenOf(x, y + 0.5).y + screenOf(x, y + cell + 0.5).y) / 2
                worst = max(worst, abs(interpolated - screenOf(x, y + cell / 2 + 0.5).y))
                y += cell
            }
        }
        print("XR presenter rate map: the grid's worst interpolation error at a cell's midpoint is \(worst) screen px")
        XCTAssertLessThan(worst, 0.3, "the grid interpolates the map within a cell to under a third of a screen pixel")
    }

    /// Through a map, every vertex lies on the ray Metal's own mapping gives its texel, at the
    /// depth drawn there: the depth of a plane tilted in eye space, computed per texel through
    /// that mapping on the CPU and drawn into the physical texture; the kernel, reading the map
    /// through its decoder on the GPU, must put every vertex back on the plane, to a tenth of a
    /// millimetre, with the uv of the texel's centre.
    func test_withARateMap_theVerticesLieOnTheMapsRays_atTheTiltedPlanesDepth() throws {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [256, 192]
        configuration.foveation = .equiAngular
        configuration.farShellMetres = 50
        // The plane is continuous, so no cell may read as a tear; at the periphery it is seen
        // at a grazing angle and a cell there spans the most depth, under a metre.
        configuration.tearThresholdMetres = 3
        configuration.skirtTexels = 0
        let foveation = try makeFoveation(configuration)
        let grid = foveation.grid
        let textureSize = foveation.physicalSize
        XCTAssertLessThanOrEqual(textureSize.x, 256)
        XCTAssertLessThanOrEqual(textureSize.y, 192)
        XCTAssertGreaterThan(foveation.screenSize.x, textureSize.x, "the screen is larger than the texture")
        let map = ReferenceMap(rateMap: foveation.rateMap, cellTexels: Float(foveation.cellTexels))
        let projection = configuration.projection
        let inverseProjection = simd_inverse(projection)

        // The plane: through (0, 0, -3) in eye space, tilted both ways. The depth at a texel is
        // where the texel's ray, through the map, meets it.
        let normal = simd_normalize(SIMD3<Float>(0.2, -0.12, 1))
        let planeOffset = simd_dot(normal, SIMD3<Float>(0, 0, -3))
        func depthOfTexel(_ texel: SIMD2<Int>) -> Float {
            let ndc = map.ndc(ofTexel: SIMD2<Float>(Float(texel.x), Float(texel.y)))
            let onNearPlane = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
            let direction = SIMD3<Float>(onNearPlane.x, onNearPlane.y, onNearPlane.z) / onNearPlane.w
            let point = direction * (planeOffset / simd_dot(normal, direction))
            let clip = projection * SIMD4<Float>(point, 1)
            return clip.z / clip.w
        }
        var depths = [Float](repeating: 0, count: textureSize.x * textureSize.y)
        for y in 0 ..< textureSize.y {
            for x in 0 ..< textureSize.x {
                depths[y * textureSize.x + x] = depthOfTexel(SIMD2<Int>(x, y))
            }
        }
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepths(depths, into: depthTexture)

        let nearestDepths = try makeNearestDepthBuffer(grid: grid)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let originFromEye = matrix4x4Translation(0.5, 1, 0)
        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, nearestDepths: nearestDepths, vertices: vertices, grid: grid, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: 0, rateMapData: foveation.rateMapData, cellTexels: Float(foveation.cellTexels))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let result = readVertices(vertices, grid: grid)
        let nearest = readNearestDepths(nearestDepths, grid: grid)
        let eyeFromOrigin = simd_inverse(originFromEye)
        var worstOffPlane: Float = 0, worstOffReference: Float = 0
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                let index = row * grid.columns + column
                let vertex = result[index]
                let entry = nearest[index]
                let centre = referenceCentre(column: column, row: row, grid: grid, textureSize: textureSize, map: map)
                XCTAssertEqual(centre, simd_min(SIMD2<Float>(Float(column), Float(row)) * map.cellTexels, SIMD2<Float>(Float(textureSize.x - 1), Float(textureSize.y - 1))), "vertex \(column),\(row) sits every cell, the last on the last texel")
                // A continuous surface: the vertex stays on its own texel, with that texel's depth,
                // and the reference agrees.
                let reference = referenceNearestDepth(column: column, row: row, grid: grid, textureSize: textureSize, projection: projection, tearThreshold: configuration.tearThresholdMetres, map: map, depthOfTexel: depthOfTexel)
                XCTAssertEqual(entry.texel, centre, "vertex \(column),\(row) stays on its own texel over a continuous surface")
                XCTAssertEqual(reference.texel, centre)
                XCTAssertFalse(entry.rim, "no rim on a continuous surface (\(column),\(row))")
                let expectedDepth = depthOfTexel(SIMD2<Int>(Int(centre.x), Int(centre.y)))
                XCTAssertEqual(entry.depth, expectedDepth, accuracy: 1e-6, "the depth of vertex \(column),\(row) is its texel's")
                XCTAssertEqual(reference.depth, expectedDepth, accuracy: 1e-6)
                // The uv is the texel's centre over the size.
                let uv = uvOfTexel(centre, textureSize: textureSize, map: map)
                XCTAssertEqual(vertex.uv.x, uv.x, accuracy: 1e-6, "u of vertex \(column),\(row)")
                XCTAssertEqual(vertex.uv.y, uv.y, accuracy: 1e-6, "v of vertex \(column),\(row)")
                XCTAssertEqual(vertex.mask, 0, "no tear on a continuous surface (\(column),\(row))")
                XCTAssertEqual(vertex.nearSide, 0)
                // The position: on the ray Metal's mapping gives the texel, at the drawn depth, so
                // on the plane; and where the reference puts it.
                let expected = originFromEye * SIMD4<Float>(referenceEyePoint(ndc: map.ndc(ofTexel: centre), depth: expectedDepth, inverseProjection: inverseProjection, farShell: configuration.farShellMetres), 1)
                let offReference = simd_length(vertex.position - SIMD3<Float>(expected.x, expected.y, expected.z))
                worstOffReference = max(worstOffReference, offReference)
                XCTAssertLessThan(offReference, 1e-4, "vertex \(column),\(row) lies where the map's ray meets the drawn depth: \(vertex.position) against \(expected)")
                let inEye = eyeFromOrigin * SIMD4<Float>(vertex.position, 1)
                let offPlane = abs(simd_dot(normal, SIMD3<Float>(inEye.x, inEye.y, inEye.z)) - planeOffset)
                worstOffPlane = max(worstOffPlane, offPlane)
                XCTAssertLessThan(offPlane, 1e-4, "vertex \(column),\(row) lies on the tilted plane (\(offPlane) m off)")
            }
        }
        print("XR presenter rate map: the kernel's vertices lie within \(worstOffPlane) m of the plane and \(worstOffReference) m of the CPU's mapping")
        /// The grid is uniform in texels, so it is dense on the screen where the texture is: the
        /// first cell at the edge spans more of the screen than one at the centre.
        func screenX(_ column: Int) -> Float {
            let point = foveation.rateMap.screenCoordinates(physicalCoordinates: MTLCoordinate2D(x: Float(column) * map.cellTexels + 0.5, y: 0.5), layer: 0)
            return point.x
        }
        XCTAssertGreaterThan(screenX(1) - screenX(0), (screenX(grid.columns / 2 + 1) - screenX(grid.columns / 2)) * 1.5, "an edge cell covers more screen than a centre cell")
    }
}

// MARK: - The material

final class XRPresenterMaterialTests: XCTestCase {
    func test_theGraph_loadsWithItsTwoParameters() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("shader graph materials need macOS 15") }
        let url = try XCTUnwrap(XRPresenterMaterial.resourceURL(), "the graph is in the target's resource bundle")
        XCTAssertEqual(url.lastPathComponent, "XRPresenter.usda")

        let material = try await XRPresenterMaterial.load()

        XCTAssertEqual(Set(material.parameterNames), [XRPresenterMaterial.colorTextureParameter, XRPresenterMaterial.eyeParameter])
        XCTAssertEqual(material.faceCulling, .none)
    }

    func test_theEdgeGraph_loadsWithTheSameParameters() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("shader graph materials need macOS 15") }
        let material = try await XRPresenterMaterial.loadEdge()
        XCTAssertEqual(Set(material.parameterNames), [XRPresenterMaterial.colorTextureParameter, XRPresenterMaterial.eyeParameter])
    }

    func test_theGraph_takesAnEyeAndATexture() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("shader graph materials need macOS 15") }
        var material = try await XRPresenterMaterial.load()
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .bgra8Unorm_srgb
        descriptor.width = 8
        descriptor.height = 8
        descriptor.textureUsage = [.renderTarget, .shaderRead]
        let texture = try await MainActor.run { try TextureResource(from: LowLevelTexture(descriptor: descriptor)) }

        try XRPresenterMaterial.configure(&material, eye: 1, texture: texture)

        guard case let .int(eye)? = material.getParameter(name: XRPresenterMaterial.eyeParameter) else {
            return XCTFail("the eye parameter is an integer")
        }
        XCTAssertEqual(eye, 2, "the right eye is 2 in the graph")
    }
}

// MARK: - The presenter with the engine's loop

/// The whole chain on a Mac: the presenter's tickets become frames of the engine's loop, which
/// draws the eyes into RealityKit's textures and places the grids from their depth.
@MainActor
final class RealityKitFrameSourceTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)

    /// Lit cubes about the origin, and the pose the fake tracking gives: the headset five units
    /// in front of them, looking at them.
    override func initializeAssets() {
        for (index, x) in [Float(0), -1.5, 1.5].enumerated() {
            let cube = createEntity()
            setEntityName(entityId: cube, name: "Cube\(index)")
            setEntityMeshDirect(entityId: cube, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Cube\(index)")
            translateTo(entityId: cube, position: simd_float3(x, 0, 0))
        }
        if let camera = CameraSystem.shared.activeCamera {
            cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 5), target: .zero, up: simd_float3(0, 1, 0))
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        viewportBefore = renderInfo.viewPort
        renderInfo.isXRStereoMode = true
        renderInfo.currentEye = 0
        renderSkyBackground = false
    }

    override func tearDown() async throws {
        renderInfo.isXRStereoMode = false
        renderInfo.currentEye = 0
        renderInfo.xrFoveation = nil
        applyXRFoveationToSceneRenderPassDescriptors()
        renderInfo.viewPort = viewportBefore
        renderer.initSizeableResources()
        destroyAllEntities()
        try await super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(10)
        while condition() == false {
            guard Date() < deadline else {
                throw XCTSkip("the loop did not get there in time", file: file, line: line)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The grid buffer's bytes, through a blit when the buffer is not readable from the CPU.
    private func bytes(of buffer: MTLBuffer) throws -> [UInt8] {
        if buffer.storageMode == .shared {
            return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length))
        }
        let copy = try XCTUnwrap(renderInfo.device.makeBuffer(length: buffer.length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: buffer, sourceOffset: 0, to: copy, destinationOffset: 0, size: buffer.length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(UnsafeRawBufferPointer(start: copy.contents(), count: copy.length))
    }

    func test_theLoop_drawsTheEyesIntoThePresenter_andPlacesTheGrids() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [320, 240]
        configuration.gridColumns = 17
        configuration.gridRows = 13
        configuration.farShellMetres = 50
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        XCTAssertEqual(presenter.root.children.count, presenter.hasEdgeBand ? 4 : 2, "one grid entity per eye, and its edge band")

        // The headset five units back, looking at the cubes.
        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        XCTAssertEqual(source.eyeSize, simd_float2(320, 240))
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()

        presenter.start(commandQueue: renderInfo.commandQueue)
        // RealityKit's updates: one ticket a tick while the loop keeps up.
        var updates = 0
        try waitUntil {
            presenter.update()
            updates += 1
            return loop.framesDrawn >= 6
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try waitUntil { lastTicket.commandBuffer.status == .completed }
        // The numbers so far, before the probe below adds frames of its own.
        let statistics = presenter.statistics.snapshot()
        try probeAlpha(presenter: presenter, loop: loop)
        presenter.stop()
        try waitUntil { thread.isFinished }

        XCTAssertGreaterThanOrEqual(loop.framesDrawn, 6)
        XCTAssertEqual(renderInfo.viewPort, simd_float2(320, 240), "the engine's targets took the presenter's size")
        XCTAssertEqual(lastTicket.commandBuffer.status, .completed, "the ticket's own command buffer carried the frame")
        XCTAssertEqual(lastTicket.colorTextures.count, 2)
        XCTAssertEqual(lastTicket.gridBuffers.count, 2)
        XCTAssertTrue(lastTicket.indexBuffers.isEmpty, "the mesh keeps its indices unless the adaptive diagonal is asked for")
        XCTAssertEqual(statistics.updates, updates)
        XCTAssertGreaterThanOrEqual(statistics.framesDrawn, 6)
        XCTAssertEqual(statistics.posesMissing, 0)
        XCTAssertGreaterThan(statistics.gpuMsMax, 0, "the frames' GPU spans were noted")

        // The eyes were drawn with the presenter's eyes: a half eye distance to each side.
        let halfDistance = configuration.interpupillaryDistance / 2
        let expectedLeft = simd_inverse(matrix4x4Translation(-halfDistance, 0, 5))
        let expectedRight = simd_inverse(matrix4x4Translation(halfDistance, 0, 5))
        XCTAssertTrue(compareMatrices(renderInfo.xrEye0View, expectedLeft), "the left eye's view")
        XCTAssertTrue(compareMatrices(renderInfo.xrEye1View, expectedRight), "the right eye's view")

        // The grids were placed from the eyes' depth: the middle vertex on the cube in front
        // (about five metres ahead of the headset, at the origin), the corners on the far shell.
        let grid = presenter.grid
        for (eye, buffer) in lastTicket.gridBuffers.enumerated() {
            let bytes = try bytes(of: buffer)
            func position(column: Int, row: Int) -> SIMD3<Float> {
                bytes.withUnsafeBytes { raw in
                    let base = (row * grid.columns + column) * XRPresenterGrid.vertexStride
                    return SIMD3<Float>(
                        raw.load(fromByteOffset: base, as: Float.self),
                        raw.load(fromByteOffset: base + 4, as: Float.self),
                        raw.load(fromByteOffset: base + 8, as: Float.self)
                    )
                }
            }
            let middle = position(column: grid.columns / 2, row: grid.rows / 2)
            let corner = position(column: 0, row: 0)
            let eyePosition = SIMD3<Float>(eye == 0 ? -halfDistance : halfDistance, 0, 5)
            XCTAssertEqual(middle.z, 0.5, accuracy: 0.1, "eye \(eye): the middle vertex lies on the near face of the cube at the origin: \(middle)")
            XCTAssertEqual(abs(middle.x), 0, accuracy: 0.2, "eye \(eye): the middle vertex is in front of the headset: \(middle)")
            XCTAssertEqual(simd_length(corner - eyePosition), configuration.farShellMetres, accuracy: 0.5, "eye \(eye): a corner sees nothing and lies on the shell: \(corner)")
        }
    }

    /// The engine's alpha at a silhouette, printed: see the probe's comment.
    @available(macOS 15.0, *)
    private func probeAlpha(presenter: XRRealityKitPresenter, loop: XRFrameLoop) throws {
        // What the engine leaves at a silhouette in mixed immersion (alpha 0 where nothing is
        // drawn): the alpha values of the left eye's texture along the row through the cubes'
        // middle, read back through a blit. Coverage anti-aliasing leaves a ramp of partial
        // alphas at each edge; a binary alpha has none, and the edge band has nothing to blend.
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        // Each anti-aliasing mode in turn: a few frames for it to take, then the row.
        for mode in [AntiAliasingMode.fxaa, .smaa, .msaa, .msaaTaa] {
            setRendering(.antiAliasing(mode))
            let framesBefore = loop.framesDrawn
            try waitUntil {
                presenter.update()
                return loop.framesDrawn >= framesBefore + 6
            }
            let mixedTicket = try XCTUnwrap(presenter.lastTicket)
            try waitUntil { mixedTicket.commandBuffer.status == .completed }
            let color = mixedTicket.colorTextures[0]
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: color.pixelFormat, width: color.width, height: color.height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            let copy = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
            let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
            let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
            blit.copy(from: color, to: copy)
            blit.endEncoding()
            commandBuffer.commit()
            try waitUntil { commandBuffer.status == .completed }
            var row = [UInt8](repeating: 0, count: color.width * 4)
            copy.getBytes(&row, bytesPerRow: color.width * 4, from: MTLRegionMake2D(0, color.height / 2, color.width, 1), mipmapLevel: 0)
            let alphas = stride(from: 3, to: row.count, by: 4).map { Int(row[$0]) }
            let partial = alphas.filter { $0 > 0 && $0 < 255 }.count
            let covered = alphas.filter { $0 == 255 }.count
            let transitions = zip(alphas, alphas.dropFirst()).filter { ($0 == 0) != ($1 == 0) }.count
            print("XR presenter alpha along the middle row with \(mode): \(covered) covered, \(partial) partial, \(alphas.count - covered - partial) empty, \(transitions) edges; partial values: \(alphas.filter { $0 > 0 && $0 < 255 })")
        }
        setRendering(.antiAliasing(.fxaa))
    }

    func test_settingsChangedWhileRunning_rideInTheTickets_andTheFixedSplitComesBack() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [64, 48]
        configuration.gridColumns = 5
        configuration.gridRows = 4
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        XCTAssertEqual(presenter.settings, XRPresenterSettings(configuration: configuration), "the settings start from the configuration")
        XCTAssertEqual(presenter.drawsEdgeBand, presenter.hasEdgeBand, "the band is drawn when its graph loaded, the configuration asking for it")
        presenter.start(commandQueue: renderInfo.commandQueue)

        func nextTicket() throws -> XRPresenterTicket {
            // No loop: the test takes the tickets itself and commits their command buffers.
            presenter.update()
            return try XCTUnwrap(presenter.mailbox.take())
        }
        func finish(_ ticket: XRPresenterTicket) throws {
            ticket.commandBuffer.commit()
            try waitUntil { ticket.commandBuffer.status == .completed }
        }
        func indices(of mesh: LowLevelMesh) -> [UInt32] {
            var read: [UInt32] = []
            mesh.withUnsafeIndices { read = Array($0.bindMemory(to: UInt32.self)) }
            return read
        }

        // The cells' split per frame asked for: the ticket carries the index buffers and the
        // settings; the test writes every cell's other diagonal, as the kernel might.
        presenter.settings.adaptiveDiagonal = true
        presenter.settings.skirtTexels = 0
        presenter.settings.tearThresholdMetres = 0.9
        presenter.settings.leadSeconds = 0.01
        let split = try nextTicket()
        XCTAssertEqual(split.indexBuffers.count, 2)
        XCTAssertTrue(split.settings.adaptiveDiagonal)
        XCTAssertEqual(split.settings.skirtTexels, 0)
        XCTAssertEqual(split.settings.tearThresholdMetres, 0.9)
        XCTAssertEqual(split.settings.leadSeconds, 0.01)
        let fixed = presenter.grid.indices()
        var flipped = fixed
        for cell in stride(from: 0, to: fixed.count, by: 6) {
            // a b c, b d c -> a b d, a d c: the other diagonal.
            let (a, b, c, d) = (fixed[cell], fixed[cell + 1], fixed[cell + 2], fixed[cell + 4])
            flipped[cell ... cell + 5] = [a, b, d, a, d, c]
        }
        let flippedBuffer = try XCTUnwrap(flipped.withUnsafeBytes { renderInfo.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        let blit = try XCTUnwrap(split.commandBuffer.makeBlitCommandEncoder())
        for buffer in split.indexBuffers {
            blit.copy(from: flippedBuffer, sourceOffset: 0, to: buffer, destinationOffset: 0, size: flippedBuffer.length)
        }
        blit.endEncoding()
        try finish(split)
        for mesh in presenter.meshes {
            XCTAssertEqual(indices(of: mesh), flipped, "the cells were split the other way")
        }

        // Turned off: the next ticket carries no index buffers, and its command buffer writes
        // the fixed split back; the one after leaves the indices alone.
        presenter.settings.adaptiveDiagonal = false
        let restore = try nextTicket()
        XCTAssertTrue(restore.indexBuffers.isEmpty)
        XCTAssertFalse(restore.settings.adaptiveDiagonal)
        try finish(restore)
        for mesh in presenter.meshes {
            XCTAssertEqual(indices(of: mesh), fixed, "the fixed split is back")
        }
        let after = try nextTicket()
        XCTAssertTrue(after.indexBuffers.isEmpty)
        try finish(after)

        // The band follows its setting: its entities are disabled, then enabled again.
        if presenter.hasEdgeBand {
            let bands = presenter.root.children.filter { $0.name.hasSuffix("edge") }
            XCTAssertEqual(bands.count, 2)
            presenter.settings.edgeBlending = false
            XCTAssertFalse(presenter.drawsEdgeBand)
            try finish(nextTicket())
            XCTAssertTrue(bands.allSatisfy { !$0.isEnabled }, "the band's entities are off")
            presenter.settings.edgeBlending = true
            try finish(nextTicket())
            XCTAssertTrue(bands.allSatisfy(\.isEnabled), "the band's entities are on again")
            XCTAssertTrue(presenter.drawsEdgeBand)
        }
        presenter.stop()
    }

    /// The configuration of the picture tests: a symmetric 90° frustum, so that RealityKit's
    /// perspective camera matches the engine's projection exactly; the eyes at the device's point
    /// (no eye distance), so that the left eye's grid is what a mono camera there sees through
    /// the eye switch; cells of four texels, and a tear threshold for this scale: a texel is 39 mm
    /// at the cubes, five metres off through this 90° frustum, and a turned cube's grazing side
    /// face changes its distance to the eye by half a metre between neighbouring vertices, which
    /// the headset's 2 mm texels never reach on such a face. The threshold stays well under the
    /// 45 m between a cube and the far shell.
    private static var pictureConfiguration: XRRealityKitPresenterConfiguration {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [256, 256]
        configuration.frustumTangents = [1, 1, 1, 1]
        configuration.interpupillaryDistance = 0
        configuration.gridColumns = 65
        configuration.gridRows = 65
        configuration.tearThresholdMetres = 1
        configuration.farShellMetres = 50
        return configuration
    }

    /// The headset of the picture tests: five metres back, looking at the cubes.
    private static let picturePose = matrix4x4Translation(0, 0, 5)

    /// The cubes turned, so that their faces run across cells at changing depth: an affine uv
    /// keystones there by a measurable fraction of a texel (64.6 dB against the engine's picture
    /// with the cubes square to the eye; the projective one is exact at 8 bits).
    private func turnTheCubes() throws {
        for index in 0 ..< 3 {
            let cube = try XCTUnwrap(findEntity(name: "Cube\(index)"))
            rotateTo(entityId: cube, angle: 35, axis: simd_float3(0, 1, 0))
        }
    }

    /// Waits for `condition`; a stalled loop is a failure here, not an unavailable environment.
    private func reach(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw PictureError.stalled(what) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The engine's left eye for `configuration`, drawn by the loop from the picture pose, as
    /// linear rgba pixels of the texture's size; and the presenter, stopped, with its grids as the
    /// last frame placed them, for RealityKit to draw.
    @available(macOS 15.0, *)
    private func drawEngineEye(_ configuration: XRRealityKitPresenterConfiguration) async throws -> (presenter: XRRealityKitPresenter, pixels: [Float], size: SIMD2<Int>) {
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        guard presenter.usesShaderGraphMaterial else { throw XCTSkip("the eye material did not load") }
        let pose = Self.picturePose
        let source = RealityKitFrameSource(presenter: presenter) { _ in pose }
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()
        presenter.start(commandQueue: renderInfo.commandQueue)
        try reach("six frames drawn") {
            presenter.update()
            return loop.framesDrawn >= 6
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try reach("the last ticket completed") { lastTicket.commandBuffer.status == .completed }
        presenter.stop()
        try reach("the loop's thread finished") { thread.isFinished }
        let eyeTexture = lastTicket.colorTextures[0]
        let pixels = try linearPixels(ofSRGB: eyeTexture)
        return (presenter, pixels, SIMD2<Int>(eyeTexture.width, eyeTexture.height))
    }

    /// RealityKit's picture of `presenter`'s grids from the picture pose through a 90° camera,
    /// `size` pixels, linear rgba over an opaque black background. The materials load
    /// asynchronously, with a placeholder in the meantime: the picture is read back when it stops
    /// changing and shows something.
    @available(macOS 15.0, *)
    private func realityKitPicture(of presenter: XRRealityKitPresenter, size: SIMD2<Int>) async throws -> [Float] {
        let configuration = presenter.configuration
        let rkRenderer = try RealityRenderer()
        rkRenderer.cameraSettings.isToneMappingEnabled = false
        rkRenderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        rkRenderer.cameraSettings.antialiasing = .none
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: configuration.nearPlane, far: configuration.farPlane, fieldOfViewInDegrees: 90))
        camera.transform = Transform(matrix: Self.picturePose)
        rkRenderer.activeCamera = camera
        rkRenderer.entities.replaceAll([camera, presenter.root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        let cameraOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: output))
        var previous: [Float] = []
        var shown: [Float] = []
        for _ in 0 ..< 60 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try rkRenderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: cameraOutput, onComplete: { _ in continuation.resume() })
                } catch { continuation.resume(throwing: error) }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            shown = halfPixels(of: output)
            if shown == previous, coloured(shown, size: size) > 0 { break }
            previous = shown
        }
        return shown
    }

    /// How many pixels show colour (any channel above 0.05): the cubes, over a black or
    /// transparent room.
    private func coloured(_ pixels: [Float], size: SIMD2<Int>) -> Int {
        (0 ..< size.x * size.y).filter { index in (0 ..< 3).contains { pixels[index * 4 + $0] > 0.05 } }.count
    }

    /// The bounds of the coloured pixels, in pixels: where the cubes are in the picture.
    private func colouredBounds(_ pixels: [Float], size: SIMD2<Int>) -> (min: SIMD2<Int>, max: SIMD2<Int>)? {
        var bounds: (min: SIMD2<Int>, max: SIMD2<Int>)?
        for y in 0 ..< size.y {
            for x in 0 ..< size.x where (0 ..< 3).contains(where: { pixels[(y * size.x + x) * 4 + $0] > 0.05 }) {
                let point = SIMD2<Int>(x, y)
                bounds = bounds.map { (simd_min($0.min, point), simd_max($0.max, point)) } ?? (point, point)
            }
        }
        return bounds
    }

    /// How two pictures agree: the mean squared difference over the colour channels of every
    /// pixel, as a peak signal-to-noise ratio in dB. A floor on the error keeps the ratio finite
    /// when the pictures are the same at 8 bits.
    private func peakSignalToNoise(_ a: [Float], _ b: [Float], size: SIMD2<Int>) -> Double {
        var squared = 0.0
        for index in 0 ..< size.x * size.y {
            for channel in 0 ..< 3 {
                let difference = Double(a[index * 4 + channel] - b[index * 4 + channel])
                squared += difference * difference
            }
        }
        let meanSquared = max(squared / Double(size.x * size.y * 3), 1e-9)
        return 10 * log10(1 / meanSquared)
    }

    /// Writes two compared pictures as PNGs when `XR_PRESENTER_DUMP` names a folder.
    private func dumpPictures(_ pictures: [(name: String, pixels: [Float], size: SIMD2<Int>)]) throws {
        guard let folder = ProcessInfo.processInfo.environment["XR_PRESENTER_DUMP"] else { return }
        for picture in pictures {
            try writePNG(picture.pixels, width: picture.size.x, height: picture.size.y, to: URL(fileURLWithPath: folder).appendingPathComponent(picture.name))
        }
    }

    /// RealityKit, drawing the presenter's grids from the engine's own eye, shows the engine's
    /// picture: the grid's geometry and the projective uv put every texel back where the engine
    /// drew it.
    func test_realityKitShowsTheEnginesPicture_fromTheEnginesEye() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let configuration = Self.pictureConfiguration
        // Mixed immersion: the engine leaves the room transparent, as on the headset. (With an
        // opaque background the grid shows the halo of background lost around every silhouette,
        // where the triangles stretched to the far shell are torn away: a later stage's.)
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        try turnTheCubes()

        // The engine's left eye, linear: the cubes over the transparent room.
        let (presenter, engine, size) = try await drawEngineEye(configuration)
        XCTAssertEqual(size, configuration.textureSize)
        XCTAssertGreaterThan(coloured(engine, size: size), 1000, "the engine drew the cubes into the eye")

        // RealityKit's picture of the grids from the same point, through the same projection.
        let shown = try await realityKitPicture(of: presenter, size: size)
        // The output's alpha is the opaque background's everywhere: colour says what was drawn.
        XCTAssertGreaterThan(coloured(shown, size: size), 1000, "RealityKit drew the grids")

        // The two pictures agree. The engine's cubes are lit over a transparent room, black in
        // both pictures; through the grid and the material they come back where they were, to
        // the bilinear resampling of a texel-aligned grid and the edges' blend.
        let psnr = peakSignalToNoise(shown, engine, size: size)
        print("RealityKit's picture of the presenter's grids against the engine's eye: PSNR \(psnr) dB")
        try dumpPictures([("realitykit.png", shown, size), ("engine.png", engine, size)])
        XCTAssertTrue(psnr.isFinite)
        XCTAssertGreaterThan(psnr, 70, "RealityKit shows the engine's picture from the engine's eye (the affine uv scores under 65 dB)")
    }

    /// Through the presenter's rate map, RealityKit's picture of the grids is the engine's
    /// picture unwarped: the eye is drawn into the map's physical texels, dense at the centre of
    /// view and sparse at the edges, and the grid, a vertex every cell of those texels, puts each
    /// back on its ray, so what RealityKit shows at the map's screen size is the scene as the
    /// engine's uniform frame of that size draws it. Against that uniform frame: the cubes land
    /// where it has them, to three pixels (a periphery texel is two pixels wide and the alpha
    /// ramp's foot reaches one more; a mapping of texels to rays that took the physical texel for
    /// the screen pixel would move an edge by up to a quarter of the screen), and the pictures
    /// agree to the resampling, which magnifies a texel at the periphery to about two pixels, so
    /// edges there are a pixel softer than the uniform frame's (the headset's eye reads them at
    /// its own resolution either way; the centre of view is what gains).
    func test_realityKitShowsTheEnginesPicture_throughTheRateMap() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        guard renderInfo.device.supportsRasterizationRateMap(layerCount: 1) else { throw XCTSkip("this GPU has no rasterization rate maps") }
        var configuration = Self.pictureConfiguration
        configuration.foveation = .equiAngular
        configuration.foveatedCellTexels = 4
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        try turnTheCubes()

        // The eye through the map: physical texels within the budget, the screen larger.
        let (foveated, _, physical) = try await drawEngineEye(configuration)
        let map = try XCTUnwrap(foveated.foveation, "the presenter made its map")
        let screen = map.screenSize
        XCTAssertEqual(physical, map.physicalSize)
        XCTAssertLessThanOrEqual(physical.x, 256)
        XCTAssertGreaterThan(screen.x, physical.x, "the screen is larger than the texture")
        XCTAssertEqual(foveated.grid.columns, (physical.x + 3) / 4 + 1, "a vertex every four texels")

        // The reference: the engine's uniform frame at the map's screen size, cells of four texels.
        var uniform = Self.pictureConfiguration
        uniform.textureSize = screen
        uniform.gridColumns = (screen.x - 1) / 4 + 1
        uniform.gridRows = (screen.y - 1) / 4 + 1
        let (_, reference, referenceSize) = try await drawEngineEye(uniform)
        XCTAssertEqual(referenceSize, screen)
        XCTAssertGreaterThan(coloured(reference, size: screen), 1000, "the engine drew the cubes into the uniform eye")

        // RealityKit's picture of the foveated grids at the screen size.
        let shown = try await realityKitPicture(of: foveated, size: screen)
        XCTAssertGreaterThan(coloured(shown, size: screen), 1000, "RealityKit drew the grids")
        let shownBounds = try XCTUnwrap(colouredBounds(shown, size: screen))
        let referenceBounds = try XCTUnwrap(colouredBounds(reference, size: screen))
        XCTAssertLessThanOrEqual(abs(shownBounds.min.x - referenceBounds.min.x), 3, "the cubes' left edge is where the uniform frame has it: \(shownBounds) against \(referenceBounds)")
        XCTAssertLessThanOrEqual(abs(shownBounds.max.x - referenceBounds.max.x), 3, "the cubes' right edge is where the uniform frame has it: \(shownBounds) against \(referenceBounds)")
        XCTAssertLessThanOrEqual(abs(shownBounds.min.y - referenceBounds.min.y), 3, "the cubes' top edge is where the uniform frame has it: \(shownBounds) against \(referenceBounds)")
        XCTAssertLessThanOrEqual(abs(shownBounds.max.y - referenceBounds.max.y), 3, "the cubes' bottom edge is where the uniform frame has it: \(shownBounds) against \(referenceBounds)")
        XCTAssertGreaterThan(referenceBounds.max.x - referenceBounds.min.x, screen.x / 3, "the cubes span a good part of the picture, so a wrong mapping would show")

        let psnr = peakSignalToNoise(shown, reference, size: screen)
        print("RealityKit's picture of the presenter's grids through the rate map (screen \(screen.x)×\(screen.y) over \(physical.x)×\(physical.y) texels) against the engine's uniform frame of the screen size: PSNR \(psnr) dB; cubes at \(shownBounds) against \(referenceBounds)")
        try dumpPictures([("realitykit-rate-map.png", shown, screen), ("engine-uniform-screen.png", reference, screen)])
        XCTAssertTrue(psnr.isFinite)
        XCTAssertGreaterThan(psnr, 30, "RealityKit shows the engine's picture through the map, to the resampling of the periphery")
    }

    private enum PictureError: Swift.Error { case stalled(String) }

    /// The texture's pixels, linear floats, rgba, row by row from the top.
    private func linearPixels(ofSRGB texture: MTLTexture) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        try waitUntil { commandBuffer.status == .completed }
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        func linear(_ byte: UInt8) -> Float {
            let value = Float(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        // bgra in memory.
        return (0 ..< texture.width * texture.height).flatMap { index -> [Float] in
            let base = index * 4
            return [linear(bytes[base + 2]), linear(bytes[base + 1]), linear(bytes[base]), Float(bytes[base + 3]) / 255]
        }
    }

    /// Linear rgba floats as an 8-bit sRGB PNG, for looking at a picture a test compared.
    private func writePNG(_ pixels: [Float], width: Int, height: Int, to url: URL) throws {
        func encoded(_ value: Float) -> UInt8 {
            let clamped = min(max(value, 0), 1)
            let srgb = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt8((srgb * 255).rounded())
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0 ..< width * height {
            for channel in 0 ..< 3 { bytes[index * 4 + channel] = encoded(pixels[index * 4 + channel]) }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw XCTSkip("no PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// An rgba16Float texture's pixels as floats.
    private func halfPixels(of texture: MTLTexture) -> [Float] {
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return halves.map { Float($0) }
    }

    /// A space closed and opened again: the second session draws. The presenter view closes a
    /// session by stopping the presenter (the loop ends with the mailbox) and then resetting the
    /// engine's world, whose entity destroys and completion (the active camera cleared, the
    /// loop stopped) the engine defers to the start of a frame. With the old loop gone, that
    /// frame is the new session's first, which then loses its camera and draws nothing. The
    /// presenter's `stop(after:)` gives the old loop that frame instead.
    func test_aSessionClosedAsTheViewClosesIt_leavesTheNextSessionDrawing() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [128, 128]
        configuration.frustumTangents = [1, 1, 1, 1]
        configuration.gridColumns = 17
        configuration.gridRows = 17
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        let devicePose = matrix4x4Translation(0, 0, 5)

        func session(_ name: String, close: (XRRealityKitPresenter, XRFrameLoop, Thread) throws -> Void) async throws -> [Float] {
            let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
            presenter.reportInterval = 0
            setSceneReady(true)
            let source = RealityKitFrameSource(presenter: presenter) { _ in devicePose }
            let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
            loop.start()
            let thread = Thread { loop.run() }
            thread.start()
            presenter.start(commandQueue: renderInfo.commandQueue)
            try waitUntil {
                presenter.update()
                return loop.framesDrawn >= 8
            }
            let lastTicket = try XCTUnwrap(presenter.lastTicket)
            try waitUntil { lastTicket.commandBuffer.status == .completed }
            let pixels = try linearPixels(ofSRGB: lastTicket.colorTextures[0])
            let coloured = (0 ..< 128 * 128).filter { index in (0 ..< 3).contains { pixels[index * 4 + $0] > 0.05 } }.count
            print("XR presenter session \(name): \(coloured) coloured pixels in the eye")
            try close(presenter, loop, thread)
            try waitUntil { thread.isFinished }
            return pixels
        }
        func coloured(_ pixels: [Float]) -> Int {
            (0 ..< 128 * 128).filter { index in (0 ..< 3).contains { pixels[index * 4 + $0] > 0.05 } }.count
        }

        // The first session, closed as the view closes it (the world reset of the XR shutdown
        // is visionOS-only; its deferred part is the engine's own): the entities destroyed at
        // the start of a frame, the completion then clearing the camera and stopping the loop.
        let first = try await session("first") { presenter, loop, _ in
            // The unlucky close: the last frame's completion has not asked for the finalization
            // yet (a window of a few milliseconds per close); the presenter asks itself.
            needsFinalizeDestroys = false
            presenter.stop(after: { done in
                setSceneReady(false)
                destroyAllEntities {
                    CameraSystem.shared.activeCamera = nil
                    loop.stop()
                    done()
                }
            })
        }
        XCTAssertGreaterThan(coloured(first), 100, "the first session drew the cubes")
        XCTAssertLessThan(coloured(first), 128 * 128 / 2, "over a transparent room")

        // The engine made again, as the view's next session makes it (a camera, set active),
        // the scene again as a game's onReady makes it, and the second session.
        CameraSystem.shared.activeCamera = findGameCamera()
        initializeAssets()
        let second = try await session("second") { presenter, loop, _ in
            presenter.stop()
            loop.stop()
        }
        // The same picture as the first session's: the first session's destroys and completion
        // did not run in the second session's frames.
        var squared = 0.0
        for index in 0 ..< 128 * 128 {
            for channel in 0 ..< 3 {
                let difference = Double(second[index * 4 + channel] - first[index * 4 + channel])
                squared += difference * difference
            }
        }
        let psnr = 10 * log10(1 / max(squared / Double(128 * 128 * 3), 1e-9))
        print("XR presenter second session against the first: PSNR \(psnr) dB")
        XCTAssertGreaterThan(psnr, 40, "the second session draws the first session's picture")
    }

    func test_aFrameWithoutAPose_clearsTheEyes_andKeepsTheGrids() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [64, 48]
        configuration.gridColumns = 4
        configuration.gridRows = 3
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        let source = RealityKitFrameSource(presenter: presenter) { _ in nil }
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()

        presenter.start(commandQueue: renderInfo.commandQueue)
        try waitUntil {
            presenter.update()
            return presenter.statistics.snapshot().posesMissing > 0 || presenter.lastTicket.map { $0.commandBuffer.status == .completed } == true
        }
        let ticket = try XCTUnwrap(presenter.lastTicket)
        presenter.stop()
        try waitUntil { thread.isFinished }
        try waitUntil { ticket.commandBuffer.status == .completed }

        XCTAssertEqual(loop.framesDrawn, 0, "no eye was drawn without a pose")
        XCTAssertEqual(ticket.commandBuffer.status, .completed, "the ticket was still committed: RealityKit wants every replaced texture's buffer")
    }

    func test_aFrameLetGoBeforeItsDrawing_commitsItsTicket() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [64, 48]
        configuration.gridColumns = 4
        configuration.gridRows = 3
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        presenter.start(commandQueue: renderInfo.commandQueue)
        presenter.update()
        let ticket = try XCTUnwrap(presenter.lastTicket)

        // The loop takes the frame and lets it go without drawing.
        var frame = source.nextFrame()
        XCTAssertNotNil(frame)
        XCTAssertEqual(ticket.commandBuffer.status, .notEnqueued)
        frame = nil
        _ = frame

        try waitUntil { ticket.commandBuffer.status == .completed }
        XCTAssertEqual(ticket.commandBuffer.status, .completed)
        presenter.stop()
    }

    /// The chain through the presenter's rate map: the textures are the map's physical size
    /// within the budget, the loop sizes the engine's targets to them and draws every eye through
    /// the map, the grid is the map's (a vertex every cell of physical texels), and the vertices
    /// land on the scene as before: the middle one on the cube ahead, a corner on the shell.
    func test_theLoop_drawsTheEyesThroughThePresentersRateMap_andPlacesTheGrids() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        guard renderInfo.device.supportsRasterizationRateMap(layerCount: 1) else { throw XCTSkip("this GPU has no rasterization rate maps") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [320, 240]
        configuration.foveation = .equiAngular
        configuration.farShellMetres = 50
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        let foveation = try XCTUnwrap(presenter.foveation, "the presenter made its map")
        let physical = foveation.physicalSize
        XCTAssertLessThanOrEqual(physical.x, 320)
        XCTAssertLessThanOrEqual(physical.y, 240)
        XCTAssertGreaterThan(foveation.screenSize.x, 320, "the eyes' screen is larger than the budget")
        XCTAssertEqual(presenter.textureSize, physical, "the textures are the map's physical size")
        XCTAssertEqual(presenter.grid, foveation.grid, "the grid is the map's")
        XCTAssertEqual(presenter.grid.columns, (physical.x + foveation.cellTexels - 1) / foveation.cellTexels + 1)
        XCTAssertNotEqual(presenter.grid.columns, configuration.gridColumns, "not the configuration's")

        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        XCTAssertEqual(source.eyeSize, simd_float2(Float(physical.x), Float(physical.y)), "the loop sizes the renderer's targets from the physical size")
        let frame = try XCTUnwrap(source.nextFrameAfter(presenter: presenter, queue: renderInfo.commandQueue))
        let eyes = try XCTUnwrap(frame.acquireEyes().first?.eyes)
        XCTAssertEqual(eyes.count, 2)
        for eye in eyes {
            XCTAssertTrue(eye.foveation?.rateMap === foveation.rateMap, "each eye carries the presenter's map")
            XCTAssertEqual(eye.viewport.width, Double(foveation.screenSize.x), "the eye's viewport is the map's screen")
            XCTAssertEqual(eye.viewport.height, Double(foveation.screenSize.y))
            XCTAssertEqual(eye.colorTexture.width, physical.x, "drawn into a physical-size texture")
            XCTAssertEqual(eye.colorTexture.height, physical.y)
            XCTAssertEqual(eye.depthTexture.width, physical.x)
        }
        _ = frame

        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()
        try waitUntil {
            presenter.update()
            return loop.framesDrawn >= 6
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try waitUntil { lastTicket.commandBuffer.status == .completed }
        presenter.stop()
        try waitUntil { thread.isFinished }

        XCTAssertGreaterThanOrEqual(loop.framesDrawn, 6)
        XCTAssertEqual(renderInfo.viewPort, simd_float2(Float(physical.x), Float(physical.y)), "the engine's targets took the physical size")
        XCTAssertTrue(renderInfo.xrFoveation?.rateMap === foveation.rateMap, "the eyes were drawn through the presenter's map")
        XCTAssertEqual(renderInfo.xrFoveation?.viewport.width, Double(foveation.screenSize.x))
        XCTAssertTrue(renderInfo.offscreenRenderPassDescriptor.rasterizationRateMap === foveation.rateMap, "the scene passes carry the map")
        XCTAssertEqual(lastTicket.colorTextures[0].width, physical.x)
        XCTAssertEqual(presenter.statistics.snapshot().posesMissing, 0)

        let halfDistance = configuration.interpupillaryDistance / 2
        let grid = presenter.grid
        for (eye, buffer) in lastTicket.gridBuffers.enumerated() {
            let bytes = try bytes(of: buffer)
            func vertex(column: Int, row: Int) -> (position: SIMD3<Float>, uv: SIMD2<Float>) {
                bytes.withUnsafeBytes { raw in
                    let base = (row * grid.columns + column) * XRPresenterGrid.vertexStride
                    let position = SIMD3<Float>(
                        raw.load(fromByteOffset: base, as: Float.self),
                        raw.load(fromByteOffset: base + 4, as: Float.self),
                        raw.load(fromByteOffset: base + 8, as: Float.self)
                    )
                    let uv = SIMD2<Float>(
                        raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset, as: Float.self),
                        raw.load(fromByteOffset: base + XRPresenterGrid.uvOffset + 4, as: Float.self)
                    )
                    return (position, uv)
                }
            }
            let middle = vertex(column: grid.columns / 2, row: grid.rows / 2)
            let corner = vertex(column: 0, row: 0)
            let eyePosition = SIMD3<Float>(eye == 0 ? -halfDistance : halfDistance, 0, 5)
            XCTAssertEqual(middle.position.z, 0.5, accuracy: 0.1, "eye \(eye): the middle vertex lies on the near face of the cube at the origin: \(middle.position)")
            XCTAssertEqual(abs(middle.position.x), 0, accuracy: 0.2, "eye \(eye): the middle vertex is in front of the headset: \(middle.position)")
            XCTAssertEqual(simd_length(corner.position - eyePosition), configuration.farShellMetres, accuracy: 0.5, "eye \(eye): a corner sees nothing and lies on the shell: \(corner.position)")
            // The uv is the texel's centre: the first vertex half a texel in, the middle one at
            // the middle texel's centre.
            XCTAssertEqual(corner.uv.x, 0.5 / Float(physical.x), accuracy: 1e-6, "eye \(eye): the corner's u is half a texel in")
            XCTAssertEqual(corner.uv.y, 0.5 / Float(physical.y), accuracy: 1e-6)
            let middleTexel = Float((grid.columns / 2) * foveation.cellTexels)
            XCTAssertEqual(middle.uv.x, min(middleTexel, Float(physical.x - 1)) / Float(physical.x) + 0.5 / Float(physical.x), accuracy: 1e-6, "eye \(eye): the middle vertex's u is its texel's centre")
        }
    }
}

@available(macOS 15.0, *)
private extension RealityKitFrameSource {
    /// A frame of a ticket the presenter posts now, for a look at its eyes without the loop.
    @MainActor
    func nextFrameAfter(presenter: XRRealityKitPresenter, queue: MTLCommandQueue) -> XRFrame? {
        presenter.start(commandQueue: queue)
        presenter.update()
        return nextFrame()
    }
}
