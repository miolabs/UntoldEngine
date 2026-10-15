//
//  TransparencyPassGateTests.swift
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

/// The transparency pass runs only on a frame with a transparent surface to draw: its
/// encoder loads and stores the lit colour and the depth of the whole frame, which a frame
/// with nothing transparent would pay to draw nothing. The GPU's own pass timing says which
/// passes ran.
@MainActor
final class TransparencyPassGateTests: BaseRenderSetup {
    private var box: EntityID = .invalid

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
        box = createEntity()
        setEntityMeshDirect(entityId: box, meshes: BasicPrimitives.createCube(extent: 1.0), assetName: "Box")
        translateTo(entityId: box, position: simd_float3(0, 0.5, 0))
        let sun = createEntity()
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, pitch: -40, yaw: 30, roll: 0)
    }

    /// The labels of the passes the last frame ran, after a few frames.
    private func passesRun() -> Set<String> {
        for _ in 0 ..< 4 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        return Set(GPUPassTiming.shared.lastFrame().passes.map(\.label))
    }

    func testNothingTransparentNoPass() throws {
        try XCTSkipUnless(renderInfo.device.supportsCounterSampling(.atStageBoundary), "no pass timing here")
        var passes = passesRun()
        XCTAssertFalse(passes.contains("Transparency"), "nothing transparent: no pass: \(passes.sorted())")

        // A blended material on the box: the pass has a surface to draw.
        let render = try XCTUnwrap(scene.get(component: RenderComponent.self, for: box))
        for mesh in render.mesh.indices {
            for submesh in render.mesh[mesh].submeshes.indices {
                render.mesh[mesh].submeshes[submesh].material?.alphaMode = .blend
            }
        }
        passes = passesRun()
        XCTAssertTrue(passes.contains("Transparency"), "a blended surface: the pass runs: \(passes.sorted())")
    }
}
