//
//  UntoldGSCookerEquivalenceTests.swift
//  UntoldEngineTests
//
//  Pins the streamed cook (windows → store → parallel writer) to the bytes of
//  the whole-array path it replaced: the same .ply cooked both ways is the
//  same file, byte for byte, for single- and two-tier bakes, and the outputs
//  carry SHA-256 pins so both paths cannot drift together. Also the progress
//  and cancellation contract of UntoldGSCookControl, and the streamed centre
//  bounds against the loaded splats.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import CShaderTypes
import simd
@testable import UntoldEngine
import XCTest

final class UntoldGSCookerEquivalenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UntoldGSCookerEquivalenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The cooker test's 300-splat ASCII grid: SH degree 1, `nx ny nz` to skip.
    private func asciiFixture() throws -> URL {
        let count = 300
        var body = ""
        for index in 0 ..< count {
            let x = Float(index % 10) * 0.1
            let y = Float(index / 10 % 10) * 0.1
            let z = Float(index / 100) * 0.1
            let rest = (0 ..< 9).map { "\(Float($0) * 0.01)" }.joined(separator: " ")
            body += "\(x) \(y) \(z) 0 0 1 0.2 0.1 -0.1 \(rest) 2.0 -4 -4 -4 1 0 0 0\n"
        }
        let header = """
        ply
        format ascii 1.0
        element vertex \(count)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        \((0 ..< 9).map { "property float f_rest_\($0)" }.joined(separator: "\n"))
        property float opacity
        property float scale_0
        property float scale_1
        property float scale_2
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header

        """
        let url = temporaryDirectory.appendingPathComponent("grid.ply")
        try Data((header + body).utf8).write(to: url)
        return url
    }

    /// A deterministic 1100-splat binary little-endian SH3 capture in the 3DGS property order
    /// plus a `uchar` property to skip: opacities across the visibility cull (1/255) and the
    /// cook floor (0.005), one degenerate splat (a −∞ log scale), higher-order terms past the
    /// ±1 quantisation range, and a trailing `face` element.
    private func binaryFixture() throws -> URL {
        let count = 1100
        var rng = SplitMix64(seed: 0x5EED_5EED_1100)
        var header = ["ply", "format binary_little_endian 1.0", "comment synthetic SH3 capture", "element vertex \(count)"]
        header += ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"].map { "property float \($0)" }
        header += (0 ..< 45).map { "property float f_rest_\($0)" }
        header += ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"].map { "property float \($0)" }
        header += ["property uchar tag", "element face 0", "property list uchar int vertex_indices", "end_header"]
        var data = Data((header.joined(separator: "\n") + "\n").utf8)

        func append(_ value: Float) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        for index in 0 ..< count {
            // A disc-ish cloud with a few outliers, so the crop and the Morton order both bite.
            let radius = rng.unit() * (index % 97 == 0 ? 6 : 2)
            let angle = rng.unit() * 2 * .pi
            append(radius * cos(angle))
            append(rng.unit() * 0.3 - 0.15)
            append(radius * sin(angle))
            append(0)
            append(0)
            append(1)
            for _ in 0 ..< 3 {
                append(rng.unit() * 2 - 1)
            }
            for term in 0 ..< 45 {
                let value = rng.unit() - 0.5
                append(index % 131 == 7 && term % 11 == 0 ? value * 4 : value)
            }
            // Opacity logits: most visible, some between the cull and the cook floor, some below.
            switch index % 53 {
            case 0: append(-7) // sigmoid ≈ 0.0009 < 1/255: culled by the reader
            case 1: append(-5.5) // sigmoid ≈ 0.0041: past the cull, under the 0.005 floor
            default: append(rng.unit() * 8 - 2)
            }
            for axis in 0 ..< 3 {
                append(index == 500 && axis == 1 ? -.infinity : rng.unit() * 4 - 6)
            }
            var q = SIMD4<Float>(rng.unit() * 2 - 1, rng.unit() * 2 - 1, rng.unit() * 2 - 1, rng.unit() * 2 - 1)
            if simd_length_squared(q) == 0 { q = SIMD4<Float>(1, 0, 0, 0) }
            append(q.x)
            append(q.y)
            append(q.z)
            append(q.w)
            data.append(UInt8(index & 0xFF))
        }
        let url = temporaryDirectory.appendingPathComponent("capture.ply")
        try data.write(to: url)
        return url
    }

    /// Options A: the source degree, a non-identity similarity, 16-splat chunks → automatic levels.
    private var transformedOptions: UntoldGSCookOptions {
        var options = UntoldGSCookOptions()
        options.log2ChunkSplats = 4
        options.transform = UntoldGSCookOptions.transform(upAxis: .z, scale: 0.5, yawDegrees: 30, translation: [0.1, 0.2, -0.3])
        options.captureExposureEV = 1.5
        return options
    }

    /// Options B: degree 1, a crop, a budget, 32-splat chunks, no coarse section.
    private var budgetedOptions: UntoldGSCookOptions {
        var options = UntoldGSCookOptions()
        options.log2ChunkSplats = 5
        options.shDegree = 1
        options.cropMin = [-1.8, -1, -1.8]
        options.cropMax = [1.8, 1, 1.8]
        options.maxSplatCount = 700
        options.coarseLevels = .off
        return options
    }

    private func sha256(_ url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func bakeBothWays(ply: URL, name: String, lodFractions: [Float], options: UntoldGSCookOptions) throws -> [(legacy: URL, streamed: URL)] {
        let legacyBase = temporaryDirectory.appendingPathComponent("legacy-\(name).untoldgs")
        let streamedBase = temporaryDirectory.appendingPathComponent("streamed-\(name).untoldgs")
        let legacy = try LegacyGaussianCookPath.bake(
            sourceAsset: LegacyGaussianCookPath.readGaussianAsset(from: ply),
            emptySourceDescription: "source .ply contains no splats",
            outputBaseURL: legacyBase, lodFractions: lodFractions, cookOptions: options
        )
        let streamed = try bakeGaussianSplatProgressiveTiers(plyURL: ply, outputBaseURL: streamedBase, lodFractions: lodFractions, cookOptions: options)
        XCTAssertEqual(legacy.cookReport, streamed.cookReport, name)
        XCTAssertEqual(legacy.boundingBoxMin, streamed.boundingBoxMin, name)
        XCTAssertEqual(legacy.boundingBoxMax, streamed.boundingBoxMax, name)
        XCTAssertEqual(legacy.tiers.count, streamed.tiers.count, name)
        for (a, b) in zip(legacy.tiers, streamed.tiers) {
            XCTAssertEqual(a.meanSquaredSplatExtent, b.meanSquaredSplatExtent, name)
            XCTAssertEqual(a.coarseReport, b.coarseReport, name)
            XCTAssertEqual(try Data(contentsOf: a.url), try Data(contentsOf: b.url), "\(name): \(a.url.lastPathComponent) is byte-identical either way")
        }
        return zip(legacy.tiers, streamed.tiers).map { ($0.url, $1.url) }
    }

    // MARK: - Byte identity

    func testASCIIFixtureBakesByteIdenticalToTheWholeArrayPath() throws {
        let ply = try asciiFixture()
        var options = UntoldGSCookOptions()
        options.log2ChunkSplats = 7
        options.cropMin = [0, 0, 0]
        options.cropMax = [0.95, 0.95, 0.15]
        options.shDegree = 0
        let single = try bakeBothWays(ply: ply, name: "grid", lodFractions: [1.0], options: options)
        XCTAssertEqual(try sha256(single[0].streamed), "c27c677da83a97ac272ff3d746f7a5d1e5697e2122ca7d5c53cba28153e583f8")

        options.coarseLevels = .levels(count: 1)
        _ = try bakeBothWays(ply: ply, name: "grid-tiers", lodFractions: [1.0, 0.5], options: options)
    }

    func testBinarySH3FixtureBakesByteIdenticalToTheWholeArrayPath() throws {
        let ply = try binaryFixture()
        XCTAssertEqual(try PLYReader.readGaussianSplatCount(from: ply), 1100)

        let transformed = try bakeBothWays(ply: ply, name: "capture", lodFractions: [1.0], options: transformedOptions)
        let file = try UntoldGSFile(url: transformed[0].streamed)
        XCTAssertEqual(file.header.shDegree, 3)
        XCTAssertTrue(file.header.hasCoarseLevels, "69-odd chunks of 16: the automatic section")
        XCTAssertEqual(file.index.coarseRatioLog2, [3, 4])
        XCTAssertEqual(try sha256(transformed[0].streamed), "e3dc509c394c4428389a6b43dc435489f861d6cb1fc9bbe5948ff21d097776c4")
        _ = try bakeBothWays(ply: ply, name: "capture-tiers", lodFractions: [1.0, 0.5], options: transformedOptions)

        let budgeted = try bakeBothWays(ply: ply, name: "budget", lodFractions: [1.0], options: budgetedOptions)
        let budgetedFile = try UntoldGSFile(url: budgeted[0].streamed)
        XCTAssertEqual(budgetedFile.header.shDegree, 1)
        XCTAssertEqual(budgetedFile.header.splatCount, 700)
        XCTAssertFalse(budgetedFile.header.hasCoarseLevels)
        XCTAssertEqual(try sha256(budgeted[0].streamed), "a61d665f6ca56d27897f69e974515d00e50cf1f5d364931446be68129ccdf327")
        _ = try bakeBothWays(ply: ply, name: "budget-tiers", lodFractions: [1.0, 0.5], options: budgetedOptions)
    }

    func testBinaryFixtureReadsIdenticallyThroughBothParsers() throws {
        let ply = try binaryFixture()
        let legacy = try LegacyGaussianCookPath.readGaussianAsset(from: ply)
        let streamed = try PLYReader.readGaussianAsset(from: ply)
        XCTAssertEqual(legacy.splats.count, streamed.splats.count)
        XCTAssertEqual(legacy.splats.count, 1100 - 21, "every 53rd splat is culled by the reader")
        for (a, b) in zip(legacy.splats, streamed.splats) {
            XCTAssertEqual(a.center, b.center)
            XCTAssertEqual(a.scale, b.scale)
            XCTAssertEqual(a.color, b.color)
            XCTAssertEqual(a.quat, b.quat)
            XCTAssertEqual(a.opacity, b.opacity)
        }
        XCTAssertEqual(legacy.sphericalHarmonics?.coefficients, streamed.sphericalHarmonics?.coefficients)
        XCTAssertEqual(streamed.sphericalHarmonics?.degree, 3)
    }

    // MARK: - Centre bounds

    func testStreamedCenterBoundsMatchTheLoadedSplats() throws {
        for ply in try [asciiFixture(), binaryFixture()] {
            let splats = try PLYReader.readGaussianSplats(from: ply)
            var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for splat in splats {
                minimum = simd_min(minimum, SIMD3<Float>(splat.center.x, splat.center.y, splat.center.z))
                maximum = simd_max(maximum, SIMD3<Float>(splat.center.x, splat.center.y, splat.center.z))
            }
            let bounds = try XCTUnwrap(PLYReader.readGaussianCenterBounds(from: ply))
            XCTAssertEqual(bounds.min, minimum, ply.lastPathComponent)
            XCTAssertEqual(bounds.max, maximum, ply.lastPathComponent)
        }
    }

    // MARK: - Progress and cancellation

    func testProgressRunsThroughThePhasesInOrderAndEndsAtOne() throws {
        let ply = try binaryFixture()
        let reports = ProgressLog()
        let control = UntoldGSCookControl(progress: { reports.append($0) })
        let output = temporaryDirectory.appendingPathComponent("progress.untoldgs")
        _ = try bakeGaussianSplatProgressiveTiers(plyURL: ply, outputBaseURL: output, lodFractions: [1.0, 0.5], cookOptions: transformedOptions, control: control)

        let all = reports.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(all.first?.phase, .read)
        XCTAssertEqual(all.last?.phase, .write)
        XCTAssertEqual(all.last?.overall, 1)
        XCTAssertEqual(all.last?.tierIndex, 1)
        XCTAssertTrue(all.allSatisfy { $0.tierCount == 2 })
        let order: [UntoldGSCookPhase] = [.read, .cook, .chunk, .coarsen, .write]
        var previous = all[0]
        for report in all.dropFirst() {
            XCTAssertGreaterThanOrEqual(report.overall, previous.overall, "overall never goes back")
            XCTAssertTrue(report.fraction >= 0 && report.fraction <= 1)
            if report.tierIndex == previous.tierIndex {
                let a = try XCTUnwrap(order.firstIndex(of: previous.phase))
                let b = try XCTUnwrap(order.firstIndex(of: report.phase))
                XCTAssertGreaterThanOrEqual(b, a, "phases arrive in order within a tier")
                if a == b {
                    XCTAssertGreaterThanOrEqual(report.fraction, previous.fraction, "fractions are monotonic within a phase")
                }
            } else {
                XCTAssertEqual(report.tierIndex, previous.tierIndex + 1)
            }
            previous = report
        }
        for phase in order {
            XCTAssertTrue(all.contains { $0.phase == phase }, "\(phase) is reported")
        }
    }

    func testProgressStaysMonotonicWhenTheTierHasNoCoarseLevels() throws {
        // Without coarse levels the chunk loop reports as `chunk` after the ordering did; 135
        // chunks of 8 take several batches, so the fraction must carry on from the ordering's
        // share rather than start again at zero.
        let ply = try binaryFixture()
        var options = transformedOptions
        options.log2ChunkSplats = 3
        options.coarseLevels = .off
        let reports = ProgressLog()
        let output = temporaryDirectory.appendingPathComponent("flat.untoldgs")
        _ = try bakeGaussianSplatProgressiveTiers(plyURL: ply, outputBaseURL: output, lodFractions: [1.0], cookOptions: options, control: UntoldGSCookControl(progress: { reports.append($0) }))

        let chunk = reports.all.filter { $0.phase == .chunk }
        XCTAssertGreaterThan(chunk.count, 4, "the ordering and every chunk batch report")
        XCTAssertFalse(reports.all.contains { $0.phase == .coarsen })
        for (previous, next) in zip(chunk, chunk.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.fraction, previous.fraction, "chunk fractions never run backwards")
            XCTAssertGreaterThanOrEqual(next.overall, previous.overall)
        }
        XCTAssertEqual(chunk.last?.fraction, 1)
        XCTAssertEqual(reports.all.last?.overall, 1)
    }

    func testCancellationInEveryPhaseLeavesNoFileBehind() throws {
        let ply = try binaryFixture()
        for phase in UntoldGSCookPhase.allCases {
            let directory = temporaryDirectory.appendingPathComponent("cancel-\(phase.rawValue)", isDirectory: true)
            let output = directory.appendingPathComponent("cancelled.untoldgs")
            let seen = ProgressLog()
            let control = UntoldGSCookControl(
                progress: { report in
                    // Cancel the moment the second tier reaches `phase`, so the first tier —
                    // renamed into place by then — has to go too. `read` and `cook` run once;
                    // the half tier is below the automatic coarse-level threshold, so
                    // `coarsen` is cancelled in the first tier, with its temporary file open.
                    if report.phase == phase, report.tierIndex == 1 || phase == .read || phase == .cook || phase == .coarsen {
                        seen.cancel()
                    }
                    seen.append(report)
                },
                isCancelled: { seen.isCancelled }
            )
            XCTAssertThrowsError(
                try bakeGaussianSplatProgressiveTiers(plyURL: ply, outputBaseURL: output, lodFractions: [1.0, 0.5], cookOptions: transformedOptions, control: control),
                "\(phase)"
            ) { error in
                XCTAssertEqual(error as? UntoldGSCookError, .cancelled, "\(phase)")
            }
            XCTAssertTrue(seen.isCancelled, "\(phase) was reached")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            XCTAssertEqual(leftovers, [], "\(phase): no tier and no temporary file remains")
        }
    }

    func testTaskCancellationStopsTheCook() async throws {
        let ply = try binaryFixture()
        let output = temporaryDirectory.appendingPathComponent("task-cancelled.untoldgs")
        let options = transformedOptions
        let task = Task.detached {
            try bakeGaussianSplatProgressiveTiers(plyURL: ply, outputBaseURL: output, lodFractions: [1.0], cookOptions: options, control: UntoldGSCookControl())
        }
        task.cancel()
        do {
            _ = try await task.value
            // A very fast cook may finish before the cancellation lands; then the file exists.
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        } catch {
            XCTAssertEqual(error as? UntoldGSCookError, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCancellationErrorDescribesItself() {
        XCTAssertEqual(UntoldGSCookError.cancelled.description, "the cook was cancelled")
    }
}

/// Progress reports collected from the cooking thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [UntoldGSCookProgress] = []
    private var cancelled = false

    func append(_ report: UntoldGSCookProgress) {
        lock.withLock { reports.append(report) }
    }

    var all: [UntoldGSCookProgress] {
        lock.withLock { reports }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
