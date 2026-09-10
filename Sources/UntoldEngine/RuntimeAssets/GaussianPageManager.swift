//
//  GaussianPageManager.swift
//  UntoldEngine
//
//  The pager of a `.untoldgs` entity loaded above the paging threshold: its records live in a
//  bounded page pool of 256-rank tiers (`GaussianComponent.packedSplatData` is the pool) and
//  every frame the pager decides, from the demand the chunk cull wrote three frames earlier,
//  which tiers to read from disk into free pool slots and which to give up. Per in-flight slot
//  it keeps a residency table (the resident rank prefix and fade of every chunk), a page table
//  (the pool slot of every tier) and a demand table (the seen screen area of every chunk); the
//  cull skips chunks with nothing resident and lists the others with their resident ranks, so
//  the working-set budget only ever sees drawable ranks. Reads run on a background queue
//  straight into retired pool slots — a slot unmapped at tick T is reused at T + 3, when every
//  frame that could read it is complete — and completions are mapped on the render thread at
//  the next tick. One lock guards what the I/O threads touch (the inbox, the generation, the
//  state); everything else is render-thread-only.
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

/// The pager's state: reading, holding after the file changed (resident pages keep drawing,
/// a reopen is tried periodically), or shut down with the entity.
public enum GaussianPagerState: Equatable, Sendable {
    case active
    case faulted
    case closed
}

/// What the pager did and holds, for the profile line and the editor's inspector.
public struct GaussianPagingStats: Equatable, Sendable {
    public var poolBytes = 0
    public var slotCount = 0
    /// Pool slots mapped or being read into.
    public var residentSlots = 0
    /// Chunks with at least their head resident, and chunks resident whole.
    public var residentChunks = 0
    public var wholeChunks = 0
    public var pendingReads = 0
    public var bytesInFlight = 0
    public var issuedThisTick = 0
    public var committedThisTick = 0
    public var evictedThisTick = 0
    /// Requests that found no slot and nothing worth displacing, over the pager's life.
    public var saturatedCandidates = 0
    public var faultedChunks = 0
    public var corruptChunks = 0
    public var tick: UInt32 = 0
    public var state: GaussianPagerState = .active

    public init() {}
}

/// The frame's inputs to one tick of the pager.
struct GaussianPagerFrameInputs {
    /// The entity's cull constants this frame (the seed's views; `uniformQuotas` is ignored).
    var cullConstants: GaussianChunkCullConstants
    /// The last read-back budget state (`GaussianSharedWorkingSet.lastBudgetState`).
    var budgetState: GaussianBudgetState
    /// The frame's working-set budget in splats (`gaussianWorkingSetBudget(residentSplats:)`):
    /// what the frame could ever draw, the bound of the fill density when the frame fits.
    var budget: Int
    var uniformQuotas: Bool
    var disableWorkingSetBudget: Bool
    /// `GaussianDebugOptions.freezePaging`: no reads, no evictions.
    var freeze = false
    /// `renderInfo.frameIndex`: tells a slot's demand words from before a gap of frames.
    var frameIndex: UInt64 = 0
    /// Frames an arriving tier fades in over (`GaussianPagingPolicy.fadeFrames`, 0 with
    /// `GaussianDebugOptions.disablePageFade`).
    var fadeFrames: UInt32 = GaussianPagingPolicy.fadeFrames
    /// `GaussianChunkPagingConstants.debugMode`.
    var debugMode: UInt32 = 0
}

/// The buffers and constants the frame binds for one slot of a paged entity.
struct GaussianPagerBindings {
    let residency: MTLBuffer
    let pageTable: MTLBuffer
    let demand: MTLBuffer
    let constants: GaussianChunkPagingConstants
}

/// One event of the pager's life, recorded when `eventLogEnabled` (tests).
public struct GaussianPagingEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case issued
        case committed
        case evicted
        case recycled
        case dropped
        case failed
        case corrupt
        case faulted
    }

    public let tick: UInt32
    public let kind: Kind
    public let chunk: Int
    public let tier: Int
    public let slot: UInt32
    public let generation: UInt32
    /// The request's load priority (issued events); 0 otherwise.
    public let priority: Float
}

/// A tier read: ranks `[firstRank, firstRank + rankCount)` of one chunk into `slots` (one per
/// tier), the core bytes into the core pool and the harmonics into the SH pool. Retains the
/// manager, hence the pools, until it completes; a completion whose generation is stale (the
/// entity was removed) is dropped.
struct GaussianPageReadRequest: @unchecked Sendable {
    let manager: GaussianPageManager
    let generation: UInt32
    let chunkIndex: Int
    let firstRank: Int
    let rankCount: Int
    let slots: [UInt32]
    let slotGenerations: [UInt32]
    /// The slots of the tiers already resident below `firstRank`, for the CRC at full residency.
    let residentSlots: [UInt32]
    let core: [GaussianPageReadRange]
    let sh: [GaussianPageReadRange]
    /// Verify the chunk's CRC once this request lands (it makes the chunk fully resident).
    let verify: Bool
    let byteCount: Int
    let priority: Float
}

/// A finished read, appended to the manager's inbox by the worker.
struct GaussianPageCompletion {
    let request: GaussianPageReadRequest
    let result: Result<Void, GaussianPagingError>
}

/// Memory-pressure levels the pools react to (`GaussianPagePoolRegistry.noteMemoryPressure`).
public enum GaussianPagePressureLevel: Sendable {
    case warning
    case critical
}

/// Pool bytes a load has claimed from the residency budget before its pager exists, so two
/// loads running at once each see the other's claim. Converted into the pager's registration
/// by `GaussianPageManager.init`, or released when the load fails.
public struct GaussianPagePoolReservation: Equatable, Sendable {
    fileprivate let id: UInt64
}

/// Every live pool and every reservation in progress: their total bytes, so a second paged
/// entity gets what the residency budget leaves, and the fan-out of a memory-pressure event.
public final class GaussianPagePoolRegistry: @unchecked Sendable {
    public static let shared = GaussianPagePoolRegistry()

    private final class Entry {
        weak var manager: GaussianPageManager?
        let bytes: Int
        init(manager: GaussianPageManager, bytes: Int) {
            self.manager = manager
            self.bytes = bytes
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var reservations: [UInt64: Int] = [:]
    private var nextReservation: UInt64 = 1
    private var _allocatedBytes = 0

    private init() {}

    /// Bytes of every registered pool and every reservation in progress.
    public var allocatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allocatedBytes
    }

