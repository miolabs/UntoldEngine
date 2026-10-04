//
//  InstancedDrawRenderTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import Metal
import simd
@testable import UntoldEngine
import XCTest

/// Entities that draw the same meshes with the same materials are encoded as one
/// instanced draw. These tests pin what makes a group, and that a frame looks the same,
/// pixel for pixel, whether its entities are drawn instanced or one by one.
@MainActor
final class InstancedDrawRenderTests: BaseRenderSetup {
    private var savedImmersionStyle: UntoldImmersionMode = .none

    override func setUp() async throws {
        try await super.setUp()
        savedImmersionStyle = renderInfo.immersionStyle
        setRendering(.instancedDraws(.enabled))
        // Every entity of these scenes is meant to be drawn, however small on screen.
        setRendering(.smallObjectCulling(pixels: 0))
    }

    override func tearDown() async throws {
        setRendering(.instancedDraws(.enabled))
        setRendering(.smallObjectCulling(pixels: 1))
        setSceneChannel(.ghostGeometry, .renderMode(.normal))
        renderInfo.immersionStyle = savedImmersionStyle
        SpatialDebugVisualization.shared.colorRenderablesByLOD = false
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 6, 16), target: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0))
    }

    // MARK: - Helpers

    private func material(
        baseColor: simd_float4 = simd_float4(0.8, 0.8, 0.8, 1),
        emissive: simd_float3 = .zero,
        metallic: Float = 0,
        roughness: Float = 0.6
    ) -> Material {
        Material(
            runtimeMaterial: RuntimeMaterialSource(
                baseColorFactor: baseColor,
                emissiveFactor: emissive,
                metallicFactor: metallic,
                roughnessFactor: roughness
            ),
            device: renderInfo.device
        )
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

    @discardableResult
    private func place(
        _ meshes: [Mesh],
        at position: simd_float3,
        scale: simd_float3 = simd_float3(repeating: 1),
        turnedBy degrees: Float = 0
    ) -> EntityID {
        let entity = createEntity()
        setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: "Shape")
        scaleTo(entityId: entity, scale: scale)
        if degrees != 0 {
            rotateTo(entityId: entity, angle: degrees, axis: simd_float3(0.3, 1, 0.2))
        }
        translateTo(entityId: entity, position: position)
        return entity
    }

    /// A 8x8 texture of two colours in squares of two texels.
    private func checkerTexture(_ first: SIMD4<UInt8>, _ second: SIMD4<UInt8>) throws -> MTLTexture {
        let size = 8
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        var texels = [UInt8]()
        for y in 0 ..< size {
            for x in 0 ..< size {
                let colour = ((x / 2) + (y / 2)).isMultiple(of: 2) ? first : second
                texels.append(contentsOf: [colour.x, colour.y, colour.z, colour.w])
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: texels, bytesPerRow: size * 4)
        return texture
    }

    /// Draws enough frames for the culling result of the scene to come back and be used.
    private func drawFrames() {
        for _ in 0 ..< 6 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    /// The lit frame, four half floats per pixel.
    private func litPixels() throws -> [Float16] {
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
        return pixels
    }

    private struct Frame {
        let pixels: [Float16]
        let opaque: RenderPasses.InstancedDrawCounts
        let shadow: RenderPasses.InstancedDrawCounts
    }

    private func frame(instanced: Bool) throws -> Frame {
        setRendering(.instancedDraws(instanced ? .enabled : .disabled))
        drawFrames()
        return try Frame(
            pixels: litPixels(),
            opaque: RenderPasses.lastOpaqueInstancedDrawCounts,
            shadow: RenderPasses.lastShadowInstancedDrawCounts
        )
    }

    /// Pixels that differ in any channel, and how many have something drawn on them.
    private func compare(_ first: [Float16], _ second: [Float16]) -> (different: Int, covered: Int) {
        XCTAssertEqual(first.count, second.count)
        var different = 0
        var covered = 0
        let background = Array(first[0 ..< 4])
        for offset in stride(from: 0, to: min(first.count, second.count), by: 4) {
            if first[offset] != second[offset] || first[offset + 1] != second[offset + 1]
                || first[offset + 2] != second[offset + 2] || first[offset + 3] != second[offset + 3]
            {
                different += 1
            }
            if first[offset] != background[0] || first[offset + 1] != background[1] || first[offset + 2] != background[2] {
                covered += 1
            }
        }
        return (different, covered)
    }

    /// Draws the scene one by one and instanced, and checks that both frames are the same
    /// picture and that the picture is not empty. Returns the instanced frame.
    @discardableResult
    private func assertSamePictureBothWays(file: StaticString = #filePath, line: UInt = #line) throws -> Frame {
        let single = try frame(instanced: false)
        let instanced = try frame(instanced: true)
        let result = compare(single.pixels, instanced.pixels)
        XCTAssertEqual(result.different, 0, "pixels that differ between the two ways of drawing", file: file, line: line)
        XCTAssertGreaterThan(result.covered, 2000, "the scene is on screen", file: file, line: line)
        XCTAssertEqual(single.opaque, RenderPasses.InstancedDrawCounts(), "nothing is instanced when the setting is off", file: file, line: line)
        return instanced
    }

    // MARK: - What makes a group

    func testEntitiesThatShareMeshesAndMaterialsAreOneDraw() throws {
        let cube = meshes(BasicPrimitives.createCube(extent: 1), with: material(baseColor: simd_float4(0.9, 0.2, 0.2, 1)))
        let sphere = meshes(BasicPrimitives.createSphere(extent: 1), with: material(baseColor: simd_float4(0.2, 0.3, 0.9, 1)))
        for index in 0 ..< 12 {
            place(cube, at: simd_float3(Float(index % 6) * 2.4 - 6, 0, Float(index / 6) * -3))
        }
        for index in 0 ..< 5 {
            place(sphere, at: simd_float3(Float(index) * 2.4 - 4.8, 2.5, -1))
        }

        let instanced = try frame(instanced: true)

        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 2, instances: 17, draws: 2))
    }

    func testAnEntityWithItsOwnMaterialIsAGroupOfItsOwn() throws {
        let shape = BasicPrimitives.createCube(extent: 1)
        // Black and glowing: what is seen is the material's own colour, whatever the light.
        let red = material(baseColor: simd_float4(0, 0, 0, 1), emissive: simd_float3(1, 0, 0))
        var entities: [EntityID] = []
        for index in 0 ..< 5 {
            entities.append(place(meshes(shape, with: red), at: simd_float3(Float(index) * 3 - 6, 0, 0)))
        }
        XCTAssertEqual(try frame(instanced: true).opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 5, draws: 1))

        // The middle one turns green: the change reaches the renderer by itself.
        XCTAssertTrue(updateMaterial(entityId: entities[2]) { $0.emissiveValue = simd_float3(0, 1, 0) })
        let edited = try frame(instanced: true)
        XCTAssertEqual(edited.opaque, RenderPasses.InstancedDrawCounts(groups: 2, instances: 5, draws: 2))

        let texture = try XCTUnwrap(textureResources.deferredColorMap)
        let camera = try XCTUnwrap(CameraSystem.shared.activeCamera)
        let view = try XCTUnwrap(scene.get(component: CameraComponent.self, for: camera)).viewSpace
        func colour(atEntity index: Int) -> simd_float3 {
            let clip = renderInfo.perspectiveSpace * view * simd_float4(Float(index) * 3 - 6, 0, 0, 1)
            let x = Int((clip.x / clip.w * 0.5 + 0.5) * Float(texture.width))
            let y = Int((0.5 - clip.y / clip.w * 0.5) * Float(texture.height))
            let offset = (y * texture.width + x) * 4
            return simd_float3(Float(edited.pixels[offset]), Float(edited.pixels[offset + 1]), Float(edited.pixels[offset + 2]))
        }
        for index in 0 ..< 5 {
            let seen = colour(atEntity: index)
            if index == 2 {
                XCTAssertGreaterThan(seen.y, 0.5, "the edited entity shows its own material, got \(seen)")
                XCTAssertLessThan(seen.x, 0.2, "the edited entity does not show the group's material, got \(seen)")
            } else {
                XCTAssertGreaterThan(seen.x, 0.5, "entity \(index) shows the group's material, got \(seen)")
                XCTAssertLessThan(seen.y, 0.2, "entity \(index) does not show the edited material, got \(seen)")
            }
        }

        // Given the group's material back, it is one of the group again.
        XCTAssertTrue(updateMaterial(entityId: entities[2]) { $0.emissiveValue = simd_float3(1, 0, 0) })
        XCTAssertEqual(try frame(instanced: true).opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 5, draws: 1))
    }

    func testSubmeshesTheOpaquePassDoesNotDrawAreNotDrawnInstancedEither() throws {
        let shape = BasicPrimitives.createCube(extent: 1)
        var glass = material(baseColor: simd_float4(0.2, 0.5, 0.9, 0.4))
        glass.alphaMode = .blend
        for index in 0 ..< 4 {
            place(meshes(shape, with: glass), at: simd_float3(Float(index) * 3 - 4.5, 0, 0))
            place(meshes(shape, with: nil), at: simd_float3(Float(index) * 3 - 4.5, 3, 0))
        }
        place(meshes(shape, with: material()), at: simd_float3(0, -3, 0))

        let instanced = try assertSamePictureBothWays()

        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 1, draws: 1), "only the solid cube")
    }

    // MARK: - The same picture

    func testAFrameOfManyMaterialsLooksTheSameDrawnBothWays() throws {
        let cube = BasicPrimitives.createCube(extent: 1)
        let sphere = BasicPrimitives.createSphere(extent: 1)

        var textured = material()
        textured.baseColor.texture = try checkerTexture(SIMD4(230, 60, 40, 255), SIMD4(250, 240, 200, 255))
        var cutOut = material(baseColor: simd_float4(1, 1, 1, 1))
        cutOut.baseColor.texture = try checkerTexture(SIMD4(40, 200, 90, 255), SIMD4(40, 200, 90, 0))
        cutOut.alphaMode = .mask
        cutOut.alphaCutoff = 0.5
        var tiled = textured
        tiled.stScale = 3

        let materials: [Material] = [
            material(baseColor: simd_float4(0.85, 0.15, 0.1, 1), roughness: 0.3),
            material(baseColor: simd_float4(0.9, 0.9, 0.95, 1), metallic: 1, roughness: 0.15),
            material(baseColor: simd_float4(0.05, 0.05, 0.05, 1), emissive: simd_float3(0.2, 0.9, 1.4)),
            textured,
            cutOut,
            tiled,
        ]
        var index = 0
        for (materialIndex, material) in materials.enumerated() {
            for copy in 0 ..< 4 {
                let shape = (materialIndex + copy).isMultiple(of: 2) ? cube : sphere
                place(
                    meshes(shape, with: material),
                    at: simd_float3(Float(index % 8) * 2.6 - 9.1, Float(index / 8) * 2.6 - 2.6, Float(copy) * -1.5),
                    scale: simd_float3(1 + Float(copy) * 0.25, 1, 0.6 + Float(materialIndex) * 0.15),
                    turnedBy: Float(index) * 17
                )
                index += 1
            }
        }

        let instanced = try assertSamePictureBothWays()

        // Six materials on two shapes each.
        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 12, instances: 24, draws: 12))
    }

    func testMeshesWithTheirOwnLocalTransformsLookTheSameDrawnBothWays() throws {
        // One entity draws a cube to its left and a sphere to its right: each mesh has a
        // local transform, the same as its world one so that the registration keeps it.
        var pair = meshes(BasicPrimitives.createCube(extent: 1), with: material(baseColor: simd_float4(0.9, 0.6, 0.1, 1)))
            + meshes(BasicPrimitives.createSphere(extent: 1), with: material(baseColor: simd_float4(0.2, 0.7, 0.4, 1)))
        pair[0].localSpace = matrix4x4Translation(-0.9, 0, 0)
        pair[0].worldSpace = pair[0].localSpace
        pair[1].localSpace = matrix4x4Translation(0.9, 0.4, 0)
        pair[1].worldSpace = pair[1].localSpace
        for index in 0 ..< 6 {
            place(pair, at: simd_float3(Float(index % 3) * 5 - 5, Float(index / 3) * 3 - 1, 0), turnedBy: Float(index) * 31)
        }

        let instanced = try assertSamePictureBothWays()

        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 6, draws: 2))
    }

    func testAnEntityThatFadesAmongInstancesLooksTheSameDrawnBothWays() throws {
        let shape = meshes(BasicPrimitives.createCube(extent: 1.5), with: material(baseColor: simd_float4(0.3, 0.6, 0.9, 1)))
        var entities: [EntityID] = []
        for index in 0 ..< 6 {
            entities.append(place(shape, at: simd_float3(Float(index) * 3 - 7.5, 0, 0), turnedBy: 20))
        }
        // Half way through a fade, an entity is drawn with a dither of its own.
        registerComponent(entityId: entities[3], componentType: MeshFadeComponent.self)
        let fade = try XCTUnwrap(scene.get(component: MeshFadeComponent.self, for: entities[3]))
        fade.progress = 0.5

        let instanced = try assertSamePictureBothWays()

        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 5, draws: 1))
    }

    func testAGhostChannelKeepsItsOpacityDrawnBothWays() throws {
        // In mixed immersion an entity on a ghost channel is drawn see-through: the
        // opacity belongs to the entity, not to the material it shares.
        renderInfo.immersionStyle = .mixed
        let shape = meshes(BasicPrimitives.createCube(extent: 1.5), with: material(emissive: simd_float3(1, 0.5, 0.1)))
        var entities: [EntityID] = []
        for index in 0 ..< 6 {
            entities.append(place(shape, at: simd_float3(Float(index) * 3 - 7.5, 0, 0)))
        }
        setEntitySceneChannels(entityId: entities[1], channels: .ghostGeometry)
        setEntitySceneChannels(entityId: entities[4], channels: .ghostGeometry)
        setSceneChannel(.ghostGeometry, .renderMode(.passthroughGhost(opacity: 0.35)))

        let instanced = try assertSamePictureBothWays()

        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 1, instances: 6, draws: 1))
    }

    func testShadowsLookTheSameDrawnBothWays() throws {
        let sun = createEntity()
        createDirLight(entityId: sun)
        setSunElevationAzimuth(entityId: sun, elevation: 50, azimuth: 30)

        let ground = meshes(BasicPrimitives.createCube(extent: 1), with: material(baseColor: simd_float4(0.7, 0.7, 0.7, 1)))
        place(ground, at: simd_float3(0, -1.2, 0), scale: simd_float3(40, 0.2, 40))
        let post = meshes(BasicPrimitives.createCube(extent: 1), with: material(baseColor: simd_float4(0.8, 0.3, 0.2, 1)))
        for index in 0 ..< 9 {
            place(post, at: simd_float3(Float(index % 3) * 4 - 4, 0.4, Float(index / 3) * -4 + 2), scale: simd_float3(0.8, 3, 0.8), turnedBy: Float(index) * 11)
        }
        RenderPasses.invalidateShadowEntityCache()

        let instanced = try assertSamePictureBothWays()

        // The ground and the posts share the cube's mesh and differ in material: two
        // groups in the opaque pass, and in every cascade they are cast into.
        XCTAssertEqual(instanced.opaque, RenderPasses.InstancedDrawCounts(groups: 2, instances: 10, draws: 2))
        XCTAssertGreaterThan(instanced.shadow.instances, 0, "the posts cast into a cascade")
        XCTAssertEqual(instanced.shadow.draws, instanced.shadow.groups, "a cube is one draw per group")
        XCTAssertLessThan(instanced.shadow.draws, instanced.shadow.instances, "casters share their draws")
    }

    // MARK: - When nothing is instanced

    func testADebugColouringDrawsEveryEntityOnItsOwn() throws {
        let shape = meshes(BasicPrimitives.createCube(extent: 1), with: material())
        for index in 0 ..< 4 {
            place(shape, at: simd_float3(Float(index) * 3 - 4.5, 0, 0))
        }
        XCTAssertEqual(try frame(instanced: true).opaque.instances, 4)

        SpatialDebugVisualization.shared.colorRenderablesByLOD = true
        XCTAssertEqual(try frame(instanced: true).opaque, RenderPasses.InstancedDrawCounts())
    }

    // MARK: - Records

    func testTheRecordBuffersOfAFrameComeBack() throws {
        let shape = meshes(BasicPrimitives.createCube(extent: 1), with: material())
        for index in 0 ..< 4 {
            place(shape, at: simd_float3(Float(index) * 3 - 4.5, 0, 0))
        }

        _ = try frame(instanced: true)

        // drawFrames waits for each frame's command buffer; the completion handlers
        // may still be running.
        let deadline = Date().addingTimeInterval(5)
        while InstanceRecordBufferPool.shared.bufferCounts.lent > 0, Date() < deadline {
            usleep(1000)
        }
        let counts = InstanceRecordBufferPool.shared.bufferCounts
        XCTAssertEqual(counts.lent, 0, "every buffer a pass borrowed is back once its frame completed")
        XCTAssertGreaterThan(counts.free, 0)
        XCTAssertLessThanOrEqual(counts.free, InstanceRecordBufferPool.maximumFreeBuffers)
    }
}
