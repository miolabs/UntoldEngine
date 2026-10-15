//
//  ShadowCascadeCountTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
