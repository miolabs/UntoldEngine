//
//  UntoldGSWriter.swift
//  UntoldEngine
//
//  Builds a version-3 `.untoldgs` file from an in-memory splat list: Morton
//  ordering, chunking with per-chunk quantisation ranges, a binary tree over
//  the chunk array, and page-aligned sections.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

public struct UntoldGSWriteOptions: Sendable {
    /// log2 of the maximum splat count per chunk. 10 (1024 splats) for objects, 12 for environments.
    public var log2ChunkSplats: UInt8 = UntoldGSFormat.defaultLog2ChunkSplats
    /// SH degree to store. Every splat must carry the matching coefficient count. 0 stores none.
    public var shDegree: UInt8 = 0
    /// Maximum chunks under a tree leaf.
    public var leafMaxChunks: Int = 8
    /// Within a chunk, order splats by opacity × area so partial reads keep the important ones.
    public var sortByImportanceWithinChunk = true
    public var coordinateSystem: UntoldGSCoordinateSystem = .rightUpBack
    public var colorSpace: UntoldGSColorSpace = .sRGBDisplayReferred
    public var antialiased = false
    public var isEnvironment = false
    /// Asset-level bounding box to bake. Defaults to the splat bounds expanded by each
    /// splat's largest scale, like `computeGaussianSplatBoundingBox`.
    public var boundingBoxMin: SIMD3<Float>?
    public var boundingBoxMax: SIMD3<Float>?
    /// Bake-time overdraw statistic for this tier — see `estimatedGaussianOverdraw`.
    public var meanSquaredSplatExtent: Float = 0
    public var splatToMesh: simd_float4x4 = matrix_identity_float4x4
    public var captureExposureEV: Float = 0
    public var captureWhiteBalance = SIMD3<Float>(repeating: 1)
    /// Per-chunk coarse levels to bake into the optional section (`UntoldGSCoarsener`). With
    /// `coarseLevelsAutomatic` off, `nil` writes no section and a value always writes one.
    public var coarseLevels: UntoldGSCoarseLevelOptions?
    /// Bake `coarseLevels ?? .default` only when the tier has at least
    /// `UntoldGSFormat.coarseLevelsAutomaticMinimumChunks` chunks and its chunks are large enough
    /// for a level at all (`minimumChunkSplats`), with the ratios clamped to the chunk size, and
    /// write no section otherwise — so small assets bake exactly as they did before the section
    /// existed. Off, `coarseLevels` decides on its own.
    public var coarseLevelsAutomatic = true

    public init() {}
}

/// What `UntoldGSFormat.writeReporting` baked beyond the fine chunks.
public struct UntoldGSWriteReport: Sendable, Equatable {
    public var chunkCount: Int
    /// The coarse section, or nil when none was written.
    public var coarse: UntoldGSCoarseLevelReport?

    public init(chunkCount: Int, coarse: UntoldGSCoarseLevelReport? = nil) {
        self.chunkCount = chunkCount
        self.coarse = coarse
    }
}

public extension UntoldGSFormat {
    /// Encodes `splats` into a complete version-3 file image.
    static func write(splats: [UntoldGSSplat], options: UntoldGSWriteOptions = .init()) throws -> Data {
        try writeReporting(splats: splats, options: options).data
    }

    /// Encodes `splats` into a complete version-3 file image and reports what was baked.
    static func writeReporting(splats: [UntoldGSSplat], options: UntoldGSWriteOptions = .init()) throws -> (data: Data, report: UntoldGSWriteReport) {
        try writeReporting(splats: splats, options: options, serialCoarsening: false)
    }