    /// Claims pool bytes in one step: `bytes` is given the bytes allocated so far and returns
    /// the size to claim, under the lock, so concurrent loads size their pools against each
    /// other. The claim counts in `allocatedBytes` until it is registered or released.
    public func reserve(bytes: (_ allocatedBytes: Int) -> Int) -> GaussianPagePoolReservation {
        lock.lock()
        defer { lock.unlock() }
        let claimed = max(0, bytes(_allocatedBytes))
        let id = nextReservation
        nextReservation &+= 1
        reservations[id] = claimed
        _allocatedBytes += claimed
        return GaussianPagePoolReservation(id: id)
    }

    /// Changes a reservation's size (the pool shrank when the device refused a buffer).
    public func resize(_ reservation: GaussianPagePoolReservation, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = reservations[reservation.id] else { return }
        let claimed = max(0, bytes)
        reservations[reservation.id] = claimed
        _allocatedBytes += claimed - previous
    }

    /// Gives a reservation back (the load failed).
    public func release(_ reservation: GaussianPagePoolReservation) {
        lock.lock()
        defer { lock.unlock() }
        guard let bytes = reservations.removeValue(forKey: reservation.id) else { return }
        _allocatedBytes -= bytes
    }

    /// The bytes a reservation holds; nil once registered or released (tests).
    public func reservedBytes(_ reservation: GaussianPagePoolReservation) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return reservations[reservation.id]
    }

    /// Registers a pager's pool bytes, converting its reservation when it has one (the bytes
    /// were counted since the claim; the difference, if any, is settled here).
    func register(_ manager: GaussianPageManager, bytes: Int, reservation: GaussianPagePoolReservation?) {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(manager)
        var reserved = 0
        if let reservation, let claimed = reservations.removeValue(forKey: reservation.id) {
            reserved = claimed
        }
        guard entries[key] == nil else {
            _allocatedBytes -= reserved
            return
        }
        entries[key] = Entry(manager: manager, bytes: bytes)
        _allocatedBytes += bytes - reserved
    }

    func unregister(_ key: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: key) else { return }
        _allocatedBytes -= entry.bytes
    }

    /// Sets every live pool's soft target: half the slots on a warning, a quarter on critical,
    /// for `GaussianPagingPolicy.pressureTicks`. The pools evict down to it and issue nothing
    /// above it; the allocation itself is fixed (whole-entity eviction remains the relief).
    public func noteMemoryPressure(_ level: GaussianPagePressureLevel) {
        let fraction = level == .critical ? GaussianPagingPolicy.pressureFractionCritical : GaussianPagingPolicy.pressureFractionWarning
        lock.lock()
        let managers = entries.values.compactMap(\.manager)
        lock.unlock()
        for manager in managers {
            manager.notePressure(fraction: fraction)
        }
    }
}

/// See the file comment.
public final class GaussianPageManager: @unchecked Sendable {
    let source: any GaussianPageSource
    let index: UntoldGSIndex
    /// The file's name, for error reports.
    let label: String
    let corePool: MTLBuffer
    let shPool: MTLBuffer?
    let residencyTables: [MTLBuffer]
    let pageTables: [MTLBuffer]
    let demandTables: [MTLBuffer]
    public let chunkCount: Int
    public let ranksPerPage: Int
    public let ranksPerPageLog2: Int
    public let pagesPerChunk: Int
    public let slotCount: Int
    let shBytesPerSplat: Int
    /// Bytes of one slot across both pools.
    let slotBytes: Int

    public var poolBytes: Int {
        corePool.length + (shPool?.length ?? 0)
    }

    // MARK: Lock-guarded (the I/O threads, the LOD system, the registry)

    private let lock = NSLock()
    private var inbox: [GaussianPageCompletion] = []
    private var _generation: UInt32 = 0
    private var _state: GaussianPagerState = .active
    private var _pendingReads = 0
    private var _bytesInFlight = 0
    private var _stats = GaussianPagingStats()
    private var _warming = false
    private var _warmth: Float = 0
    private var _warmingSinceTick: UInt32?
    private var _tickForWarmth: UInt32 = 0
    private var _pressureRequest: Float?
    private var registryKey: ObjectIdentifier?

    // MARK: Render-thread state

