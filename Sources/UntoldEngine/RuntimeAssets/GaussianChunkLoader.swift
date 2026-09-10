//
//  GaussianChunkLoader.swift
//  UntoldEngine
//
//  Loads a version-3 `.untoldgs` file for rendering. Below the paging threshold
//  (`GaussianPagingPolicy`) it reads every chunk by byte range (CRC-verified) into
//  the packed buffer that stays resident — the 16-byte core records the fused
//  per-chunk pass (`gaussianChunkDecodePreprocess`) decodes every frame — binds the
//  SH bytes as they are (the file already stores the renderer's byte contract), and
//  keeps the chunk table (`GaussianChunkTable`) so the frame can cull chunk by
//  chunk. Above the threshold the records live in a bounded page pool of 256-rank
//  tiers instead: the packed buffer is the pool, the chunk table carries the
//  per-slot residency, page and demand tables, nothing is read at load, and a
//  `GaussianPageManager` fills the pool from the cull's demand frame by frame. The
//  file is never read whole and no CPU decode runs. `decodeEncodedSplats` expands
//  a whole-resident load's records once into the `EncodedGaussianSplat` layout with
//  the `gaussianDecodeChunks` kernel, for the whole-buffer path (when the per-chunk
//  kernels are unavailable) and for tests.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import Foundation
import Metal
import simd

/// The chunk table of a `.untoldgs` asset as the renderer keeps it after the load: the
/// per-chunk decode constants (`GaussianChunkDecodeConstants`, 48 bytes per chunk — centre
/// AABB, log-scale range, first splat and count) GPU-resident for the chunk-level cull
/// (`gaussianChunkCull`), the file's index on the CPU (the pager's byte ranges and CRCs, the
/// tests), and for a paged entity the per-slot tables the pager writes.
struct GaussianChunkTable {
    /// `GaussianChunkDecodeConstants × chunkCount`, in chunk order; `firstSplat` runs
    /// contiguously so chunk `i` owns splats `firstSplat ..< firstSplat + splatCount` of the
    /// packed buffer (and of the SH buffer) — of a whole-resident entity; a paged entity's
    /// fused pass maps ranks through the page table instead and never reads it.
    let constantsBuffer: MTLBuffer
    let chunkCount: Int
    /// `1 << header.log2ChunkSplats`: the most splats any chunk holds, the threadgroup width
    /// of the per-chunk passes.
    let splatsPerChunk: Int
    let index: UntoldGSIndex
    /// Per in-flight frame slot, written by `gaussianChunkCull` and `gaussianComputeChunkQuotas`
    /// and read by the fused pass the same frame: the visible-chunk list
    /// (`GaussianVisibleChunk × chunkCount`) and its `GaussianVisibleSet`-shaped record.
    /// Allocated by `buildGaussianLoadResult` (`allocateGaussianVisibleChunkBuffers`).
    var visibleChunks: [MTLBuffer] = []
    var visibleChunkSets: [MTLBuffer] = []
    /// A paged entity's per-slot tables (`GaussianPageManager`): the residency
    /// (`GaussianChunkResidency × chunkCount`), the page table (`uint × chunkCount ×
    /// pagesPerChunk`) and the demand words (`uint × chunkCount`); empty for a whole-resident
    /// entity.
    var residencyTables: [MTLBuffer] = []
    var pageTables: [MTLBuffer] = []
    var demandTables: [MTLBuffer] = []
    /// Tiers per chunk and log2 of the ranks per tier of a paged entity (1 and 0 otherwise).
    var pagesPerChunk = 1
    var ranksPerPageLog2 = 0

    var gpuBytes: Int {
        constantsBuffer.length
            + visibleChunks.reduce(0) { $0 + $1.length }
            + visibleChunkSets.reduce(0) { $0 + $1.length }
            + residencyTables.reduce(0) { $0 + $1.length }
            + pageTables.reduce(0) { $0 + $1.length }
            + demandTables.reduce(0) { $0 + $1.length }
    }
}

