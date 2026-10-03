//
//  EngineLockDiagnostics.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os

/// What one lock name did over a period: a frame in `EngineStatsSnapshot.locks`, or everything
/// since the last `EngineLockDiagnostics.reset()` in `EngineLockDiagnostics.snapshot()`.
public struct EngineLockStats: Codable, Sendable, Equatable {
    /// The name given to `EngineLock`, `EngineProtected` or `EngineRecursiveLock`.
    public var name: String
    /// Live lock objects reported under this name.
    public var instances: Int = 0
    /// Times the lock was taken, not counting re-entries.
    public var acquisitions: Int = 0
    /// Times a thread that already held a recursive lock took it again.
    public var reentries: Int = 0
    /// Acquisitions that found the lock held by another thread and had to wait.
    public var contended: Int = 0
    /// Time spent waiting in contended acquisitions.
    public var waitMs: Double = 0.0
    /// Time the lock was held. The clock ticks every 42 ns on Apple silicon, so this is only
    /// meaningful summed over many acquisitions.
    public var holdMs: Double = 0.0
    /// Longest single hold since the last `EngineLockDiagnostics.reset()`.
    public var maxHoldMs: Double = 0.0

    public init(name: String) {
        self.name = name
    }
}

/// How often one source location took a lock (recorded only with `recordsSites` on).
public struct EngineLockSiteStats: Codable, Sendable, Equatable {
    public var name: String
    public var file: String
    public var line: Int
    public var count: Int
}

/// Counts and timings of the engine's locks, available in builds compiled with
/// `ENGINE_LOCK_DIAGNOSTICS`. In every other build the calls below return nothing and the lock
/// types carry no instrumentation at all.
///
///     swift build -Xswiftc -DENGINE_LOCK_DIAGNOSTICS
public enum EngineLockDiagnostics {
    /// Whether this build was compiled with `ENGINE_LOCK_DIAGNOSTICS`.
    public static var isCompiledIn: Bool {
        #if ENGINE_LOCK_DIAGNOSTICS
            return true
        #else
            return false
        #endif
    }

    /// When true, every acquisition is also counted per source location (file and line of the
    /// `lock()` or `withLock` call). Costs a dictionary update per acquisition, so it is off by
    /// default; `UNTOLD_LOCK_SITES=1` in the environment turns it on from launch.
    public nonisolated(unsafe) static var recordsSites: Bool =
        ProcessInfo.processInfo.environment["UNTOLD_LOCK_SITES"] == "1"

    /// Totals per lock name since the last `reset()`, most active first.
    public static func snapshot() -> [EngineLockStats] {
        #if ENGINE_LOCK_DIAGNOSTICS
            os_unfair_lock_lock(registryLock)
            let totals = totalsLocked()
            os_unfair_lock_unlock(registryLock)
            return totals.map { stats(name: $0.key, instances: $0.value.instances, counters: $0.value.counters) }
                .sorted(by: moreActive)
        #else
            return []
        #endif
    }

    /// What every lock name did since the previous call, most active first. The stats monitor
    /// calls this once per frame to fill `EngineStatsSnapshot.locks`.
    public static func consumeFrameDelta() -> [EngineLockStats] {
        #if ENGINE_LOCK_DIAGNOSTICS
            os_unfair_lock_lock(registryLock)
            let totals = totalsLocked()
            var result: [EngineLockStats] = []
            for (name, entry) in totals {
                var delta = entry.counters
                if let base = registry.frameBase[name] {
                    delta.subtract(base)
                }
                if delta.acquisitions == 0, delta.reentries == 0 {
                    continue
                }
                result.append(stats(name: name, instances: entry.instances, counters: delta))
            }
            registry.frameBase = totals.mapValues(\.counters)
            os_unfair_lock_unlock(registryLock)
            return result.sorted(by: moreActive)
        #else
            return []
        #endif
    }

