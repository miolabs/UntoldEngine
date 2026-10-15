//
//  ShadowCascadeCountTests.swift
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
import XCTest

/// The sun's shadow is drawn in as many cascades as the setting asks for, one on the headset
/// by default and every cascade elsewhere: one cascade reaches the whole shadow distance, the
/// first of two stops short of it, and the shader is told how many to read.
@MainActor
final class ShadowCascadeCountTests: BaseRenderSetup {
    override func tearDown() async throws {
        ShadowSystem.cascadesWanted = nil
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 1, 4), target: .zero, up: simd_float3(0, 1, 0))
        let box = createEntity()
        setEntityMeshDirect(entityId: box, meshes: BasicPrimitives.createCube(extent: 1.0), assetName: "Box")
        translateTo(entityId: box, position: simd_float3(0, 0.5, 0))
        // The base scene's own directional light is the active sun.
    }

    private func drawFrames() {
        for _ in 0 ..< 2 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    func testTheSettingChoosesTheCascades() {
        setRendering(.shadowCascades(1))
        drawFrames()
        XCTAssertEqual(getShadowCascades(), 1)
        XCTAssertEqual(shadowSystem.makeUniforms().cascadeCount, 1, "the shader reads one")
        XCTAssertTrue(shadowSystem.isActive)
        let single = shadowSystem.cascadeSplitDistances[0]

        setRendering(.shadowCascades(2))
        drawFrames()
        XCTAssertEqual(getShadowCascades(), 2)
        XCTAssertEqual(shadowSystem.makeUniforms().cascadeCount, 2)
        XCTAssertLessThan(shadowSystem.cascadeSplitDistances[0], single, "the first of two stops short of the shadow distance")
        XCTAssertEqual(shadowSystem.cascadeSplitDistances[1], single, accuracy: 1e-3, "the last split is the shadow distance either way")

        setRendering(.shadowCascades(5))
        XCTAssertEqual(getShadowCascades(), csmCascadeCount, "never more than the maps hold")
        setRendering(.shadowCascades(0))
        XCTAssertEqual(getShadowCascades(), 1, "never none: a sun casts")
    }

    private func readFloats(_ texture: MTLTexture) -> [Float] {
        var halves = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return halves.map { Float(Float16(bitPattern: $0)) }
    }

    /// The lit frame's pixels that the sun's shadow darkens by a third or more: the floor
    /// under and beside the box.
    private func shadowedPixels(cascades: Int) throws -> Int {
        let sun = try XCTUnwrap(LightingSystem.shared.activeDirectionalLight)
        setRendering(.shadowCascades(cascades))
        setLight(entityId: sun, .directional(.castsShadow(true)))
        drawFrames()
        let shadowed = try readFloats(XCTUnwrap(textureResources.deferredColorMap))
        setLight(entityId: sun, .directional(.castsShadow(false)))
        drawFrames()
        let unshadowed = try readFloats(XCTUnwrap(textureResources.deferredColorMap))
        setLight(entityId: sun, .directional(.castsShadow(true)))
        var count = 0
        for i in stride(from: 0, to: min(shadowed.count, unshadowed.count), by: 4) {
            let lit = unshadowed[i] + unshadowed[i + 1] + unshadowed[i + 2]
            let dark = shadowed[i] + shadowed[i + 1] + shadowed[i + 2]
            if lit > 0.05, dark < 0.67 * lit { count += 1 }
        }
        return count
    }

    func testOneCascadeStillCastsAShadow() throws {
        // A floor for the box to cast onto, and a sun that reaches across it.
        let floor = createEntity()
        setEntityMeshDirect(entityId: floor, meshes: BasicPrimitives.createCube(extent: 6.0), assetName: "Floor")
        translateTo(entityId: floor, position: simd_float3(0, -3.0, 0))
        let sun = try XCTUnwrap(LightingSystem.shared.activeDirectionalLight)
        rotateTo(entityId: sun, pitch: -55, yaw: 30, roll: 0)
        setVisibleEntities()

        let withTwo = try shadowedPixels(cascades: 2)
        let withOne = try shadowedPixels(cascades: 1)
        XCTAssertGreaterThan(withTwo, 0, "two cascades shadow the floor under the box")
        XCTAssertGreaterThan(withOne, 0, "one cascade shadows it too")
        XCTAssertGreaterThan(withOne, withTwo / 2, "one cascade over the whole distance shadows about the same pixels")
    }

    func testTheHeadsetDefaultsToOneCascadeAndTheDesktopToAll() {
        ShadowSystem.cascadesWanted = nil
        let saved = renderInfo.isXRStereoMode
        defer { renderInfo.isXRStereoMode = saved }
        renderInfo.isXRStereoMode = true
        XCTAssertEqual(shadowSystem.cascadeCount, 1)
        renderInfo.isXRStereoMode = false
        XCTAssertEqual(shadowSystem.cascadeCount, csmCascadeCount)
    }
}
