//
//  UntoldMeshReducerTests.swift
//  UntoldEngine
//
//  `untoldengine reduce`: a model simplified in place towards a budget, one deviation
//  shared by its meshes, and a pack reduced as a whole.
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

final class UntoldMeshReducerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UntoldMeshReducerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func triangles(_ url: URL) throws -> [Int] {
        try UntoldReader().readAsset(from: url).meshes.map { Int($0.indexCount) / 3 }
    }

    func testAReducedModelMeetsItsBudgetAndStaysAModel() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 64)]).write(to: directory, name: "hill")
        let source = try UntoldReader().readAsset(from: modelURL)

        let reduction = try UntoldMeshReducer.reduce(modelAt: modelURL, target: .triangles(2000))

        XCTAssertNil(reduction.skipped)
        XCTAssertEqual(reduction.triangleCount, 8192)
        XCTAssertLessThanOrEqual(reduction.reducedTriangleCount, 2000)
        XCTAssertGreaterThan(reduction.reducedTriangleCount, 1000, "the search spends the budget, it does not overshoot it")
        // readAsset checks the content hash and every mesh record's ranges.
        let decoded = try UntoldReader().readAsset(from: modelURL)
        XCTAssertEqual(decoded.header.fileType, source.header.fileType)
        XCTAssertEqual(decoded.header.flags & UntoldFileFlags.generatedLODLevel, 0)
        XCTAssertEqual(decoded.entities, source.entities)
        XCTAssertEqual(decoded.materials.count, source.materials.count)
        XCTAssertEqual(try triangles(modelURL).reduce(0, +), reduction.reducedTriangleCount)
    }

    func testOneDeviationTakesMoreFromAFlatPartThanFromACurvedOne() throws {
        // A finely tessellated flat box beside a wavy surface: the same share of each
        // would flatten the waves; the same deviation empties the box first.
        let model = LODTestModel(meshes: [.box(size: 2, cells: 20), .wavySurface(cells: 48, offset: SIMD3<Float>(0, 5, 0), material: 1)])
        let modelURL = try model.write(to: directory, name: "two")
        let before = try triangles(modelURL)

        try UntoldMeshReducer.reduce(modelAt: modelURL, target: .ratio(0.3))

        let after = try triangles(modelURL)
        let boxShare = Float(after[0]) / Float(before[0])
        let surfaceShare = Float(after[1]) / Float(before[1])
        XCTAssertLessThan(boxShare, 0.05, "a flat box needs a handful of triangles, kept \(after[0]) of \(before[0])")
        XCTAssertGreaterThan(surfaceShare, 0.3, "the curved surface keeps more than the flat share, kept \(after[1]) of \(before[1])")
        XCTAssertLessThanOrEqual(after.reduce(0, +), Int(Float(before.reduce(0, +)) * 0.3) + 1)
    }

    func testAModelWithinItsBudgetIsLeftAlone() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 16)]).write(to: directory, name: "small")
        let bytes = try Data(contentsOf: modelURL)

        let reduction = try UntoldMeshReducer.reduce(modelAt: modelURL, target: .triangles(10000))

        XCTAssertEqual(reduction.skipped, .withinTarget)
        XCTAssertEqual(try Data(contentsOf: modelURL), bytes)
    }

    func testAnOutputLeavesTheInputAlone() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 64)]).write(to: directory, name: "hill")
        let bytes = try Data(contentsOf: modelURL)
        let outputURL = directory.appendingPathComponent("hill_low.untold")

        try UntoldMeshReducer.reduce(modelAt: modelURL, writingTo: outputURL, target: .ratio(0.25))

        XCTAssertEqual(try Data(contentsOf: modelURL), bytes)
        XCTAssertLessThan(try triangles(outputURL).reduce(0, +), 8192 / 3)
    }

    func testReducingRemovesTheLevelsOfTheFullModel() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 64)]).write(to: directory, name: "hill")
        let chain = try UntoldMeshLODCooker.cookChain(forModelAt: modelURL)
        XCTAssertFalse(chain.levels.isEmpty)

        try UntoldMeshReducer.reduce(modelAt: modelURL, target: .triangles(3000))

        for level in chain.levels {
            XCTAssertFalse(FileManager.default.fileExists(atPath: level.url.path), "\(level.url.lastPathComponent) was cooked from the full model")
        }
    }

    func testALevelIsNotReduced() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 64)]).write(to: directory, name: "hill")
        let chain = try UntoldMeshLODCooker.cookChain(forModelAt: modelURL)
        let level = try XCTUnwrap(chain.levels.first)

        XCTAssertThrowsError(try UntoldMeshReducer.reduce(modelAt: level.url, target: .ratio(0.5)))
    }

    func testTargetsAreChecked() throws {
        let modelURL = try LODTestModel(meshes: [.wavySurface(cells: 16)]).write(to: directory, name: "small")
        XCTAssertThrowsError(try UntoldMeshReducer.reduce(modelAt: modelURL, target: .ratio(1)))
        XCTAssertThrowsError(try UntoldMeshReducer.reduce(modelAt: modelURL, target: .ratio(0)))
        XCTAssertThrowsError(try UntoldMeshReducer.reduce(modelAt: modelURL, target: .triangles(0)))
    }

    func testAPackIsReducedAsAWholeAndLosesItsStaleChains() throws {
        let hill = directory.appendingPathComponent("Site/Hill/Hill.untold")
        let rock = directory.appendingPathComponent("Site/Rock/Rock.untold")
        for (url, model) in [(hill, LODTestModel(meshes: [.wavySurface(cells: 64)])), (rock, LODTestModel(meshes: [.box(size: 2, cells: 24)]))] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try model.data().write(to: url)
        }
        let identity: [[Double]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "models": [
                ["displayName": "Hill", "path": "Site/Hill/Hill.untold", "transform": identity],
                ["displayName": "Hill 2", "path": "Site/Hill/Hill.untold", "transform": identity],
                ["displayName": "Rock", "path": "Site/Rock/Rock.untold", "transform": identity],
            ],
            "exporter": "kept",
        ]
        let packURL = directory.appendingPathComponent("Site.untoldpack")
        try JSONSerialization.data(withJSONObject: manifest).write(to: packURL)
        try UntoldMeshLODCooker.cookChains(forPackAt: packURL)
        let full = try triangles(hill).reduce(0, +) + triangles(rock).reduce(0, +)

        let reductions = try UntoldMeshReducer.reducePack(at: packURL, target: .triangles(full / 4))

        XCTAssertEqual(reductions.count, 2, "a model placed twice is reduced once")
        XCTAssertLessThanOrEqual(reductions.reduce(0) { $0 + $1.reducedTriangleCount }, full / 4)
        XCTAssertEqual(try triangles(hill).reduce(0, +) + triangles(rock).reduce(0, +), reductions.reduce(0) { $0 + $1.reducedTriangleCount })
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: packURL)) as? [String: Any])
        XCTAssertNil(raw[UntoldMeshLODCooker.packManifestKey], "the chains were cooked from the full models")
        XCTAssertEqual(raw["exporter"] as? String, "kept")
        XCTAssertEqual((raw["models"] as? [[String: Any]])?.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UntoldMeshLODCooker.levelURL(forModelAt: hill, level: 1).path))
    }
}