    /// `writeReporting` with the coarsener's chunk loop optionally forced onto one thread (tests
    /// pin that the scheduling never changes a byte).
    internal static func writeReporting(splats: [UntoldGSSplat], options: UntoldGSWriteOptions, serialCoarsening: Bool) throws -> (data: Data, report: UntoldGSWriteReport) {
        guard !splats.isEmpty else { throw UntoldGSError.invalidInput("no splats to write") }
        guard options.shDegree <= maxSHDegree else {
            throw UntoldGSError.unsupported("spherical-harmonics degree \(options.shDegree)")
        }
        guard options.log2ChunkSplats >= 1, options.log2ChunkSplats <= maxLog2ChunkSplats else {
            throw UntoldGSError.unsupported("log2ChunkSplats \(options.log2ChunkSplats)")
        }

        let shCount = shCoefficientCount(degree: options.shDegree)
        for (index, splat) in splats.enumerated() {
            guard splat.sphericalHarmonics.count == shCount else {
                throw UntoldGSError.invalidInput(
                    "splat \(index) carries \(splat.sphericalHarmonics.count) SH coefficients, expected \(shCount)"
                )
            }
            // One degenerate splat (a scale that overflowed through exp() on import, a NaN
            // colour) must fail the bake, not trap inside an integer conversion.
            guard splat.isFinite else {
                throw UntoldGSError.invalidInput("splat \(index) has non-finite data or a non-positive scale")
            }
        }

        let bounds = bounds(of: splats)
        let order = mortonOrder(splats, boundsMin: bounds.min, boundsMax: bounds.max)
        let splatsPerChunk = 1 << Int(options.log2ChunkSplats)
        let chunkRanges = stride(from: 0, to: order.count, by: splatsPerChunk).map { start in
            Array(order[start ..< min(start + splatsPerChunk, order.count)])
        }

        // The coarse levels: automatic above the chunk-count threshold (the template's ratios
        // clamped to the chunk size), or exactly what was asked for.
        let coarseOptions: UntoldGSCoarseLevelOptions? = try {
            if options.coarseLevelsAutomatic {
                let template = options.coarseLevels ?? .default
                try template.validate(log2ChunkSplats: maxLog2ChunkSplats)
                // Below the chunk-count threshold, or with chunks too small for any chunk to
                // have a level, no section at all.
                guard chunkRanges.count >= coarseLevelsAutomaticMinimumChunks, splatsPerChunk >= template.minimumChunkSplats else { return nil }
                let clamped = template.clamped(toLog2ChunkSplats: options.log2ChunkSplats)
                return clamped.levelCount > 0 ? clamped : nil
            }
            guard let requested = options.coarseLevels else { return nil }
            try requested.validate(log2ChunkSplats: options.log2ChunkSplats)
            return requested
        }()

        let headerSection = alignedToPage(headerSize)
        let chunkIndexOffset = headerSection
        let chunkIndexSection = alignedToPage(chunkRanges.count * chunkEntrySize)

        var entries: [UntoldGSChunkEntry] = []
        entries.reserveCapacity(chunkRanges.count)
        var payloads: [Data] = []
        payloads.reserveCapacity(chunkRanges.count)

        for indices in chunkRanges {
            var ordered = indices
            if options.sortByImportanceWithinChunk {
                ordered.sort { importance(splats[$0]) > importance(splats[$1]) }
            }
            let encoded = encodeChunk(ordered.map { splats[$0] }, shCount: shCount)
            entries.append(encoded.entry)
            payloads.append(encoded.payload)
        }

        // The merge seeds on the Morton order of each chunk (`chunkRanges`), not the importance
        // order the fine payload took; one chunk per iteration, results by chunk index. The
        // chunk's splats are gathered inside the work item, so one chunk's copy lives per thread
        // rather than a second copy of the whole tier for the pass.
        var coarseLevels: [UntoldGSCoarseLevels] = []
        if let coarseOptions {
            coarseLevels = try coarsenChunks(splats, ranges: chunkRanges, options: coarseOptions, serial: serialCoarsening)
        }

        let nodes = try buildTree(entries: &entries, leafMaxChunks: max(1, options.leafMaxChunks))
        let nodeTreeOffset = chunkIndexOffset + chunkIndexSection
        let nodeTreeSection = alignedToPage(nodes.count * treeNodeSize)
        let payloadOffset = nodeTreeOffset + nodeTreeSection

        var cursor = payloadOffset
        for index in entries.indices {
            entries[index].payloadOffset = UInt64(cursor)
            cursor += Int(entries[index].payloadBytes)
        }
        var fileSize = cursor

        var flags: UInt32 = 0
        if options.shDegree > 0 {
            flags |= UntoldGSFlags.hasSphericalHarmonics
        }
        if options.antialiased {
            flags |= UntoldGSFlags.antialiased
        }
        if options.isEnvironment {
            flags |= UntoldGSFlags.environment
        }

        // The coarse section: the level-major index on the page after the last fine payload, the
        // records after it coarsest level first, each level in chunk order, 16-byte aligned.
        var coarseEntries: [UntoldGSChunkEntry] = []
        var coarsePayloads: [Data] = []
        var coarseIndexOffset = 0
        var coarsePayloadOffset = 0
        var coarseRecordCount = 0
        var coarseReport: UntoldGSCoarseLevelReport?
        if let coarseOptions {
            let levelCount = coarseOptions.levelCount
            coarseIndexOffset = alignedToPage(cursor)
            coarsePayloadOffset = coarseIndexOffset + alignedToPage(levelCount * entries.count * coarseIndexEntrySize)
            coarseEntries = [UntoldGSChunkEntry](repeating: UntoldGSChunkEntry.emptyCoarse(level: 0, chunk: 0, nodeId: 0), count: levelCount * entries.count)
            var recordsPerLevel = [Int](repeating: 0, count: levelCount)
            var chunksWithoutLevels = 0
            cursor = coarsePayloadOffset
            for level in stride(from: levelCount, through: 1, by: -1) {
                for chunk in entries.indices {
                    let merged = coarseLevels[chunk].level(level)
                    let slot = (level - 1) * entries.count + chunk
                    if level == 1, merged.isEmpty {
                        chunksWithoutLevels += 1
                    }
                    guard !merged.isEmpty else {
                        coarseEntries[slot] = .emptyCoarse(level: UInt16(level), chunk: UInt32(chunk), nodeId: entries[chunk].nodeId)
                        continue
                    }
                    let encoded = encodeChunk(orderedByImportance(merged), shCount: 0, padToPage: false)
                    var entry = encoded.entry
                    entry.payloadOffset = UInt64(cursor)
                    entry.lodLevel = UInt16(level)
                    entry.nodeId = entries[chunk].nodeId
                    entry.reserved0 = UInt32(chunk)
                    coarseEntries[slot] = entry
                    coarsePayloads.append(encoded.payload)
                    cursor += encoded.payload.count
                    recordsPerLevel[level - 1] += merged.count
                    coarseRecordCount += merged.count
                }
            }
            fileSize = alignedToPage(cursor)
            flags |= UntoldGSFlags.hasCoarseLevels
            coarseReport = UntoldGSCoarseLevelReport(
                levelCount: levelCount,
                ratioLog2: Array(coarseOptions.ratioLog2.prefix(levelCount)),
                recordsPerLevel: recordsPerLevel,
                bytes: fileSize - coarseIndexOffset,
                chunksWithoutLevels: chunksWithoutLevels
            )
        }

        // Only scanned when the caller did not supply a box (the bake always does).
        let boundingBox = (options.boundingBoxMin == nil || options.boundingBoxMax == nil)
            ? defaultBoundingBox(of: splats)
            : (min: options.boundingBoxMin!, max: options.boundingBoxMax!)
        let header = UntoldGSHeaderV3(
            flags: flags,
            shDegree: options.shDegree,
            coordinateSystem: options.coordinateSystem,
            colorSpace: options.colorSpace,
            log2ChunkSplats: options.log2ChunkSplats,
            splatCount: UInt32(splats.count),
            chunkCount: UInt32(entries.count),
            nodeCount: UInt32(nodes.count),
            lodLevels: 1,
            boundsMin: bounds.min,
            boundsMax: bounds.max,
            boundingBoxMin: options.boundingBoxMin ?? boundingBox.min,
            boundingBoxMax: options.boundingBoxMax ?? boundingBox.max,
            meanSquaredSplatExtent: options.meanSquaredSplatExtent,
            captureExposureEV: options.captureExposureEV,
            captureWhiteBalance: options.captureWhiteBalance,
            splatToMesh: options.splatToMesh,
            chunkIndexOffset: UInt64(chunkIndexOffset),
            nodeTreeOffset: UInt64(nodeTreeOffset),
            paletteOffset: 0,
            payloadOffset: UInt64(payloadOffset),
            fileSize: UInt64(fileSize),
            coarseIndexOffset: UInt64(coarseIndexOffset),
            coarsePayloadOffset: UInt64(coarsePayloadOffset),
            coarseRecordCount: UInt32(coarseRecordCount),
            coarseLevelCount: UInt8(coarseOptions?.levelCount ?? 0),
            coarseRatioLog2: coarseOptions.map { Array($0.ratioLog2.prefix($0.levelCount)) } ?? [0, 0]
        )

        let writer = UntoldBinaryWriter()
        header.encode(to: writer)
        writer.align(to: pageAlignment)
        for entry in entries {
            entry.encode(to: writer)
        }
        writer.align(to: pageAlignment)
        for node in nodes {
            node.encode(to: writer)
        }
        writer.align(to: pageAlignment)
        precondition(writer.count == payloadOffset, "section layout mismatch")
        for payload in payloads {
            writer.writeData(payload)
            writer.align(to: pageAlignment)
        }
        if coarseOptions != nil {
            precondition(writer.count == coarseIndexOffset, "coarse index layout mismatch")
            for entry in coarseEntries {
                entry.encode(to: writer)
            }
            writer.align(to: pageAlignment)
            precondition(writer.count == coarsePayloadOffset, "coarse payload layout mismatch")
            for payload in coarsePayloads {
                writer.writeData(payload)
            }
            writer.align(to: pageAlignment)
        }
        precondition(writer.count == fileSize, "payload layout mismatch")
        return (writer.data, UntoldGSWriteReport(chunkCount: entries.count, coarse: coarseReport))
    }

