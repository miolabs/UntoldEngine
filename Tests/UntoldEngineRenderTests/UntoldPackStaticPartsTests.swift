//
//  UntoldPackStaticPartsTests.swift
//  UntoldEngine
//
//  Loading a `.untoldpack` marks as static the parts of the models it places a single
//  time, and hands them to the batching system: which parts get the mark, and what
//  becomes of them with batching on and off.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
@testable import UntoldEngine
@testable import UntoldEngineMeshCook
import XCTest

final class UntoldPackStaticPartsTests: BaseRenderSetup {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        LoadingSystem.shared.resourceURLFn = getResourceURL
        LODSystem.shared.reset()
        resetBatching()
        BatchingSystem.shared.restFramesBeforeRebatch = 1
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UntoldPackStaticPartsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        LoadingSystem.shared.resourceURLFn = getResourceURL
        LODSystem.shared.reset()
        resetBatching()
        BatchingSystem.shared.restFramesBeforeRebatch = 30
        destroyAllEntities()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(8, 6, 16), target: simd_float3(8, 0, 0), up: simd_float3(0, 1, 0))
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

    private struct Placement {
        var name: String
        /// A bundled test model: "ball" (one mesh) or "stadium" (seven).
        var asset: String
        var path: String
        var position = SIMD3<Float>(0, 0, 0)
    }

    /// Copies the bundled models to their paths under tempRoot and writes a manifest that
    /// places them. The scene of these tests stands around x = 8, clear of the border
    /// between two batch cells at 0.
    private func writePack(_ placements: [Placement], cookChains: Bool = false) throws -> URL {
        var models: [[String: Any]] = []
        for placement in placements {
            let source = try XCTUnwrap(
                LoadingSystem.shared.resourceURL(forResource: placement.asset, withExtension: "untold"),
                "bundled \(placement.asset).untold not found"
            )
            let destination = tempRoot.appendingPathComponent(placement.path)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            models.append([
                "displayName": placement.name,
                "path": placement.path,
                "transform": [
                    [1, 0, 0, Double(placement.position.x)],
                    [0, 1, 0, Double(placement.position.y)],
                    [0, 0, 1, Double(placement.position.z)],
                    [0, 0, 0, 1],
                ],
            ])
        }
        let manifest: [String: Any] = ["formatVersion": 1, "sourceAsset": "Site.blend", "models": models]
        let packURL = tempRoot.appendingPathComponent("Site").appendingPathExtension("untoldpack")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: packURL)
        if cookChains {
            let report = try UntoldMeshLODCooker.cookChains(forPackAt: packURL, options: UntoldMeshLODOptions(minimumTriangles: 0))
            XCTAssertTrue(report.failures.isEmpty)
        }
        return packURL
    }

    /// Loads a pack and returns its root and its placements by display name.
    private func loadPack(_ packURL: URL) async throws -> (root: EntityID, children: [String: EntityID]) {
        let rootId = createEntity()
        let expectation = expectation(description: "pack load completes")
        setEntityMeshAsync(entityId: rootId, filename: packURL.deletingPathExtension().path, withExtension: "untoldpack") { success in
            XCTAssertTrue(success)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 20.0)
        let scenegraph = try XCTUnwrap(scene.get(component: ScenegraphComponent.self, for: rootId))
        return (rootId, Dictionary(uniqueKeysWithValues: scenegraph.children.map { (getEntityName(entityId: $0), $0) }))
    }

    /// The entities of a placement that draw a mesh: the placement itself for a model of
    /// one node, its descendants for one of several.
    private func parts(of placement: EntityID) -> [EntityID] {
        var found: [EntityID] = []
        var queue = [placement]
        while let entity = queue.popLast() {
            if scene.get(component: RenderComponent.self, for: entity) != nil {
                found.append(entity)
            }
            queue.append(contentsOf: getEntityChildren(parentId: entity))
        }
        return found
    }

    private func isMarked(_ entity: EntityID) -> Bool {
        scene.get(component: StaticBatchComponent.self, for: entity) != nil
    }

    private func isBatched(_ entity: EntityID) -> Bool {
        BatchingSystem.shared.isBatched(entityId: entity)
    }

    private func drawFrames(_ count: Int = 6) {
        for _ in 0 ..< count {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    /// Two balls from two files, each placed once and close enough to share a batch cell.
    /// The files stand in one folder, as the models of a cooked pack do: their materials
    /// name the same textures, so they are one material to the batching system.
    private func twoSingleBalls(z: Float = 0) -> [Placement] {
        [
            Placement(name: "First", asset: "ball", path: "Models/First.untold", position: SIMD3<Float>(6, 0, z)),
            Placement(name: "Second", asset: "ball", path: "Models/Second.untold", position: SIMD3<Float>(10, 0, z)),
        ]
    }

    // MARK: - Which parts are marked

    func testThePartsOfAModelPlacedOnceAreMarkedStatic() async throws {
        let packURL = try writePack([
            Placement(name: "Single", asset: "ball", path: "Single/Ball.untold", position: SIMD3<Float>(4, 0, 0)),
            Placement(name: "Twin A", asset: "ball", path: "Twin/Ball.untold", position: SIMD3<Float>(8, 0, 0)),
            Placement(name: "Twin B", asset: "ball", path: "Twin/Ball.untold", position: SIMD3<Float>(12, 0, 0)),
            Placement(name: "Stadium", asset: "stadium", path: "Stadium/Stadium.untold", position: SIMD3<Float>(8, 0, -20)),
        ])

        let (_, children) = try await loadPack(packURL)

        let single = try parts(of: XCTUnwrap(children["Single"]))
        XCTAssertEqual(single.count, 1)
        XCTAssertTrue(single.allSatisfy(isMarked))

        // A model placed twice is drawn with instancing: one copy of its meshes.
        for name in ["Twin A", "Twin B"] {
            let twin = try parts(of: XCTUnwrap(children[name]))
            XCTAssertEqual(twin.count, 1)
            XCTAssertFalse(twin.contains(where: isMarked), name)
        }

        // Every node of a model of several.
        let stadium = try parts(of: XCTUnwrap(children["Stadium"]))
        XCTAssertEqual(stadium.count, 7)
        XCTAssertTrue(stadium.allSatisfy(isMarked))
    }

    func testAModelWithALODChainIsNotMarked() async throws {
        let packURL = try writePack(
            [Placement(name: "Single", asset: "ball", path: "Single/Ball.untold", position: SIMD3<Float>(4, 0, 0))],
            cookChains: true
        )

        let (_, children) = try await loadPack(packURL)

        let single = try parts(of: XCTUnwrap(children["Single"]))
        XCTAssertNotNil(scene.get(component: LODComponent.self, for: single[0]), "the chain was loaded")
        XCTAssertFalse(single.contains(where: isMarked), "its meshes change with the distance, which a batch cannot follow")
    }

    func testTheSettingTurnsTheMarkingOff() async throws {
        setBatching(.packSinglePlacements(false))
        let packURL = try writePack(twoSingleBalls())

        let (root, _) = try await loadPack(packURL)

        XCTAssertEqual(parts(of: root).count, 2)
        XCTAssertFalse(parts(of: root).contains(where: isMarked))
    }

    // MARK: - What becomes of the marked parts

    func testThePartsAreBatchedOnceThePackIsIn() async throws {
        enableBatching(true)
        let packURL = try writePack(twoSingleBalls())

        let (root, _) = try await loadPack(packURL)
        drawFrames()

        let balls = parts(of: root)
        XCTAssertEqual(balls.count, 2)
        XCTAssertTrue(balls.allSatisfy(isBatched), "two files with the same material are one batch")
        XCTAssertEqual(BatchingSystem.shared.batchGroups.count, 1)
    }

    func testThePartsAreBatchedUnseenAndWhateverTheirSize() async throws {
        enableBatching(true)
        setBatching(.visibilityGatedBuild(true))
        setBatching(.runtimeCellLimits(vertices: 8, indices: 8, bytes: 64))
        // Behind the camera.
        let packURL = try writePack(twoSingleBalls(z: 200))

        let (root, _) = try await loadPack(packURL)
        drawFrames()

        XCTAssertTrue(parts(of: root).allSatisfy(isBatched))
    }

    func testWithBatchingOffTheMarksWaitForABuild() async throws {
        let packURL = try writePack(twoSingleBalls())

        let (root, _) = try await loadPack(packURL)
        drawFrames()

        let balls = parts(of: root)
        XCTAssertTrue(balls.allSatisfy(isMarked))
        XCTAssertFalse(balls.contains(where: isBatched))
        XCTAssertTrue(BatchingSystem.shared.batchGroups.isEmpty)

        enableBatching(true)
        generateBatches()
        XCTAssertTrue(balls.allSatisfy(isBatched))
    }

    func testAPackMovedAfterItLoadedIsBatchedWhereItStands() async throws {
        enableBatching(true)
        let packURL = try writePack(twoSingleBalls())
        let (root, _) = try await loadPack(packURL)
        drawFrames()
        let balls = parts(of: root)
        XCTAssertTrue(balls.allSatisfy(isBatched))
        let heightBefore = try XCTUnwrap(BatchingSystem.shared.batchGroups.first).boundingBox.max.y

        // What an editor does when it drops a pack at a point: move its root once it is in.
        translateTo(entityId: root, position: simd_float3(0, 3, 0))
        drawFrames(1)
        XCTAssertFalse(balls.contains(where: isBatched), "the batch held the balls where they stood")
        XCTAssertTrue(balls.allSatisfy(isMarked))

        drawFrames()
        XCTAssertTrue(balls.allSatisfy(isBatched))
        let heightAfter = try XCTUnwrap(BatchingSystem.shared.batchGroups.first).boundingBox.max.y
        XCTAssertEqual(heightAfter, heightBefore + 3, accuracy: 0.01)
    }
}
