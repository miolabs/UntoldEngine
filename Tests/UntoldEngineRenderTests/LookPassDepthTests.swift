//
//  LookPassDepthTests.swift
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

/// The look pass draws into its own descriptor, colour alone: it never tests or writes
/// depth, and the frame's depth loaded and stored through it was a full-size read and write
/// per eye for nothing. The other post-process passes keep the frame's depth.
@MainActor
final class LookPassDepthTests: BaseRenderSetup {
    override func tearDown() async throws {
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

    private func readFloats(_ texture: MTLTexture) -> [Float] {
        var halves = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return halves.map { Float(Float16(bitPattern: $0)) }
    }

    func testTheLookPassCarriesNoDepthAttachment() throws {
        let look = try XCTUnwrap(renderInfo.lookRenderPassDescriptor)
        XCTAssertNil(look.depthAttachment.texture, "the look pass has no depth to load or store")
        let post = try XCTUnwrap(renderInfo.postProcessRenderPassDescriptor)
        XCTAssertNotNil(post.depthAttachment.texture, "the other post-process passes keep the frame's depth")

        for _ in 0 ..< 3 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        let output = try XCTUnwrap(textureResources.lookTexture)
        XCTAssertTrue(output.usage.contains(.renderTarget))
        XCTAssertFalse(output.usage.contains(.shaderWrite), "no shader write: the GPU may compress it")
        XCTAssertTrue(readFloats(output).contains { $0 > 0.01 }, "the look pass still wrote the lit frame")
    }
}