    /// Encodes and writes atomically, creating the parent directory when needed.
    static func write(splats: [UntoldGSSplat], options: UntoldGSWriteOptions = .init(), to url: URL) throws {
        _ = try writeReporting(splats: splats, options: options, to: url)
    }

    /// `write(splats:options:to:)` returning what was baked.
    static func writeReporting(splats: [UntoldGSSplat], options: UntoldGSWriteOptions = .init(), to url: URL) throws -> UntoldGSWriteReport {
        let (data, report) = try writeReporting(splats: splats, options: options)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return report
    }

    // MARK: - Coarse levels

    /// Coarsens every chunk — `ranges[c]` the indices into `splats` of chunk `c`, in Morton
    /// order — in parallel unless `serial`; the result of chunk `c` lands at index `c` whatever
    /// the scheduling, and each chunk's arithmetic is sequential in a fixed order, so the bytes
    /// never depend on the thread count. Each work item gathers its own chunk's splats, so the
    /// memory in flight is one chunk per thread, not a copy of the tier.
    internal static func coarsenChunks(_ splats: [UntoldGSSplat], ranges: [[Int]], options: UntoldGSCoarseLevelOptions, serial: Bool) throws -> [UntoldGSCoarseLevels] {
        let results = CoarsenedChunks(count: ranges.count)
        let work: @Sendable (Int) -> Void = { chunk in
            do {
                let gathered = ranges[chunk].map { splats[$0] }
                try results.store(UntoldGSCoarsener.coarsen(gathered, options: options), at: chunk)
            } catch let error as UntoldGSError {
                results.fail(error, at: chunk)
            } catch {
                results.fail(.invalidInput("\(error)"), at: chunk)
            }
        }
        if serial {
            for chunk in ranges.indices {
                work(chunk)
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: ranges.count, execute: work)
        }
        return try results.take()
    }

