//
//  BlendedSubmeshFlagTests.swift
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

/// The transparency pass asks every visible entity whether it has anything blended to
/// draw. A render component remembers the answer until its meshes change: these tests
/// pin that the answer follows the materials, and that the pass draws by it.
@MainActor
final class BlendedSubmeshFlagTests: BaseRenderSetup {
    override func tearDown() async throws {
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 2, 8), target: .zero, up: simd_float3(0, 1, 0))
    }

    private func material(_ alphaMode: MaterialAlphaMode) -> Material {
        var material = Material(
            runtimeMaterial: RuntimeMaterialSource(
                baseColorFactor: simd_float4(0.3, 0.6, 0.9, 0.5),
                emissiveFactor: .zero,
                metallicFactor: 0,
                roughnessFactor: 0.5
            ),
            device: renderInfo.device
        )
        material.alphaMode = alphaMode
        return material
    }

    /// A copy of `meshes` whose submeshes all have `material`.
    private func meshes(_ meshes: [Mesh], with material: Material?) -> [Mesh] {
        var copy = meshes
        for meshIndex in copy.indices {
            for submeshIndex in copy[meshIndex].submeshes.indices {
                copy[meshIndex].submeshes[submeshIndex].material = material
            }
        }
        return copy
    }

    private func transparentDraws() -> Int {
        for _ in 0 ..< 6 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        return RenderStatsCollector.shared.snapshot().drawCallsTransparent
    }

    func testTheAnswerFollowsTheMaterials() {
        let cube = BasicPrimitives.createCube(extent: 1)
        let component = RenderComponent()
        XCTAssertFalse(component.hasBlendedSubmeshes, "no meshes")

        component.mesh = meshes(cube, with: material(.opaque))
        XCTAssertFalse(component.hasBlendedSubmeshes)

        component.mesh[0].submeshes[0].material?.alphaMode = .blend
        XCTAssertTrue(component.hasBlendedSubmeshes, "one material changed where it is")

        component.mesh[0].submeshes[0].material?.alphaMode = .mask
        XCTAssertFalse(component.hasBlendedSubmeshes, "a cut-out is drawn by the opaque pass")

        // One blended submesh among several meshes is enough.
        component.mesh = meshes(cube, with: material(.opaque)) + meshes(cube, with: nil) + meshes(cube, with: material(.blend))
        XCTAssertTrue(component.hasBlendedSubmeshes)

        component.mesh.removeLast()
        XCTAssertFalse(component.hasBlendedSubmeshes)
    }

    func testTheTransparencyPassDrawsWhatBecomesBlended() {
        let solid = createEntity()
        setEntityMeshDirect(entityId: solid, meshes: meshes(BasicPrimitives.createCube(extent: 1), with: material(.opaque)), assetName: "Solid")
        translateTo(entityId: solid, position: simd_float3(-1.5, 0, 0))
        let glass = createEntity()
        setEntityMeshDirect(entityId: glass, meshes: meshes(BasicPrimitives.createCube(extent: 1), with: material(.blend)), assetName: "Glass")
        translateTo(entityId: glass, position: simd_float3(1.5, 0, 0))

        XCTAssertEqual(transparentDraws(), 1, "the glass cube")

        // The solid cube turns to glass between two frames, then back.
        XCTAssertTrue(updateMaterial(entityId: solid) { $0.alphaMode = .blend })
        XCTAssertEqual(transparentDraws(), 2)

        XCTAssertTrue(updateMaterial(entityId: solid) { $0.alphaMode = .opaque })
        XCTAssertEqual(transparentDraws(), 1)
    }
}
