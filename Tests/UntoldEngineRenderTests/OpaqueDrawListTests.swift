//
//  OpaqueDrawListTests.swift
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

/// The opaque pass encodes its draws by material and then by mesh, and sets on the
/// encoder only what changed. These tests pin the order, and that a draw still gets
/// its own material, mesh and transform when its neighbours share some of them.
@MainActor
final class OpaqueDrawListTests: BaseRenderSetup {
    override func tearDown() async throws {
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {}

    // MARK: - Helpers

    private func emissiveMaterial(_ color: simd_float3, alphaMode: MaterialAlphaMode = .opaque) -> Material {
        var material = Material(
            runtimeMaterial: RuntimeMaterialSource(
                baseColorFactor: simd_float4(0, 0, 0, 1),
                emissiveFactor: color,
                metallicFactor: 0.0,
                roughnessFactor: 1.0
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

    private func listEntity() -> OpaqueDrawList.Entity {
        OpaqueDrawList.Entity(
            entityId: .invalid,
            world: WorldTransformComponent(),
            deformation: nil,
            hasSkeleton: false,
            passthroughAlpha: 1,
            tileRepresentationFade: nil,
            meshFade: nil
        )
    }

    /// Adds `meshes` as one entity and returns the index of its mesh list.
    @discardableResult
    private func add(_ meshes: [Mesh], to list: inout OpaqueDrawList) -> Int32 {
        let entity = list.add(entity: listEntity())
        list.add(meshes: meshes, ditherThreshold: 1, ditherMode: 0, entity: entity)
        return Int32(list.meshLists.count - 1)
    }

    /// The mesh lists of the draws, in encoding order.
    private func encodedLists(_ list: OpaqueDrawList) -> [Int32] {
        list.order().map { list.draws[$0].meshList }
    }

    // MARK: - Order

    func testDrawsThatShareAMaterialAreNeighbours() {
        let cube = BasicPrimitives.createCube(extent: 1)
        let sphere = BasicPrimitives.createSphere(extent: 1)
        let red = emissiveMaterial(simd_float3(1, 0, 0))
        let green = emissiveMaterial(simd_float3(0, 1, 0))
        var list = OpaqueDrawList()

        // red, green, red, green, red as the visible list brings them.
        let lists = [
            add(meshes(cube, with: red), to: &list),
            add(meshes(sphere, with: green), to: &list),
            add(meshes(sphere, with: red), to: &list),
            add(meshes(cube, with: green), to: &list),
            add(meshes(cube, with: red), to: &list),
        ]

        // The materials in the order they were first seen; within red, the cube (seen
        // first) before the sphere.
        XCTAssertEqual(encodedLists(list), [lists[0], lists[4], lists[2], lists[1], lists[3]])
    }

    func testDrawsThatShareMaterialAndMeshKeepTheOrderTheyWereAddedIn() {
        let cube = BasicPrimitives.createCube(extent: 1)
        let red = emissiveMaterial(simd_float3(1, 0, 0))
        var list = OpaqueDrawList()

        let lists = (0 ..< 40).map { _ in add(meshes(cube, with: red), to: &list) }

        XCTAssertEqual(encodedLists(list), lists)
    }

    func testTheSameInputGivesTheSameOrder() {
        let cube = BasicPrimitives.createCube(extent: 1)
        let sphere = BasicPrimitives.createSphere(extent: 1)
        let materials = (0 ..< 7).map { emissiveMaterial(simd_float3(Float($0) / 7, 0.5, 0.25)) }
        var generator = SystemRandomNumberGenerator()
        let input: [[Mesh]] = (0 ..< 200).map { _ in
            meshes(Bool.random(using: &generator) ? cube : sphere, with: materials.randomElement(using: &generator)!)
        }

        var first = OpaqueDrawList()
        var second = OpaqueDrawList(expectedEntities: input.count)
        for meshes in input {
            add(meshes, to: &first)
            add(meshes, to: &second)
        }

        XCTAssertEqual(first.order(), second.order())
        XCTAssertEqual(Set(first.order()), Set(first.draws.indices), "every draw is in the order once")
        XCTAssertEqual(first.order().count, first.draws.count)
    }

    func testEveryMaterialIsOneRunAndEveryMeshOneRunWithinIt() {
        let shapes = [BasicPrimitives.createCube(extent: 1), BasicPrimitives.createSphere(extent: 1), BasicPrimitives.createCube(extent: 2)]
        let materials = (0 ..< 5).map { emissiveMaterial(simd_float3(Float($0) / 5, 0.2, 0.9)) }
        var generator = SystemRandomNumberGenerator()
        var list = OpaqueDrawList()
        var materialOfList: [Int32: Int] = [:]
        var shapeOfList: [Int32: Int] = [:]
        for _ in 0 ..< 300 {
            let material = Int.random(in: materials.indices, using: &generator)
            let shape = Int.random(in: shapes.indices, using: &generator)
            let index = add(meshes(shapes[shape], with: materials[material]), to: &list)
            materialOfList[index] = material
            shapeOfList[index] = shape
        }

        let encoded = encodedLists(list)
        let materialRuns = runs(encoded.map { materialOfList[$0]! })
        let materialAndShapeRuns = runs(encoded.map { materialOfList[$0]! * 100 + shapeOfList[$0]! })

        XCTAssertEqual(materialRuns, Set(materialOfList.values).count, "a material's draws are not split")
        XCTAssertEqual(
            materialAndShapeRuns,
            Set(materialOfList.keys.map { materialOfList[$0]! * 100 + shapeOfList[$0]! }).count,
            "within a material, a mesh's draws are not split"
        )
    }

    private func runs(_ values: [Int]) -> Int {
        var count = 0
        var last: Int?
        for value in values where value != last {
            count += 1
            last = value
        }
        return count
    }

    // MARK: - What is in the list

    func testBlendedSubmeshesAndSubmeshesWithoutAMaterialAreLeftOut() {
        let cube = BasicPrimitives.createCube(extent: 1)
        var list = OpaqueDrawList()

        add(meshes(cube, with: emissiveMaterial(simd_float3(1, 1, 1), alphaMode: .blend)), to: &list)
        add(meshes(cube, with: nil), to: &list)
        XCTAssertTrue(list.draws.isEmpty)
        XCTAssertTrue(list.order().isEmpty)

        let opaque = add(meshes(cube, with: emissiveMaterial(simd_float3(1, 1, 1))), to: &list)
        let masked = add(meshes(cube, with: emissiveMaterial(simd_float3(1, 1, 1), alphaMode: .mask)), to: &list)
        XCTAssertEqual(Set(list.draws.map(\.meshList)), [opaque, masked])
    }

    func testAnEmptyListHasNothingToEncode() {
        let list = OpaqueDrawList()

        XCTAssertTrue(list.order().isEmpty)
    }

    // MARK: - On screen

    /// Two entities that draw the same mesh with different materials, and two that draw
    /// different meshes with the same material: each ends up with its own colour in
    /// its own place.
    func testNeighboursThatShareAMeshOrAMaterialAreDrawnAsThemselves() throws {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 10), target: .zero, up: simd_float3(0, 1, 0))

        let cube = BasicPrimitives.createCube(extent: 1)
        let sphere = BasicPrimitives.createSphere(extent: 1)
        let red = emissiveMaterial(simd_float3(1, 0, 0))
        let green = emissiveMaterial(simd_float3(0, 1, 0))

        // Left to right: red cube, green cube, green sphere, red sphere.
        let placements: [(meshes: [Mesh], material: Material, x: Float, expected: simd_float3)] = [
            (cube, red, -4.5, simd_float3(1, 0, 0)),
            (cube, green, -1.5, simd_float3(0, 1, 0)),
            (sphere, green, 1.5, simd_float3(0, 1, 0)),
            (sphere, red, 4.5, simd_float3(1, 0, 0)),
        ]
        for placement in placements {
            let entity = createEntity()
            setEntityMeshDirect(entityId: entity, meshes: meshes(placement.meshes, with: placement.material), assetName: "Shape")
            translateTo(entityId: entity, position: simd_float3(placement.x, 0, 0))
        }
        setVisibleEntities()
        renderer.draw(in: renderer.metalView)
        renderInfo.lastCommandBuffer?.waitUntilCompleted()

        let texture = try XCTUnwrap(textureResources.deferredColorMap)
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
        var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }

        let projection = renderInfo.perspectiveSpace
        let view = try XCTUnwrap(scene.get(component: CameraComponent.self, for: camera)).viewSpace
        for placement in placements {
            // Where the centre of the shape lands on screen.
            let clip = projection * view * simd_float4(placement.x, 0, 0, 1)
            let x = Int((clip.x / clip.w * 0.5 + 0.5) * Float(texture.width))
            let y = Int((0.5 - clip.y / clip.w * 0.5) * Float(texture.height))
            let offset = (y * texture.width + x) * 4
            let color = simd_float3(Float(pixels[offset]), Float(pixels[offset + 1]), Float(pixels[offset + 2]))
            let dominant = placement.expected.x > 0 ? color.x : color.y
            let other = placement.expected.x > 0 ? color.y : color.x
            XCTAssertGreaterThan(dominant, 0.5, "the shape at x \(placement.x) shows its own material, got \(color)")
            XCTAssertLessThan(other, 0.2, "the shape at x \(placement.x) does not show its neighbour's material, got \(color)")
        }
    }
}