    /// The coarsener's per-chunk results, filled from `concurrentPerform` under one lock (one
    /// store per chunk, so the lock is never contended for long).
    private final class CoarsenedChunks: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [UntoldGSCoarseLevels]
        private var failures: [UntoldGSError?]

        init(count: Int) {
            levels = [UntoldGSCoarseLevels](repeating: .none, count: count)
            failures = [UntoldGSError?](repeating: nil, count: count)
        }

        func store(_ result: UntoldGSCoarseLevels, at chunk: Int) {
            lock.withLock { levels[chunk] = result }
        }

        func fail(_ error: UntoldGSError, at chunk: Int) {
            lock.withLock { failures[chunk] = error }
        }

        /// The levels by chunk index, or the first chunk's failure.
        func take() throws -> [UntoldGSCoarseLevels] {
            try lock.withLock {
                if let failure = failures.compactMap({ $0 }).first {
                    throw failure
                }
                return levels
            }
        }
    }

    /// The rank order of a coarse level: importance descending, ties by index.
    internal static func orderedByImportance(_ splats: [UntoldGSSplat]) -> [UntoldGSSplat] {
        UntoldGSCoarsener.orderedByImportance(splats)
    }

    // MARK: - Ordering

    /// Indices of `splats` sorted by Morton key over `boundsMin...boundsMax`.
    static func mortonOrder(_ splats: [UntoldGSSplat], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) -> [Int] {
        let keys = splats.map { UntoldGSPacking.mortonKey($0.position, boundsMin: boundsMin, boundsMax: boundsMax) }
        return splats.indices.sorted { a, b in
            keys[a] != keys[b] ? keys[a] < keys[b] : a < b
        }
    }

    /// Bounds of the splat centres.
    static func bounds(of splats: [UntoldGSSplat]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for splat in splats {
            minimum = simd_min(minimum, splat.position)
            maximum = simd_max(maximum, splat.position)
        }
        return (minimum, maximum)
    }

    /// Centre bounds expanded by each splat's largest scale (`computeGaussianSplatBoundingBox`
    /// applies the same rule to importer splats through `expandedBoundingBox`).
    static func defaultBoundingBox(of splats: [UntoldGSSplat]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        expandedBoundingBox(count: splats.count, position: { splats[$0].position }, radius: { splats[$0].scale.max() })
    }

    /// Bounds of `count` centres, each grown by its radius: the box a splat visually extends
    /// to, rather than a centres-only box. Empty input gives the empty (inverted) box.
    static func expandedBoundingBox(
        count: Int,
        position: (Int) -> SIMD3<Float>,
        radius: (Int) -> Float
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for index in 0 ..< count {
            let extent = SIMD3<Float>(repeating: radius(index))
            let center = position(index)
            minimum = simd_min(minimum, center - extent)
            maximum = simd_max(maximum, center + extent)
        }
        return (minimum, maximum)
    }

    /// Opacity × summed pairwise scale products (proportional to surface area).
    internal static func importance(_ splat: UntoldGSSplat) -> Float {
        let s = splat.scale
        return splat.opacity * (s.x * s.y + s.y * s.z + s.z * s.x)
    }

    // MARK: - Chunk encoding

    internal struct EncodedChunk {
        var entry: UntoldGSChunkEntry
        var payload: Data
    }

    /// Encodes one chunk (or one coarse level of a chunk) against its own ranges. A fine chunk's
    /// `payloadBytes` is padded to the page; a coarse level's (`padToPage == false`) is the
    /// unpadded core size, the levels being packed 16-byte aligned inside their own region.
    internal static func encodeChunk(_ splats: [UntoldGSSplat], shCount: Int, padToPage: Bool = true) -> EncodedChunk {
        var aabbMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var aabbMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var logScaleMin = Float.greatestFiniteMagnitude
        var logScaleMax = -Float.greatestFiniteMagnitude

        for splat in splats {
            aabbMin = simd_min(aabbMin, splat.position)
            aabbMax = simd_max(aabbMax, splat.position)
            for axis in 0 ..< 3 {
                let logScale = log(max(splat.scale[axis], Float.leastNormalMagnitude))
                logScaleMin = min(logScaleMin, logScale)
                logScaleMax = max(logScaleMax, logScale)
            }
        }

        let ranges = UntoldGSPacking.ChunkRanges(
            aabbMin: aabbMin, aabbMax: aabbMax, logScaleMin: logScaleMin, logScaleMax: logScaleMax
        )

        let coreWriter = UntoldBinaryWriter()
        for splat in splats {
            let record = UntoldGSPacking.encode(splat, ranges: ranges)
            coreWriter.writeUInt32LE(record.position)
            coreWriter.writeUInt32LE(record.rotation)
            coreWriter.writeUInt32LE(record.scale)
            coreWriter.writeUInt32LE(record.rgba)
        }
        if shCount > 0 {
            for splat in splats {
                for coefficient in splat.sphericalHarmonics {
                    coreWriter.writeUInt8(UntoldGSPacking.packSHCoefficient(coefficient))
                }
            }
        }

        let payload = coreWriter.data
        let entry = UntoldGSChunkEntry(
            payloadOffset: 0,
            payloadBytes: UInt32(padToPage ? alignedToPage(payload.count) : payload.count),
            coreBytes: UInt32(splats.count * coreRecordSize),
            splatCount: UInt32(splats.count),
            lodLevel: 0,
            nodeId: 0,
            aabbMin: aabbMin,
            aabbMax: aabbMax,
            logScaleMin: logScaleMin,
            logScaleMax: logScaleMax,
            crc32: UntoldGSCRC32.checksum(payload)
        )
        return EncodedChunk(entry: entry, payload: payload)
    }

    // MARK: - Tree

    /// Binary tree over the chunk array by range halving, so every node's chunks are
    /// contiguous. Nodes are stored in preorder; leaves stamp `nodeId` on their chunks.
    internal static func buildTree(entries: inout [UntoldGSChunkEntry], leafMaxChunks: Int) throws -> [UntoldGSTreeNode] {
        var nodes: [UntoldGSTreeNode] = []

        func build(first: Int, count: Int) -> UInt32 {
            let nodeIndex = UInt32(nodes.count)
            var aabbMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var aabbMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for index in first ..< first + count {
                aabbMin = simd_min(aabbMin, entries[index].aabbMin)
                aabbMax = simd_max(aabbMax, entries[index].aabbMax)
            }
            nodes.append(UntoldGSTreeNode(aabbMin: aabbMin, aabbMax: aabbMax, firstChunk: UInt32(first), chunkCount: UInt32(count)))

            if count <= leafMaxChunks {
                for index in first ..< first + count {
                    entries[index].nodeId = UInt16(truncatingIfNeeded: nodeIndex)
                }
                return nodeIndex
            }
            let half = count / 2
            let child0 = build(first: first, count: half)
            let child1 = build(first: first + half, count: count - half)
            nodes[Int(nodeIndex)].child0 = child0
            nodes[Int(nodeIndex)].child1 = child1
            return nodeIndex
        }

        _ = build(first: 0, count: entries.count)
        guard nodes.count <= Int(UInt16.max) else {
            throw UntoldGSError.unsupported("tree with \(nodes.count) nodes exceeds \(UInt16.max)")
        }
        return nodes
    }
}

