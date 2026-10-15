//
//  ShadowPassGateTests.swift
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

/// The sun's shadow cascades are drawn only while the sun lights something: the shading
/// multiplies the shadow by the sun's intensity, so a sun at zero would have its two depth
/// maps drawn every frame for nothing. The GPU's own pass timing says which passes ran.
@MainActor
final class ShadowPassGateTests: BaseRenderSetup {
    override func setUp() async throws {
        try await super.setUp()
        setRendering(.gpuPassTiming(.enabled))
    }

    override func tearDown() async throws {
        setRendering(.gpuPassTiming(.disabled))
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
        // The base scene's own directional light is the active sun; a second one would not be.
    }

    /// The labels of the passes the last frame ran, after a few frames.
    private func passesRun() -> Set<String> {
        for _ in 0 ..< 4 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        return Set(GPUPassTiming.shared.lastFrame().passes.map(\.label))
    }

    func testASunAtZeroIntensityDrawsNoCascades() throws {
        try XCTSkipUnless(renderInfo.device.supportsCounterSampling(.atStageBoundary), "no pass timing here")
        let sun = try XCTUnwrap(LightingSystem.shared.activeDirectionalLight, "the scene's sun")
        updateLightIntensity(entityId: sun, intensity: 2.0)
        var passes = passesRun()
        XCTAssertTrue(passes.contains("Shadows"), "a lit sun casts: \(passes.sorted())")
        XCTAssertTrue(shadowSystem.isActive)

        updateLightIntensity(entityId: sun, intensity: 0.0)
        passes = passesRun()
        XCTAssertFalse(passes.contains("Shadows"), "a sun at zero lights nothing: no cascades: \(passes.sorted())")
        XCTAssertFalse(shadowSystem.isActive)

        updateLightIntensity(entityId: sun, intensity: 1.0)
        passes = passesRun()
        XCTAssertTrue(passes.contains("Shadows"), "lit again: the cascades are back: \(passes.sorted())")
    }
}
