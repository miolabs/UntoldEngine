//
//  StaticBatchMembershipTests.swift
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

/// An entity marked static is drawn by its batch when it is in one, and by itself when
/// it is not. These tests pin who draws it as it enters and leaves a batch: when no batch
/// takes it, when it moves, loses its mark or is destroyed, and when it is placed to stay.
/// The measure is the frame itself: with batching on it is the frame drawn without.
@MainActor
final class StaticBatchMembershipTests: BaseRenderSetup {
    private var sun: EntityID = .invalid

    override func setUp() async throws {
        try await super.setUp()
        resetBatching()
        // A moved entity is batched again after one frame at rest, so that a test does
        // not have to draw the half second of frames the engine waits by default.
        BatchingSystem.shared.restFramesBeforeRebatch = 1
        // Every entity of these scenes is meant to be drawn, however small on screen.
        setRendering(.smallObjectCulling(pixels: 0))
    }

    override func tearDown() async throws {
        resetBatching()
        BatchingSystem.shared.restFramesBeforeRebatch = 30
        setRendering(.smallObjectCulling(pixels: 1))
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        // The scene stands around x = 8, clear of the border between two batch cells at 0.
        cameraLookAt(entityId: camera, eye: simd_float3(8, 6, 16), target: simd_float3(8, 0, 0), up: simd_float3(0, 1, 0))

        sun = createEntity()
        createDirLight(entityId: sun)
        setSunElevationAzimuth(entityId: sun, elevation: 50, azimuth: 30)
    }

    // MARK: - Helpers

    /// Batching off and empty, with every cell built in the tick that finds it dirty.
    private func resetBatching() {
        clearSceneBatches()
        enableBatching(false)
        setBatching(.cellSize(32))
        setBatching(.maxDirtyCellsPerTick(8))
        setBatching(.rebuildBudgets(vertices: 1_000_000_000, indices: 1_000_000_000, bytes: 1_000_000_000))
        setBatching(.runtimeCellLimits(vertices: 1_000_000_000, indices: 1_000_000_000, bytes: 1_000_000_000))
        setBatching(.quiescenceFramesBeforeBuild(0))
        setBatching(.recentVisibilityWindowFrames(120))
        setBatching(.visibilityGatedBuild(false))
        setBatching(.backgroundArtifactBuild(false))
        setBatching(.maxBuildDispatchesPerTick(8))
        setBatching(.maxArtifactAppliesPerTick(8))
        setBatching(.packSinglePlacements(true))
    }

    private func material(_ baseColor: simd_float4, clearCoat: Float = 0) -> Material {
        var material = Material(
            runtimeMaterial: RuntimeMaterialSource(baseColorFactor: baseColor, metallicFactor: 0, roughnessFactor: 0.6),
            device: renderInfo.device
        )
        material.clearCoat = clearCoat
        return material
    }

    private let red = simd_float4(0.9, 0.2, 0.2, 1)
    private let blue = simd_float4(0.2, 0.3, 0.9, 1)
    private let grey = simd_float4(0.7, 0.7, 0.7, 1)

    /// A cube whose mesh sits `offset` away from its entity.
    private func cube(_ material: Material, offset: simd_float3 = .zero) -> [Mesh] {
        var meshes = BasicPrimitives.createCube(extent: 1)
        for meshIndex in meshes.indices {
            // Both, or the engine takes the mesh for one that carries its node's transform
            // and puts it back at the entity's origin.
            meshes[meshIndex].localSpace.columns.3 = simd_float4(offset, 1)
            meshes[meshIndex].worldSpace = meshes[meshIndex].localSpace
            for submeshIndex in meshes[meshIndex].submeshes.indices {
                meshes[meshIndex].submeshes[submeshIndex].material = material
            }
        }
        return meshes
    }