    /// Per source location counts since the last `reset()`, most active first. Empty unless
    /// `recordsSites` was on while the locks were taken.
    public static func sites(top: Int = 40) -> [EngineLockSiteStats] {
        #if ENGINE_LOCK_DIAGNOSTICS
            os_unfair_lock_lock(registryLock)
            var merged: [SiteName: UInt64] = registry.retiredSites
            for record in registry.live.values {
                let name = record.name.description
                let copy: [EngineLockSite: UInt64]? = record.whileHeld { record.sites }
                for (site, count) in copy ?? [:] {
                    merged[SiteName(name: name, file: site.fileName, line: site.line), default: 0] += count
                }
            }
            os_unfair_lock_unlock(registryLock)
            return merged
                .map { EngineLockSiteStats(name: $0.key.name, file: $0.key.file, line: Int($0.key.line), count: Int($0.value)) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.file, $0.line) < ($1.file, $1.line) }
                .prefix(max(0, top))
                .map { $0 }
        #else
            return []
        #endif
    }

    /// Zeroes every counter. Call it from a point where the calling thread holds no engine lock.
    public static func reset() {
        #if ENGINE_LOCK_DIAGNOSTICS
            os_unfair_lock_lock(registryLock)
            for record in registry.live.values {
                let cleared: Void? = record.whileHeld {
                    record.counters = EngineLockCounters()
                    record.sites.removeAll(keepingCapacity: true)
                }
                if cleared == nil {
                    // Held for the whole retry window: zero the plain counters anyway. A racing
                    // update may survive; that is acceptable for a diagnostics counter.
                    record.counters = EngineLockCounters()
                }
            }
            registry.retired.removeAll()
            registry.retiredSites.removeAll()
            registry.frameBase.removeAll()
            os_unfair_lock_unlock(registryLock)
        #endif
    }

    /// A table of `snapshot()` (and of `sites()` when sites were recorded), with counts divided
    /// by `divisor`, for example the number of frames the counters cover.
    public static func report(per divisor: Int = 1, unit: String = "frame", top: Int = 24) -> String {
        #if ENGINE_LOCK_DIAGNOSTICS
            let d = Double(max(1, divisor))
            var lines: [String] = []
            let locks = snapshot()
            let total = locks.reduce(0) { $0 + $1.acquisitions + $1.reentries }
            lines.append(String(format: "Engine locks: %.1f lock calls per %@", Double(total) / d, unit))
            lines.append("  " + "lock".padding(toLength: 34, withPad: " ", startingAt: 0)
                + "      taken  reentries  contended    wait ms    hold ms  max hold ms  instances")
            for lock in locks.prefix(max(0, top)) {
                lines.append("  " + lock.name.padding(toLength: 34, withPad: " ", startingAt: 0) + String(
                    format: " %10.1f %10.1f %10d %10.3f %10.3f %12.4f %10d",
                    Double(lock.acquisitions) / d, Double(lock.reentries) / d, lock.contended,
                    lock.waitMs, lock.holdMs / d, lock.maxHoldMs, lock.instances
                ))
            }
            let siteRows = sites(top: top)
            if !siteRows.isEmpty {
                lines.append("  by source location (calls per \(unit))")
                for site in siteRows {
                    lines.append(String(format: "  %10.1f  ", Double(site.count) / d) + "\(site.file):\(site.line)  [\(site.name)]")
                }
            }
            return lines.joined(separator: "\n")
        #else
            return "Engine lock diagnostics are not compiled in (build with -DENGINE_LOCK_DIAGNOSTICS)."
        #endif
    }
}

