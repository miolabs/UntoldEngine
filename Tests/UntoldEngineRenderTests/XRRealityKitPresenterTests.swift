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

    /// What the synthetic depth holds at a texture position (uv, v = 0 at the top).
    private func syntheticDepth(uv: SIMD2<Float>, projection: simd_float4x4) -> Float {
        let centred = uv - SIMD2<Float>(0.5, 0.5)
        if simd_length(centred) < Self.holeRadius { return 0 }
        return depth(ofDistance: uv.x < 0.5 ? Self.nearPlaneDistance : Self.farPlaneDistance, projection: projection)
    }

    /// Draws the synthetic depth into a depth texture with a fragment shader writing the depth.
    private func makeDepthTexture(width: Int, height: Int, projection: simd_float4x4) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        struct Depths { float near; float far; float holeRadius; float padding; };
        vertex V fullscreen(uint id [[vertex_id]]) {
            float2 ndc = float2((id == 2) ? 3.0f : -1.0f, (id == 1) ? 3.0f : -1.0f);
            V out; out.position = float4(ndc, 0, 1); out.uv = float2(ndc.x * 0.5f + 0.5f, 1.0f - (ndc.y * 0.5f + 0.5f));
            return out;
        }
        struct Out { float depth [[depth(any)]]; };
        fragment Out depths(V in [[stage_in]], constant Depths &d [[buffer(0)]]) {
            Out out;
            float2 centred = in.uv - 0.5f;
            if (length(centred) < d.holeRadius) { out.depth = 0.0f; }
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

        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthStencil)
        var depths = SIMD4<Float>(
            depth(ofDistance: Self.nearPlaneDistance, projection: projection),
            depth(ofDistance: Self.farPlaneDistance, projection: projection),
            Self.holeRadius,
            0
        )
        encoder.setFragmentBytes(&depths, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
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

    /// The kernel's `nearestDepth`, in Swift, over the synthetic depth.
    private func referenceNearestDepth(uv: SIMD2<Float>, grid: XRPresenterGrid, textureSize: SIMD2<Int>, projection: simd_float4x4) -> Float {
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        let cell = size / SIMD2<Float>(Float(grid.columns - 1), Float(grid.rows - 1))
        let centre = uv * (size - 1)
        let taps = SIMD2<Int>(min(4, max(1, Int(ceil(cell.x)))), min(4, max(1, Int(ceil(cell.y)))))
        var nearest: Float = 0
        for j in 0 ..< taps.y {
            for i in 0 ..< taps.x {
                let offset = (SIMD2<Float>(Float(i), Float(j)) + 0.5) / SIMD2<Float>(Float(taps.x), Float(taps.y)) - 0.5
                let p = simd_clamp((centre + offset * cell).rounded(.toNearestOrEven), SIMD2<Float>(0, 0), size - 1)
                let pixelUV = p / (size - 1)
                nearest = max(nearest, syntheticDepth(uv: pixelUV, projection: projection))
            }
        }
        return nearest
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

    func test_theKernel_placesTheVertices_asTheReferenceDoes() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        // The jumps here are 3 m (the seam) and 45 m (the hole). The threshold stays above the
        // distance a diagonal step covers on the oblique far plane at this coarse grid's corner
        // (0.56 m), which is no tear.
        configuration.tearThresholdMetres = 1
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y, projection: projection)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        // The eye one metre up and half a metre to the right of the origin, looking straight ahead.
        let originFromEye = matrix4x4Translation(0.5, 1, 0)

        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, vertices: vertices, grid: grid, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let result = readVertices(vertices, grid: grid)
        let inverseProjection = simd_inverse(projection)
        let nearDepth = depth(ofDistance: Self.nearPlaneDistance, projection: projection)
        let farDepth = depth(ofDistance: Self.farPlaneDistance, projection: projection)
        var nearPlane = 0, farPlane = 0, shell = 0, tears = 0
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                let uv = SIMD2<Float>(Float(column) / Float(grid.columns - 1), Float(row) / Float(grid.rows - 1))
                let vertex = result[row * grid.columns + column]
                XCTAssertEqual(vertex.uv.x, uv.x, accuracy: 1e-6)
                XCTAssertEqual(vertex.uv.y, uv.y, accuracy: 1e-6, "v = 0 at the top row, unflipped")

                let sampled = referenceNearestDepth(uv: uv, grid: grid, textureSize: textureSize, projection: projection)
                let eye = referenceEyePoint(uv: uv, depth: sampled, inverseProjection: inverseProjection, farShell: configuration.farShellMetres)
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

    func test_theUniforms_haveTheKernelsLayout() {
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.stride, 160)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.inverseProjection), 64)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.gridSize), 128)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.textureSize), 136)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.farShell), 144)
        XCTAssertEqual(MemoryLayout<XRGridUnprojectUniforms>.offset(of: \.flags), 152)
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
