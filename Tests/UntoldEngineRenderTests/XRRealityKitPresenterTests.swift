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

    func test_theDegenerateIndices_areSixCopiesOfEachCellsFirstVertex() {
        let grid = XRPresenterGrid(columns: 4, rows: 3)
        let indices = grid.degenerateIndices()
        XCTAssertEqual(indices.count, grid.indexCount)
        XCTAssertEqual(indices, [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6])
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

// MARK: - The render scale

/// The configuration's render scale: its clamp, the size it renders at, and the texels per
/// degree it gives, without Metal.
final class XRPresenterRenderScaleTests: XCTestCase {
    func test_theRenderScale_isClamped_andOneLeavesTheSizeAsItIs() {
        var configuration = XRRealityKitPresenterConfiguration()
        XCTAssertEqual(configuration.renderScale, 1, "the drawable size by default")
        XCTAssertEqual(configuration.clampedRenderScale, 1)
        XCTAssertEqual(configuration.renderedTextureSize, configuration.textureSize, "at 1 the rendered size is the texture size itself")
        XCTAssertEqual(configuration.eyeSize, simd_float2(1920, 1824))

        configuration.renderScale = 1.5
        XCTAssertEqual(configuration.clampedRenderScale, 1.5)
        XCTAssertEqual(configuration.renderedTextureSize, SIMD2<Int>(2880, 2736), "1.5 times the drawable size")
        XCTAssertEqual(configuration.eyeSize, simd_float2(2880, 2736))

        configuration.renderScale = 0
        XCTAssertEqual(configuration.clampedRenderScale, 0.5, "clamped below")
        XCTAssertEqual(configuration.renderedTextureSize, SIMD2<Int>(960, 912))
        configuration.renderScale = 10
        XCTAssertEqual(configuration.clampedRenderScale, 2, "clamped above")
        XCTAssertEqual(configuration.renderedTextureSize, SIMD2<Int>(3840, 3648))
        configuration.renderScale = -3
        XCTAssertEqual(configuration.clampedRenderScale, 0.5)
        configuration.renderScale = .nan
        XCTAssertEqual(configuration.clampedRenderScale, 1, "not a number is 1")
        XCTAssertEqual(configuration.renderedTextureSize, configuration.textureSize)
        configuration.renderScale = .infinity
        XCTAssertEqual(configuration.clampedRenderScale, 1)

        // Odd sizes round to whole pixels (halves away from zero), never below one.
        configuration.renderScale = 1.5
        configuration.textureSize = [321, 1]
        XCTAssertEqual(configuration.renderedTextureSize, SIMD2<Int>(482, 2))
        configuration.renderScale = 0.5
        XCTAssertEqual(configuration.renderedTextureSize, SIMD2<Int>(161, 1), "160.5 rounds up; at least one pixel")
    }

    func test_theTexelsPerDegreeAtTheCentre_areTheTexelsPerUnitTangentPerRadian_andGrowWithTheScale() {
        var configuration = XRRealityKitPresenterConfiguration()
        // 1920 texels over 2.6 of tangent: 738 per unit tangent, 12.9 per degree at the centre.
        XCTAssertEqual(configuration.centreTexelsPerDegree, 1920 / 2.6 * .pi / 180, accuracy: 1e-4)
        XCTAssertEqual(configuration.centreTexelsPerDegree, 12.89, accuracy: 0.01)
        configuration.renderScale = 1.5
        XCTAssertEqual(configuration.centreTexelsPerDegree, 2880 / 2.6 * .pi / 180, accuracy: 1e-4)
        XCTAssertEqual(configuration.centreTexelsPerDegree, 19.33, accuracy: 0.01, "1.5 times the texels per degree")
        // A 90° symmetric frustum of 256 texels: 128 per unit tangent, 2.23 per degree at the centre.
        configuration.renderScale = 1
        configuration.textureSize = [256, 256]
        configuration.frustumTangents = [1, 1, 1, 1]
        XCTAssertEqual(configuration.centreTexelsPerDegree, 128 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(XRRealityKitPresenterConfiguration.centreTexelsPerDegree(width: 100, tangents: [0, 0, 1, 1]), 0, "no frustum, no density")
    }
}

// MARK: - The silhouette

/// The configuration's silhouette choice, without Metal: the shipped cut and band by default.
final class XRPresenterSilhouetteTests: XCTestCase {
    func test_theCutAndBand_isTheDefault_andTheCasesHaveLabels() {
        let configuration = XRRealityKitPresenterConfiguration()
        XCTAssertEqual(configuration.silhouette, .cutAndBand, "the shipped chain by default")
        XCTAssertTrue(configuration.edgeBlending, "with its band on")
        XCTAssertEqual(XRPresenterSilhouette.allCases, [.cutAndBand, .blendedCore])
        XCTAssertEqual(XRPresenterSilhouette.cutAndBand.label, "cut and band")
        XCTAssertEqual(XRPresenterSilhouette.blendedCore.label, "blended core")
        XCTAssertEqual(XRPresenterSilhouette(rawValue: "blendedCore"), .blendedCore, "a launch argument's name")
    }

    /// The silhouette cells: the skirt by default, the alpha crossing beside it, live in the
    /// settings, which then ask for the index buffers each frame as the adaptive diagonal does.
    func test_theSilhouetteCells_areTheSkirtByDefault_andTheCrossingRewritesTheIndices() {
        var configuration = XRRealityKitPresenterConfiguration()
        XCTAssertEqual(configuration.silhouetteCells, .skirt, "the shipped rule by default")
        XCTAssertEqual(XRPresenterSilhouetteCells.allCases, [.skirt, .alphaCrossing])
        XCTAssertEqual(XRPresenterSilhouetteCells.skirt.label, "skirt")
        XCTAssertEqual(XRPresenterSilhouetteCells.alphaCrossing.label, "alpha crossing")
        XCTAssertEqual(XRPresenterSilhouetteCells(rawValue: "alphaCrossing"), .alphaCrossing, "a launch argument's name")
        var settings = XRPresenterSettings(configuration: configuration)
        XCTAssertEqual(settings.silhouetteCells, .skirt)
        XCTAssertFalse(settings.rewritesIndices, "the fixed split and the skirt keep the mesh's indices")
        settings.silhouetteCells = .alphaCrossing
        XCTAssertTrue(settings.rewritesIndices, "the crossing drops triangles in the index buffer each frame")
        settings.silhouetteCells = .skirt
        settings.adaptiveDiagonal = true
        XCTAssertTrue(settings.rewritesIndices, "as the adaptive diagonal always did")
        configuration.silhouetteCells = .alphaCrossing
        XCTAssertEqual(XRPresenterSettings(configuration: configuration).silhouetteCells, .alphaCrossing, "the settings start from the configuration")
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

    /// The alpha the kernel's crossing search reads beside the synthetic depth: 1 on the planes,
    /// 0 in the hole, and across the hole's rim a ramp a texel wide (the coverage the engine's
    /// anti-aliasing would leave), so the one-half crossing lies at a sub-texel position.
    private var alphaPipeline: MTLRenderPipelineState?

    private func makeAlphaPipeline() throws -> MTLRenderPipelineState {
        if let alphaPipeline { return alphaPipeline }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        struct Alpha { float holeRadius; float texelsPerUnit; float2 padding; };
        vertex V fullscreenAlpha(uint id [[vertex_id]]) {
            float2 ndc = float2((id == 2) ? 3.0f : -1.0f, (id == 1) ? 3.0f : -1.0f);
            V out; out.position = float4(ndc, 0, 1); out.uv = float2(ndc.x * 0.5f + 0.5f, 1.0f - (ndc.y * 0.5f + 0.5f));
            return out;
        }
        fragment float4 alphas(V in [[stage_in]], constant Alpha &a [[buffer(0)]]) {
            float2 centred = in.uv - 0.5f;
            float alpha = clamp(0.5f + (length(centred) - a.holeRadius) * a.texelsPerUnit, 0.0f, 1.0f);
            return float4(0.2f * alpha, 0.5f * alpha, 0.8f * alpha, alpha);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "fullscreenAlpha")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "alphas")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        alphaPipeline = pipeline
        return pipeline
    }

    /// A colour texture of the presenter's format, for the alpha.
    private func makeAlphaTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Draws the synthetic alpha into `texture`: the ramp across the hole's rim is a texel wide
    /// along the texture's width.
    private func drawAlpha(into texture: MTLTexture) throws {
        let pipeline = try makeAlphaPipeline()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        var alpha = (holeRadius: Self.holeRadius, texelsPerUnit: Float(texture.width), padding: SIMD2<Float>(0, 0))
        encoder.setFragmentBytes(&alpha, length: MemoryLayout.stride(ofValue: alpha), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The alpha texture's texels as the sampler holds them (8-bit, over 255), row by row.
    private func readAlpha(_ texture: MTLTexture) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return (0 ..< texture.width * texture.height).map { Float(bytes[$0 * 4 + 3]) / 255 }
    }

    /// The kernel's alpha search, in Swift, over the alpha read back from the texture: the
    /// filtered alpha (bilinear between texel centres, the edge texel repeated outside) read
    /// every half texel along the line from the edge texel `t` toward the centre `c`, from one
    /// and a half texels inside `t` to one and a half past `c`; the surface must be found (alpha
    /// at or above one half) by half a texel past `t`, the crossing is the first fall below one
    /// half after that, its step halved four times and the crossing interpolated within what is
    /// left. Nil when there is none within reach.
    private func referenceCrossing(edgeTexel t: SIMD2<Float>, centre c: SIMD2<Float>, textureSize: SIMD2<Int>, alpha: [Float]) -> SIMD2<Float>? {
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        func filtered(_ p: SIMD2<Float>) -> Float {
            let fx = min(max(p.x - 0.5, 0), size.x - 1)
            let fy = min(max(p.y - 0.5, 0), size.y - 1)
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, textureSize.x - 1), y1 = min(y0 + 1, textureSize.y - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            func a(_ x: Int, _ y: Int) -> Float { alpha[y * textureSize.x + x] }
            let top = a(x0, y0) * (1 - tx) + a(x1, y0) * tx
            let bottom = a(x0, y1) * (1 - tx) + a(x1, y1) * tx
            return top * (1 - ty) + bottom * ty
        }
        let away = c - t
        let length = simd_length(away)
        guard length > 1e-3 else { return nil }
        let direction = away / length
        let end = length + 1.5
        var s: Float = -1.5
        var previous = filtered(t + s * direction + 0.5)
        var onSurface = previous >= 0.5
        s += 0.5
        while s <= end + 1e-4 {
            let a = filtered(t + s * direction + 0.5)
            if !onSurface {
                if a >= 0.5 {
                    onSurface = true
                } else if s > 0.5 + 1e-4 {
                    return nil
                }
            } else if a < 0.5 {
                var lo = s - 0.5, hi = s, aLo = previous, aHi = a
                for _ in 0 ..< 4 {
                    let mid = 0.5 * (lo + hi)
                    let am = filtered(t + mid * direction + 0.5)
                    if am >= 0.5 { lo = mid; aLo = am } else { hi = mid; aHi = am }
                }
                let f = (aLo - 0.5) / max(aLo - aHi, 1e-6)
                return simd_clamp(t + (lo + f * (hi - lo)) * direction, SIMD2<Float>(0, 0), size - 1)
            }
            previous = a
            s += 0.5
        }
        return nil
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

    /// The scratch of the dispatches for `grid` and a depth of `textureSize`, readable by the test.
    private func makeScratch(grid: XRPresenterGrid, textureSize: SIMD2<Int>) throws -> XRGridUnprojectScratch {
        try XCTUnwrap(XRGridUnprojectScratch(device: device, grid: grid, textureSize: textureSize, options: .storageModeShared, label: "test"))
    }

    /// The block buffer's contents, row by row.
    private func readBlockNearestDepths(_ buffer: MTLBuffer, textureSize: SIMD2<Int>) -> [Float] {
        let count = XRGridUnprojectPass.blockCount(textureSize: textureSize)
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        return (0 ..< count.x * count.y).map { raw.load(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self) }
    }

    /// The third dispatch's rule, in Swift: whether a cell is split along the other diagonal
    /// (top-left to bottom-right), from the first dispatch's entries read along the cell's own
    /// ray: only where the default diagonal crosses a depth jump and the other does not.
    private func referenceSplitsTheOtherWay(column: Int, row: Int, grid: XRPresenterGrid, entries: [(depth: Float, texel: SIMD2<Float>, rim: Bool)], projection: simd_float4x4, tearThreshold: Float) -> Bool {
        let a = row * grid.columns + column, b = a + 1, c = a + grid.columns, d = c + 1
        let centreUV = SIMD2<Float>((Float(column) + 0.5) / Float(grid.columns - 1), (Float(row) + 0.5) / Float(grid.rows - 1))
        let ndc = SIMD2<Float>(centreUV.x * 2 - 1, 1 - centreUV.y * 2)
        let inverseProjection = simd_inverse(projection)
        let ra = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
        let rb = inverseProjection * SIMD4<Float>(0, 0, 1, 0)
        func z(_ index: Int) -> Float {
            let dd = max(entries[index].depth, 1e-6)
            return -(ra.z + dd * rb.z) / (ra.w + dd * rb.w)
        }
        return abs(z(b) - z(c)) > tearThreshold && abs(z(a) - z(d)) <= tearThreshold
    }

    /// An index buffer's contents.
    private func readIndices(_ buffer: MTLBuffer, grid: XRPresenterGrid) -> [UInt32] {
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        return (0 ..< grid.indexCount).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self) }
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
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        // The eye one metre up and half a metre to the right of the origin, looking straight ahead.
        let originFromEye = matrix4x4Translation(0.5, 1, 0)

        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let result = readVertices(vertices, grid: grid)
        let nearest = readNearestDepths(scratch.nearestDepths, grid: grid)
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

    /// With the tears off (`XRRealityKitPresenterConfiguration.tears`), the kernel writes a zero
    /// mask for every vertex and places the vertices exactly as it does with them on: the switch
    /// isolates the tear decision, with the placement and the rims the same.
    func test_withTheTearsOff_theMaskIsZero_andThePlacementIsTheSame() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let pass = try XRGridUnprojectPass(device: device)
        func run(tears: Bool) throws -> (vertices: [Vertex], nearest: [(depth: Float, texel: SIMD2<Float>, rim: Bool)]) {
            // A scratch of its own per run: the placement's hysteresis reads the previous entries.
            let scratch = try makeScratch(grid: grid, textureSize: textureSize)
            let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels, tears: tears)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return (readVertices(vertices, grid: grid), readNearestDepths(scratch.nearestDepths, grid: grid))
        }
        let with = try run(tears: true)
        let without = try run(tears: false)
        XCTAssertGreaterThan(with.vertices.filter { $0.mask > 0.5 || $0.nearSide > 0.5 }.count, 20, "the planes' seam and the hole tear with the tears on")
        XCTAssertGreaterThan(with.nearest.filter(\.rim).count, 10, "rim vertices either way")
        for index in 0 ..< grid.vertexCount {
            let where_ = "vertex \(index % grid.columns),\(index / grid.columns)"
            XCTAssertEqual(without.vertices[index].mask, 0, "no far side with the tears off at \(where_)")
            XCTAssertEqual(without.vertices[index].nearSide, 0, "no near side with the tears off at \(where_)")
            XCTAssertEqual(without.vertices[index].position, with.vertices[index].position, "placed the same at \(where_)")
            XCTAssertEqual(without.vertices[index].uv, with.vertices[index].uv, "the same uv at \(where_)")
            XCTAssertEqual(without.nearest[index].depth, with.nearest[index].depth, "the same depth at \(where_)")
            XCTAssertEqual(without.nearest[index].texel, with.nearest[index].texel, "the same texel at \(where_)")
            XCTAssertEqual(without.nearest[index].rim, with.nearest[index].rim, "the same rim flag at \(where_)")
        }
    }

    /// The alpha-crossing silhouette cells on the two planes and the hole, the alpha texture
    /// beside the depth. The hole is a silhouette against the shell: its rim vertices sit on the
    /// ramp's one-half crossing as the reference's search finds it (to a twentieth of a texel,
    /// the sampler's filter against the reference's arithmetic) at the plane's depth, and are
    /// kind 1; the seam's rim vertices find no crossing (alpha 1 across it) and keep the skirt,
    /// kind 2, placed byte for byte as the skirt rule places them; every other vertex is placed
    /// as under the skirt rule, kind 0, or 3 on the shell. In the core's index buffer no
    /// triangle joins a crossing vertex to the shell (those are degenerate, and in this scene no
    /// kept triangle mixes shell and surface at all), a cell with a crossing vertex and one
    /// shell corner is split so that corner is alone in its triangle, and every other cell is
    /// split as the fixed or adaptive rule says; the band keeps the cells with a rim vertex or a
    /// mask channel but none whose four corners are on the shell, each the core's cell. Under the
    /// skirt rule the colour bound changes no byte.
    func test_withTheAlphaCrossing_theHolesRimSitsOnTheCrossing_theSeamKeepsTheSkirt_andNoTriangleSpansTheShell() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        let size = SIMD2<Float>(Float(textureSize.x), Float(textureSize.y))
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let inverseProjection = simd_inverse(projection)
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let alphaTexture = try makeAlphaTexture(width: textureSize.x, height: textureSize.y)
        try drawAlpha(into: alphaTexture)
        let alpha = try readAlpha(alphaTexture)
        XCTAssertEqual(alpha[12 * textureSize.x + 12], 1, "the planes are opaque")
        XCTAssertEqual(alpha[96 * textureSize.x + 128], 0, "the hole is transparent")
        let originFromEye = matrix4x4Translation(0.5, 1, 0)
        let pass = try XRGridUnprojectPass(device: device)
        let vertexLength = grid.vertexCount * XRPresenterGrid.vertexStride
        let indexLength = grid.indexCount * MemoryLayout<UInt32>.stride

        struct Run {
            let vertices: [Vertex]
            let vertexBytes: [UInt8]
            let entries: [(depth: Float, texel: SIMD2<Float>, rim: Bool)]
            let core: [UInt32]
            let band: [UInt32]
        }
        func run(_ cells: XRPresenterSilhouetteCells, color: MTLTexture?, adaptiveDiagonal: Bool = false) throws -> Run {
            let scratch = try makeScratch(grid: grid, textureSize: textureSize)
            let vertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
            let indices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
            let bandVertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
            let bandIndices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
            memset(bandIndices.contents(), 0xFF, indexLength)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, color: color, scratch: scratch, vertices: vertices, indices: indices, bandVertices: bandVertices, bandIndices: bandIndices, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels, adaptiveDiagonal: adaptiveDiagonal, silhouetteCells: cells)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
            XCTAssertEqual(
                Array(UnsafeRawBufferPointer(start: bandVertices.contents(), count: vertexLength)),
                Array(UnsafeRawBufferPointer(start: vertices.contents(), count: vertexLength)),
                "the band's vertices are the core's bytes"
            )
            return Run(
                vertices: readVertices(vertices, grid: grid),
                vertexBytes: Array(UnsafeRawBufferPointer(start: vertices.contents(), count: vertexLength)),
                entries: readNearestDepths(scratch.nearestDepths, grid: grid),
                core: readIndices(indices, grid: grid),
                band: readIndices(bandIndices, grid: grid)
            )
        }
        let skirt = try run(.skirt, color: nil)
        let skirtWithColour = try run(.skirt, color: alphaTexture)
        XCTAssertEqual(skirtWithColour.vertexBytes, skirt.vertexBytes, "under the skirt rule the colour bound changes no vertex byte")
        XCTAssertEqual(skirtWithColour.core, skirt.core, "nor an index")
        XCTAssertEqual(skirtWithColour.band, skirt.band, "nor a band cell")
        for vertex in skirt.vertices {
            XCTAssertEqual(vertex.uvw.w, 0, "the skirt rule writes no kind")
        }

        for adaptiveDiagonal in [false, true] {
            let crossing = try run(.alphaCrossing, color: alphaTexture, adaptiveDiagonal: adaptiveDiagonal)
            let split = adaptiveDiagonal ? "adaptive" : "fixed"
            var kinds = [Float](repeating: 0, count: grid.vertexCount)
            var crossings = 0, skirts = 0, shells = 0
            var worstCrossingTexels: Float = 0
            for row in 0 ..< grid.rows {
                for column in 0 ..< grid.columns {
                    let index = row * grid.columns + column
                    let where_ = "vertex \(column),\(row) (\(split) split)"
                    let vertex = crossing.vertices[index]
                    let entry = crossing.entries[index]
                    let before = skirt.entries[index]
                    XCTAssertEqual(entry.depth, before.depth, "the entries are the skirt rule's at \(where_)")
                    XCTAssertEqual(entry.texel, before.texel, "the entries are the skirt rule's at \(where_)")
                    XCTAssertEqual(entry.rim, before.rim, "the entries are the skirt rule's at \(where_)")
                    let kind = vertex.uvw.w
                    kinds[index] = kind
                    let centre = referenceCentre(column: column, row: row, grid: grid, textureSize: textureSize, map: nil)
                    let onShell = entry.depth <= 0 || simd_length(referenceEyePoint(uv: uvOfTexel(entry.texel, textureSize: textureSize), depth: entry.depth, inverseProjection: inverseProjection, farShell: 1e9)) > configuration.farShellMetres
                    let reference = entry.rim && !onShell ? referenceCrossing(edgeTexel: entry.texel, centre: centre, textureSize: textureSize, alpha: alpha) : nil
                    let expectedKind: Float = onShell ? 3 : (entry.rim ? (reference != nil ? 1 : 2) : 0)
                    XCTAssertEqual(kind, expectedKind, "the kind of \(where_)")
                    if let reference, kind == 1 {
                        crossings += 1
                        // On the crossing, within a twentieth of a texel of the reference's.
                        let placed = vertex.uv * (size - 1)
                        let off = simd_length(placed - reference)
                        worstCrossingTexels = max(worstCrossingTexels, off)
                        XCTAssertLessThan(off, 0.05, "\(where_) sits on the alpha crossing (\(placed) against \(reference))")
                        // At the surface's depth: the covered texel half a texel inside the
                        // crossing when it lies within the threshold of the edge texel's depth
                        // along this vertex's ray, else the edge texel's.
                        var ownDepth = entry.depth
                        let inward = entry.texel - reference
                        if simd_length(inward) > 1e-3 {
                            let covered = simd_clamp((reference + inward * (0.5 / simd_length(inward))).rounded(.toNearestOrAwayFromZero), SIMD2<Float>(0, 0), size - 1)
                            let coveredDepth = syntheticDepth(texel: SIMD2<Int>(Int(covered.x), Int(covered.y)), textureSize: textureSize, projection: projection)
                            let ndc = referenceNDC(ofTexel: centre, textureSize: textureSize, map: nil)
                            let ra = inverseProjection * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
                            let rb = inverseProjection * SIMD4<Float>(0, 0, 1, 0)
                            func zInFront(_ d: Float) -> Float {
                                let dd = max(d, 1e-6)
                                return -(ra.z + dd * rb.z) / (ra.w + dd * rb.w)
                            }
                            if coveredDepth > 0, abs(zInFront(coveredDepth) - zInFront(entry.depth)) <= configuration.tearThresholdMetres {
                                ownDepth = coveredDepth
                            }
                        }
                        XCTAssertEqual(vertex.uvw.z, -simd_mul(simd_inverse(originFromEye), SIMD4<Float>(vertex.position, 1)).z, accuracy: 1e-3, "the projective depth is the vertex's at \(where_)")
                        let eye = referenceEyePoint(uv: uvOfTexel(reference, textureSize: textureSize), depth: ownDepth, inverseProjection: inverseProjection, farShell: configuration.farShellMetres)
                        let expected = originFromEye * SIMD4<Float>(eye, 1)
                        XCTAssertEqual(vertex.position.x, expected.x, accuracy: 0.002, "x of \(where_), on the crossing at the plane's depth")
                        XCTAssertEqual(vertex.position.y, expected.y, accuracy: 0.002, "y of \(where_)")
                        XCTAssertEqual(vertex.position.z, expected.z, accuracy: 0.002, "z of \(where_)")
                        let onAPlane = abs(-eye.z - Self.nearPlaneDistance) < 0.01 || abs(-eye.z - Self.farPlaneDistance) < 0.02
                        XCTAssertTrue(onAPlane, "\(where_) lies at the depth of the plane the hole is cut in (\(-eye.z) m)")
                    } else {
                        if kind == 2 { skirts += 1 }
                        if kind == 3 { shells += 1 }
                        // Everything but the kind as the skirt rule left it: the same arithmetic in
                        // the kernel's other specialization, to the rounding the compiler's fused
                        // multiplies move (a few units in the last place).
                        let before = skirt.vertices[index]
                        XCTAssertEqual(simd_length(vertex.position - before.position), 0, accuracy: 2e-6 * max(1, simd_length(before.position)), "placed as under the skirt rule at \(where_)")
                        XCTAssertEqual(simd_length(vertex.uv - before.uv), 0, accuracy: 1e-6, "the skirt rule's uv at \(where_)")
                        XCTAssertEqual(vertex.mask, before.mask, "the skirt rule's mask at \(where_)")
                        XCTAssertEqual(vertex.nearSide, before.nearSide, "the skirt rule's mask at \(where_)")
                        let uvw = SIMD3<Float>(vertex.uvw.x, vertex.uvw.y, vertex.uvw.z), uvwBefore = SIMD3<Float>(before.uvw.x, before.uvw.y, before.uvw.z)
                        XCTAssertEqual(simd_length(uvw - uvwBefore), 0, accuracy: 2e-6 * max(1, simd_length(uvwBefore)), "the skirt rule's projective uv at \(where_)")
                    }
                }
            }
            print("XR presenter silhouette cells (\(split) split): \(crossings) crossing vertices around the hole (the worst \(String(format: "%.3f", worstCrossingTexels)) texel from the reference's), \(skirts) skirt vertices along the seam, \(shells) on the shell")
            XCTAssertGreaterThan(crossings, 10, "the hole's rim vertices sit on the crossing")
            XCTAssertGreaterThan(skirts, 10, "the seam's rim vertices keep the skirt")
            XCTAssertGreaterThan(shells, 20, "the hole sees the shell")

            /// The core's triangles, from the kinds pass 2 wrote: on the shell, on the crossing.
            func isShell(_ i: UInt32) -> Bool { kinds[Int(i)] == 3 }
            func isCrossing(_ i: UInt32) -> Bool { kinds[Int(i)] == 1 }
            func spansTheShell(_ i: UInt32, _ j: UInt32, _ k: UInt32) -> Bool {
                (isShell(i) || isShell(j) || isShell(k)) && (isCrossing(i) || isCrossing(j) || isCrossing(k))
            }
            var degenerate = 0, singleShellCells = 0
            for row in 0 ..< grid.rows - 1 {
                for column in 0 ..< grid.columns - 1 {
                    let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                    let cell = (row * (grid.columns - 1) + column) * 6
                    let written = Array(crossing.core[cell ..< cell + 6])
                    let where_ = "cell \(column),\(row) (\(split) split)"
                    let shellCorners = [a, b, c, d].filter(isShell).count
                    let hasCrossing = [a, b, c, d].contains(where: isCrossing)
                    let otherWay: Bool
                    if hasCrossing, shellCorners == 1 {
                        singleShellCells += 1
                        otherWay = isShell(b) || isShell(c)
                    } else {
                        otherWay = adaptiveDiagonal && referenceSplitsTheOtherWay(column: column, row: row, grid: grid, entries: crossing.entries, projection: projection, tearThreshold: configuration.tearThresholdMetres)
                    }
                    let triangles: [[UInt32]] = otherWay ? [[a, c, d], [a, d, b]] : [[a, c, b], [b, c, d]]
                    var expected: [UInt32] = []
                    for triangle in triangles {
                        if spansTheShell(triangle[0], triangle[1], triangle[2]) {
                            degenerate += 1
                            expected += [triangle[0], triangle[0], triangle[0]]
                        } else {
                            expected += triangle
                            let shell = triangle.filter(isShell).count
                            XCTAssertTrue(shell == 0 || shell == 3, "a kept triangle of \(where_) lies on the shell or off it, never across")
                        }
                    }
                    XCTAssertEqual(written, expected, "the core's \(where_)")
                    // The band: the cells along an edge that are not all shell, each the core's.
                    let along = [a, b, c, d].contains { i in
                        crossing.entries[Int(i)].rim || crossing.vertices[Int(i)].mask > 0 || crossing.vertices[Int(i)].nearSide > 0
                    }
                    let allShell = shellCorners == 4
                    let band = Array(crossing.band[cell ..< cell + 6])
                    if along, !allShell {
                        XCTAssertEqual(band, written, "the band's \(where_) is the core's")
                    } else {
                        XCTAssertEqual(band, [UInt32](repeating: a, count: 6), "the band's \(where_) is degenerate")
                    }
                }
            }
            print("XR presenter silhouette cells (\(split) split): \(degenerate) triangles from the hole's rim to the shell written degenerate, \(singleShellCells) cells with one shell corner split around it")
            XCTAssertGreaterThan(degenerate, 20, "the triangles from the crossing vertices to the shell are gone")
            XCTAssertGreaterThan(singleShellCells, 4, "cells with one shell corner occur around the hole")
            // The hole's centre: the core keeps the shell there, the band draws nothing.
            let centreCell = (12 * (grid.columns - 1) + 16) * 6
            XCTAssertEqual(Set(crossing.core[centreCell ..< centreCell + 6]).count, 4, "the core keeps the shell at the hole's centre")
            XCTAssertEqual(Set(crossing.band[centreCell ..< centreCell + 6]).count, 1, "the band has nothing at the hole's centre")
        }
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
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
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
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let nearest = readNearestDepths(scratch.nearestDepths, grid: grid)
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
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let indices = try XCTUnwrap(device.makeBuffer(length: grid.indexCount * MemoryLayout<UInt32>.stride, options: .storageModeShared))

        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, indices: indices, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let entries = readNearestDepths(scratch.nearestDepths, grid: grid)
        let written = readIndices(indices, grid: grid)
        var fixedSplits = 0, otherSplits = 0, rimFixed = 0, rimOther = 0
        for row in 0 ..< grid.rows - 1 {
            for column in 0 ..< grid.columns - 1 {
                let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                let centreUV = SIMD2<Float>((Float(column) + 0.5) / Float(grid.columns - 1), (Float(row) + 0.5) / Float(grid.rows - 1))
                let other = referenceSplitsTheOtherWay(column: column, row: row, grid: grid, entries: entries, projection: projection, tearThreshold: configuration.tearThresholdMetres)
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

    /// The edge band's mesh on the two planes and the hole: its vertices are the core's bytes,
    /// and its index buffer keeps a cell's two triangles, split as the core's are, when one of
    /// the cell's four vertices is a rim vertex or carries a tear-mask channel, and makes the
    /// cell six copies of one index otherwise. So the cells along the planes' seam and around
    /// the hole's rim are kept, the cells inside the planes, inside the hole and on the shell
    /// are degenerate, and the kept cells are a small part of the grid; with the fixed diagonal
    /// the same cells are kept, each with the fixed split.
    func test_theBand_keepsTheCellsAlongTheSeamAndTheHolesRim_andDropsTheRest() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertexLength = grid.vertexCount * XRPresenterGrid.vertexStride
        let indexLength = grid.indexCount * MemoryLayout<UInt32>.stride
        let vertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
        let indices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
        let bandVertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
        let bandIndices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
        // Filled with ones first, so that a vertex or a cell the kernel left alone would show.
        memset(bandVertices.contents(), 0xFF, vertexLength)
        memset(bandIndices.contents(), 0xFF, indexLength)
        let pass = try XRGridUnprojectPass(device: device)
        func run(adaptiveDiagonal: Bool) throws {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, indices: indices, bandVertices: bandVertices, bandIndices: bandIndices, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels, adaptiveDiagonal: adaptiveDiagonal)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
        }
        try run(adaptiveDiagonal: true)

        XCTAssertEqual(
            Array(UnsafeRawBufferPointer(start: bandVertices.contents(), count: vertexLength)),
            Array(UnsafeRawBufferPointer(start: vertices.contents(), count: vertexLength)),
            "the band's vertices are the core's bytes"
        )
        let entries = readNearestDepths(scratch.nearestDepths, grid: grid)
        let result = readVertices(vertices, grid: grid)
        let core = readIndices(indices, grid: grid)
        let band = readIndices(bandIndices, grid: grid)
        func alongAnEdge(_ index: UInt32) -> Bool {
            entries[Int(index)].rim || result[Int(index)].mask > 0 || result[Int(index)].nearSide > 0
        }
        func cellStart(_ column: Int, _ row: Int) -> Int { (row * (grid.columns - 1) + column) * 6 }
        func isKept(_ column: Int, _ row: Int, in indices: [UInt32]) -> Bool {
            let cell = cellStart(column, row)
            return Set(indices[cell ..< cell + 6]).count > 1
        }
        var kept = 0
        for row in 0 ..< grid.rows - 1 {
            for column in 0 ..< grid.columns - 1 {
                let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                let cell = cellStart(column, row)
                let written = Array(band[cell ..< cell + 6])
                if [a, b, c, d].contains(where: alongAnEdge) {
                    kept += 1
                    let other = referenceSplitsTheOtherWay(column: column, row: row, grid: grid, entries: entries, projection: projection, tearThreshold: configuration.tearThresholdMetres)
                    let expected: [UInt32] = other ? [a, c, d, a, d, b] : [a, c, b, b, c, d]
                    XCTAssertEqual(written, expected, "cell \(column),\(row), along an edge, keeps its two triangles split as the core's")
                    XCTAssertEqual(written, Array(core[cell ..< cell + 6]), "the band's cell \(column),\(row) is the core's cell")
                } else {
                    XCTAssertEqual(written, [UInt32](repeating: a, count: 6), "cell \(column),\(row), away from every edge, is degenerate")
                }
            }
        }
        // Where the kept cells are: the three cell columns whose corners are the seam's two
        // vertex columns (16 the near side, 17 the far side), on rows away from the hole, and
        // no cell further out; all around the hole's rim; nothing deep inside a plane or the
        // hole, nor at the grid's corners.
        for row in [1, 2, 20, 22] {
            for column in 15 ... 17 {
                XCTAssertTrue(isKept(column, row, in: band), "cell \(column),\(row) at the seam is kept")
            }
            XCTAssertFalse(isKept(14, row, in: band), "cell 14,\(row), a cell before the seam, is degenerate")
            XCTAssertFalse(isKept(18, row, in: band), "cell 18,\(row), a cell past the seam, is degenerate")
        }
        for step in 0 ..< 16 {
            let angle = Float(step) / 16 * 2 * .pi
            let rim = SIMD2<Float>(0.5 + Self.holeRadius * cos(angle), 0.5 + Self.holeRadius * sin(angle))
            let column = min(Int(rim.x * Float(grid.columns - 1)), grid.columns - 2)
            let row = min(Int(rim.y * Float(grid.rows - 1)), grid.rows - 2)
            XCTAssertTrue(isKept(column, row, in: band), "cell \(column),\(row) on the hole's rim is kept")
        }
        for (column, row) in [(3, 12), (6, 3), (28, 5), (26, 20), (16, 12), (0, 0), (31, 23)] {
            XCTAssertFalse(isKept(column, row, in: band), "cell \(column),\(row), inside a plane, inside the hole or at a corner, is degenerate")
        }
        let cells = (grid.columns - 1) * (grid.rows - 1)
        print("XR presenter edge band: \(kept) of \(cells) cells kept on the two planes and the hole (\(String(format: "%.1f", Double(kept) / Double(cells) * 100)) %)")
        XCTAssertGreaterThan(kept, 60, "the seam and the hole's rim keep cells")
        XCTAssertLessThan(kept, cells / 3, "the band keeps a small part of the grid")

        // The fixed diagonal: the same cells kept, each with the fixed split.
        try run(adaptiveDiagonal: false)
        let fixedBand = readIndices(bandIndices, grid: grid)
        var keptAgain = 0
        for row in 0 ..< grid.rows - 1 {
            for column in 0 ..< grid.columns - 1 {
                let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                let cell = cellStart(column, row)
                let written = Array(fixedBand[cell ..< cell + 6])
                if isKept(column, row, in: band) {
                    keptAgain += 1
                    XCTAssertEqual(written, [a, c, b, b, c, d], "cell \(column),\(row) is kept with the fixed split")
                } else {
                    XCTAssertEqual(written, [UInt32](repeating: a, count: 6), "cell \(column),\(row) is degenerate as before")
                }
            }
        }
        XCTAssertEqual(keptAgain, kept, "the fixed diagonal keeps the same cells")
    }

    /// The block dispatch on a depth whose size is no multiple of the block: a depth of 37 × 29
    /// texels with a value of its own at every texel, so that a block's nearest depth is
    /// exactly one texel's and a block read one texel wide of its bounds, or one short, shows.
    /// Every block's entry is the largest depth of the texels it covers, the blocks of the last
    /// column and row covering the texels left there alone.
    func test_theBlockDispatch_writesEachBlocksNearestDepth_theEdgeBlocksCutToTheTexture() throws {
        let textureSize = SIMD2<Int>(37, 29)
        let grid = XRPresenterGrid(columns: 5, rows: 4)
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let count = XRGridUnprojectPass.blockCount(textureSize: textureSize)
        XCTAssertEqual(count, SIMD2<Int>(5, 4), "five blocks of eight cover 37 texels, four cover 29")
        XCTAssertEqual(XRGridUnprojectPass.blockCount(textureSize: [1920, 1824]), SIMD2<Int>(240, 228))
        XCTAssertEqual(XRGridUnprojectPass.blockCount(textureSize: [256, 192]), SIMD2<Int>(32, 24))
        XCTAssertEqual(scratch.blockNearestDepths.length, 20 * MemoryLayout<Float>.stride)
        XCTAssertEqual(scratch.scanList.length, XRGridUnprojectPass.scanListHeaderLength + grid.vertexCount * MemoryLayout<UInt32>.stride)
        func depthOf(_ x: Int, _ y: Int) -> Float {
            // A depth of its own per texel, in (0.05, 0.95), scattered so neighbours differ.
            0.05 + 0.9 * Float((x * 7919 + y * 104_729 + x * y * 31) % 1009) / 1008
        }
        var depths = [Float](repeating: 0, count: textureSize.x * textureSize.y)
        for y in 0 ..< textureSize.y {
            for x in 0 ..< textureSize.x {
                depths[y * textureSize.x + x] = depthOf(x, y)
            }
        }
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepths(depths, into: depthTexture)
        let configuration = XRRealityKitPresenterConfiguration()
        memset(scratch.blockNearestDepths.contents(), 0xFF, scratch.blockNearestDepths.length)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, originFromEye: matrix_identity_float4x4, projection: configuration.projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let blocks = readBlockNearestDepths(scratch.blockNearestDepths, textureSize: textureSize)
        for blockRow in 0 ..< count.y {
            for blockColumn in 0 ..< count.x {
                var expected: Float = 0
                for y in blockRow * 8 ..< min(blockRow * 8 + 8, textureSize.y) {
                    for x in blockColumn * 8 ..< min(blockColumn * 8 + 8, textureSize.x) {
                        expected = max(expected, depthOf(x, y))
                    }
                }
                XCTAssertEqual(blocks[blockRow * count.x + blockColumn], expected, "block \(blockColumn),\(blockRow) holds the nearest depth of its texels")
            }
        }
        // The last column of blocks covers five texels, the last row five: cut, not read past.
        XCTAssertEqual(blocks[4], (0 ..< 8).flatMap { y in (32 ..< 37).map { x in depthOf(x, y) } }.max())
        XCTAssertEqual(blocks[3 * count.x], (24 ..< 29).flatMap { y in (0 ..< 8).map { x in depthOf(x, y) } }.max())
    }

    /// The fast path of the nearest-depth dispatch against the scan, on the two planes and the
    /// hole: two frames, the first with a one-texel line a texel off a vertex column (which
    /// pulls that column's vertices onto the line), the second without it (where the hysteresis
    /// keeps them on the line's texel), each run twice from the same previous entries, once
    /// with the fast path and once with every vertex scanned (flag bit 1). The entries, the
    /// vertices, the core's indices and the band's are the same bytes either way, the
    /// hysteresis included; and on the second frame most vertices, those on a plane or deep in
    /// the hole, take the fast path, while the ones within two blocks of the seam and the hole's
    /// rim scan.
    func test_theFastPath_settlesMostVerticesOnThePlanes_andWritesTheScansBytes() throws {
        let grid = XRPresenterGrid(columns: 33, rows: 25)
        let textureSize = SIMD2<Int>(256, 192)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.farShellMetres = 50
        configuration.tearThresholdMetres = 0.9
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertexLength = grid.vertexCount * XRPresenterGrid.vertexStride
        let indexLength = grid.indexCount * MemoryLayout<UInt32>.stride
        let vertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
        let indices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
        let bandVertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModeShared))
        let bandIndices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModeShared))
        let pass = try XRGridUnprojectPass(device: device)
        struct Frame {
            var entries: [UInt8]
            var vertices: [UInt8]
            var indices: [UInt8]
            var band: [UInt8]
            var fast: Int
            var scanned: Int
        }
        func run(fastPath: Bool, previousEntries: [UInt8]) throws -> Frame {
            let nearestDepths = scratch.nearestDepths
            previousEntries.withUnsafeBytes { nearestDepths.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            // The list filled with ones first, so that a frame that left it alone would show.
            memset(scratch.scanList.contents(), 0xFF, scratch.scanList.length)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, indices: indices, bandVertices: bandVertices, bandIndices: bandIndices, originFromEye: matrix4x4Translation(0.5, 1, 0), projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels, fastPath: fastPath)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed)
            let scanned = scratch.scannedVertexCount
            // The listed vertices are distinct and within the grid.
            let list = UnsafeRawBufferPointer(start: scratch.scanList.contents() + XRGridUnprojectPass.scanListHeaderLength, count: grid.vertexCount * MemoryLayout<UInt32>.stride)
            let listed = (0 ..< min(scanned, grid.vertexCount)).map { Int(list.load(fromByteOffset: $0 * MemoryLayout<UInt32>.stride, as: UInt32.self)) }
            XCTAssertEqual(Set(listed).count, listed.count, "each listed vertex once")
            XCTAssertNil(listed.first { $0 >= grid.vertexCount }, "every listed vertex is in the grid")
            return Frame(
                entries: Array(UnsafeRawBufferPointer(start: nearestDepths.contents(), count: nearestDepths.length)),
                vertices: Array(UnsafeRawBufferPointer(start: vertices.contents(), count: vertexLength)),
                indices: Array(UnsafeRawBufferPointer(start: indices.contents(), count: indexLength)),
                band: Array(UnsafeRawBufferPointer(start: bandIndices.contents(), count: indexLength)),
                fast: grid.vertexCount - scanned,
                scanned: scanned
            )
        }
        func assertSameBytes(_ fast: Frame, _ scan: Frame, _ frame: String) {
            XCTAssertEqual(fast.entries, scan.entries, "\(frame): the fast path writes the scan's entries, byte for byte")
            XCTAssertEqual(fast.vertices, scan.vertices, "\(frame): the vertices")
            XCTAssertEqual(fast.indices, scan.indices, "\(frame): the core's indices")
            XCTAssertEqual(fast.band, scan.band, "\(frame): the band's indices")
            XCTAssertEqual(scan.fast, 0, "\(frame): the flag sends every vertex to the scan")
            XCTAssertEqual(scan.scanned, grid.vertexCount)
        }

        // Frame one: a vertical line a metre ahead at texel column 97, a texel past the centre
        // texel (96) of vertex column 12, whose vertices land on it. The entries start as
        // zeros: no previous frame.
        let lineDistance: Float = 1
        try drawDepth(into: depthTexture, projection: projection, line: Line(column: 97, depth: depth(ofDistance: lineDistance, projection: projection)))
        let none = [UInt8](repeating: 0, count: scratch.nearestDepths.length)
        let fastFirst = try run(fastPath: true, previousEntries: none)
        let scanFirst = try run(fastPath: false, previousEntries: none)
        assertSameBytes(fastFirst, scanFirst, "the frame with the line")
        let firstEntries = readNearestDepths(scratch.nearestDepths, grid: grid)
        for row in 0 ..< grid.rows {
            XCTAssertEqual(firstEntries[row * grid.columns + 12].texel.x, 97, "vertex 12,\(row) lands on the line")
        }

        // Frame two: the line gone, the previous entries frame one's. The hysteresis keeps
        // vertex column 12 on texel 97 (within a texel of its centre texel, and on the near
        // plane now), through the fast path as through the scan.
        try drawDepth(into: depthTexture, projection: projection)
        let fastSecond = try run(fastPath: true, previousEntries: fastFirst.entries)
        let scanSecond = try run(fastPath: false, previousEntries: fastFirst.entries)
        assertSameBytes(fastSecond, scanSecond, "the frame after the line")
        let secondEntries = readNearestDepths(scratch.nearestDepths, grid: grid)
        let nearDepth = depth(ofDistance: Self.nearPlaneDistance, projection: projection)
        var keptOnTheLinesTexel = 0
        for row in 0 ..< grid.rows {
            let entry = secondEntries[row * grid.columns + 12]
            if entry.texel.x == 97, abs(entry.depth - nearDepth) < 1e-6 { keptOnTheLinesTexel += 1 }
        }
        XCTAssertGreaterThan(keptOnTheLinesTexel, 15, "the hysteresis keeps vertex column 12 on the line's texel, at the near plane's depth, away from the hole")
        // A third frame from the second's entries: the same bytes still, and the same count.
        let fastThird = try run(fastPath: true, previousEntries: fastSecond.entries)
        let scanThird = try run(fastPath: false, previousEntries: fastSecond.entries)
        assertSameBytes(fastThird, scanThird, "a steady frame")
        XCTAssertEqual(fastThird.fast, fastSecond.fast)

        // Most vertices take the fast path: the planes and the hole's middle. The scan is kept
        // for the vertices whose blocks reach across the seam or the hole's rim: with blocks of
        // 8 texels, those within about two blocks of either.
        let fraction = Double(fastSecond.fast) / Double(grid.vertexCount)
        print("XR presenter fast path: \(fastSecond.fast) of \(grid.vertexCount) vertices settled from the blocks on the two planes and the hole (\(String(format: "%.1f", fraction * 100)) %), \(fastSecond.scanned) scanned")
        XCTAssertGreaterThan(fraction, 0.6, "most vertices sit on a plane or deep in the hole")
        XCTAssertGreaterThan(fastSecond.scanned, 50, "the seam's and the rim's vertices scan")
    }

    /// The kernels' GPU time at the headset's size: the two planes and the hole drawn at
    /// 1920 × 1824, the 256 × 240 grid, the edge band on and the fixed diagonal, as the headset
    /// runs them; each frame a command buffer of its own holding the unprojection alone, timed by
    /// the command buffer's GPU timestamps over 60 frames after four of warm-up, with the fast
    /// path and with every vertex scanned (the dispatches as they were before the blocks, plus
    /// the block dispatch). A measurement, printed: it asserts only that the frames complete and
    /// that the fast path settles most of this scene's vertices. The Mac's milliseconds are not
    /// the headset's, but a change's ratio carries over.
    func test_theKernels_atTheHeadsetsSize_timedByGPUTimestamps() throws {
        let configuration = XRRealityKitPresenterConfiguration()
        let grid = XRPresenterGrid(columns: configuration.gridColumns, rows: configuration.gridRows)
        let textureSize = configuration.textureSize
        let projection = configuration.projection
        let depthTexture = try makeDepthTexture(width: textureSize.x, height: textureSize.y)
        try drawDepth(into: depthTexture, projection: projection)
        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertexLength = grid.vertexCount * XRPresenterGrid.vertexStride
        let indexLength = grid.indexCount * MemoryLayout<UInt32>.stride
        let vertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModePrivate))
        let bandVertices = try XCTUnwrap(device.makeBuffer(length: vertexLength, options: .storageModePrivate))
        let bandIndices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModePrivate))
        let indices = try XCTUnwrap(device.makeBuffer(length: indexLength, options: .storageModePrivate))
        let alphaTexture = try makeAlphaTexture(width: textureSize.x, height: textureSize.y)
        try drawAlpha(into: alphaTexture)
        let pass = try XRGridUnprojectPass(device: device)
        func time(fastPath: Bool, cells: XRPresenterSilhouetteCells = .skirt, triangulate: Bool = false) throws -> (median: Double, mean: Double, min: Double) {
            var milliseconds: [Double] = []
            for frame in 0 ..< 64 {
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                pass.encode(commandBuffer: commandBuffer, depth: depthTexture, color: alphaTexture, scratch: scratch, vertices: vertices, indices: triangulate ? indices : nil, bandVertices: bandVertices, bandIndices: bandIndices, originFromEye: matrix_identity_float4x4, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: configuration.skirtTexels, adaptiveDiagonal: false, fastPath: fastPath, silhouetteCells: cells)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                XCTAssertEqual(commandBuffer.status, .completed)
                if frame >= 4 { milliseconds.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000) }
            }
            milliseconds.sort()
            return (milliseconds[milliseconds.count / 2], milliseconds.reduce(0, +) / Double(milliseconds.count), milliseconds[0])
        }
        let scanned = try time(fastPath: false)
        let fast = try time(fastPath: true)
        // How many of the headset-sized grid's vertices the blocks settled on the last frame.
        let settled = grid.vertexCount - scratch.scannedVertexCount
        // The index buffer rewritten each frame (as under the adaptive diagonal), under the
        // skirt and under the alpha crossing, which reads the colour for the rim vertices and
        // the kinds for the triangles.
        let fastTriangulated = try time(fastPath: true, triangulate: true)
        let crossing = try time(fastPath: true, cells: .alphaCrossing, triangulate: true)
        func format(_ t: (median: Double, mean: Double, min: Double)) -> String {
            String(format: "median %.3f ms, mean %.3f ms, min %.3f ms", t.median, t.mean, t.min)
        }
        print("XR presenter kernels at \(textureSize.x)×\(textureSize.y), grid \(grid.columns)×\(grid.rows), 60 frames on \(device.name): every vertex scanned \(format(scanned)); fast path \(format(fast)); \(settled) of \(grid.vertexCount) vertices settled from the blocks (\(String(format: "%.1f", Double(settled) / Double(grid.vertexCount) * 100)) %); with the index buffer rewritten: skirt \(format(fastTriangulated)), alpha crossing \(format(crossing))")
        XCTAssertGreaterThan(Double(settled) / Double(grid.vertexCount), 0.8, "at the headset's size most of the two planes' vertices are settled from the blocks")
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

    /// The grid's cell under a render scale: the configured cell times the scale when that
    /// divides the tile, else the tile's divisor nearest in ratio; what divides is taken as it
    /// is, so scale 1 keeps today's cell.
    func test_theFoveatedCell_scalesWithTheRenderScale_andSnapsToTheTilesDivisors() {
        func cell(_ texels: Int, scale: Float, granularity: Int = 32) -> Int? {
            var configuration = XRRealityKitPresenterConfiguration()
            configuration.foveatedCellTexels = texels
            configuration.renderScale = scale
            return XRPresenterFoveation.cellTexels(for: configuration, granularity: [granularity, granularity])
        }
        XCTAssertEqual(cell(8, scale: 1), 8, "the shipped cell at scale 1")
        XCTAssertEqual(cell(4, scale: 1), 4)
        XCTAssertEqual(cell(16, scale: 1), 16)
        XCTAssertEqual(cell(8, scale: 2), 16, "twice the texels, twice the cell: the grid's count stays")
        XCTAssertEqual(cell(8, scale: 0.5), 4)
        XCTAssertEqual(cell(8, scale: 1.5), 16, "12 texels divide no 32-texel tile: 16 is nearer in ratio (1.33) than 8 (1.5)")
        XCTAssertEqual(cell(4, scale: 1.5), 8, "6 snaps to 8 (1.33) rather than 4 (1.5): the denser grid at 1.5 is a cell of 4")
        XCTAssertEqual(cell(8, scale: 1.25), 8, "10 snaps to 8 (1.25) rather than 16 (1.6)")
        XCTAssertEqual(cell(6, scale: 1), 8, "a configured cell that does not divide snaps too")
        XCTAssertEqual(cell(1, scale: 1), 2, "two texels at least")
        XCTAssertEqual(cell(8, scale: 1, granularity: 4), 4, "a tile of 4: the cell within it")
        XCTAssertEqual(cell(8, scale: 1, granularity: 16), 8)
        XCTAssertNil(cell(8, scale: 1, granularity: 1), "a tile of one texel has no cell")
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.renderScale = 1.5
        XCTAssertEqual(XRPresenterFoveation.cellTexels(for: configuration, granularity: [32, 16]), 16, "along both axes")
        XCTAssertEqual(XRPresenterFoveation.cellTexels(for: configuration, granularity: [32, 8]), 8)
    }

    /// The shipped map at a render scale of 1.5: the budget is the scaled size, the screen
    /// grows with it (so the centre of view gains the scale), the texels per degree at the
    /// centre are 1.5 times the map's at scale 1, and the grid keeps about its vertex count
    /// instead of growing with the texels (the cell snapped to the tile).
    func test_theShippedMap_atARenderScale_growsItsScreenWithTheBudget_andKeepsTheGridsCount() throws {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.foveation = .equiAngular
        let plain = try makeFoveation(configuration)
        configuration.renderScale = 1.5
        let scaled = try makeFoveation(configuration)
        print("XR presenter rate map at a render scale of 1.5 on this Mac: \(scaled)")

        XCTAssertEqual(scaled.budget, SIMD2<Int>(2880, 2736), "the budget is the scaled size")
        XCTAssertEqual(configuration.renderedTextureSize, scaled.budget)
        XCTAssertLessThanOrEqual(scaled.physicalSize.x, 2880, "within the budget")
        XCTAssertLessThanOrEqual(scaled.physicalSize.y, 2736)
        XCTAssertGreaterThan(scaled.physicalSize.x * scaled.physicalSize.y, Int(0.9 * 2880.0 * 2736.0), "and nearly all of it")
        XCTAssertEqual(Float(scaled.screenSize.x) / Float(plain.screenSize.x), 1.5, accuracy: 0.03, "the screen grows with the budget: \(scaled.screenSize) against \(plain.screenSize)")
        XCTAssertEqual(Float(scaled.screenSize.y) / Float(plain.screenSize.y), 1.5, accuracy: 0.03)
        XCTAssertEqual(scaled.screenScale.x, plain.screenScale.x, accuracy: 0.03, "the same profile over the budget")
        let tangents = configuration.frustumTangents
        XCTAssertEqual(scaled.centreTexelsPerDegree(tangents: tangents) / plain.centreTexelsPerDegree(tangents: tangents), 1.5, accuracy: 0.03, "1.5 times the texels per degree at the centre of view")
        XCTAssertGreaterThan(plain.centreTexelsPerDegree(tangents: tangents), configuration.centreTexelsPerDegree / 1.5 * 1.25, "the map's centre is denser than the uniform frame's")
        XCTAssertEqual(scaled.frame.viewport.width, Double(scaled.screenSize.x), "the eyes' viewport is the scaled screen")
        XCTAssertEqual(scaled.rateMapData.physicalSize, SIMD2<Float>(Float(scaled.physicalSize.x), Float(scaled.physicalSize.y)))

        XCTAssertEqual(scaled.granularity, plain.granularity, "the tile is the GPU's")
        XCTAssertEqual(scaled.cellTexels, try XCTUnwrap(XRPresenterFoveation.cellTexels(for: configuration, granularity: scaled.granularity)))
        XCTAssertEqual(scaled.granularity.x % scaled.cellTexels, 0, "the cell divides the tile")
        if scaled.granularity == [32, 32] {
            XCTAssertEqual(plain.cellTexels, 8)
            XCTAssertEqual(scaled.cellTexels, 16, "8 × 1.5 snapped to the tile's divisor nearest in ratio")
        }
        XCTAssertEqual(scaled.grid.columns, (scaled.physicalSize.x + scaled.cellTexels - 1) / scaled.cellTexels + 1)
        XCTAssertLessThanOrEqual(scaled.grid.vertexCount, plain.grid.vertexCount, "the grid does not grow with the texels: \(scaled.grid) against \(plain.grid)")
        XCTAssertGreaterThan(scaled.grid.vertexCount, plain.grid.vertexCount / 3, "nor does it collapse")
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

        let scratch = try makeScratch(grid: grid, textureSize: textureSize)
        let vertices = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * XRPresenterGrid.vertexStride, options: .storageModeShared))
        let originFromEye = matrix4x4Translation(0.5, 1, 0)
        let pass = try XRGridUnprojectPass(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        pass.encode(commandBuffer: commandBuffer, depth: depthTexture, scratch: scratch, vertices: vertices, originFromEye: originFromEye, projection: projection, farShell: configuration.farShellMetres, tearThreshold: configuration.tearThresholdMetres, skirtTexels: 0, rateMapData: foveation.rateMapData, cellTexels: Float(foveation.cellTexels))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let result = readVertices(vertices, grid: grid)
        let nearest = readNearestDepths(scratch.nearestDepths, grid: grid)
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

    /// The blended core's graph: the band's parameters, its depth write on, both faces drawn.
    /// (`writesDepth` reads true on every shader graph material as loaded, the band's too; the
    /// blended core sets it all the same, and the box test below says what the depth does.)
    func test_theBlendedGraph_loadsWithTheSameParameters_andWritesDepth() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("shader graph materials need macOS 15") }
        let url = try XCTUnwrap(XRPresenterMaterial.resourceURL(XRPresenterMaterial.blendedResourceName), "the graph is in the target's resource bundle")
        XCTAssertEqual(url.lastPathComponent, "XRPresenterBlended.usda")

        let material = try await XRPresenterMaterial.loadBlended()
        XCTAssertEqual(Set(material.parameterNames), [XRPresenterMaterial.colorTextureParameter, XRPresenterMaterial.eyeParameter])
        XCTAssertTrue(material.writesDepth, "the blended core keeps the depth write on")
        XCTAssertTrue(material.readsDepth)
        XCTAssertEqual(material.faceCulling, .none)

        let edge = try await XRPresenterMaterial.loadEdge()
        print("XR presenter materials: the band's graph as loaded reads writesDepth \(edge.writesDepth); the blended core's \(material.writesDepth)")
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

    /// A full mip chain reaches one texel: 1920 × 1824 has eleven levels, 320 × 240 nine, a
    /// texel one.
    func test_theMipChain_reachesOneTexel() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        XCTAssertEqual(XRRealityKitPresenter.mipLevelCount(width: 1920, height: 1824), 11)
        XCTAssertEqual(XRRealityKitPresenter.mipLevelCount(width: 320, height: 240), 9)
        XCTAssertEqual(XRRealityKitPresenter.mipLevelCount(width: 1, height: 1), 1)
        XCTAssertEqual(XRRealityKitPresenter.mipLevelCount(width: 960, height: 912), 10)
    }

    /// With `mipmapped` on, the eye textures carry the full chain, and a frame fills it: after
    /// the eyes are drawn, level 2 of the left eye (a quarter of the size) holds the cubes'
    /// opaque pixels where the base level does, averaged down.
    func test_withMipmapsOn_theEyeTexturesCarryTheChain_andAFrameFillsIt() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.pipelineDepth = 1
        configuration.textureSize = [320, 240]
        configuration.gridColumns = 17
        configuration.gridRows = 13
        configuration.farShellMetres = 50
        configuration.mipmapped = true
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        XCTAssertTrue(presenter.mipmapped)

        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()
        presenter.start(commandQueue: renderInfo.commandQueue)
        try waitUntil {
            presenter.update()
            return loop.framesDrawn >= 6
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try waitUntil { lastTicket.commandBuffer.status == .completed }
        presenter.stop()
        try waitUntil { thread.isFinished }

        let color = lastTicket.colorTextures[0]
        XCTAssertEqual(color.mipmapLevelCount, 9, "320 × 240 down to one texel")
        // Level 2, 80 × 60, read back through a blit.
        let level = 2
        let width = color.width >> level
        let height = color.height >> level
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: color.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: color, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        try waitUntil { commandBuffer.status == .completed }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        copy.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let alphas = stride(from: 3, to: pixels.count, by: 4).map { Int(pixels[$0]) }
        let opaque = alphas.filter { $0 == 255 }.count
        XCTAssertGreaterThan(opaque, width * height / 20, "the cubes' pixels are opaque at level \(level) too (\(opaque) of \(width * height))")
        let centre = alphas[(height / 2) * width + width / 2]
        XCTAssertEqual(centre, 255, "the cube at the centre of view is opaque at level \(level)")
    }

    func test_theLoop_drawsTheEyesIntoThePresenter_andPlacesTheGrids() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.pipelineDepth = 1 // one set: the test counts the entities
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
        XCTAssertEqual(lastTicket.bandBuffers.count, presenter.hasEdgeBand ? 2 : 0, "the band's vertex buffers ride in the ticket while it is drawn")
        XCTAssertEqual(lastTicket.bandIndexBuffers.count, presenter.hasEdgeBand ? 2 : 0, "and its index buffers")
        XCTAssertEqual(presenter.bandMeshes.count, presenter.hasEdgeBand ? 2 : 0, "the band has a mesh per eye")
        XCTAssertEqual(statistics.updates, updates)
        XCTAssertGreaterThanOrEqual(statistics.framesDrawn, 6)
        XCTAssertEqual(statistics.posesMissing, 0)
        XCTAssertGreaterThan(statistics.gpuMsMax, 0, "the frames' GPU spans were noted")
        XCTAssertGreaterThan(statistics.leadMsAverage, 0, "each frame's lead was noted")
        XCTAssertGreaterThan(statistics.completionMsMax, 0, "the frames' times to completion were noted on the GPU's completion")
        XCTAssertGreaterThan(statistics.frameMsMax, 0, "the CPU frame, to the loop's commit, was noted")
        XCTAssertGreaterThan(statistics.worstFrame.completionMs, 0, "the longest frame of the span is kept with its split")
        XCTAssertEqual(statistics.worstFrame.completionMs, statistics.completionMsMax, accuracy: 1e-6)
        XCTAssertEqual(statistics.worstFrame.cpu + statistics.worstFrame.wait + statistics.worstFrame.gpu, statistics.worstFrame.completion, accuracy: 1e-12, "its stages sum to its completion")
        XCTAssertLessThanOrEqual(statistics.worstFrame.gpuMs, statistics.gpuMsMax + 1e-6)
        XCTAssertLessThanOrEqual(statistics.worstFrame.waitMs, statistics.waitMsMax + 1e-6)
        XCTAssertGreaterThan(statistics.refreshMs, 0, "the refresh period follows the updates the test drove")
        XCTAssertLessThanOrEqual(statistics.lateFrames, statistics.framesDrawn)
        XCTAssertGreaterThan(source.lead.framesNoted, 0, "and entered the adaptive lead's average")
        XCTAssertGreaterThan(try XCTUnwrap(source.lead.frameSecondsAverage), 0)

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
        configuration.pipelineDepth = 1 // one set: the test counts the entities
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
        presenter.settings.tears = false
        presenter.settings.leadSeconds = 0.01
        presenter.settings.adaptiveLead = true
        presenter.settings.displayLatencySeconds = 0.012
        let split = try nextTicket()
        XCTAssertEqual(split.indexBuffers.count, 2)
        XCTAssertTrue(split.settings.adaptiveDiagonal)
        XCTAssertEqual(split.settings.skirtTexels, 0)
        XCTAssertEqual(split.settings.tearThresholdMetres, 0.9)
        XCTAssertFalse(split.settings.tears)
        XCTAssertEqual(split.settings.leadSeconds, 0.01)
        XCTAssertTrue(split.settings.adaptiveLead)
        XCTAssertEqual(split.settings.displayLatencySeconds, 0.012)
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

        // The band follows its setting: its entities are disabled and its buffers leave the
        // tickets, then both come back. The band's meshes began with every cell degenerate, and
        // a ticket committed without the kernel (every one here) leaves them so: its index
        // buffers start from the degenerate cells each frame.
        if presenter.hasEdgeBand {
            let bands = presenter.root.children.filter { $0.name.hasSuffix("edge") }
            XCTAssertEqual(bands.count, 2)
            XCTAssertEqual(split.bandBuffers.count, 2, "the band's buffers rode in the first ticket")
            XCTAssertEqual(split.bandIndexBuffers.count, 2)
            presenter.settings.edgeBlending = false
            XCTAssertFalse(presenter.drawsEdgeBand)
            let off = try nextTicket()
            XCTAssertTrue(off.bandBuffers.isEmpty, "no band buffers while the band is off")
            XCTAssertTrue(off.bandIndexBuffers.isEmpty)
            try finish(off)
            XCTAssertTrue(bands.allSatisfy { !$0.isEnabled }, "the band's entities are off")
            presenter.settings.edgeBlending = true
            let on = try nextTicket()
            XCTAssertEqual(on.bandBuffers.count, 2, "the band's buffers ride in the tickets again")
            XCTAssertEqual(on.bandIndexBuffers.count, 2)
            try finish(on)
            XCTAssertTrue(bands.allSatisfy(\.isEnabled), "the band's entities are on again")
            XCTAssertTrue(presenter.drawsEdgeBand)
            for mesh in presenter.bandMeshes {
                XCTAssertEqual(indices(of: mesh), presenter.grid.degenerateIndices(), "a frame that draws nothing leaves the band empty")
            }
        }
        presenter.stop()
    }

    /// Each frame is posed for its ticket's posting plus the lead: the fixed lead past the
    /// pickup, or, when the ticket's settings ask for it and frames have completed, the
    /// measured one; the leads in force reach the statistics.
    func test_theFrame_isPosedForItsTicketsPostingPlusTheLead_fixedOrMeasured() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [64, 48]
        configuration.gridColumns = 5
        configuration.gridRows = 4
        configuration.leadSeconds = 0.02
        configuration.displayLatencySeconds = 0.012
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        presenter.start(commandQueue: renderInfo.commandQueue)

        func nextFrameLead() throws -> TimeInterval {
            // No loop: the test takes the frames itself; a frame let go commits its command buffer.
            presenter.update()
            let ticket = try XCTUnwrap(presenter.lastTicket)
            let frame = try XCTUnwrap(source.nextFrame())
            let lead = frame.timing.presentationTime - ticket.postedAt
            XCTAssertLessThan(lead, 0.1, "no frame is posed further ahead than the lead's range")
            return lead
        }

        // Fixed: `leadSeconds` past the pickup, which comes after the posting.
        let fixed = try nextFrameLead()
        XCTAssertGreaterThanOrEqual(fixed, 0.02)
        XCTAssertNil(source.lead.frameSecondsAverage, "nothing was drawn: no frame completed")

        // Adaptive with no frame completed: the fixed lead still.
        presenter.settings.adaptiveLead = true
        let early = try nextFrameLead()
        XCTAssertGreaterThanOrEqual(early, 0.02)
        XCTAssertLessThan(early, 0.02 + 0.01, "the fixed lead plus the ticket's age at pickup, microseconds here")

        // Frames completed, as the GPU's completion notes them: the lead follows the average
        // frame plus the display latency, past the ticket's age.
        source.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.002))
        source.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.002))
        XCTAssertEqual(try XCTUnwrap(source.lead.frameSecondsAverage), 0.006, accuracy: 1e-9)
        XCTAssertEqual(source.lead.framesNoted, 2)
        let measured = try nextFrameLead()
        XCTAssertGreaterThanOrEqual(measured, 0.018)
        XCTAssertLessThan(measured, 0.018 + 0.01)

        // Back to the fixed lead on the next ticket; the frames seen stay for the next time.
        presenter.settings.adaptiveLead = false
        let fixedAgain = try nextFrameLead()
        XCTAssertGreaterThanOrEqual(fixedAgain, 0.02)
        XCTAssertEqual(source.lead.framesNoted, 2)

        let numbers = presenter.statistics.snapshot()
        XCTAssertEqual(numbers.framesDrawn, 4, "four tickets taken")
        XCTAssertEqual(numbers.leadMsMax, max(fixed, early, measured, fixedAgain) * 1000, accuracy: 1e-6, "the leads in force reached the statistics")
        XCTAssertEqual(numbers.leadMsAverage, (fixed + early + measured + fixedAgain) / 4 * 1000, accuracy: 1e-6)
        XCTAssertEqual(numbers.completionMsAverage, 6, accuracy: 1e-9, "and the frames' times to completion")
        XCTAssertEqual(numbers.frameMsAverage, 3, accuracy: 1e-9, "split into their stages")
        XCTAssertEqual(numbers.waitMsMax, 1, accuracy: 1e-9)
        XCTAssertEqual(numbers.gpuMsMax, 2, accuracy: 1e-9)
        presenter.stop()
    }

    /// The chain at a render scale of 1.5 without a map: the presenter's textures, its depth,
    /// the kernel's scratch and the loop's targets take the scaled size, the grid keeps the
    /// configured vertex count, the frame source reports the scaled eye size, and the loop
    /// draws into it.
    func test_atARenderScale_thePresenterSizesItsTexturesDepthAndKernelToTheScaledSize_andKeepsTheGrid() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.pipelineDepth = 1
        configuration.textureSize = [320, 240]
        configuration.renderScale = 1.5
        configuration.gridColumns = 17
        configuration.gridRows = 13
        configuration.farShellMetres = 50
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        XCTAssertEqual(presenter.renderScale, 1.5)
        XCTAssertEqual(presenter.textureSize, SIMD2<Int>(480, 360), "the textures are the scaled size")
        XCTAssertNil(presenter.foveation)
        XCTAssertEqual(presenter.grid, XRPresenterGrid(columns: 17, rows: 13), "the grid keeps its vertices; its cell grows with the texels")
        for eye in 0 ..< 2 {
            XCTAssertEqual(presenter.depthTextures[eye].width, 480, "the depth is the scaled size")
            XCTAssertEqual(presenter.depthTextures[eye].height, 360)
            XCTAssertEqual(presenter.unprojectScratch[eye].textureSize, SIMD2<Int>(480, 360), "the kernel's scratch was made for the scaled depth")
            XCTAssertEqual(presenter.unprojectScratch[eye].grid, presenter.grid)
            XCTAssertEqual(presenter.unprojectScratch[eye].blockNearestDepths.length, 60 * 45 * MemoryLayout<Float>.stride, "the block dispatch covers the scaled depth")
        }
        XCTAssertEqual(presenter.centreTexelsPerDegree, configuration.centreTexelsPerDegree)
        XCTAssertEqual(presenter.centreTexelsPerDegree, 480 / 2.6 * .pi / 180, accuracy: 1e-4)

        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        XCTAssertEqual(source.eyeSize, simd_float2(480, 360), "the loop sizes the renderer's targets from the scaled size")
        let frame = try XCTUnwrap(source.nextFrameAfter(presenter: presenter, queue: renderInfo.commandQueue))
        let eyes = try XCTUnwrap(frame.acquireEyes().first?.eyes)
        for eye in eyes {
            XCTAssertEqual(eye.colorTexture.width, 480, "RealityKit's texture is the scaled size")
            XCTAssertEqual(eye.colorTexture.height, 360)
            XCTAssertEqual(eye.viewport.width, 480, "the viewport is the texture's")
            XCTAssertEqual(eye.viewport.height, 360)
            XCTAssertNil(eye.foveation)
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
        XCTAssertEqual(renderInfo.viewPort, simd_float2(480, 360), "the engine's targets took the scaled size")
        XCTAssertEqual(lastTicket.colorTextures[0].width, 480)
        XCTAssertEqual(presenter.statistics.snapshot().posesMissing, 0)

        // The middle vertex lies on the cube ahead, as at scale 1: the grid's placement does
        // not depend on the texel size.
        let grid = presenter.grid
        let bytes = try bytes(of: lastTicket.gridBuffers[0])
        let base = ((grid.rows / 2) * grid.columns + grid.columns / 2) * XRPresenterGrid.vertexStride
        let middle = bytes.withUnsafeBytes { raw in
            SIMD3<Float>(raw.load(fromByteOffset: base, as: Float.self), raw.load(fromByteOffset: base + 4, as: Float.self), raw.load(fromByteOffset: base + 8, as: Float.self))
        }
        XCTAssertEqual(middle.z, 0.5, accuracy: 0.1, "the middle vertex lies on the near face of the cube at the origin: \(middle)")
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
        configuration.pipelineDepth = 1 // one set: the pictures are read at the first render, and the band test counts the entities
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
    /// `size` pixels, linear rgba over an opaque black background, with `extras` in the scene
    /// beside them. The materials load asynchronously, with a placeholder in the meantime: the
    /// picture is read back when it stops changing and shows something.
    @available(macOS 15.0, *)
    private func realityKitPicture(of presenter: XRRealityKitPresenter, size: SIMD2<Int>, extras: [Entity] = []) async throws -> [Float] {
        let configuration = presenter.configuration
        let rkRenderer = try RealityRenderer()
        rkRenderer.cameraSettings.isToneMappingEnabled = false
        rkRenderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        rkRenderer.cameraSettings.antialiasing = .none
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: configuration.nearPlane, far: configuration.farPlane, fieldOfViewInDegrees: 90))
        camera.transform = Transform(matrix: Self.picturePose)
        rkRenderer.activeCamera = camera
        rkRenderer.entities.replaceAll([camera, presenter.root] + extras)
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

    /// Two refreshes deep, RealityKit's picture is still the engine's: the set shown is the one
    /// whose ticket of two updates ago completed, drawn into through a presentation buffer
    /// committed behind the frame's, so what RealityKit draws is a frame the engine finished.
    func test_realityKitShowsTheEnginesPicture_twoRefreshesDeep() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = Self.pictureConfiguration
        configuration.pipelineDepth = 2
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        try turnTheCubes()

        let (presenter, engine, size) = try await drawEngineEye(configuration)
        XCTAssertEqual(presenter.presentationSets, 2)
        XCTAssertGreaterThan(coloured(engine, size: size), 1000, "the engine drew the cubes into the eye")
        try reach("the presentations committed") { presenter.pendingPresentations == 0 }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        XCTAssertEqual(lastTicket.settings.pipelineDepth, 2)
        try reach("the last presentation completed") { lastTicket.presentationBuffer.status == .completed }
        let statistics = presenter.statistics.snapshot()
        XCTAssertEqual(statistics.plannedRefreshes, 2, "the frames were planned two refreshes")

        let shown = try await realityKitPicture(of: presenter, size: size)
        XCTAssertGreaterThan(coloured(shown, size: size), 1000, "RealityKit drew the set shown")
        let psnr = peakSignalToNoise(shown, engine, size: size)
        print("RealityKit's picture two refreshes deep against the engine's eye: PSNR \(psnr) dB")
        try dumpPictures([("realitykit-two-deep.png", shown, size), ("engine-two-deep.png", engine, size)])
        XCTAssertTrue(psnr.isFinite)
        XCTAssertGreaterThan(psnr, 70, "the set shown holds a frame the engine drew from the same pose")
    }

    /// At a render scale of 1.5, RealityKit's picture of the grids is still the engine's: the
    /// eye is drawn at the scaled size and the grid (the configured vertex count, a cell of six
    /// texels now) puts every texel back where the engine drew it, against the engine's own
    /// frame of that size. At 8 bits the two are the same, as at scale 1.
    func test_realityKitShowsTheEnginesPicture_atARenderScale() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = Self.pictureConfiguration
        configuration.renderScale = 1.5
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        try turnTheCubes()

        let (presenter, engine, size) = try await drawEngineEye(configuration)
        XCTAssertEqual(size, SIMD2<Int>(384, 384), "the eye was drawn at 1.5 times the configured size")
        XCTAssertEqual(presenter.textureSize, size)
        XCTAssertEqual(presenter.grid, XRPresenterGrid(columns: 65, rows: 65), "the grid is the configured one")
        XCTAssertGreaterThan(coloured(engine, size: size), 2250, "the engine drew the cubes into the scaled eye (2.25 times the pixels of the scale-1 picture)")

        let shown = try await realityKitPicture(of: presenter, size: size)
        XCTAssertGreaterThan(coloured(shown, size: size), 2250, "RealityKit drew the grids")
        let psnr = peakSignalToNoise(shown, engine, size: size)
        print("RealityKit's picture of the presenter's grids at a render scale of 1.5 (\(size.x)×\(size.y)) against the engine's eye of that size: PSNR \(psnr) dB")
        try dumpPictures([("realitykit-scale-1.5.png", shown, size), ("engine-scale-1.5.png", engine, size)])
        XCTAssertTrue(psnr.isFinite)
        XCTAssertGreaterThan(psnr, 70, "RealityKit shows the engine's scaled picture from the engine's eye")
    }

    /// The engine's frames through the presenter at the headset's configuration (1920 × 1824
    /// per eye, the 256 × 240 grid, the band, the pipeline two refreshes deep) for `frames`
    /// frames of the test scene from the picture pose: each ticket's command buffer's GPU span
    /// in milliseconds after `warmUp` frames, the engine's busy time averaged by the pass
    /// timing, and the textures' memory. The command buffer is the frame's whole: the eyes,
    /// the unprojection, the band.
    @available(macOS 15.0, *)
    private func timeEngineFrames(_ configuration: XRRealityKitPresenterConfiguration, frames: Int, warmUp: Int) async throws -> (spansMs: [Double], busyMs: Double, colourBytesPerSet: Int, depthBytes: Int, textureSize: SIMD2<Int>) {
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
        var tickets: [XRPresenterTicket] = []
        try reach("\(frames) frames drawn") {
            presenter.update()
            if let ticket = presenter.lastTicket, ticket.serial != tickets.last?.serial { tickets.append(ticket) }
            return loop.framesDrawn >= frames
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try reach("the last ticket completed") { lastTicket.commandBuffer.status == .completed }
        let busy = GPUPassTiming.shared.busy().averageMs
        // Every frame posted has completed, so the stop commits the presentations left at once.
        presenter.stop()
        try reach("the loop's thread finished") { thread.isFinished }
        try reach("the presentations committed") { presenter.pendingPresentations == 0 }
        let completed = tickets.filter { $0.commandBuffer.status == .completed && $0.commandBuffer.gpuEndTime > $0.commandBuffer.gpuStartTime }
        let spans = completed.dropFirst(warmUp).map { ($0.commandBuffer.gpuEndTime - $0.commandBuffer.gpuStartTime) * 1000 }
        let colour = lastTicket.colorTextures.reduce(0) { $0 + $1.allocatedSize }
        let depth = presenter.depthTextures.reduce(0) { $0 + $1.allocatedSize }
        return (spans, busy, colour, depth, presenter.textureSize)
    }

    /// The engine's GPU frame through the presenter at the headset's configuration, at a render
    /// scale of 1 and of 1.5, on this Mac: the command buffers' GPU spans (median and mean)
    /// and the engine's own busy time, with the memory of each set's two eye textures and of
    /// the depth pair. A measurement, printed; it asserts that the frames complete, that the
    /// scaled run's textures are 2880 × 2736 (so RealityKit takes a `LowLevelTexture` of that
    /// size), and that the scaled frame costs more than the plain one and less than four times
    /// it. The Mac's milliseconds are not the headset's; the ratio is what carries over.
    func test_theEnginesGPUFrame_throughThePresenter_atARenderScaleOfOneAndOneAndAHalf_timed() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        setRendering(.gpuPassTiming(.enabled))
        defer { setRendering(.gpuPassTiming(.disabled)) }
        try turnTheCubes()

        func summary(_ spans: [Double]) -> (median: Double, mean: Double) {
            let sorted = spans.sorted()
            return (sorted[sorted.count / 2], sorted.reduce(0, +) / Double(sorted.count))
        }
        func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

        var results: [(scale: Float, median: Double, mean: Double, busy: Double, size: SIMD2<Int>, colour: Int, depth: Int)] = []
        for scale: Float in [1, 1.5] {
            var configuration = XRRealityKitPresenterConfiguration()
            configuration.renderScale = scale
            // The busy average starts afresh for each scale.
            setRendering(.gpuPassTiming(.disabled))
            setRendering(.gpuPassTiming(.enabled))
            let timed = try await timeEngineFrames(configuration, frames: 50, warmUp: 10)
            XCTAssertGreaterThanOrEqual(timed.spansMs.count, 20, "enough frames timed at scale \(scale)")
            let (median, mean) = summary(timed.spansMs)
            results.append((scale, median, mean, timed.busyMs, timed.textureSize, timed.colourBytesPerSet, timed.depthBytes))
            let line = String(
                format: "XR presenter at a render scale of %.1f on %@: %d×%d per eye, grid 256×240, two sets; GPU span per frame median %.3f ms, mean %.3f ms over %d frames; engine busy (pass timing) %.3f ms; eye textures %@ per set (%@ for the two sets), depth %@ shared",
                scale, renderInfo.device.name, timed.textureSize.x, timed.textureSize.y, median, mean, timed.spansMs.count, timed.busyMs,
                megabytes(timed.colourBytesPerSet), megabytes(timed.colourBytesPerSet * 2), megabytes(timed.depthBytes)
            )
            print(line)
        }
        XCTAssertEqual(results[0].size, SIMD2<Int>(1920, 1824))
        XCTAssertEqual(results[1].size, SIMD2<Int>(2880, 2736), "RealityKit made the scaled textures")
        XCTAssertGreaterThanOrEqual(results[1].colour, 2 * 2880 * 2736 * 4, "two bgra eyes per set")
        XCTAssertGreaterThanOrEqual(results[1].depth, 2 * 2880 * 2736 * 4, "two depth32 eyes")
        let ratio = results[1].median / results[0].median
        print(String(format: "XR presenter render scale 1.5 against 1: the GPU span's median grows %.2f× (2.25× the pixels)", ratio))
        XCTAssertGreaterThan(ratio, 1, "the scaled frame costs more")
        XCTAssertLessThan(ratio, 4, "and not more than the pixels would explain")
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

    /// The edge band's vertex and index buffers as `[UInt32]` and the grid's bytes of one eye of
    /// a ticket, with the eye's scratch entries' rim flags and the vertices' tear mask, read back
    /// once the ticket's frame completed.
    @available(macOS 15.0, *)
    private func bandOfEye(_ eye: Int, ticket: XRPresenterTicket, presenter: XRRealityKitPresenter) throws -> (indices: [UInt32], core: [UInt8], band: [UInt8], rim: [Bool], masked: [Bool]) {
        let core = try bytes(of: ticket.gridBuffers[eye])
        let band = try bytes(of: ticket.bandBuffers[eye])
        let indices = try bytes(of: ticket.bandIndexBuffers[eye]).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let entries = try bytes(of: presenter.nearestDepthBuffers[eye])
        let grid = presenter.grid
        let rim = entries.withUnsafeBytes { raw in
            (0 ..< grid.vertexCount).map { raw.load(fromByteOffset: $0 * MemoryLayout<SIMD4<Float>>.stride + 12, as: Float.self) > 0.5 }
        }
        let masked = core.withUnsafeBytes { raw in
            (0 ..< grid.vertexCount).map { index -> Bool in
                let base = index * XRPresenterGrid.vertexStride + XRPresenterGrid.maskOffset
                return Float(raw.load(fromByteOffset: base, as: Float16.self)) > 0 || Float(raw.load(fromByteOffset: base + 2, as: Float16.self)) > 0
            }
        }
        return (indices, core, band, rim, masked)
    }

    /// The chain with the edge band: the band's buffers ride in the ticket while it is drawn,
    /// the kernel fills its vertices with the grid's bytes and its index buffer with the cells
    /// along the cubes' silhouettes alone (a rim vertex or a tear-mask channel at a corner, by
    /// the scratch entries and the grid's vertices), every other cell degenerate: a few per cent
    /// of the grid around the three cubes, none at the shell's corners, none inside a cube's
    /// face; and the band's meshes hold what the kernel wrote once the frame completed.
    func test_theLoop_fillsTheBandsMeshes_withTheCellsAlongTheCubes() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        let (presenter, _, _) = try await drawEngineEye(Self.pictureConfiguration)
        guard presenter.hasEdgeBand else { throw XCTSkip("the band's graph did not load") }
        let ticket = try XCTUnwrap(presenter.lastTicket)
        XCTAssertEqual(ticket.bandBuffers.count, 2)
        XCTAssertEqual(ticket.bandIndexBuffers.count, 2)
        let grid = presenter.grid
        let cells = (grid.columns - 1) * (grid.rows - 1)
        for eye in 0 ..< 2 {
            let read = try bandOfEye(eye, ticket: ticket, presenter: presenter)
            XCTAssertEqual(read.band, read.core, "eye \(eye): the band's vertices are the grid's bytes")
            XCTAssertEqual(read.indices.count, grid.indexCount)
            var kept = 0
            var keptCells = Set<Int>()
            for row in 0 ..< grid.rows - 1 {
                for column in 0 ..< grid.columns - 1 {
                    let a = UInt32(row * grid.columns + column), b = a + 1, c = a + UInt32(grid.columns), d = c + 1
                    let cell = (row * (grid.columns - 1) + column) * 6
                    let written = Array(read.indices[cell ..< cell + 6])
                    if [a, b, c, d].contains(where: { read.rim[Int($0)] || read.masked[Int($0)] }) {
                        kept += 1
                        keptCells.insert(row * (grid.columns - 1) + column)
                        XCTAssertEqual(written, [a, c, b, b, c, d], "eye \(eye): cell \(column),\(row) at a silhouette keeps its triangles, the fixed split (the adaptive diagonal is off)")
                    } else {
                        XCTAssertEqual(written, [UInt32](repeating: a, count: 6), "eye \(eye): cell \(column),\(row) away from the cubes is degenerate")
                    }
                }
            }
            print("XR presenter edge band: eye \(eye) keeps \(kept) of \(cells) cells around the three cubes (\(String(format: "%.1f", Double(kept) / Double(cells) * 100)) %)")
            XCTAssertGreaterThan(kept, 20, "eye \(eye): the cubes' silhouettes keep cells")
            XCTAssertLessThan(kept, cells / 5, "eye \(eye): the shell and the cubes' faces, most of the grid, are degenerate")
            XCTAssertFalse(keptCells.contains(0), "eye \(eye): the top-left corner, on the shell, is degenerate")
            XCTAssertFalse(keptCells.contains(cells - 1), "eye \(eye): the bottom-right corner, on the shell, is degenerate")
            // The middle cell lies on the near face of the cube at the origin, a cell in from its edges.
            XCTAssertFalse(keptCells.contains((grid.rows / 2) * (grid.columns - 1) + grid.columns / 2), "eye \(eye): the middle cell, inside the cube's face, is degenerate")
            // The band's mesh holds the frame's indices.
            var meshIndices: [UInt32] = []
            presenter.bandMeshes[eye].withUnsafeIndices { meshIndices = Array($0.bindMemory(to: UInt32.self)) }
            XCTAssertEqual(meshIndices, read.indices, "eye \(eye): the band's mesh holds what the kernel wrote")
        }
    }

    /// The band on meshes of its own, the cells along silhouettes alone, shows what the band
    /// over the whole grid showed. Under MSAA, whose coverage the band blends: RealityKit's
    /// picture with the band's meshes against the picture with the band's entities put back on
    /// the grids' meshes (every cell, as the band was first drawn), and both against the
    /// engine's eye. A silhouette's partly covered texel that the band's cells missed would show
    /// as a cut pixel against a blended one, at about 55 dB for a single one.
    func test_theBandsCells_showWhatTheWholeGridsBandShowed() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        let modeBefore = antiAliasingMode
        setRendering(.antiAliasing(.msaa))
        defer { setRendering(.antiAliasing(modeBefore)) }
        try turnTheCubes()
        let (presenter, engine, size) = try await drawEngineEye(Self.pictureConfiguration)
        guard presenter.hasEdgeBand else { throw XCTSkip("the band's graph did not load") }
        XCTAssertGreaterThan(coloured(engine, size: size), 1000, "the engine drew the cubes into the eye")
        let partlyCovered = stride(from: 3, to: engine.count, by: 4).filter { engine[$0] > 0 && engine[$0] < 1 }.count
        XCTAssertGreaterThan(partlyCovered, 50, "MSAA left partly covered texels along the cubes' silhouettes for the band to blend")

        let withCells = try await realityKitPicture(of: presenter, size: size)
        XCTAssertGreaterThan(coloured(withCells, size: size), 1000, "RealityKit drew the grids and the band")
        let entities = presenter.root.children.compactMap { $0 as? ModelEntity }
        let cores = entities.filter { !$0.name.hasSuffix("edge") }
        let bands = entities.filter { $0.name.hasSuffix("edge") }
        XCTAssertEqual(cores.count, 2)
        XCTAssertEqual(bands.count, 2)
        // Without the band: the core alone cuts the partly covered texels, a visible difference.
        for band in bands { band.isEnabled = false }
        let withoutBand = try await realityKitPicture(of: presenter, size: size)
        for band in bands { band.isEnabled = true }
        // The band's entities back on the grids' meshes: every cell blended, as before.
        for (band, core) in zip(bands, cores) {
            band.model?.mesh = try XCTUnwrap(core.model?.mesh)
        }
        let wholeGrid = try await realityKitPicture(of: presenter, size: size)
        XCTAssertGreaterThan(coloured(wholeGrid, size: size), 1000)

        let cellsAgainstWholeGrid = peakSignalToNoise(withCells, wholeGrid, size: size)
        let cellsAgainstEngine = peakSignalToNoise(withCells, engine, size: size)
        let wholeGridAgainstEngine = peakSignalToNoise(wholeGrid, engine, size: size)
        let withoutBandAgainstCells = peakSignalToNoise(withoutBand, withCells, size: size)
        print("RealityKit's picture with the band's cells against the band over the whole grid: PSNR \(cellsAgainstWholeGrid) dB; against the engine's MSAA eye \(cellsAgainstEngine) dB (the whole grid's band: \(wholeGridAgainstEngine) dB; no band: \(withoutBandAgainstCells) dB against the cells, \(partlyCovered) partly covered texels)")
        try dumpPictures([("band-cells.png", withCells, size), ("band-whole-grid.png", wholeGrid, size), ("band-none.png", withoutBand, size), ("engine-msaa.png", engine, size)])
        XCTAssertLessThan(withoutBandAgainstCells, 60, "the band blends what the core alone cuts")
        XCTAssertTrue(cellsAgainstWholeGrid.isFinite)
        XCTAssertGreaterThan(cellsAgainstWholeGrid, 70, "the band's cells blend every texel the whole grid's band blended")
        XCTAssertGreaterThan(cellsAgainstEngine, 70, "RealityKit shows the engine's MSAA picture through the core and the band's cells")
    }

    /// The blended core (`silhouette = .blendedCore`): the grids take the blended graph with
    /// its depth write on, no band is made (no band entities, no band buffers in the ticket,
    /// `hasEdgeBand` false whatever the band setting says), and RealityKit's picture through
    /// it is the engine's eye at the e2e threshold; under MSAA it is the shipped chain's
    /// picture (the cut covered by the band equals the band alone on the Mac, as the straightness
    /// measurements found), so what changes on the device is the device's rasterization of the
    /// cut, not the Mac's picture.
    func test_theBlendedCore_showsTheEnginesPicture_withNoBand_andItsGridsWriteDepth() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = Self.pictureConfiguration
        configuration.silhouette = .blendedCore
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        let modeBefore = antiAliasingMode
        setRendering(.antiAliasing(.msaa))
        defer { setRendering(.antiAliasing(modeBefore)) }
        try turnTheCubes()

        let (presenter, engine, size) = try await drawEngineEye(configuration)
        XCTAssertEqual(presenter.silhouette, .blendedCore, "the blended core's graph loaded")
        XCTAssertFalse(presenter.hasEdgeBand, "no band under the blended core")
        XCTAssertFalse(presenter.drawsEdgeBand)
        presenter.settings.edgeBlending = true
        XCTAssertFalse(presenter.drawsEdgeBand, "the band setting has nothing to turn on")
        XCTAssertEqual(presenter.root.children.count, 2, "one grid entity per eye and nothing else")
        XCTAssertTrue(presenter.bandMeshes.isEmpty)
        let ticket = try XCTUnwrap(presenter.lastTicket)
        XCTAssertTrue(ticket.bandBuffers.isEmpty, "the ticket carries no band buffers, so the kernel's band pass is not encoded")
        XCTAssertTrue(ticket.bandIndexBuffers.isEmpty)
        for entity in presenter.root.children.compactMap({ $0 as? ModelEntity }) {
            let material = try XCTUnwrap(entity.model?.materials.first as? ShaderGraphMaterial, "\(entity.name) shows through the shader graph")
            XCTAssertTrue(material.writesDepth, "\(entity.name) writes depth")
            XCTAssertEqual(material.faceCulling, .none)
        }
        XCTAssertGreaterThan(coloured(engine, size: size), 1000, "the engine drew the cubes into the eye")
        let partlyCovered = stride(from: 3, to: engine.count, by: 4).filter { engine[$0] > 0 && engine[$0] < 1 }.count
        XCTAssertGreaterThan(partlyCovered, 50, "MSAA left partly covered texels along the cubes' silhouettes")

        let blended = try await realityKitPicture(of: presenter, size: size)
        XCTAssertGreaterThan(coloured(blended, size: size), 1000, "RealityKit drew the grids")
        let againstEngine = peakSignalToNoise(blended, engine, size: size)

        // The shipped chain's picture of the same frame's scene, for the comparison.
        let (shipped, _, _) = try await drawEngineEye(Self.pictureConfiguration)
        XCTAssertEqual(shipped.silhouette, .cutAndBand)
        guard shipped.hasEdgeBand else { throw XCTSkip("the band's graph did not load") }
        let cutAndBand = try await realityKitPicture(of: shipped, size: size)
        let againstShipped = peakSignalToNoise(blended, cutAndBand, size: size)
        print("RealityKit's picture through the blended core against the engine's MSAA eye: PSNR \(againstEngine) dB; against the shipped cut and band \(againstShipped) dB (\(partlyCovered) partly covered texels)")
        try dumpPictures([("blended-core.png", blended, size), ("blended-core-shipped.png", cutAndBand, size), ("blended-core-engine.png", engine, size)])
        XCTAssertTrue(againstEngine.isFinite)
        XCTAssertGreaterThan(againstEngine, 70, "RealityKit shows the engine's picture through the blended core")
        XCTAssertGreaterThan(againstShipped, 70, "the blended core is the shipped chain's picture on the Mac")
    }

    /// A box of one colour the size of the view, with no light on it, in RealityKit's
    /// transparent pass (so that it is drawn where a sort group puts it, not first with the
    /// opaque geometry), `behind` metres behind the cubes.
    @available(macOS 15.0, *)
    private func boxBehindTheCubes(order: Int32, group: ModelSortGroup) -> ModelEntity {
        var material = UnlitMaterial(color: .init(red: 0, green: 1, blue: 0, alpha: 1))
        material.blending = .transparent(opacity: 1.0)
        let box = ModelEntity(mesh: .generateBox(width: 40, height: 40, depth: 0.1), materials: [material])
        box.name = "Box behind the cubes"
        box.position = [0, 0, -3]
        box.components.set(ModelSortGroupComponent(group: group, order: order))
        return box
    }

    /// Whether a pixel is the box's colour: the picture's top-left pixel's, where nothing but
    /// the far shell, behind the box, lies (RealityKit maps the material's green into its
    /// working colour space, so the picture's own reading of it is the reference).
    private func isBox(_ pixels: [Float], _ index: Int) -> Bool {
        (0 ..< 3).allSatisfy { abs(pixels[index * 4 + $0] - pixels[$0]) < 0.05 }
    }

    /// The texels where the eye's alpha is 0 and so is every texel within `margin`: the room
    /// away from the cubes' silhouettes and their skirts.
    private func roomTexels(_ engine: [Float], size: SIMD2<Int>, margin: Int) -> [Int] {
        (0 ..< size.x * size.y).filter { index in
            let x = index % size.x, y = index / size.x
            for dy in -margin ... margin {
                for dx in -margin ... margin {
                    let sx = x + dx, sy = y + dy
                    guard sx >= 0, sy >= 0, sx < size.x, sy < size.y else { continue }
                    if engine[(sy * size.x + sx) * 4 + 3] > 0 { return false }
                }
            }
            return true
        }
    }

    /// The blended core writes depth: a RealityKit box behind the cubes, drawn after the grids
    /// in the transparent pass (a sort group orders them), is hidden where the grid is opaque
    /// (the cubes' fully covered texels: the grid's depth, written, rejects the box's
    /// fragments there) and shows where the grid is transparent (the room: the far shell lies
    /// behind the box). With the grids' depth write turned off the same box covers the cubes,
    /// and with the left eye's grid gone the right eye's, collapsed in the vertex stage for a
    /// mono camera, hides nothing: an invisible grid writes no depth. Around each cube the
    /// box is hidden under a halo too: the skirt's texels and the near part of the triangles
    /// stretched to the far shell write their depth at an opacity near 0 (the alpha test
    /// discarded them; a blend cannot), so a RealityKit entity drawn after the grid, or
    /// composited by the layer's depth, loses that sliver beside every silhouette; the halo
    /// is counted and printed, with the shipped chain's own (its band blends too).
    func test_theBlendedCore_writesDepth_aBoxBehindTheCubesIsHiddenWhereTheGridIsOpaque_andShowsWhereItIsTransparent() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = Self.pictureConfiguration
        configuration.silhouette = .blendedCore
        let styleBefore = renderInfo.immersionStyle
        renderInfo.immersionStyle = .mixed
        defer { renderInfo.immersionStyle = styleBefore }
        try turnTheCubes()
        let (presenter, engine, size) = try await drawEngineEye(configuration)
        guard presenter.silhouette == .blendedCore else { throw XCTSkip("the blended core's graph did not load") }
        let pixels = size.x * size.y
        let opaque = (0 ..< pixels).filter { engine[$0 * 4 + 3] >= 1 }
        let transparent = (0 ..< pixels).filter { engine[$0 * 4 + 3] <= 0 }
        // The room six texels and more from any covered texel: past the skirt (three texels)
        // and the near part of a stretched cell (four texels here).
        let room = roomTexels(engine, size: size, margin: 6)
        XCTAssertGreaterThan(opaque.count, 1000, "the cubes cover texels fully")
        XCTAssertGreaterThan(room.count, 10000, "the room is most of the eye")

        let grids = presenter.root.children.compactMap { $0 as? ModelEntity }
        XCTAssertEqual(grids.count, 2)
        let group = ModelSortGroup()
        for grid in grids {
            grid.components.set(ModelSortGroupComponent(group: group, order: 0))
        }
        let box = boxBehindTheCubes(order: 1, group: group)

        // The box drawn after the grids, which write depth.
        let withDepth = try await realityKitPicture(of: presenter, size: size, extras: [box])
        XCTAssertTrue(isBox(withDepth, 0) && withDepth[1] > 0.5, "the top-left pixel is the box's green, through the far shell behind it")
        let boxOverOpaque = opaque.filter { isBox(withDepth, $0) }.count
        let boxOverRoom = room.filter { isBox(withDepth, $0) }.count
        let halo = transparent.filter { !isBox(withDepth, $0) }.count
        var opaqueError = 0.0
        for index in opaque {
            for channel in 0 ..< 3 {
                opaqueError = max(opaqueError, Double(abs(withDepth[index * 4 + channel] - engine[index * 4 + channel])))
            }
        }

        // The same box over grids that write no depth: it covers the cubes.
        for grid in grids {
            guard var material = grid.model?.materials.first as? ShaderGraphMaterial else { continue }
            material.writesDepth = false
            grid.model?.materials = [material]
        }
        let withoutDepth = try await realityKitPicture(of: presenter, size: size, extras: [box])
        let boxOverOpaqueWithoutDepth = opaque.filter { isBox(withoutDepth, $0) }.count
        for grid in grids {
            guard var material = grid.model?.materials.first as? ShaderGraphMaterial else { continue }
            material.writesDepth = true
            grid.model?.materials = [material]
        }

        // The right eye's grid alone (the left disabled): collapsed for the mono camera, it
        // draws nothing and writes no depth, so the box shows whole.
        let left = try XCTUnwrap(grids.first { !$0.name.contains("right") })
        left.isEnabled = false
        let otherEyeOnly = try await realityKitPicture(of: presenter, size: size, extras: [box])
        left.isEnabled = true
        let boxEverywhereOtherEye = (0 ..< pixels).filter { isBox(otherEyeOnly, $0) }.count

        // The shipped chain's halo, for the comparison: its core's alpha test discards what
        // the blend writes, and its band blends over the same texels.
        let (shipped, _, _) = try await drawEngineEye(Self.pictureConfiguration)
        let shippedGrids = shipped.root.children.compactMap { $0 as? ModelEntity }
        for grid in shippedGrids {
            grid.components.set(ModelSortGroupComponent(group: group, order: 0))
        }
        let shippedWithBox = try await realityKitPicture(of: shipped, size: size, extras: [box])
        let shippedHalo = transparent.filter { !isBox(shippedWithBox, $0) }.count
        let shippedBoxOverOpaque = opaque.filter { isBox(shippedWithBox, $0) }.count

        print("XR presenter blended core, depth write: the box behind the cubes shows over \(boxOverOpaque) of \(opaque.count) opaque texels and \(boxOverRoom) of \(room.count) room texels six or more from the cubes (the opaque texels differ from the engine's by at most \(opaqueError)); hidden under a halo of \(halo) of the \(transparent.count) transparent texels (the shipped chain, band \(shipped.drawsEdgeBand ? "on" : "off"): \(shippedHalo), the box over \(shippedBoxOverOpaque) opaque texels); with the depth write off it covers \(boxOverOpaqueWithoutDepth) of the opaque texels; with the other eye's grid alone it fills \(boxEverywhereOtherEye) of \(pixels) pixels")
        try dumpPictures([("blended-core-depth-box.png", withDepth, size), ("blended-core-depth-box-no-write.png", withoutDepth, size), ("blended-core-depth-box-other-eye.png", otherEyeOnly, size), ("blended-core-depth-box-shipped.png", shippedWithBox, size)])
        XCTAssertEqual(boxOverOpaque, 0, "the grid's depth hides the box where the cubes are opaque")
        XCTAssertLessThan(opaqueError, 0.02, "the cubes show over the hidden box as the engine drew them")
        XCTAssertGreaterThan(boxOverRoom, room.count * 99 / 100, "the box shows through the room, where the grid is the far shell behind it")
        XCTAssertGreaterThan(boxOverOpaqueWithoutDepth, opaque.count * 99 / 100, "without the depth write the box, drawn after, covers the cubes")
        XCTAssertEqual(boxEverywhereOtherEye, pixels, "the other eye's grid, collapsed, writes no depth")
        XCTAssertEqual(shippedBoxOverOpaque, 0, "the shipped core's depth hides the box under the cubes too")
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

        var ended = false
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
            }, then: { ended = true })
        }
        // The end is reported through the main queue, which a synchronous spin on the run loop
        // does not service here: an asynchronous wait lets it through.
        let deadline = Date().addingTimeInterval(5)
        while !ended, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ended, "the close says when the session has ended")
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

        // A close that has to give up: the loop ended before it (a game stopped the engine
        // itself), so no frame finishes the destroys and the exchange ends by the fallback with
        // the reset still pending. The next open finishes it before making its camera.
        var gaveUp = false
        _ = try await session("third") { presenter, loop, thread in
            loop.stop()
            presenter.update()
            try waitUntil { thread.isFinished }
            presenter.stop(after: { done in
                setSceneReady(false)
                destroyAllEntities {
                    CameraSystem.shared.activeCamera = nil
                    done()
                }
            }, then: { gaveUp = true })
        }
        let fallbackDeadline = Date().addingTimeInterval(5)
        while !gaveUp, Date() < fallbackDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(gaveUp, "the close ended by its fallback")
        finalizeDestroysNow()
        CameraSystem.shared.activeCamera = findGameCamera()
        initializeAssets()
        let fourth = try await session("fourth") { presenter, loop, _ in
            presenter.stop()
            loop.stop()
        }
        XCTAssertEqual(coloured(fourth), coloured(first), "the session after a close that gave up draws the picture too")
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
