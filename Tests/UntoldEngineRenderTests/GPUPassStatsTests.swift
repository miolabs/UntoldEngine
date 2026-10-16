//
//  GPUPassStatsTests.swift
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

/// The engine stats carry the GPU pass timer's last frame: with the timing on, the snapshot
/// lists the frame's passes and the overlay prints them; off, it lists none.
@MainActor
final class GPUPassStatsTests: BaseRenderSetup {
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
        let sun = createEntity()
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, pitch: -40, yaw: 30, roll: 0)
    }

    private func drawFrames(_ count: Int) {
        for _ in 0 ..< count {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    func testTheStatsCarryTheTimedPasses() throws {
        try XCTSkipUnless(renderInfo.device.supportsCounterSampling(.atStageBoundary), "no stage-boundary sampling here")
        drawFrames(3)
        XCTAssertTrue(getEngineStatsSnapshot().gpuPasses.passes.isEmpty, "off by default")

        setRendering(.gpuPassTiming(.enabled))
        drawFrames(10)
        let stats = getEngineStatsSnapshot()
        XCTAssertFalse(stats.gpuPasses.passes.isEmpty, "the stats carry the frame's passes")
        XCTAssertEqual(stats.gpuPasses.totalMs, stats.gpuPasses.passes.reduce(0) { $0 + $1.totalMs }, accuracy: 1e-9)
        XCTAssertGreaterThan(stats.gpuPasses.totalMs, 0)
        XCTAssertTrue(formatEngineStatsOverlay(stats).contains("GPU passes ("), formatEngineStatsOverlay(stats))
    }
}