/// GPU-resident result of loading a `.untoldgs` file.
struct GaussianChunkLoadResult {
    let splatCount: Int
    /// The file's 16-byte core records, contiguous in chunk order (`uint4` per splat) — or,
    /// for a paged load, the core page pool the pager fills.
    let packedSplatBuffer: MTLBuffer
    /// The harmonics as stored — or the harmonics page pool, in the core pool's slot layout.
    let sphericalHarmonicsBuffer: MTLBuffer?
    let sphericalHarmonicsMetadata: GaussianSHMetadata?
    let meanSquaredSplatExtent: Float
    /// Capture exposure (EV) and white balance the cook recorded in the header.
    let captureExposureEV: Float
    let captureWhiteBalance: SIMD3<Float>
    let boundingBox: (min: simd_float3, max: simd_float3)
    /// Chunk index of the file, kept for callers that want to page later.
    let index: UntoldGSIndex
    /// The same index's decode constants, GPU-resident, for the chunk-level cull.
    let chunkTable: GaussianChunkTable
    /// The pager of a paged load; nil when every record is resident.
    var pager: GaussianPageManager?

    /// Whether the records live in a page pool.
    var isPaged: Bool {
        pager != nil
    }
}

enum GaussianChunkLoadError: Error, CustomStringConvertible {
    case decodePipelineUnavailable
    case deviceUnavailable
    case tooManySplats(Int)
    case bufferAllocationFailed(String)
    case gpuDecodeFailed(String)
    /// `decodeEncodedSplats` of a paged load: the pool holds only what the frames asked for.
    case pagedAssetCannotBeExpanded

    var description: String {
        switch self {
        case .decodePipelineUnavailable: "the Gaussian decode compute pipeline is not available"
        case .deviceUnavailable: "no Metal device or command queue"
        case let .tooManySplats(count): "too many Gaussian splats: \(count) exceeds maximum \(maxNumOfGaussians)"
        case let .bufferAllocationFailed(what): "failed to allocate \(what)"
        case let .gpuDecodeFailed(reason): "GPU decode failed: \(reason)"
        case .pagedAssetCannotBeExpanded: "a paged Gaussian asset cannot be expanded into the whole-buffer layout"
        }
    }
}

enum GaussianChunkLoader {
    /// True when the decode kernel compiled, so `.untoldgs` files can take the GPU path.
    static var isAvailable: Bool {
        gaussianDecodePipeline.success && gaussianDecodePipeline.pipelineState != nil
    }