extension UntoldGSChunkEntry {
    /// The coarse index entry of a chunk that has no records at `level`: zero sizes and ranges,
    /// labelled with its level and chunk so the index stays self-describing.
    static func emptyCoarse(level: UInt16, chunk: UInt32, nodeId: UInt16) -> UntoldGSChunkEntry {
        UntoldGSChunkEntry(
            payloadOffset: 0, payloadBytes: 0, coreBytes: 0, splatCount: 0,
            lodLevel: level, nodeId: nodeId,
            aabbMin: .zero, aabbMax: .zero, logScaleMin: 0, logScaleMax: 0,
            reserved0: chunk, crc32: 0
        )
    }
}

// MARK: - Importer conversion

/// Converts importer splats (plus their channel-major SH including the DC term) into
/// writer splats carrying only the higher-order SH coefficients. `keeping` selects and
/// orders the splats, as the progressive bake does.
func makeUntoldGSSplats(asset: GaussianSplatAsset, keeping indices: [Int]) -> [UntoldGSSplat] {
    let perChannel = asset.sphericalHarmonics?.coefficientsPerChannel ?? 1
    let perSplat = perChannel * 3
    let higherOrder = perChannel - 1
    var splats: [UntoldGSSplat] = []
    splats.reserveCapacity(indices.count)
    for index in indices {
        var coefficients: [Float] = []
        if let harmonics = asset.sphericalHarmonics, higherOrder > 0 {
            coefficients.reserveCapacity(higherOrder * 3)
            let base = index * perSplat
            for channel in 0 ..< 3 {
                let start = base + channel * perChannel + 1
                coefficients.append(contentsOf: harmonics.coefficients[start ..< start + higherOrder])
            }
        }
        splats.append(UntoldGSSplat(asset.splats[index], sphericalHarmonics: coefficients))
    }
    return splats
}