    private(set) var tick: UInt32 = 0
    private var states: [GaussianChunkPageState]
    private var masterResidency: [GaussianChunkResidency]
    private var masterPageTable: [UInt32]
    private var slotChunk: [Int32]
    private var slotTier: [UInt8]
    private var slotGeneration: [UInt32]
    /// Sorted descending: `popLast` hands out the lowest free slot, so a fresh pool fills in
    /// ascending runs and a chunk's tiers coalesce into one read.
    private var freeSlots: [UInt32]
    private var retiring = GaussianPageRetireRing()
    private var journals: [[Int]]
    private var journalMarks: [[Bool]]
    private var journalFull: [Bool]
    private var demandStampTick: [UInt32?]
    private var demandStampFrame: [UInt64]
    private var residentChunks = Set<Int>()
    private var fading: [Int] = []
    private var lastReopenTick: UInt32 = 0
    /// The budget state's frame count at the first tick: a readback that has not moved past it
    /// predates this entity's frames (another scene's cap) and is not applied.
    private var baselineFrameCount: UInt32?
    private var faultedChunkCount = 0
    private var corruptChunkCount = 0
    private var saturatedCandidates = 0
    private var reportedAssetFault = false
    private var reportedChunkFault = false
    private var reportedCorruption = false
    private var lastConstants: [GaussianChunkPagingConstants]
    private var pressureFraction: Float?
    private var pressureUntilTick: UInt32 = 0
    /// `handleError` calls the pager made, for tests.
    public private(set) var errorReports = 0
    /// Record every issue, commit, eviction, recycle and drop (tests; lock-guarded, a worker
    /// records the drops after a shutdown).
    public var eventLogEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _eventLogEnabled }
        set { lock.lock(); _eventLogEnabled = newValue; lock.unlock() }
    }

    public var eventLog: [GaussianPagingEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _eventLog
    }

    private var _eventLogEnabled = false
    private var _eventLog: [GaussianPagingEvent] = []

    private static let queue = DispatchQueue(label: "com.untold.gaussian.paging", qos: .userInitiated, attributes: .concurrent)
    /// This pager's reads running on the queue at once: `GaussianPagingPolicy.maxConcurrentReads`
    /// at its creation. The rest wait in `_pendingRequests` (lock-guarded, in issue order) and
    /// occupy no thread: a worker that finishes starts the next one.
    private let maxRunningReads: Int
    private var _runningReads = 0
    private var _pendingRequests: [GaussianPageReadRequest] = []
    private var _pendingHead = 0

    /// Takes the pools and the nine per-slot tables the loader allocated, initialises the tables
    /// (nothing resident, every tier absent, no demand) and registers the pool bytes, converting
    /// the load's reservation when it made one.
    init(
        source: any GaussianPageSource,
        index: UntoldGSIndex,
        label: String,
        corePool: MTLBuffer,
        shPool: MTLBuffer?,
        residencyTables: [MTLBuffer],
        pageTables: [MTLBuffer],
        demandTables: [MTLBuffer],
        slotCount: Int,
        ranksPerPage: Int,
        pagesPerChunk: Int,
        reservation: GaussianPagePoolReservation? = nil
    ) {
        self.source = source
        self.index = index
        self.label = label
        self.corePool = corePool
        self.shPool = shPool
        self.residencyTables = residencyTables
        self.pageTables = pageTables
        self.demandTables = demandTables
        self.slotCount = slotCount
        self.ranksPerPage = ranksPerPage
        ranksPerPageLog2 = max(0, ranksPerPage.trailingZeroBitCount)
        self.pagesPerChunk = pagesPerChunk
        chunkCount = index.chunks.count
        shBytesPerSplat = index.header.shBytesPerSplat
        slotBytes = ranksPerPage * (UntoldGSFormat.coreRecordSize + shBytesPerSplat)
        maxRunningReads = max(1, GaussianPagingPolicy.maxConcurrentReads)

        states = Array(repeating: GaussianChunkPageState(), count: chunkCount)
        masterResidency = Array(repeating: GaussianChunkResidency(residentRanks: 0, fadeFromRank: 0, arrivalFrame: 0, _pad0: 0), count: chunkCount)
        masterPageTable = Array(repeating: kGaussianPageSlotInvalid, count: chunkCount * pagesPerChunk)
        slotChunk = Array(repeating: -1, count: slotCount)
        slotTier = Array(repeating: 0, count: slotCount)
        slotGeneration = Array(repeating: 0, count: slotCount)
        freeSlots = (0 ..< slotCount).reversed().map { UInt32($0) }
        let slots = residencyTables.count
        journals = Array(repeating: [], count: slots)
        journalMarks = Array(repeating: Array(repeating: false, count: chunkCount), count: slots)
        journalFull = Array(repeating: false, count: slots)
        demandStampTick = Array(repeating: nil, count: slots)
        demandStampFrame = Array(repeating: 0, count: slots)
        lastConstants = Array(repeating: GaussianChunkPagingConstants(), count: slots)
        for k in 0 ..< slots {
            copyMasterTables(toSlot: k)
            memset(demandTables[k].contents(), 0, demandTables[k].length)
        }
        let key = ObjectIdentifier(self)
        registryKey = key
        GaussianPagePoolRegistry.shared.register(self, bytes: poolBytes, reservation: reservation)
    }

    deinit {
        shutdown()
        source.close()
    }

    // MARK: Public state

    public var state: GaussianPagerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var stats: GaussianPagingStats {
        lock.lock()
        defer { lock.unlock() }
        return _stats
    }

    /// The resident ranks of a chunk as the master tables hold them (tests, the inspector).
    public func residentRanks(of chunk: Int) -> UInt32 {
        masterResidency[chunk].residentRanks
    }

    public func chunkState(_ chunk: Int) -> GaussianChunkPageState {
        states[chunk]
    }

    /// The pool slot of a tier, or nil (tests).
    public func poolSlot(chunk: Int, tier: Int) -> UInt32? {
        let slot = masterPageTable[chunk * pagesPerChunk + tier]
        return slot == kGaussianPageSlotInvalid ? nil : slot
    }

    /// Free slots and slots waiting in the retire ring (tests).
    public var freeSlotCount: Int {
        freeSlots.count
    }

    public var retiringSlotCount: Int {
        retiring.total
    }

    /// The LOD system is waiting for this tier to warm before switching to it: its demand is
    /// culled every frame (`encodeGaussianChunkDemand`) and the pager fills it.
    public var warming: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _warming }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue, !_warming { _warmingSinceTick = _tickForWarmth }
            if !newValue { _warmingSinceTick = nil }
            _warming = newValue
        }
    }

    /// Whether the demanded chunks hold `GaussianPagingPolicy.warmFraction` of their wanted
    /// ranks, or the warming has gone on for `warmTimeoutTicks`.
    public var isWarm: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _state != .closed, _tickForWarmth > 0 else { return false }
        if let since = _warmingSinceTick, _tickForWarmth &- since >= GaussianPagingPolicy.warmTimeoutTicks {
            return true
        }
        return _warmth >= GaussianPagingPolicy.warmFraction
    }

    /// The bindings of `slot` as the last tick left them, for the fused pass of the same frame.
    func bindings(slot: Int) -> GaussianPagerBindings {
        GaussianPagerBindings(residency: residencyTables[slot], pageTable: pageTables[slot], demand: demandTables[slot], constants: lastConstants[slot])
    }

    /// Stops the pager: no read is issued after this, the reads waiting to start and the
    /// completions waiting for a tick are dropped here (every one holds the manager, and no
    /// tick will ever drain them), completions of the reads still running are dropped by the
    /// generation check, the pool bytes leave the registry, and the source closes when the last
    /// running read releases it. In-flight frames keep the pools alive through their command
    /// buffers.
    public func shutdown() {
        lock.lock()
        guard _state != .closed else {
            lock.unlock()
            return
        }
        _generation &+= 1
        _state = .closed
        _stats.state = .closed
        var dropped: [GaussianPageReadRequest] = inbox.map(\.request)
        inbox.removeAll()
        let pending = _pendingRequests[_pendingHead...]
        for request in pending {
            _pendingReads -= 1
            _bytesInFlight -= request.byteCount
        }
        dropped.append(contentsOf: pending)
        _pendingRequests.removeAll()
        _pendingHead = 0
        _stats.pendingReads = _pendingReads
        _stats.bytesInFlight = _bytesInFlight
        if _eventLogEnabled {
            for request in dropped {
                for slot in request.slots {
                    _eventLog.append(GaussianPagingEvent(tick: tick, kind: .dropped, chunk: request.chunkIndex, tier: request.firstRank / ranksPerPage, slot: slot, generation: 0, priority: 0))
                }
            }
        }
        let idle = _pendingReads == 0
        let key = registryKey
        registryKey = nil
        lock.unlock()
        if let key { GaussianPagePoolRegistry.shared.unregister(key) }
        if idle { source.close() }
    }

    /// Every slot in the retire ring becomes free at once. Only when no command buffer is in
    /// flight (tests that drive frames by hand and wait for each one): a slot the ring still
    /// holds may be mapped by the page table of a frame the GPU is executing, and the read that
    /// takes it would write over records that frame decodes. Debug builds assert that the last
    /// frame is complete; the method is not engine API.
    func noteGPUIdle() {
        assert(
            (renderInfo.lastCommandBuffer as MTLCommandBuffer?).map { $0.status == .completed || $0.status == .error || $0.status == .notEnqueued } ?? true,
            "GaussianPageManager.noteGPUIdle with a command buffer in flight"
        )
        let slots = retiring.drainAll()
        for slot in slots {
            slotGeneration[Int(slot)] &+= 1
            log(.recycled, chunk: -1, tier: 0, slot: slot)
        }
        addFreeSlots(slots)
    }

    /// Called by the registry on a memory-pressure event, from its thread; the next tick applies it.
    func notePressure(fraction: Float) {
        lock.lock()
        _pressureRequest = fraction
        lock.unlock()
    }

    // MARK: The tick

    /// One tick for the frame that owns `slot`: recycle the slots retired three ticks ago, map
    /// the reads that landed, ingest this slot's demand (or the CPU seed), compute the wanted
    /// ranks, evict, issue reads, bring the slot's tables up to date, and return what to bind.
    /// A warming tier (`warming`, the LOD system's pending switch) takes the same tick: its
    /// demand words come from its demand-only cull and its reads are issued like a live
    /// entity's — the tier has to fill before the switch (`isWarm`) — and of the bindings
    /// returned only the demand table is bound, since no frame draws it yet.
    func tick(slot: Int, frame: GaussianPagerFrameInputs) -> GaussianPagerBindings {
        tick &+= 1
        let now = tick
        var issued = 0
        var committed = 0
        var evicted = 0

        // 1. The slots retired three ticks ago are free again.
        let recycled = retiring.recycle(atTick: now)
        for slot in recycled {
            slotGeneration[Int(slot)] &+= 1
            log(.recycled, chunk: -1, tier: 0, slot: slot)
        }
        addFreeSlots(recycled)

        // 2. Landed reads.
        committed += drainInbox(now: now, fadeFrames: frame.fadeFrames)

        // 3. Fades that are done.
        expireFades(now: now, fadeFrames: frame.fadeFrames)

        // 4. A faulted source tries to reopen periodically.
        var active = state == .active
        if state == .faulted, now &- lastReopenTick >= GaussianPagingPolicy.faultReopenTicks {
            lastReopenTick = now
            if (try? source.reopen()) != nil {
                setState(.active)
                active = true
            }
        }

        if active {
            let pressure = takePressureRequest(now: now)
            // 5. Demand.
            let demand = ingestDemand(slot: slot, frame: frame, now: now)
            // 6. Wanted ranks.
            computeWants(demanded: demand.chunks, totalArea: demand.totalArea, totalSplats: demand.totalSplats, frame: frame, now: now)
            // 7 and 8. Eviction and reads.
            if !frame.freeze {
                let result = issueReads(demanded: demand.chunks, now: now, pressureTarget: pressure)
                issued = result.issued
                evicted = result.evicted
            }
        }

        // 9. This slot's tables and stamp.
        applyJournal(slot: slot)
        demandStampTick[slot] = now
        demandStampFrame[slot] = frame.frameIndex

        var constants = GaussianChunkPagingConstants()
        constants.pagesPerChunk = UInt32(pagesPerChunk)
        constants.ranksPerPageLog2 = UInt32(ranksPerPageLog2)
        constants.frameIndex = now
        constants.fadeFrames = frame.fadeFrames
        constants.debugMode = frame.debugMode
        lastConstants[slot] = constants

        publishStats(now: now, issued: issued, committed: committed, evicted: evicted)
        return bindings(slot: slot)
    }

    private func setState(_ state: GaussianPagerState) {
        lock.lock()
        if _state != .closed {
            _state = state
            _stats.state = state
        }
        lock.unlock()
    }

    private func takePressureRequest(now: UInt32) -> Int? {
        lock.lock()
        let request = _pressureRequest
        _pressureRequest = nil
        lock.unlock()
        if let request {
            pressureFraction = request
            pressureUntilTick = now &+ GaussianPagingPolicy.pressureTicks
        }
        guard let fraction = pressureFraction else { return nil }
        if now >= pressureUntilTick {
            pressureFraction = nil
            return nil
        }
        return Int(Float(slotCount) * fraction)
    }

    private func publishStats(now: UInt32, issued: Int, committed: Int, evicted: Int) {
        var stats = GaussianPagingStats()
        stats.poolBytes = poolBytes
        stats.slotCount = slotCount
        stats.residentSlots = slotCount - freeSlots.count - retiring.total
        stats.residentChunks = residentChunks.count
        stats.wholeChunks = residentChunks.reduce(0) { $0 + (Int(states[$1].residentRanks) >= Int(index.chunks[$1].splatCount) ? 1 : 0) }
        stats.issuedThisTick = issued
        stats.committedThisTick = committed
        stats.evictedThisTick = evicted
        stats.saturatedCandidates = saturatedCandidates
        stats.faultedChunks = faultedChunkCount
        stats.corruptChunks = corruptChunkCount
        stats.tick = now
        lock.lock()
        stats.pendingReads = _pendingReads
        stats.bytesInFlight = _bytesInFlight
        stats.state = _state
        _stats = stats
        _tickForWarmth = now
        lock.unlock()
    }

    // MARK: Completions

    /// Maps the landed reads in priority order, up to `maxCommitsPerTick` tiers; the rest wait.
    /// A failed read frees its slots at once (never mapped, never referenced by a frame).
    private func drainInbox(now: UInt32, fadeFrames: UInt32) -> Int {
        lock.lock()
        var completions = inbox
        inbox.removeAll(keepingCapacity: true)
        let generation = _generation
        lock.unlock()
        guard !completions.isEmpty else { return 0 }
        completions.sort { $0.request.priority > $1.request.priority }

        var committed = 0
        var deferred: [GaussianPageCompletion] = []
        for completion in completions {
            let request = completion.request
            let chunk = request.chunkIndex
            let stale = request.generation != generation
                || zip(request.slots, request.slotGenerations).contains { slotGeneration[Int($0)] != $1 }
            if stale {
                for slot in request.slots {
                    log(.dropped, chunk: chunk, tier: request.firstRank / ranksPerPage, slot: slot)
                }
                continue
            }
            switch completion.result {
            case .success:
                let tiers = request.slots.count
                if committed > 0, committed + tiers > GaussianPagingPolicy.maxCommitsPerTick {
                    deferred.append(completion)
                    continue
                }
                map(request, now: now, fadeFrames: fadeFrames)
                committed += tiers
            case let .failure(error):
                fail(request, error: error, now: now)
            }
        }
        if !deferred.isEmpty {
            lock.lock()
            inbox.insert(contentsOf: deferred, at: 0)
            lock.unlock()
        }
        return committed
    }

    private func map(_ request: GaussianPageReadRequest, now: UInt32, fadeFrames: UInt32) {
        let chunk = request.chunkIndex
        let firstTier = request.firstRank / ranksPerPage
        let row = chunk * pagesPerChunk
        for (offset, slot) in request.slots.enumerated() {
            masterPageTable[row + firstTier + offset] = slot
            slotChunk[Int(slot)] = Int32(chunk)
            slotTier[Int(slot)] = UInt8(firstTier + offset)
            log(.committed, chunk: chunk, tier: firstTier + offset, slot: slot)
        }
        let resident = UInt32(request.firstRank + request.rankCount)
        masterResidency[chunk] = GaussianChunkResidency(residentRanks: resident, fadeFromRank: UInt32(request.firstRank), arrivalFrame: now, _pad0: 0)
        var state = states[chunk]
        state.residentRanks = UInt16(resident)
        state.fadeFromRank = UInt16(request.firstRank)
        state.arrivalTick = now
        state.mappedAtTick = now
        state.flags.remove(.loading)
        if fadeFrames > 0 {
            state.flags.insert(.fadeActive)
            fading.append(chunk)
        }
        states[chunk] = state
        residentChunks.insert(chunk)
        journal(chunk)
    }

    private func fail(_ request: GaussianPageReadRequest, error: GaussianPagingError, now: UInt32) {
        let chunk = request.chunkIndex
        let tier = request.firstRank / ranksPerPage
        for slot in request.slots {
            slotChunk[Int(slot)] = -1
            log(.failed, chunk: chunk, tier: tier, slot: slot)
        }
        addFreeSlots(request.slots)
        states[chunk].flags.remove(.loading)

        switch error {
        case .closed:
            return
        case .fileChanged, .truncated:
            faultAsset(reason: "\(error)", now: now)
        case .corrupt:
            evictChunk(chunk, now: now)
            faultChunk(chunk)
            corruptChunkCount += 1
            if !reportedCorruption {
                reportedCorruption = true
                report("chunk \(chunk) of \(label) failed its CRC once fully resident; the chunk is dropped")
            }
        case .ioFailure:
            states[chunk].failures &+= 1
            let failures = Int(states[chunk].failures)
            if failures >= GaussianPagingPolicy.retryTicks.count + 1 || failures > GaussianPagingPolicy.retryTicks.count {
                faultChunk(chunk)
                if !reportedChunkFault {
                    reportedChunkFault = true
                    report("chunk \(chunk) of \(label) could not be read (\(error)); the chunk is dropped")
                }
            } else {
                states[chunk].retryAfterTick = now &+ GaussianPagingPolicy.retryTicks[failures - 1]
            }
        }
        // A failing disk, not a bad chunk: more than a percent of the chunks (and more than a
        // handful, so one corrupt chunk of a small asset does not fault the whole).
        if faultedChunkCount >= GaussianPagingPolicy.faultedChunkMinimum,
           Double(faultedChunkCount) > GaussianPagingPolicy.faultedChunkFraction * Double(max(1, chunkCount)),
           state == .active
        {
            faultAsset(reason: "\(faultedChunkCount) chunks faulted", now: now)
        }
    }

    private func faultChunk(_ chunk: Int) {
        guard !states[chunk].flags.contains(.faulted) else { return }
        states[chunk].flags.insert(.faulted)
        faultedChunkCount += 1
        log(.faulted, chunk: chunk, tier: 0, slot: kGaussianPageSlotInvalid)
    }

    private func faultAsset(reason: String, now: UInt32) {
        guard state == .active else { return }
        setState(.faulted)
        lastReopenTick = now
        if !reportedAssetFault {
            reportedAssetFault = true
            report("\(label) changed under the pager (\(reason)); its resident pages keep drawing until the file is back")
        }
    }

    private func report(_ message: String) {
        errorReports += 1
        handleError(.assetDataMissing, "Gaussian paging: \(message)")
    }

    private func expireFades(now: UInt32, fadeFrames: UInt32) {
        guard !fading.isEmpty else { return }
        fading.removeAll { chunk in
            // The fade reaches 1 at arrival + fadeFrames - 1 (the kernel counts the arrival frame).
            let done = fadeFrames == 0 || now &- states[chunk].arrivalTick &+ 1 >= fadeFrames
            if done { states[chunk].flags.remove(.fadeActive) }
            return done
        }
    }

    // MARK: Demand and wants

    /// This slot's demand words when they are this entity's and recent, else the CPU seed
    /// (frustum and area for every chunk, no HZB).
    private func ingestDemand(slot: Int, frame: GaussianPagerFrameInputs, now: UInt32) -> (chunks: [Int], totalArea: Float, totalSplats: Int) {
        var demanded: [Int] = []
        var totalArea: Float = 0
        var totalSplats = 0
        let fresh = demandStampTick[slot] != nil && frame.frameIndex &- demandStampFrame[slot] <= GaussianPagingPolicy.seedGapFrames
        if fresh {
            let words = demandTables[slot].contents().bindMemory(to: UInt32.self, capacity: chunkCount)
            for chunk in 0 ..< chunkCount {
                let bits = words[chunk]
                guard bits != 0 else { continue }
                let area = Float(bitPattern: bits)
                guard area > 0, area.isFinite else { continue }
                states[chunk].lastDemandTick = now
                states[chunk].lastArea = area
                demanded.append(chunk)
                totalArea += area
                totalSplats += Int(index.chunks[chunk].splatCount)
            }
        } else {
            var constants = frame.cullConstants
            constants.uniformQuotas = 0
            for chunk in 0 ..< chunkCount {
                let area = GaussianPageManager.seedArea(entry: index.chunks[chunk], constants: constants)
                guard area > 0 else { continue }
                states[chunk].lastDemandTick = now
                states[chunk].lastArea = area
                demanded.append(chunk)
                totalArea += area
                totalSplats += Int(index.chunks[chunk].splatCount)
            }
        }
        return (demanded, totalArea, totalSplats)
    }

    /// The area the cull would write for a chunk it keeps in some view (frustum only), 0 when
    /// no view keeps it: `GaussianChunkCullMath.chunkScreenArea` without the minimum clamp of a
    /// rejected chunk.
    static func seedArea(entry: UntoldGSChunkEntry, constants: GaussianChunkCullConstants) -> Float {
        let box = GaussianChunkCullMath.paddedBox(aabbMin: entry.aabbMin, aabbMax: entry.aabbMax, logScaleMax: entry.logScaleMax)
        let limit = max(0, 1 + constants.clipGuardBand)
        var kept = false
        var area: Float = 0
        let view0 = GaussianChunkCullMath.screenArea(boxMin: box.min, boxMax: box.max, viewProjection: constants.viewProjection0, clipGuardBand: constants.clipGuardBand)
        if view0.passes {
            kept = true
            area = max(area, view0.area)
        }
        if constants.viewCount > 1 {
            let view1 = GaussianChunkCullMath.screenArea(boxMin: box.min, boxMax: box.max, viewProjection: constants.viewProjection1, clipGuardBand: constants.clipGuardBand)
            if view1.passes {
                kept = true
                area = max(area, view1.area)
            }
        }
        guard kept else { return 0 }
        return min(max(area, gaussianScreenAreaMin), limit * limit)
    }

    private func computeWants(demanded: [Int], totalArea: Float, totalSplats: Int, frame: GaussianPagerFrameInputs, now: UInt32) {
        // A readback that predates this entity's frames (the state is zero, or it is another
        // scene's) says nothing about this entity: the frame is taken as fitting until a frame
        // that saw the entity has been read back.
        let state = frame.budgetState
        if let baseline = baselineFrameCount, state.frameCount < baseline {
            baselineFrameCount = state.frameCount
        }
        if baselineFrameCount == nil { baselineFrameCount = state.frameCount }
        let stale = state.frameCount == 0 || state.frameCount <= (baselineFrameCount ?? 0)
        let cap = stale ? Float.infinity : state.densityCap
        let reserved = stale ? 0 : Int(state.reservedSplats)
        let fill = GaussianPagingPolicy.fillDensity(budget: frame.budget, reservedSplats: reserved, demandedArea: totalArea)
        let fillScale = GaussianPagingPolicy.fillScale(budget: frame.budget, reservedSplats: reserved, demandedSplats: totalSplats)
        var neededTotal = 0
        var residentOfNeeded = 0
        for chunk in demanded {
            let count = index.chunks[chunk].splatCount
            var state = states[chunk]
            let want = GaussianPagingPolicy.wantedRanks(
                splatCount: count,
                area: state.lastArea,
                densityCap: cap,
                fillDensity: fill,
                fillScale: fillScale,
                uniformQuotas: frame.uniformQuotas,
                disableWorkingSetBudget: frame.disableWorkingSetBudget
            )
            let needed = GaussianPagingPolicy.neededRanks(want: want, splatCount: count)
            state.neededRanks = UInt16(needed)
            let residentTiers = tiers(state.residentRanks)
            let wantedTiers = GaussianPagingPolicy.tiersNeeded(needed: needed, ranksPerPage: ranksPerPage)
            if residentTiers > wantedTiers {
                if state.surplusSinceTick == 0 { state.surplusSinceTick = now }
            } else {
                state.surplusSinceTick = 0
            }
            states[chunk] = state
            neededTotal += Int(needed)
            residentOfNeeded += min(Int(needed), Int(state.residentRanks))
        }
        let warmth: Float = neededTotal == 0 ? 1 : Float(residentOfNeeded) / Float(neededTotal)
        lock.lock()
        _warmth = warmth
        lock.unlock()
    }

    private func tiers(_ ranks: UInt16) -> Int {
        (Int(ranks) + ranksPerPage - 1) / ranksPerPage
    }

    // MARK: Eviction and reads

    private func issueReads(demanded: [Int], now: UInt32, pressureTarget: Int?) -> (issued: Int, evicted: Int) {
        var evicted = 0
        let residentSlots = slotCount - freeSlots.count - retiring.total

        // Under pressure: down to the soft target, nothing issued above it, and nothing issued
        // that would carry the pool back above it.
        if let target = pressureTarget, residentSlots > target {
            let victims = GaussianPagingPolicy.selectVictims(
                states: states,
                resident: Array(residentChunks),
                count: min(residentSlots - target, GaussianPagingPolicy.maxEvictionsPerTick),
                inputs: GaussianEvictionInputs(tick: now, ranksPerPage: ranksPerPage, pressure: true)
            )
            for victim in victims {
                evict(chunk: victim.chunk, tier: victim.tier, now: now)
                evicted += 1
            }
            return (0, evicted)
        }
        var issuableSlots = pressureTarget.map { max(0, $0 - residentSlots) } ?? Int.max

        // Candidates by priority.
        var candidates: [(chunk: Int, priority: Float, tiers: Int)] = []
        for chunk in demanded {
            let state = states[chunk]
            guard GaussianPagingPolicy.isLoadCandidate(state, tick: now) else { continue }
            let priority = GaussianPagingPolicy.loadPriority(area: state.lastArea, residentRanks: UInt32(state.residentRanks), neededRanks: UInt32(state.neededRanks), ranksPerPage: ranksPerPage)
            guard priority > 0 else { continue }
            let missing = GaussianPagingPolicy.tiersNeeded(needed: UInt32(state.neededRanks), ranksPerPage: ranksPerPage) - tiers(state.residentRanks)
            guard missing > 0 else { continue }
            candidates.append((chunk, priority, missing))
        }
        guard !candidates.isEmpty else { return (0, evicted) }
        candidates.sort { $0.priority > $1.priority }
        let maxReads = GaussianPagingPolicy.maxPageReadsPerTick
        if candidates.count > maxReads {
            candidates.removeLast(candidates.count - maxReads)
        }

        // Evict ahead: enough for the candidates beyond what is free or retiring. The free and
        // retiring slots serve the candidates in priority order, so the missing slots are the
        // tail of that order: the displacement margin is tested per missing slot against the
        // priority of the candidate it serves, not the best candidate's alone (the stale and
        // surplus classes are free of consequence and need no margin).
        let neededSlots = candidates.reduce(0) { $0 + $1.tiers }
        let available = freeSlots.count + retiring.total
        if neededSlots > available {
            let shortfall = min(neededSlots - available, GaussianPagingPolicy.maxEvictionsPerTick)
            var slotPriorities: [Float] = []
            slotPriorities.reserveCapacity(shortfall)
            var cumulative = 0
            for candidate in candidates where slotPriorities.count < shortfall {
                let end = cumulative + candidate.tiers
                var slot = max(cumulative, available)
                while slot < end, slotPriorities.count < shortfall {
                    slotPriorities.append(candidate.priority)
                    slot += 1
                }
                cumulative = end
            }
            let victims = GaussianPagingPolicy.selectVictims(
                states: states,
                resident: Array(residentChunks),
                count: shortfall,
                inputs: GaussianEvictionInputs(tick: now, ranksPerPage: ranksPerPage, candidatePriority: candidates.first?.priority, slotPriorities: slotPriorities)
            )
            for victim in victims {
                evict(chunk: victim.chunk, tier: victim.tier, now: now)
                evicted += 1
            }
            // Saturated: the requests whose slots nothing free, retiring or worth displacing
            // covers. A request waiting only for the retire ring is not one of them.
            if victims.count < shortfall {
                let covered = available + victims.count
                cumulative = 0
                for candidate in candidates {
                    cumulative += candidate.tiers
                    if cumulative > covered { saturatedCandidates += 1 }
                }
            }
        }

        // Issue in priority order while the caps allow and free slots suffice.
        var issued = 0
        var issuedBytes = 0
        lock.lock()
        let inFlight = _bytesInFlight
        let generation = _generation
        lock.unlock()
        let byteCap = GaussianPagingPolicy.maxPageBytesInFlight
        for candidate in candidates {
            guard issued < maxReads else { break }
            let chunk = candidate.chunk
            let state = states[chunk]
            // The evict-ahead may have taken this candidate's own tail for a stronger request:
            // it then waits out the reload cooldown like any evicted chunk instead of fetching
            // the tier back in the same tick.
            guard GaussianPagingPolicy.isLoadCandidate(state, tick: now) else { continue }
            let count = Int(index.chunks[chunk].splatCount)
            let firstTier = tiers(state.residentRanks)
            let lastTier = GaussianPagingPolicy.tiersNeeded(needed: UInt32(state.neededRanks), ranksPerPage: ranksPerPage)
            let tierCount = lastTier - firstTier
            guard tierCount > 0 else { continue }
            let firstRank = Int(state.residentRanks)
            let rankCount = min(count, lastTier * ranksPerPage) - firstRank
            guard rankCount > 0 else { continue }
            let bytes = rankCount * (UntoldGSFormat.coreRecordSize + shBytesPerSplat)
            if inFlight + issuedBytes + bytes > byteCap, inFlight + issuedBytes > 0 {
                break
            }
            guard tierCount <= issuableSlots else { break }
            // Not enough free slots yet: the ones evicted ahead for it are in the retire ring.
            guard freeSlots.count >= tierCount else { continue }
            issuableSlots -= tierCount
            var slots: [UInt32] = []
            slots.reserveCapacity(tierCount)
            for _ in 0 ..< tierCount {
                slots.append(freeSlots.removeLast())
            }
            let ranges = GaussianPagingPolicy.coalesceRequest(
                chunk: index.chunks[chunk],
                firstRank: firstRank,
                rankCount: rankCount,
                slots: slots,
                ranksPerPage: ranksPerPage,
                shBytesPerSplat: shBytesPerSplat
            )
            let row = chunk * pagesPerChunk
            let residentSlots = (0 ..< firstTier).map { masterPageTable[row + $0] }
            let request = GaussianPageReadRequest(
                manager: self,
                generation: generation,
                chunkIndex: chunk,
                firstRank: firstRank,
                rankCount: rankCount,
                slots: slots,
                slotGenerations: slots.map { slotGeneration[Int($0)] },
                residentSlots: residentSlots,
                core: ranges.core,
                sh: ranges.sh,
                verify: GaussianPagingPolicy.verifyPagedChunkCRC && firstRank + rankCount == count,
                byteCount: bytes,
                priority: candidate.priority
            )
            for (offset, slot) in slots.enumerated() {
                slotChunk[Int(slot)] = Int32(chunk)
                slotTier[Int(slot)] = UInt8(firstTier + offset)
                log(.issued, chunk: chunk, tier: firstTier + offset, slot: slot, priority: candidate.priority)
            }
            states[chunk].flags.insert(.loading)
            enqueue(request)
            issued += 1
            issuedBytes += bytes
        }
        return (issued, evicted)
    }

    /// Unmaps one tier: the master tables, the journals, the retire ring, the reload cooldown.
    /// Tiers are evicted from the top down, so the prefix invariant holds at every step.
    private func evict(chunk: Int, tier: Int, now: UInt32) {
        let row = chunk * pagesPerChunk
        let slot = masterPageTable[row + tier]
        guard slot != kGaussianPageSlotInvalid else { return }
        masterPageTable[row + tier] = kGaussianPageSlotInvalid
        let resident = UInt32(tier * ranksPerPage)
        masterResidency[chunk].residentRanks = resident
        var state = states[chunk]
        state.residentRanks = UInt16(resident)
        state.retryAfterTick = max(state.retryAfterTick, now &+ GaussianPagingPolicy.reloadCooldownTicks)
        if tiers(state.residentRanks) <= GaussianPagingPolicy.tiersNeeded(needed: UInt32(state.neededRanks), ranksPerPage: ranksPerPage) {
            state.surplusSinceTick = 0
        }
        if state.fadeFromRank >= UInt16(resident) {
            state.flags.remove(.fadeActive)
        }
        states[chunk] = state
        if tier == 0 {
            residentChunks.remove(chunk)
        }
        slotChunk[Int(slot)] = -1
        retiring.retire(slot, atTick: now)
        journal(chunk)
        log(.evicted, chunk: chunk, tier: tier, slot: slot)
    }

    private func evictChunk(_ chunk: Int, now: UInt32) {
        let top = tiers(states[chunk].residentRanks)
        for tier in stride(from: top - 1, through: 0, by: -1) {
            evict(chunk: chunk, tier: tier, now: now)
        }
    }

    private func addFreeSlots(_ slots: [UInt32]) {
        guard !slots.isEmpty else { return }
        if freeSlots.isEmpty {
            freeSlots = slots.sorted(by: >)
            return
        }
        // Merge into the descending list.
        let incoming = slots.sorted(by: >)
        var merged: [UInt32] = []
        merged.reserveCapacity(freeSlots.count + incoming.count)
        var a = 0
        var b = 0
        while a < freeSlots.count, b < incoming.count {
            if freeSlots[a] >= incoming[b] {
                merged.append(freeSlots[a])
                a += 1
            } else {
                merged.append(incoming[b])
                b += 1
            }
        }
        merged.append(contentsOf: freeSlots[a...])
        merged.append(contentsOf: incoming[b...])
        freeSlots = merged
    }

    // MARK: Journals

    private func journal(_ chunk: Int) {
        for slot in journals.indices where !journalFull[slot] {
            guard !journalMarks[slot][chunk] else { continue }
            journalMarks[slot][chunk] = true
            journals[slot].append(chunk)
            if journals[slot].count > chunkCount / 4 {
                journalFull[slot] = true
                journals[slot].removeAll(keepingCapacity: true)
            }
        }
    }

    private func applyJournal(slot: Int) {
        if journalFull[slot] {
            copyMasterTables(toSlot: slot)
            journalFull[slot] = false
            journalMarks[slot] = Array(repeating: false, count: chunkCount)
            journals[slot].removeAll(keepingCapacity: true)
            return
        }
        guard !journals[slot].isEmpty else { return }
        let residency = residencyTables[slot].contents().bindMemory(to: GaussianChunkResidency.self, capacity: chunkCount)
        let pages = pageTables[slot].contents().bindMemory(to: UInt32.self, capacity: chunkCount * pagesPerChunk)
        for chunk in journals[slot] {
            residency[chunk] = masterResidency[chunk]
            let row = chunk * pagesPerChunk
            for tier in 0 ..< pagesPerChunk {
                pages[row + tier] = masterPageTable[row + tier]
            }
            journalMarks[slot][chunk] = false
        }
        journals[slot].removeAll(keepingCapacity: true)
    }

    private func copyMasterTables(toSlot slot: Int) {
        masterResidency.withUnsafeBytes { bytes in
            residencyTables[slot].contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        masterPageTable.withUnsafeBytes { bytes in
            pageTables[slot].contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    // MARK: I/O

    /// Queues a request and starts it if a running slot is free. Nothing blocks on the queue:
    /// at most `maxRunningReads` of this pager's reads occupy a thread, the rest wait in the
    /// list in issue (priority) order until a worker finishes and pulls the next one.
    private func enqueue(_ request: GaussianPageReadRequest) {
        lock.lock()
        _pendingReads += 1
        _bytesInFlight += request.byteCount
        _pendingRequests.append(request)
        lock.unlock()
        startPendingReads()
    }

    /// Dispatches waiting requests while running slots are free.
    private func startPendingReads() {
        lock.lock()
        var starting: [GaussianPageReadRequest] = []
        while _runningReads < maxRunningReads, _pendingHead < _pendingRequests.count {
            starting.append(_pendingRequests[_pendingHead])
            _pendingHead += 1
            _runningReads += 1
        }
        if _pendingHead == _pendingRequests.count {
            _pendingRequests.removeAll(keepingCapacity: true)
            _pendingHead = 0
        } else if _pendingHead > 64, _pendingHead * 2 > _pendingRequests.count {
            _pendingRequests.removeFirst(_pendingHead)
            _pendingHead = 0
        }
        lock.unlock()
        for request in starting {
            GaussianPageManager.queue.async {
                let manager = request.manager
                let result = manager.perform(request)
                manager.complete(request, result: result)
                manager.lock.lock()
                manager._runningReads -= 1
                manager.lock.unlock()
                manager.startPendingReads()
            }
        }
    }

    /// The worker: the request's ranges into the pools, then the chunk's CRC when the request
    /// completes it.
    private func perform(_ request: GaussianPageReadRequest) -> Result<Void, GaussianPagingError> {
        lock.lock()
        let closed = _state == .closed || request.generation != _generation
        lock.unlock()
        if closed { return .failure(.closed) }
        do {
            let coreBase = corePool.contents()
            for range in request.core {
                try source.read(offset: range.fileOffset, count: range.byteCount, into: coreBase + range.poolOffset)
            }
            if let shPool {
                let shBase = shPool.contents()
                for range in request.sh {
                    try source.read(offset: range.fileOffset, count: range.byteCount, into: shBase + range.poolOffset)
                }
            }
        } catch let error as GaussianPagingError {
            return .failure(error)
        } catch {
            return .failure(.ioFailure(errno: EIO))
        }
        if request.verify, !verifyChunk(request) {
            return .failure(.corrupt(chunk: request.chunkIndex))
        }
        return .success(())
    }

    /// The CRC over the chunk's resident bytes in file order — the core tiers from their pool
    /// slots in rank order, then the harmonics — against the index entry's.
    private func verifyChunk(_ request: GaussianPageReadRequest) -> Bool {
        let entry = index.chunks[request.chunkIndex]
        let count = Int(entry.splatCount)
        let firstTier = request.firstRank / ranksPerPage
        let tierCount = (count + ranksPerPage - 1) / ranksPerPage
        guard request.residentSlots.count == firstTier else { return false }
        var crc = UntoldGSCRC32.initialValue
        func slot(_ tier: Int) -> Int {
            tier < firstTier ? Int(request.residentSlots[tier]) : Int(request.slots[tier - firstTier])
        }
        let coreBase = UnsafeRawPointer(corePool.contents())
        for tier in 0 ..< tierCount {
            let ranks = min(ranksPerPage, count - tier * ranksPerPage)
            let bytes = UnsafeRawBufferPointer(start: coreBase + slot(tier) * ranksPerPage * UntoldGSFormat.coreRecordSize, count: ranks * UntoldGSFormat.coreRecordSize)
            UntoldGSCRC32.update(&crc, bytes)
        }
        if let shPool, shBytesPerSplat > 0 {
            let shBase = UnsafeRawPointer(shPool.contents())
            for tier in 0 ..< tierCount {
                let ranks = min(ranksPerPage, count - tier * ranksPerPage)
                let bytes = UnsafeRawBufferPointer(start: shBase + slot(tier) * ranksPerPage * shBytesPerSplat, count: ranks * shBytesPerSplat)
                UntoldGSCRC32.update(&crc, bytes)
            }
        }
        return UntoldGSCRC32.finalize(crc) == entry.crc32
    }

    private func complete(_ request: GaussianPageReadRequest, result: Result<Void, GaussianPagingError>) {
        lock.lock()
        _pendingReads -= 1
        _bytesInFlight -= request.byteCount
        _stats.pendingReads = _pendingReads
        _stats.bytesInFlight = _bytesInFlight
        if _state == .closed || request.generation != _generation {
            // Nobody will tick again: the completion is dropped here, into pool memory no frame
            // reads (the pools outlive the request through the manager it retains).
            if _eventLogEnabled {
                for slot in request.slots {
                    _eventLog.append(GaussianPagingEvent(tick: tick, kind: .dropped, chunk: request.chunkIndex, tier: request.firstRank / ranksPerPage, slot: slot, generation: 0, priority: 0))
                }
            }
        } else {
            inbox.append(GaussianPageCompletion(request: request, result: result))
        }
        let closeSource = _state == .closed && _pendingReads == 0
        lock.unlock()
        if closeSource {
            source.close()
        }
    }

    // MARK: Events

    private func log(_ kind: GaussianPagingEvent.Kind, chunk: Int, tier: Int, slot: UInt32, priority: Float = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard _eventLogEnabled else { return }
        let generation = slot == kGaussianPageSlotInvalid ? 0 : slotGeneration[Int(slot)]
        _eventLog.append(GaussianPagingEvent(tick: tick, kind: kind, chunk: chunk, tier: tier, slot: slot, generation: generation, priority: priority))
    }
}