    /// Reads `url` into GPU buffers. Synchronous: the caller is already off the render thread
    /// on the async and streaming paths, and the synchronous `setEntityGaussian` blocks by
    /// contract. Nothing runs on the GPU here; the records are decoded by the frame. With
    /// `allowPaging` (the caller has the per-chunk kernels) an asset above the paging
    /// threshold gets a page pool and a pager instead of resident records; the whole-resident
    /// load is unchanged below it.
    static func load(url: URL, allowPaging: Bool = false) throws -> GaussianChunkLoadResult {
        guard let device = renderInfo.device else {
            throw GaussianChunkLoadError.deviceUnavailable
        }
        guard isAvailable else {
            throw GaussianChunkLoadError.decodePipelineUnavailable
        }

        let source = try GaussianPageSourceFactory.make(url)
        let index = source.index
        let header = index.header
        let splatCount = Int(header.splatCount)
        guard splatCount <= Int(maxNumOfGaussians) else {
            source.close()
            throw GaussianChunkLoadError.tooManySplats(splatCount)
        }
        let shBytesPerSplat = header.shBytesPerSplat

        let assetBytes = GaussianPagingPolicy.assetBytes(splatCount: splatCount, shBytesPerSplat: shBytesPerSplat)
        let residencyBudget = GaussianPagingPolicy.residencyBudgetBytes()
        let pages = GaussianPagingPolicy.shouldPage(
            assetBytes: assetBytes,
            thresholdBytes: GaussianPagingPolicy.pagingThresholdBytes(residencyBudgetBytes: residencyBudget),
            allowPaging: allowPaging,
            disablePaging: GaussianDebugOptions.shared.disablePaging
        )
        if pages {
            return try loadPaged(source: source, url: url, device: device, residencyBudgetBytes: residencyBudget)
        }
        // Whole resident: the source served the index; the records come through UntoldGSFile.
        source.close()
        let file = try UntoldGSFile(url: url)

        // Packed records for every chunk, contiguous, in chunk order: the resident splat data.
        guard let packedBuffer = device.makeBuffer(length: splatCount * UntoldGSFormat.coreRecordSize, options: .storageModeShared) else {
            throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian packed splat buffer")
        }
        packedBuffer.label = "Gaussian Packed Chunks"

        let sphericalHarmonicsBuffer: MTLBuffer?
        if shBytesPerSplat > 0 {
            guard let buffer = device.makeBuffer(length: splatCount * shBytesPerSplat, options: .storageModeShared) else {
                throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian spherical-harmonics buffer")
            }
            buffer.label = "Gaussian Spherical Harmonics"
            sphericalHarmonicsBuffer = buffer
        } else {
            sphericalHarmonicsBuffer = nil
        }

        var constants: [GaussianChunkDecodeConstants] = []
        constants.reserveCapacity(file.index.chunks.count)
        var firstSplat = 0
        let packedBase = packedBuffer.contents()
        let shBase = sphericalHarmonicsBuffer?.contents()

        for chunkIndex in file.index.chunks.indices {
            let chunk = file.index.chunks[chunkIndex]
            let payload = try file.chunkPayload(at: chunkIndex, verify: true)
            let count = Int(chunk.splatCount)
            let coreBytes = Int(chunk.coreBytes)

            payload.withUnsafeBytes { bytes in
                let source = bytes.baseAddress!
                packedBase.advanced(by: firstSplat * UntoldGSFormat.coreRecordSize)
                    .copyMemory(from: source, byteCount: coreBytes)
                if let shBase, shBytesPerSplat > 0 {
                    shBase.advanced(by: firstSplat * shBytesPerSplat)
                        .copyMemory(from: source.advanced(by: coreBytes), byteCount: count * shBytesPerSplat)
                }
            }

            constants.append(GaussianChunkDecodeConstants(
                aabbMinX: chunk.aabbMin.x, aabbMinY: chunk.aabbMin.y, aabbMinZ: chunk.aabbMin.z,
                logScaleMin: chunk.logScaleMin,
                aabbMaxX: chunk.aabbMax.x, aabbMaxY: chunk.aabbMax.y, aabbMaxZ: chunk.aabbMax.z,
                logScaleMax: chunk.logScaleMax,
                firstSplat: UInt32(firstSplat),
                splatCount: UInt32(count),
                _pad0: 0, _pad1: 0
            ))
            firstSplat += count
        }

        guard let constantsBuffer = device.makeBuffer(
            bytes: constants,
            length: constants.count * MemoryLayout<GaussianChunkDecodeConstants>.stride,
            options: .storageModeShared
        ) else {
            throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian chunk constants buffer")
        }
        constantsBuffer.label = "Gaussian Chunk Table"

        return GaussianChunkLoadResult(
            splatCount: splatCount,
            packedSplatBuffer: packedBuffer,
            sphericalHarmonicsBuffer: sphericalHarmonicsBuffer,
            sphericalHarmonicsMetadata: header.shMetadata,
            meanSquaredSplatExtent: header.meanSquaredSplatExtent,
            captureExposureEV: header.captureExposureEV,
            captureWhiteBalance: header.captureWhiteBalance,
            boundingBox: (header.boundingBoxMin, header.boundingBoxMax),
            index: file.index,
            chunkTable: GaussianChunkTable(
                constantsBuffer: constantsBuffer,
                chunkCount: constants.count,
                splatsPerChunk: header.splatsPerChunk,
                index: file.index
            )
        )
    }

