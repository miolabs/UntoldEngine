//
//  LookPassCoverageAlphaTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import simd
@testable import UntoldEngine
@testable import UntoldEngineXR
@testable import UntoldEngineXRRealityKit
import XCTest

/// A mixed-immersion frame is premultiplied: a silhouette texel the multisample resolve partly
/// covers holds its coverage as alpha and the face's colour times that coverage. The look pass
/// must grade and tone-map the face's colour, not the fraction: the tone map of a quarter of
/// the colour is not a quarter of the tone-mapped colour, and the rim of a lit face came out up
/// to 1.3 times as bright as the face (a bright pulsing rim along the near-horizontal edges on
/// the headset). Rendered through the RealityKit presenter's chain, as the headset is.
@MainActor
final class LookPassCoverageAlphaTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)
    private var styleBefore: UntoldImmersionMode = .none
    private var modeBefore: AntiAliasingMode = .fxaa
    private var operatorBefore: TonemapOperator = .aces
    private var gradingBefore = false

    /// A lit face with near-horizontal edges: a white cube facing the headset, rolled a few
    /// degrees so its top and bottom edges cross the texture's rows and the resolve leaves every
    /// coverage along them; the sun ahead of the face and above it, bright enough for the tone
    /// map's shoulder, where the error is largest.
    override func initializeAssets() {
        let slab = createEntity()
        setEntityName(entityId: slab, name: "Slab")
        setEntityMeshDirect(entityId: slab, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Slab")
        updateMaterialColor(entityId: slab, color: .white)
        updateMaterialRoughness(entityId: slab, roughness: 1)
        updateMaterialMetallic(entityId: slab, metallic: 0)
        rotateTo(entityId: slab, pitch: 0, yaw: 0, roll: 3)
        if let sun = LightingSystem.shared.activeDirectionalLight {
            setSunElevationAzimuth(entityId: sun, elevation: 30, azimuth: 0)
            updateLightIntensity(entityId: sun, intensity: 2)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        viewportBefore = renderInfo.viewPort
        styleBefore = renderInfo.immersionStyle
        modeBefore = antiAliasingMode
        operatorBefore = TonemapParams.shared.operator
        gradingBefore = ColorGradingParams.shared.enabled
        renderInfo.isXRStereoMode = true
        renderInfo.currentEye = 0
        renderSkyBackground = false
        renderInfo.immersionStyle = .mixed
        ColorGradingParams.shared.enabled = false
    }

    override func tearDown() async throws {
        renderInfo.isXRStereoMode = false
        renderInfo.currentEye = 0
        renderInfo.xrFoveation = nil
        applyXRFoveationToSceneRenderPassDescriptors()
        renderInfo.immersionStyle = styleBefore
        renderInfo.viewPort = viewportBefore
        renderer.initSizeableResources()
        antiAliasingMode = modeBefore
        setPostFX(.tonemapOperator(operatorBefore))
        ColorGradingParams.shared.enabled = gradingBefore
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

    /// The eye texture's texels (bgra, the display's encoding of the premultiplied colour, the
    /// alpha linear), through a blit: RealityKit's textures are not readable from the CPU.
    private func texels(of texture: MTLTexture) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            copy.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// A rim texel: one on a near-horizontal silhouette, partly covered, with the face whole on
    /// one side of it and nothing on the other.
    private struct RimTexel {
        let x: Int
        let y: Int
        /// The texel's alpha.
        let coverage: Float
        /// The face's luminance one row in, as displayed.
        let face: Float
        /// The texel's luminance behind its coverage, over the face's.
        let ratio: Float
    }

    private func rimTexels(in bytes: [UInt8], width: Int, height: Int) -> [RimTexel] {
        func linear(_ byte: UInt8) -> Float {
            let encoded = Float(byte) / 255
            return encoded <= 0.04045 ? encoded / 12.92 : powf((encoded + 0.055) / 1.055, 2.4)
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }
        func luminance(_ x: Int, _ y: Int) -> Float {
            let i = (y * width + x) * 4
            return 0.2126 * linear(bytes[i + 2]) + 0.7152 * linear(bytes[i + 1]) + 0.0722 * linear(bytes[i])
        }
        var rim: [RimTexel] = []
        for y in 1 ..< height - 1 {
            for x in 0 ..< width {
                let a = alpha(x, y)
                guard a >= 26, a <= 230 else { continue } // 0.1 ... 0.9
                let above = alpha(x, y - 1)
                let below = alpha(x, y + 1)
                let interior: Int
                if above == 255, below == 0 {
                    interior = y - 1
                } else if below == 255, above == 0 {
                    interior = y + 1
                } else {
                    continue
                }
                let coverage = Float(a) / 255
                let face = luminance(x, interior)
                rim.append(RimTexel(x: x, y: y, coverage: coverage, face: face, ratio: luminance(x, y) / coverage / face))
            }
        }
        return rim
    }

    /// The rim texels by coverage: the multisample resolve's quarters.
    private func byCoverage(_ rim: [RimTexel]) -> [(name: String, coverage: Float, texels: [RimTexel])] {
        [("quarter", Float(0.25)), ("half", 0.5), ("three quarters", 0.75)].map { name, coverage in
            (name, coverage, rim.filter { abs($0.coverage - coverage) < 2.5 / 255 })
        }
    }

    func test_thePartlyCoveredRimOfALitFace_isAsBrightAsTheFace() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        // A third of the headset's texture, so the texels stay square.
        configuration.textureSize = [640, 608]
        configuration.gridColumns = 17
        configuration.gridRows = 13
        configuration.farShellMetres = 50
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        // The headset two metres from the face, looking at it.
        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 2.5) }
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        setRendering(.antiAliasing(.msaa))
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()
        presenter.start(commandQueue: renderInfo.commandQueue)
        defer {
            presenter.stop()
            try? waitUntil { thread.isFinished }
        }

        /// The left eye's texels after frames with the tone map.
        func eyeTexels(toneMap: TonemapOperator) throws -> [UInt8] {
            setPostFX(.tonemapOperator(toneMap))
            let framesBefore = loop.framesDrawn
            try waitUntil {
                presenter.update()
                return loop.framesDrawn >= framesBefore + 8
            }
            let ticket = try XCTUnwrap(presenter.lastTicket)
            try waitUntil { ticket.commandBuffer.status == .completed }
            XCTAssertEqual(ticket.colorTextures[0].width, 640)
            return try texels(of: ticket.colorTextures[0])
        }

        // Without a tone map the rim is the face's colour times its coverage already: the
        // control for the measurement. With one, the same must hold.
        for toneMap in [TonemapOperator.none, .aces, .agx] {
            let rim = try rimTexels(in: eyeTexels(toneMap: toneMap), width: 640, height: 608)
            let quarters = byCoverage(rim)
            let report = quarters.map { "\($0.name) \(String(format: "%.3f", $0.texels.map(\.ratio).reduce(0, +) / Float(max($0.texels.count, 1)))) (\($0.texels.count))" }.joined(separator: ", ")
            let face = rim.map(\.face).reduce(0, +) / Float(max(rim.count, 1))
            print("Look pass rim over face with \(toneMap): \(report); face \(String(format: "%.3f", face)) over \(rim.count) rim texels")

            // The alpha is the resolve's coverage, untouched: the quarters, each along the edges.
            XCTAssertGreaterThanOrEqual(rim.count, 30, "\(toneMap): the rolled face's edges leave partly covered texels")
            XCTAssertEqual(quarters.map(\.texels.count).reduce(0, +), rim.count, "\(toneMap): every rim texel holds a quarter, a half or three quarters of coverage")
            for quarter in quarters {
                XCTAssertGreaterThanOrEqual(quarter.texels.count, 5, "\(toneMap): \(quarter.name) coverage along the edges")
            }
            // The face is bright enough for the tone map to bend: dark, the test would see nothing.
            XCTAssertGreaterThan(face, 0.35, "\(toneMap): the face is lit")
            // The rim's colour behind its coverage is the face's, within the display's eight bits
            // (the display encodes the premultiplied colour, so a quarter-covered texel's error
            // is four times a step).
            for quarter in quarters {
                let mean = quarter.texels.map(\.ratio).reduce(0, +) / Float(max(quarter.texels.count, 1))
                XCTAssertEqual(mean, 1, accuracy: 0.04, "\(toneMap): \(quarter.name)-covered rim texels over the face")
                for texel in quarter.texels {
                    XCTAssertEqual(texel.ratio, 1, accuracy: 0.06, "\(toneMap): the rim texel at (\(texel.x), \(texel.y)), coverage \(texel.coverage), over the face")
                }
            }
        }
    }
}