#if ENGINE_LOCK_DIAGNOSTICS

    struct EngineLockCounters: Sendable {
        var acquisitions: UInt64 = 0
        var reentries: UInt64 = 0
        var contended: UInt64 = 0
        var waitTicks: UInt64 = 0
        var holdTicks: UInt64 = 0
        var maxHoldTicks: UInt64 = 0

        mutating func add(_ other: EngineLockCounters) {
            acquisitions &+= other.acquisitions
            reentries &+= other.reentries
            contended &+= other.contended
            waitTicks &+= other.waitTicks
            holdTicks &+= other.holdTicks
            maxHoldTicks = max(maxHoldTicks, other.maxHoldTicks)
        }

        /// Subtracts an earlier reading of the same counters. The maximum is not a sum and stays.
        mutating func subtract(_ base: EngineLockCounters) {
            acquisitions = acquisitions >= base.acquisitions ? acquisitions - base.acquisitions : 0
            reentries = reentries >= base.reentries ? reentries - base.reentries : 0
            contended = contended >= base.contended ? contended - base.contended : 0
            waitTicks = waitTicks >= base.waitTicks ? waitTicks - base.waitTicks : 0
            holdTicks = holdTicks >= base.holdTicks ? holdTicks - base.holdTicks : 0
        }
    }

    struct EngineLockSite: Hashable {
        /// `#fileID` literals are static, so the address identifies the file within a module.
        let file: UnsafePointer<UInt8>
        let fileLength: Int
        let line: UInt

        var fileName: String {
            String(decoding: UnsafeBufferPointer(start: file, count: fileLength), as: UTF8.self)
        }
    }

    /// Per-lock counters. Every field is written only by the thread that holds the lock the
    /// record belongs to, so the lock itself protects them.
    @usableFromInline
    final class EngineLockRecord: @unchecked Sendable {
        let name: StaticString
        let unfairLock: UnsafeMutablePointer<os_unfair_lock>
        var counters = EngineLockCounters()
        var holdStart: UInt64 = 0
        var sites: [EngineLockSite: UInt64] = [:]

        init(name: StaticString, lock: UnsafeMutablePointer<os_unfair_lock>) {
            self.name = name
            unfairLock = lock
        }

        @usableFromInline
        func lock(_ unfairLock: UnsafeMutablePointer<os_unfair_lock>, file: StaticString, line: UInt) {
            if os_unfair_lock_trylock(unfairLock) {
                holdStart = mach_absolute_time()
            } else {
                let waitStart = mach_absolute_time()
                os_unfair_lock_lock(unfairLock)
                let now = mach_absolute_time()
                counters.contended &+= 1
                counters.waitTicks &+= now &- waitStart
                holdStart = now
            }
            counters.acquisitions &+= 1
            if EngineLockDiagnostics.recordsSites {
                noteSite(file: file, line: line)
            }
        }

        @usableFromInline
        func tryLock(_ unfairLock: UnsafeMutablePointer<os_unfair_lock>, file: StaticString, line: UInt) -> Bool {
            guard os_unfair_lock_trylock(unfairLock) else { return false }
            holdStart = mach_absolute_time()
            counters.acquisitions &+= 1
            if EngineLockDiagnostics.recordsSites {
                noteSite(file: file, line: line)
            }
            return true
        }

        @usableFromInline
        func unlock(_ unfairLock: UnsafeMutablePointer<os_unfair_lock>) {
            let held = mach_absolute_time() &- holdStart
            counters.holdTicks &+= held
            if held > counters.maxHoldTicks {
                counters.maxHoldTicks = held
            }
            os_unfair_lock_unlock(unfairLock)
        }

        /// A thread that already holds the (recursive) lock took it again.
        @usableFromInline
        func reentered(file: StaticString, line: UInt) {
            counters.reentries &+= 1
            if EngineLockDiagnostics.recordsSites {
                noteSite(file: file, line: line)
            }
        }

        private func noteSite(file: StaticString, line: UInt) {
            guard file.hasPointerRepresentation else { return }
            sites[EngineLockSite(file: file.utf8Start, fileLength: file.utf8CodeUnitCount, line: line), default: 0] &+= 1
        }

        /// Reads the counters. Takes the lock when it is free; when it is not (another thread
        /// holds it, or the caller does), reads the plain words as they are.
        func readCounters() -> EngineLockCounters {
            let locked = os_unfair_lock_trylock(unfairLock)
            let copy = counters
            if locked {
                os_unfair_lock_unlock(unfairLock)
            }
            return copy
        }

        /// Runs `body` holding the lock, without counting the acquisition. Retries for up to
        /// about 100 ms and returns nil if the lock stayed held, which also covers a caller
        /// that holds it itself (an unfair lock cannot tell and would trap on a blocking lock).
        func whileHeld<Result>(_ body: () -> Result) -> Result? {
            for _ in 0 ..< 2000 {
                if os_unfair_lock_trylock(unfairLock) {
                    defer { os_unfair_lock_unlock(unfairLock) }
                    return body()
                }
                usleep(50)
            }
            return nil
        }
    }

    extension EngineLockDiagnostics {
        struct SiteName: Hashable {
            let name: String
            let file: String
            let line: UInt
        }

        struct Registry {
            var live: [ObjectIdentifier: EngineLockRecord] = [:]
            /// Counters of locks that were deallocated, by name.
            var retired: [String: EngineLockCounters] = [:]
            var retiredSites: [SiteName: UInt64] = [:]
            /// Totals at the previous `consumeFrameDelta()`.
            var frameBase: [String: EngineLockCounters] = [:]
        }

        /// Guards `registry`. A raw unfair lock: the registry cannot be measured by itself.
        nonisolated(unsafe) static let registryLock: UnsafeMutablePointer<os_unfair_lock> = {
            let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
            pointer.initialize(to: os_unfair_lock())
            return pointer
        }()

        nonisolated(unsafe) static var registry = Registry()

        static let millisecondsPerTick: Double = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return Double(info.numer) / Double(info.denom) / 1_000_000.0
        }()

        @usableFromInline
        static func register(name: StaticString, lock: UnsafeMutablePointer<os_unfair_lock>) -> EngineLockRecord {
            let record = EngineLockRecord(name: name, lock: lock)
            os_unfair_lock_lock(registryLock)
            registry.live[ObjectIdentifier(record)] = record
            os_unfair_lock_unlock(registryLock)
            return record
        }

        /// Called from the lock's deinit, so nothing else can hold or take the lock any more.
        @usableFromInline
        static func retire(_ record: EngineLockRecord) {
            let name = record.name.description
            os_unfair_lock_lock(registryLock)
            registry.live.removeValue(forKey: ObjectIdentifier(record))
            registry.retired[name, default: EngineLockCounters()].add(record.counters)
            for (site, count) in record.sites {
                registry.retiredSites[SiteName(name: name, file: site.fileName, line: site.line), default: 0] += count
            }
            os_unfair_lock_unlock(registryLock)
        }

        /// Totals by name. Call with `registryLock` held.
        static func totalsLocked() -> [String: (counters: EngineLockCounters, instances: Int)] {
            var totals: [String: (counters: EngineLockCounters, instances: Int)] = [:]
            for (name, counters) in registry.retired {
                totals[name] = (counters, 0)
            }
            for record in registry.live.values {
                let name = record.name.description
                var entry = totals[name] ?? (EngineLockCounters(), 0)
                entry.counters.add(record.readCounters())
                entry.instances += 1
                totals[name] = entry
            }
            return totals
        }

        static func stats(name: String, instances: Int, counters: EngineLockCounters) -> EngineLockStats {
            var result = EngineLockStats(name: name)
            result.instances = instances
            result.acquisitions = Int(clamping: counters.acquisitions)
            result.reentries = Int(clamping: counters.reentries)
            result.contended = Int(clamping: counters.contended)
            result.waitMs = Double(counters.waitTicks) * millisecondsPerTick
            result.holdMs = Double(counters.holdTicks) * millisecondsPerTick
            result.maxHoldMs = Double(counters.maxHoldTicks) * millisecondsPerTick
            return result
        }

        static func moreActive(_ lhs: EngineLockStats, _ rhs: EngineLockStats) -> Bool {
            let l = lhs.acquisitions + lhs.reentries
            let r = rhs.acquisitions + rhs.reentries
            return l != r ? l > r : lhs.name < rhs.name
        }
    }

#endif