    @discardableResult
    private func place(
        _ meshes: [Mesh],
        at position: simd_float3,
        scale: simd_float3 = simd_float3(repeating: 1),
        isStatic: Bool = true,
        under parent: EntityID? = nil
    ) -> EntityID {
        let entity = createEntity()
        setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: "Shape")
        if let parent {
            setParent(childId: entity, parentId: parent)
        }
        scaleTo(entityId: entity, scale: scale)
        translateTo(entityId: entity, position: position)
        if isStatic {
            setEntityStaticBatch(entityId: entity)
        }
        return entity
    }

    /// A floor that is no part of any batch, for shadows to fall on.
    private func placeGround() {
        place(cube(material(grey)), at: simd_float3(8, -1.2, 0), scale: simd_float3(40, 0.2, 40), isStatic: false)
    }

    /// Draws enough frames for the culling result of the scene to come back and be used,
    /// and for a cell that changed to be rebuilt.
    private func drawFrames(_ count: Int = 6) {
        for _ in 0 ..< count {
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

    /// The frame of the scene as it stands, drawn without any batch.
    private func frameWithoutBatches() throws -> [Float16] {
        enableBatching(false)
        drawFrames()
        return try litPixels()
    }

    /// Pixels that differ visibly between two frames, and how many of the first have
    /// something drawn on them. A batch holds its vertices already placed in the world,
    /// so an edge can land a hair away from where the entity's own draw puts it: a pixel
    /// counts when a channel differs by more than `tolerance`.
    private func compare(_ first: [Float16], _ second: [Float16], tolerance: Float = 0.02) -> (different: Int, covered: Int) {
        XCTAssertEqual(first.count, second.count)
        var different = 0
        var covered = 0
        let background = Array(first[0 ..< 4])
        for offset in stride(from: 0, to: min(first.count, second.count), by: 4) {
            for channel in 0 ..< 3 where abs(Float(first[offset + channel]) - Float(second[offset + channel])) > tolerance {
                different += 1
                break
            }
            if first[offset] != background[0] || first[offset + 1] != background[1] || first[offset + 2] != background[2] {
                covered += 1
            }
        }
        return (different, covered)
    }

    /// Checks that the frame drawn now, with batches, is the frame `unbatched`.
    ///
    /// The edges of a shape can differ by a pixel between a batch and the entity's own
    /// draw; a shape or a shadow that is missing, or drawn twice, is thousands.
    private func assertSameFrame(
        as unbatched: [Float16],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let batched = try litPixels()
        let result = compare(unbatched, batched)
        XCTAssertLessThan(result.different, 150, "pixels that differ from the frame drawn without batches", file: file, line: line)
        XCTAssertGreaterThan(result.covered, 2000, "the scene is on screen", file: file, line: line)
    }

    /// Checks that the frame just drawn, with the batches as they are now, is the frame
    /// the scene gives without them. Batching is off when this returns.
    private func assertTheFrameIsTheOneWithoutBatches(file: StaticString = #filePath, line: UInt = #line) throws {
        let batched = try litPixels()
        let unbatched = try frameWithoutBatches()
        let result = compare(unbatched, batched)
        XCTAssertLessThan(result.different, 150, "pixels that differ from the frame drawn without batches", file: file, line: line)
        XCTAssertGreaterThan(result.covered, 2000, "the scene is on screen", file: file, line: line)
    }

    private func isBatched(_ entity: EntityID) -> Bool {
        BatchingSystem.shared.isBatched(entityId: entity)
    }

    /// The box around every vertex the batches hold.
    private var batchedBounds: (min: simd_float3, max: simd_float3)? {
        let groups = BatchingSystem.shared.batchGroups
        guard var bounds = groups.first?.boundingBox else { return nil }
        for group in groups.dropFirst() {
            bounds.min = simd_min(bounds.min, group.boundingBox.min)
            bounds.max = simd_max(bounds.max, group.boundingBox.max)
        }
        return bounds
    }

    private var batchedEntities: Set<EntityID> {
        Set(BatchingSystem.shared.batchGroups.flatMap(\.entityIds))
    }

    // MARK: - An entity that no batch takes

    func testAMarkedEntityThatNoBatchTakesCastsItsShadow() throws {
        placeGround()
        // Two posts with a material each: neither has anyone to share a batch with.
        let redPost = place(cube(material(red)), at: simd_float3(5, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        let bluePost = place(cube(material(blue)), at: simd_float3(11, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        let unbatched = try frameWithoutBatches()
        let castersWithoutBatches = RenderPasses.lastShadowInstancedDrawCounts.instances
        XCTAssertGreaterThan(castersWithoutBatches, 0)

        enableBatching(true)
        generateBatches()
        drawFrames()

        XCTAssertFalse(isBatched(redPost))
        XCTAssertFalse(isBatched(bluePost))
        XCTAssertFalse(BatchingSystem.shared.awaitsBatch(entityId: redPost))
        XCTAssertEqual(RenderPasses.lastShadowInstancedDrawCounts.instances, castersWithoutBatches, "the posts cast as they do without batching")
        try assertSameFrame(as: unbatched)
    }

    func testAMarkedEntityThatNoBatchTakesCastsItsShadowFromAPointLight() throws {
        setLight(entityId: sun, .directional(.castsShadow(false)))
        let lamp = createEntity()
        createPointLight(entityId: lamp)
        translateTo(entityId: lamp, position: simd_float3(8, 4, 3))
        setLight(entityId: lamp, .power(4000))
        setLight(entityId: lamp, .point(.range(40)))
        setLight(entityId: lamp, .point(.castsShadow(true)))

        try assertThePostsCastTheSameWithBatchingOn()
    }

    func testAMarkedEntityThatNoBatchTakesCastsItsShadowFromASpotLight() throws {
        setLight(entityId: sun, .directional(.castsShadow(false)))
        let lamp = createEntity()
        createSpotLight(entityId: lamp)
        translateTo(entityId: lamp, position: simd_float3(8, 9, 3))
        setLight(entityId: lamp, .power(8000))
        setLight(entityId: lamp, .spot(.coneAngle(80)))
        setLight(entityId: lamp, .spot(.range(40)))
        setLight(entityId: lamp, .spot(.castsShadow(true)))

        try assertThePostsCastTheSameWithBatchingOn()
    }

    /// Two posts with a material each, which no batch takes, on a floor: checks that the
    /// light of the scene draws their shadows, and draws them the same with batching on.
    private func assertThePostsCastTheSameWithBatchingOn(file: StaticString = #filePath, line: UInt = #line) throws {
        placeGround()
        let posts = [
            place(cube(material(red)), at: simd_float3(5, 0.4, 0), scale: simd_float3(0.8, 3, 0.8)),
            place(cube(material(blue)), at: simd_float3(11, 0.4, 0), scale: simd_float3(0.8, 3, 0.8)),
        ]
        // The posts have shadows to lose: the frame differs when they are told not to cast.
        for post in posts {
            try XCTUnwrap(scene.get(component: RenderComponent.self, for: post)).castsShadow = false
        }
        let withoutShadows = try frameWithoutBatches()
        for post in posts {
            try XCTUnwrap(scene.get(component: RenderComponent.self, for: post)).castsShadow = true
        }
        let unbatched = try frameWithoutBatches()
        XCTAssertGreaterThan(compare(withoutShadows, unbatched).different, 1000, "the light draws the shadows of the posts", file: file, line: line)

        enableBatching(true)
        generateBatches()
        drawFrames()

        XCTAssertFalse(posts.contains(where: isBatched), file: file, line: line)
        try assertSameFrame(as: unbatched, file: file, line: line)
    }

    func testAnEntityWithOneMaterialInABatchAndOneOutIsDrawnWhole() throws {
        placeGround()
        // The first entity is a red cube and a blue one; only its red cube has company.
        let both = place(cube(material(red)) + cube(material(blue), offset: simd_float3(0, 0, 3)), at: simd_float3(5, 0, 0))
        let other = place(cube(material(red)), at: simd_float3(11, 0, 0))
        let unbatched = try frameWithoutBatches()

        enableBatching(true)
        generateBatches()
        drawFrames()

        XCTAssertTrue(isBatched(both))
        XCTAssertTrue(isBatched(other))
        try assertSameFrame(as: unbatched)
    }

    func testMaterialsThatDifferInTheirClearCoatAreNotMerged() {
        let plain = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let coated = place(cube(material(red, clearCoat: 1)), at: simd_float3(11, 0, 0))

        enableBatching(true)
        generateBatches()

        XCTAssertFalse(isBatched(plain), "a batch draws all of its entities with the material of one")
        XCTAssertFalse(isBatched(coated))
    }

    // MARK: - An entity of a streamed cell

    func testAnEntityOfAStreamedCellCastsNothingWhileItWaitsForItsBatch() {
        placeGround()
        let posts = [
            place(cube(material(red)), at: simd_float3(5, 0.4, 0), scale: simd_float3(0.8, 3, 0.8)),
            place(cube(material(red)), at: simd_float3(11, 0.4, 0), scale: simd_float3(0.8, 3, 0.8)),
        ]
        enableBatching(true)
        drawFrames()
        let castersOfTheScene = RenderPasses.lastShadowInstancedDrawCounts.instances
        XCTAssertGreaterThan(castersOfTheScene, 0, "marked entities that the batching system was not told of cast")

        // A tile comes in: its cell is not built before it has been still for a while.
        setBatching(.quiescenceFramesBeforeBuild(1000))
        BatchingSystem.shared.notifyTileEntitiesResident(Set(posts))
        XCTAssertTrue(BatchingSystem.shared.awaitsBatch(entityId: posts[0]), "queued")
        drawFrames()

        XCTAssertFalse(isBatched(posts[0]))
        XCTAssertTrue(BatchingSystem.shared.awaitsBatch(entityId: posts[0]), "in a cell that waits")
        XCTAssertLessThan(RenderPasses.lastShadowInstancedDrawCounts.instances, castersOfTheScene, "the posts do not cast for now")
    }

    func testACellBuiltInTheBackgroundIsAppliedWhenNothingElseChanges() {
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(11, 0, 0))
        enableBatching(true)
        setBatching(.backgroundArtifactBuild(true))

        // The one cell of the scene is built on the batching system's own queue. Its
        // batch is ready some frames later, when no cell is dirty any more.
        BatchingSystem.shared.notifyTileEntitiesResident([first, second])
        var frames = 0
        while !isBatched(first), frames < 300 {
            drawFrames(1)
            frames += 1
        }

        XCTAssertTrue(isBatched(first), "after \(frames) frames")
        XCTAssertTrue(isBatched(second))
    }

    // MARK: - An entity that moves

    func testAnEntityThatMovesLeavesItsBatchAndIsBatchedAgainWhereItStops() throws {
        placeGround()
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(11, 0, 0))
        enableBatching(true)
        generateBatches()
        drawFrames()
        XCTAssertTrue(isBatched(first))
        XCTAssertTrue(isBatched(second))
        XCTAssertEqual(try XCTUnwrap(batchedBounds).min.x, 4.5, accuracy: 0.01)

        translateTo(entityId: first, position: simd_float3(2, 0, 2))
        renderer.draw(in: renderer.metalView)
        renderInfo.lastCommandBuffer?.waitUntilCompleted()

        XCTAssertFalse(isBatched(first), "the frame after the move is drawn without the batch")
        XCTAssertFalse(isBatched(second), "its neighbour is alone now")
        XCTAssertNotNil(scene.get(component: StaticBatchComponent.self, for: first), "it keeps its mark")

        drawFrames()
        XCTAssertTrue(isBatched(first), "at rest, it is batched where it stands")
        XCTAssertTrue(isBatched(second))
        XCTAssertEqual(try XCTUnwrap(batchedBounds).min.x, 1.5, accuracy: 0.01)

        try assertTheFrameIsTheOneWithoutBatches()
    }

    func testAnEntityThatKeepsMovingStaysOutOfItsBatch() {
        placeGround()
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(11, 0, 0))
        enableBatching(true)
        generateBatches()
        drawFrames()
        XCTAssertTrue(isBatched(first))

        for step in 1 ... 8 {
            translateTo(entityId: first, position: simd_float3(5 - Float(step) * 0.2, 0, 0))
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
            XCTAssertFalse(isBatched(first), "step \(step)")
            XCTAssertFalse(isBatched(second), "step \(step)")
        }
    }

    func testEntitiesMovedWithTheirParentAreBatchedAgainWhereTheyStop() throws {
        placeGround()
        let parent = createEntity()
        registerTransformComponent(entityId: parent)
        registerSceneGraphComponent(entityId: parent)
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0), under: parent)
        let second = place(cube(material(red)), at: simd_float3(11, 0, 0), under: parent)
        enableBatching(true)
        generateBatches()
        drawFrames()
        XCTAssertTrue(isBatched(first))
        XCTAssertEqual(try XCTUnwrap(batchedBounds).max.y, 0.5, accuracy: 0.01)

        translateTo(entityId: parent, position: simd_float3(0, 2, 0))
        renderer.draw(in: renderer.metalView)
        renderInfo.lastCommandBuffer?.waitUntilCompleted()
        XCTAssertFalse(isBatched(first))
        XCTAssertFalse(isBatched(second))

        drawFrames()
        XCTAssertTrue(isBatched(first))
        XCTAssertTrue(isBatched(second))
        XCTAssertEqual(try XCTUnwrap(batchedBounds).max.y, 2.5, accuracy: 0.01)
        try assertTheFrameIsTheOneWithoutBatches()
    }

    // MARK: - An entity that stops being static

    func testAnEntityThatLosesItsMarkLeavesItsBatch() throws {
        placeGround()
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(8, 0, 0))
        let third = place(cube(material(red)), at: simd_float3(11, 0, 0))
        enableBatching(true)
        generateBatches()
        drawFrames()
        XCTAssertEqual(batchedEntities, [first, second, third])

        removeEntityStaticBatchComponent(entityId: first)
        XCTAssertFalse(isBatched(first), "at once: the next frame draws it by itself")
        drawFrames()

        XCTAssertEqual(batchedEntities, [second, third])
        try assertTheFrameIsTheOneWithoutBatches()
    }

    func testADestroyedEntityIsNotDrawnByItsBatch() throws {
        placeGround()
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(8, 0, 0))
        let third = place(cube(material(red)), at: simd_float3(11, 0, 0))
        enableBatching(true)
        generateBatches()
        drawFrames()
        XCTAssertEqual(batchedEntities, [first, second, third])

        destroyEntity(entityId: first)
        drawFrames()

        XCTAssertEqual(batchedEntities, [second, third])
        XCTAssertEqual(try XCTUnwrap(batchedBounds).min.x, 7.5, accuracy: 0.01, "its vertices are gone with it")
        try assertTheFrameIsTheOneWithoutBatches()
    }

    // MARK: - Entities placed to stay

    func testPlacedEntitiesAreBatchedUnseenAndWhateverTheirSize() {
        // Behind the camera, in a cell of their own, and over the size a streamed cell may have.
        let first = place(cube(material(red)), at: simd_float3(5, 0, 200))
        let second = place(cube(material(red)), at: simd_float3(11, 0, 200))
        enableBatching(true)
        setBatching(.visibilityGatedBuild(true))
        setBatching(.runtimeCellLimits(vertices: 8, indices: 8, bytes: 64))

        // Told of as a tile is, they wait to be seen.
        BatchingSystem.shared.notifyTileEntitiesResident([first, second])
        drawFrames()
        XCTAssertFalse(isBatched(first))

        BatchingSystem.shared.notifyStaticEntitiesPlaced([first, second])
        XCTAssertFalse(BatchingSystem.shared.awaitsBatch(entityId: first), "it casts for itself until its batch is built")
        drawFrames()

        XCTAssertTrue(isBatched(first))
        XCTAssertTrue(isBatched(second))
    }

    func testPlacingEntitiesDoesNothingWhileBatchingIsOff() {
        let first = place(cube(material(red)), at: simd_float3(5, 0, 0))
        let second = place(cube(material(red)), at: simd_float3(11, 0, 0))

        BatchingSystem.shared.notifyStaticEntitiesPlaced([first, second])
        drawFrames()
        XCTAssertFalse(isBatched(first))

        // The marks are there for a later build.
        enableBatching(true)
        generateBatches()
        XCTAssertTrue(isBatched(first))
        XCTAssertTrue(isBatched(second))
    }
}
