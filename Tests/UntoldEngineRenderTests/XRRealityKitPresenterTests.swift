//
//  XRRealityKitPresenterTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    /// The kernel's `eyePoint`, in Swift.
    private func referenceEyePoint(uv: SIMD2<Float>, depth: Float, inverseProjection: simd_float4x4, farShell: Float) -> SIMD3<Float> {
        let ndc = SIMD2<Float>(uv.x * 2 - 1, 1 - uv.y * 2)
        let eye = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, max(depth, 1e-6), 1)
        var point = SIMD3<Float>(eye.x, eye.y, eye.z) / eye.w
        let distance = simd_length(point)
        if depth <= 0 || distance > farShell {
            point = point * (farShell / max(distance, 1e-6))
        }
        return point
    }

    /// The kernel's footprint of a grid vertex, in Swift: the texels of the cell about the vertex
    /// plus a margin of half a cell, `lo ... hi` on each axis, clamped to the texture.
    private func referenceFootprint(column: Int, row: Int, grid: XRPresenterGrid, textureSize: SIMD2<Int>) -> (lo: SIMD2<Int>, hi: SIMD2<Int>) {
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let cells = SIMD2<Float>(Float(grid.columns - 1), Float(grid.rows - 1))
        let halfCell = size / cells * 0.5
        let centre = SIMD2<Float>(Float(column), Float(row)) * (1 / cells) * (size - 1)
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
    private func referenceNearestDepth(column: Int, row: Int, grid: XRPresenterGrid, textureSize: SIMD2<Int>, projection: simd_float4x4, tearThreshold: Float, line: Line = Line(), skirtTexels: Float = 0) -> (depth: Float, texel: SIMD2<Float>, rim: Bool, placed: SIMD2<Float>) {
        let (lo, hi) = referenceFootprint(column: column, row: row, grid: grid, textureSize: textureSize)
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let cells = SIMD2<Float>(Float(grid.columns - 1), Float(grid.rows - 1))
        let centre = SIMD2<Float>(Float(column), Float(row)) * (1 / cells) * (size - 1)
        func depthAt(_ x: Int, _ y: Int) -> Float {
            if Int32(x) == line.column || Int32(y) == line.row { return line.depth }
            return syntheticDepth(texel: SIMD2<Int>(x, y), textureSize: textureSize, projection: projection)
        }
        var nearest: Float = 0
        for y in lo.y ... hi.y {
            for x in lo.x ... hi.x {
                nearest = max(nearest, depthAt(x, y))
            }
        }
        let centreUV = centre / (size - 1)
        let ndc = SIMD2<Float>(centreUV.x * 2 - 1, 1 - centreUV.y * 2)
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

    /// The uv of a texel: v = 0 at the top row.
    private func uvOfTexel(_ texel: SIMD2<Float>, textureSize: SIMD2<Int>) -> SIMD2<Float> {
        texel / SIMD2<Float>(Float(textureSize.x - 1), Float(textureSize.y - 1))
    }

    private struct Vertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
        /// The tear mask's x: the far side of a depth jump.
        var mask: Float
        /// The tear mask's y: the near side.
        var nearSide: Float
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
            return Vertex(position: position, uv: uv, mask: mask, nearSide: nearSide)
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
            // Positive for a counter-clockwise triangle with y up and the first row at the top.
            func at(_ i: UInt32) -> SIMD2<Float> { SIMD2<Float>(Float(Int(i) % grid.columns), -Float(Int(i) / grid.columns)) }
            let u = at(q) - at(p), v = at(r) - at(p)
            return u.x * v.y - u.y * v.x
        }
        for cell in stride(from: 0, to: grid.indexCount, by: 3) {
            XCTAssertGreaterThan(signedArea(written[cell], written[cell + 1], written[cell + 2]), 0, "triangle at index \(cell) is counter-clockwise")
        }
    }

    func test_theUniforms_haveTheKernelsLayout() {
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.stride, 160)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.inverseProjection), 64)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.gridSize), 128)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.textureSize), 136)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.farShell), 144)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.flags), 152)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.skirtTexels), 156)
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
        XCTAssertEqual(presenter.root.children.count, 2, "one grid entity per eye")

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
        presenter.stop()
        try waitUntil { thread.isFinished }
        try waitUntil { lastTicket.commandBuffer.status == .completed }

        XCTAssertGreaterThanOrEqual(loop.framesDrawn, 6)
        XCTAssertEqual(renderInfo.viewPort, simd_float2(320, 240), "the engine's targets took the presenter's size")
        XCTAssertEqual(lastTicket.commandBuffer.status, .completed, "the ticket's own command buffer carried the frame")
        XCTAssertEqual(lastTicket.colorTextures.count, 2)
        XCTAssertEqual(lastTicket.gridBuffers.count, 2)
        XCTAssertEqual(lastTicket.indexBuffers.count, 2, "the cells' split follows the depth each frame")
        let statistics = presenter.statistics.snapshot()
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
}