    /// The paged load: the decode constants from the index without reading a payload
    /// (`firstSplat` still the file-order prefix sum, unused by a paged frame), the two pools
    /// sized by `GaussianPagingPolicy` against what the residency budget leaves, the nine
    /// per-slot tables, and the pager that owns them all.
    private static func loadPaged(source: any GaussianPageSource, url: URL, device: MTLDevice, residencyBudgetBytes: Int) throws -> GaussianChunkLoadResult {
        let index = source.index
        let header = index.header
        let splatCount = Int(header.splatCount)
        let shBytesPerSplat = header.shBytesPerSplat
        let chunkCount = index.chunks.count
        let ranksPerPage = GaussianPagingPolicy.ranksPerPage(splatsPerChunk: header.splatsPerChunk)
        let pagesPerChunk = GaussianPagingPolicy.pagesPerChunk(splatsPerChunk: header.splatsPerChunk)
        let slotBytes = ranksPerPage * (UntoldGSFormat.coreRecordSize + shBytesPerSplat)
        let assetBytes = GaussianPagingPolicy.assetBytes(splatCount: splatCount, shBytesPerSplat: shBytesPerSplat)
        // Sized and claimed in one step under the registry's lock: two loads running at once
        // (tiers of one progressive entity, streamed entities) each see the other's claim, so
        // the pools together stay within the residency budget. The claim becomes the pager's
        // registration once it exists and is given back on every failure before that.
        let registry = GaussianPagePoolRegistry.shared
        var slotCount = 0
        let reservation = registry.reserve { allocatedBytes in
            slotCount = GaussianPagingPolicy.poolSlotCount(
                assetBytes: assetBytes,
                slotBytes: slotBytes,
                residencyBudgetBytes: residencyBudgetBytes,
                allocatedBytes: allocatedBytes
            )
            return slotCount * slotBytes
        }
        var unregistered: GaussianPagePoolReservation? = reservation
        defer {
            if let unregistered { registry.release(unregistered) }
        }

        // The pools: halve the slot count down to the minimum when the device refuses.
        var corePool: MTLBuffer?
        var shPool: MTLBuffer?
        while corePool == nil {
            corePool = device.makeBuffer(length: slotCount * ranksPerPage * UntoldGSFormat.coreRecordSize, options: .storageModeShared)
            if corePool != nil, shBytesPerSplat > 0 {
                shPool = device.makeBuffer(length: slotCount * ranksPerPage * shBytesPerSplat, options: .storageModeShared)
                if shPool == nil { corePool = nil }
            }
            if corePool == nil {
                guard slotCount > GaussianPagingPolicy.minPoolSlots else {
                    source.close()
                    throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian page pool")
                }
                slotCount = max(GaussianPagingPolicy.minPoolSlots, slotCount / 2)
                registry.resize(reservation, bytes: slotCount * slotBytes)
            }
        }
        guard let corePool else {
            source.close()
            throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian page pool")
        }
        corePool.label = "Gaussian Page Pool Core"
        shPool?.label = "Gaussian Page Pool SH"

        // The decode constants, as the whole load builds them, without a payload read.
        var constants: [GaussianChunkDecodeConstants] = []
        constants.reserveCapacity(chunkCount)
        var firstSplat = 0
        for chunk in index.chunks {
            constants.append(GaussianChunkDecodeConstants(
                aabbMinX: chunk.aabbMin.x, aabbMinY: chunk.aabbMin.y, aabbMinZ: chunk.aabbMin.z,
                logScaleMin: chunk.logScaleMin,
                aabbMaxX: chunk.aabbMax.x, aabbMaxY: chunk.aabbMax.y, aabbMaxZ: chunk.aabbMax.z,
                logScaleMax: chunk.logScaleMax,
                firstSplat: UInt32(firstSplat),
                splatCount: chunk.splatCount,
                _pad0: 0, _pad1: 0
            ))
            firstSplat += Int(chunk.splatCount)
        }
        guard let constantsBuffer = device.makeBuffer(
            bytes: constants,
            length: constants.count * MemoryLayout<GaussianChunkDecodeConstants>.stride,
            options: .storageModeShared
        ) else {
            source.close()
            throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian chunk constants buffer")
        }
        constantsBuffer.label = "Gaussian Chunk Table"

        // The nine per-slot tables; the pager initialises them.
        var residencyTables: [MTLBuffer] = []
        var pageTables: [MTLBuffer] = []
        var demandTables: [MTLBuffer] = []
        for slot in 0 ..< maxInFlightCommandBuffers {
            guard let residency = device.makeBuffer(length: max(1, chunkCount) * MemoryLayout<GaussianChunkResidency>.stride, options: .storageModeShared),
                  let pageTable = device.makeBuffer(length: max(1, chunkCount * pagesPerChunk) * MemoryLayout<UInt32>.stride, options: .storageModeShared),
                  let demand = device.makeBuffer(length: max(1, chunkCount) * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else {
                source.close()
                throw GaussianChunkLoadError.bufferAllocationFailed("Gaussian page tables")
            }
            residency.label = "Gaussian Chunk Residency \(slot)"
            pageTable.label = "Gaussian Page Table \(slot)"
            demand.label = "Gaussian Chunk Demand \(slot)"
            residencyTables.append(residency)
            pageTables.append(pageTable)
            demandTables.append(demand)
        }

        let pager = GaussianPageManager(
            source: source,
            index: index,
            label: url.lastPathComponent,
            corePool: corePool,
            shPool: shPool,
            residencyTables: residencyTables,
            pageTables: pageTables,
            demandTables: demandTables,
            slotCount: slotCount,
            ranksPerPage: ranksPerPage,
            pagesPerChunk: pagesPerChunk,
            reservation: reservation
        )
        unregistered = nil

        var table = GaussianChunkTable(
            constantsBuffer: constantsBuffer,
            chunkCount: chunkCount,
            splatsPerChunk: header.splatsPerChunk,
            index: index
        )
        table.residencyTables = residencyTables
        table.pageTables = pageTables
        table.demandTables = demandTables
        table.pagesPerChunk = pagesPerChunk
        table.ranksPerPageLog2 = pager.ranksPerPageLog2

        return GaussianChunkLoadResult(
            splatCount: splatCount,
            packedSplatBuffer: corePool,
            sphericalHarmonicsBuffer: shPool,
            sphericalHarmonicsMetadata: header.shMetadata,
            meanSquaredSplatExtent: header.meanSquaredSplatExtent,
            captureExposureEV: header.captureExposureEV,
            captureWhiteBalance: header.captureWhiteBalance,
            boundingBox: (header.boundingBoxMin, header.boundingBoxMax),
            index: index,
            chunkTable: table,
            pager: pager
        )
    }

    /// Expands `loaded`'s packed records into a new `EncodedGaussianSplat` buffer with the
    /// `gaussianDecodeChunks` kernel, waiting for the GPU: the whole-buffer representation a
    /// `.ply` loads to, for a `.untoldgs` that has to take that path (the per-chunk kernels are
    /// unavailable) and for tests of the decode.
    static func decodeEncodedSplats(_ loaded: GaussianChunkLoadResult) throws -> MTLBuffer {
        guard !loaded.isPaged else {
            throw GaussianChunkLoadError.pagedAssetCannotBeExpanded
        }
        guard let device = renderInfo.device, let commandQueue = renderInfo.commandQueue else {
            throw GaussianChunkLoadError.deviceUnavailable
        }
        guard isAvailable, let pipelineState = gaussianDecodePipeline.pipelineState else {
            throw GaussianChunkLoadError.decodePipelineUnavailable
        }
        guard let encodedSplatBuffer = device.makeBuffer(length: max(1, loaded.splatCount) * MemoryLayout<EncodedGaussianSplat>.stride, options: .storageModeShared) else {
            throw GaussianChunkLoadError.bufferAllocationFailed("Encoded Gaussian splat buffer")
        }
        encodedSplatBuffer.label = "Gaussian Encoded Splats"

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw GaussianChunkLoadError.gpuDecodeFailed("could not create a command buffer")
        }
        commandBuffer.label = "Gaussian Chunk Decode"
        encoder.label = "Gaussian Decode Chunks"
        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(loaded.packedSplatBuffer, offset: 0, index: Int(gaussianDecodePackedIndex.rawValue))
        encoder.setBuffer(loaded.chunkTable.constantsBuffer, offset: 0, index: Int(gaussianDecodeChunksIndex.rawValue))
        var chunkCount = UInt32(loaded.chunkTable.chunkCount)
        encoder.setBytes(&chunkCount, length: MemoryLayout<UInt32>.stride, index: Int(gaussianDecodeChunkCountIndex.rawValue))
        encoder.setBuffer(encodedSplatBuffer, offset: 0, index: Int(gaussianDecodeOutputIndex.rawValue))

        // One threadgroup per chunk; the kernel strides over the chunk when it holds more
        // splats than a threadgroup has threads.
        let threadsPerGroup = max(1, min(loaded.chunkTable.splatsPerChunk, pipelineState.maxTotalThreadsPerThreadgroup))
        encoder.dispatchThreadgroups(
            MTLSize(width: max(1, loaded.chunkTable.chunkCount), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw GaussianChunkLoadError.gpuDecodeFailed(error.localizedDescription)
        }
        return encodedSplatBuffer
    }
}
