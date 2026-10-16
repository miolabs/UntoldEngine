//
//  EngineLockTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os
@testable import UntoldEngine
import XCTest

private final class Counter: @unchecked Sendable {
    var value = 0
}

private let threads = 8
private let iterations = 20000

final class EngineLockTests: XCTestCase {
    // MARK: - Behaviour (every build)

    func test_engineLock_excludesOtherThreads() {
        let lock = EngineLock("Test.exclusion")
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                lock.lock()
                counter.value += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(counter.value, threads * iterations)
    }

    func test_engineLock_withLockReturnsTheBodyResultAndReleasesOnThrow() {
        struct Failure: Error {}
        let lock = EngineLock("Test.withLock")
        XCTAssertEqual(lock.withLock { 7 }, 7)
        XCTAssertThrowsError(try lock.withLock { throw Failure() })
        // Released by the throwing call: taking it again must not deadlock.
        XCTAssertTrue(lock.tryLock())
        lock.unlock()
    }

    func test_engineLock_tryLockFailsWhileAnotherThreadHoldsIt() {
        let lock = EngineLock("Test.tryLock")
        lock.lock()
        let taken = Counter()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            if lock.tryLock() {
                taken.value = 1
                lock.unlock()
            }
            done.signal()
        }
        done.wait()
        XCTAssertEqual(taken.value, 0)
        lock.unlock()
        XCTAssertTrue(lock.tryLock())
        lock.unlock()
    }

    func test_engineProtected_serialisesMutations() {
        let state = EngineProtected<[Int: Int]>("Test.protected", [:])
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for _ in 0 ..< iterations {
                state.withLock { $0[thread, default: 0] += 1 }
            }
        }
        let snapshot = state.withLock { $0 }
        XCTAssertEqual(snapshot.count, threads)
        XCTAssertTrue(snapshot.values.allSatisfy { $0 == iterations })
    }

    func test_recursiveLock_sameThreadMayReenter() {
        let lock = EngineRecursiveLock("Test.recursive.reenter")
        let value: Int = lock.withLock {
            lock.withLock {
                lock.lock()
                defer { lock.unlock() }
                return 3
            }
        }
        XCTAssertEqual(value, 3)
    }

    func test_recursiveLock_staysHeldUntilTheOutermostUnlock() {
        let lock = EngineRecursiveLock("Test.recursive.outermost")
        let entered = Counter()
        let done = DispatchSemaphore(value: 0)

        lock.lock()
        lock.lock()
        Thread.detachNewThread {
            lock.lock()
            entered.value = 1
            lock.unlock()
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(entered.value, 0, "taken by another thread at depth 2")
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(entered.value, 0, "taken by another thread at depth 1")
        lock.unlock()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(entered.value, 1)
    }

    func test_recursiveLock_excludesOtherThreadsWhileNested() {
        let lock = EngineRecursiveLock("Test.recursive.exclusion")
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                lock.lock()
                lock.lock()
                counter.value += 1
                lock.unlock()
                counter.value += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(counter.value, 2 * threads * iterations)
    }

    // MARK: - Diagnostics

    #if ENGINE_LOCK_DIAGNOSTICS

        private func stats(_ name: String) -> EngineLockStats? {
            EngineLockDiagnostics.snapshot().first { $0.name == name }
        }

        func test_diagnostics_countAcquisitionsAndReentries() throws {
            XCTAssertTrue(EngineLockDiagnostics.isCompiledIn)
            let lock = EngineLock("Test.diag.count")
            let recursive = EngineRecursiveLock("Test.diag.reentry")
            for _ in 0 ..< 100 {
                lock.lock()
                lock.unlock()
                recursive.lock()
                recursive.lock()
                recursive.lock()
                recursive.unlock()
                recursive.unlock()
                recursive.unlock()
            }
            let plain = try XCTUnwrap(stats("Test.diag.count"))
            XCTAssertEqual(plain.acquisitions, 100)
            XCTAssertEqual(plain.reentries, 0)
            XCTAssertEqual(plain.contended, 0)
            XCTAssertEqual(plain.instances, 1)
            let nested = try XCTUnwrap(stats("Test.diag.reentry"))
            XCTAssertEqual(nested.acquisitions, 100)
            XCTAssertEqual(nested.reentries, 200)
        }

        func test_diagnostics_measureWaitAndHoldUnderContention() throws {
            let lock = EngineLock("Test.diag.contention")
            let holding = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                lock.lock()
                holding.signal()
                Thread.sleep(forTimeInterval: 0.05)
                lock.unlock()
                done.signal()
            }
            holding.wait()
            lock.lock()
            lock.unlock()
            done.wait()
            let result = try XCTUnwrap(stats("Test.diag.contention"))
            XCTAssertEqual(result.acquisitions, 2)
            XCTAssertEqual(result.contended, 1)
            XCTAssertGreaterThan(result.waitMs, 20.0)
            XCTAssertGreaterThan(result.holdMs, 40.0)
            XCTAssertGreaterThan(result.maxHoldMs, 40.0)
        }

        func test_diagnostics_locksSharingANameAreReportedTogetherAndSurviveDeallocation() throws {
            var first: EngineLock? = EngineLock("Test.diag.shared")
            let second = EngineLock("Test.diag.shared")
            first?.withLock {}
            second.withLock {}
            second.withLock {}
            XCTAssertEqual(try XCTUnwrap(stats("Test.diag.shared")).instances, 2)
            first = nil
            let result = try XCTUnwrap(stats("Test.diag.shared"))
            XCTAssertEqual(result.instances, 1)
            XCTAssertEqual(result.acquisitions, 3)
        }

        func test_diagnostics_recordSourceLocationsWhenAsked() throws {
            let previous = EngineLockDiagnostics.recordsSites
            EngineLockDiagnostics.recordsSites = true
            defer { EngineLockDiagnostics.recordsSites = previous }

            let lock = EngineLock("Test.diag.sites")
            for _ in 0 ..< 5 {
                lock.lock()
                lock.unlock()
            }
            let site = try XCTUnwrap(EngineLockDiagnostics.sites(top: 10000).first { $0.name == "Test.diag.sites" })
            XCTAssertEqual(site.count, 5)
            XCTAssertTrue(site.file.hasSuffix("EngineLockTests.swift"), site.file)
            XCTAssertGreaterThan(site.line, 0)
        }

        func test_diagnostics_frameDeltaReportsOnlyWhatHappenedSinceThePreviousCall() throws {
            let lock = EngineLock("Test.diag.delta")
            lock.withLock {}
            _ = EngineLockDiagnostics.consumeFrameDelta()
            lock.withLock {}
            lock.withLock {}
            let delta = try XCTUnwrap(EngineLockDiagnostics.consumeFrameDelta().first { $0.name == "Test.diag.delta" })
            XCTAssertEqual(delta.acquisitions, 2)
            XCTAssertNil(EngineLockDiagnostics.consumeFrameDelta().first { $0.name == "Test.diag.delta" })
        }

        func test_diagnostics_reportListsTheLockByName() {
            let lock = EngineLock("Test.diag.report")
            lock.withLock {}
            XCTAssertTrue(EngineLockDiagnostics.report(top: 10000).contains("Test.diag.report"))
        }

    #else

        func test_diagnostics_areAbsentFromANormalBuild() {
            XCTAssertFalse(EngineLockDiagnostics.isCompiledIn)
            let lock = EngineLock("Test.diag.absent")
            lock.withLock {}
            XCTAssertTrue(EngineLockDiagnostics.snapshot().isEmpty)
            XCTAssertTrue(EngineLockDiagnostics.consumeFrameDelta().isEmpty)
            XCTAssertTrue(EngineLockDiagnostics.sites().isEmpty)
        }

    #endif

    // MARK: - Cost (opt-in, meaningful in a release build)

    /// Prints the cost of an uncontended lock and unlock for each engine lock type next to the
    /// primitives they replace. Opt-in: `UNTOLD_LOCK_COST=1`, with a release build:
    ///
    ///     UNTOLD_LOCK_COST=1 swift test -c release -Xswiftc -enable-testing --filter EngineLockTests/test_cost
    ///
    /// In a normal build `EngineLock` must cost what the bare `os_unfair_lock` costs.
    func test_cost_uncontendedLockAndUnlock() throws {
        guard ProcessInfo.processInfo.environment["UNTOLD_LOCK_COST"] == "1" else {
            throw XCTSkip("Set UNTOLD_LOCK_COST=1 to run the lock cost comparison")
        }
        let operations = 5_000_000

        func nanosecondsPerOperation(_ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 7 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / Double(operations))
            }
            return best
        }

        let counter = Counter()

        let raw = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
        defer {
            raw.deinitialize(count: 1)
            raw.deallocate()
        }
        let rawNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                os_unfair_lock_lock(raw)
                counter.value &+= 1
                os_unfair_lock_unlock(raw)
            }
        }

        let allocated = OSAllocatedUnfairLock()
        let allocatedNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                allocated.lock()
                counter.value &+= 1
                allocated.unlock()
            }
        }

        let engineLock = EngineLock("Test.cost.lock")
        let engineNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                engineLock.lock()
                counter.value &+= 1
                engineLock.unlock()
            }
        }

        let protected = EngineProtected<Int>("Test.cost.protected", 0)
        let protectedNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                protected.withLock { $0 &+= 1 }
            }
        }

        let nsLock = NSLock()
        let nsLockNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                nsLock.lock()
                counter.value &+= 1
                nsLock.unlock()
            }
        }

        let engineRecursive = EngineRecursiveLock("Test.cost.recursive")
        let engineRecursiveNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                engineRecursive.lock()
                counter.value &+= 1
                engineRecursive.unlock()
            }
        }

        let nsRecursive = NSRecursiveLock()
        let nsRecursiveNs = nanosecondsPerOperation {
            for _ in 0 ..< operations {
                nsRecursive.lock()
                counter.value &+= 1
                nsRecursive.unlock()
            }
        }

        print(String(format: "LOCK_COST diagnostics=%@", EngineLockDiagnostics.isCompiledIn ? "on" : "off"))
        print(String(format: "LOCK_COST os_unfair_lock          %6.2f ns", rawNs))
        print(String(format: "LOCK_COST OSAllocatedUnfairLock   %6.2f ns", allocatedNs))
        print(String(format: "LOCK_COST EngineLock              %6.2f ns", engineNs))
        print(String(format: "LOCK_COST EngineProtected         %6.2f ns", protectedNs))
        print(String(format: "LOCK_COST NSLock                  %6.2f ns", nsLockNs))
        print(String(format: "LOCK_COST EngineRecursiveLock     %6.2f ns", engineRecursiveNs))
        print(String(format: "LOCK_COST NSRecursiveLock         %6.2f ns", nsRecursiveNs))
        XCTAssertGreaterThan(counter.value, 0)
    }
}
