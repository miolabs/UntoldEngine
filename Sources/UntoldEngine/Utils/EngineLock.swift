//
//  EngineLock.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CEngineAtomics
import Foundation
import os

// The engine's lock types.
//
// Every engine lock is one of the three types below, so the primitive is chosen in one place and
// every lock can be measured the same way. In a normal build each call compiles down to the bare
// `os_unfair_lock` call and nothing else. Built with `ENGINE_LOCK_DIAGNOSTICS` (a compile-time
// flag, see docs/API/UsingProfiler.md), every acquisition is also counted and timed per named
// lock, and `EngineLockDiagnostics` reports the result.
//
// The flag is a build mode rather than a runtime switch on purpose: a frame takes hundreds of
// thousands of locks, so even a one-nanosecond runtime check would cost a measurable part of it.
//
// Rules (docs/proposals/ActorsAndLocks.md): `EngineLock` or `EngineProtected` by default;
// `EngineRecursiveLock` only where re-entry is real, and never on a per-entity path. None of
// them may be held across a suspension point.

/// A non-recursive lock for engine state. Locking it twice from the same thread is a programming
/// error and traps.
public final class EngineLock: @unchecked Sendable {
    /// Name the lock is reported under by `EngineLockDiagnostics`. Locks that guard the same kind
    /// of state share a name and are reported together.
    public let name: StaticString

    @usableFromInline let unfairLock: UnsafeMutablePointer<os_unfair_lock>
    #if ENGINE_LOCK_DIAGNOSTICS
        @usableFromInline let record: EngineLockRecord
    #endif

    public init(_ name: StaticString) {
        self.name = name
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
        #if ENGINE_LOCK_DIAGNOSTICS
            record = EngineLockDiagnostics.register(name: name, lock: unfairLock)
        #endif
    }

    deinit {
        #if ENGINE_LOCK_DIAGNOSTICS
            EngineLockDiagnostics.retire(record)
        #endif
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inlinable @inline(__always)
    public func lock(file: StaticString = #fileID, line: UInt = #line) {
        #if ENGINE_LOCK_DIAGNOSTICS
            record.lock(unfairLock, file: file, line: line)
        #else
            os_unfair_lock_lock(unfairLock)
        #endif
    }

    @inlinable @inline(__always)
    public func unlock() {
        #if ENGINE_LOCK_DIAGNOSTICS
            record.unlock(unfairLock)
        #else
            os_unfair_lock_unlock(unfairLock)
        #endif
    }

    /// Takes the lock if it is free. Returns whether it was taken.
    @inlinable @inline(__always)
    public func tryLock(file: StaticString = #fileID, line: UInt = #line) -> Bool {
        #if ENGINE_LOCK_DIAGNOSTICS
            return record.tryLock(unfairLock, file: file, line: line)
        #else
            return os_unfair_lock_trylock(unfairLock)
        #endif
    }

    @inlinable @inline(__always)
    public func withLock<Result>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock(file: file, line: line)
        defer { unlock() }
        return try body()
    }
}

/// A value that can only be reached while holding its lock.
public final class EngineProtected<State>: @unchecked Sendable {
    @usableFromInline let guardLock: EngineLock
    /// Kept behind a pointer so the access inside `withLock` carries no dynamic exclusivity check.
    @usableFromInline let state: UnsafeMutablePointer<State>

    public init(_ name: StaticString, _ initialState: State) {
        guardLock = EngineLock(name)
        state = .allocate(capacity: 1)
        state.initialize(to: initialState)
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }

    @inlinable @inline(__always)
    public func withLock<Result>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: (inout State) throws -> Result
    ) rethrows -> Result {
        guardLock.lock(file: file, line: line)
        defer { guardLock.unlock() }
        return try body(&state.pointee)
    }
}

/// A lock the thread that holds it may take again. Each `lock()` needs its own `unlock()`.
///
/// Costs a thread-identity read more than `EngineLock` on every call; use it only where code
/// that already holds the lock really calls back into code that takes it.
public final class EngineRecursiveLock: @unchecked Sendable {
    public let name: StaticString

    @usableFromInline let unfairLock: UnsafeMutablePointer<os_unfair_lock>
    /// Identifier of the thread holding the lock, or zero. Read without the lock (atomically) to
    /// recognise a re-entry: a thread can only read its own identifier back if it stored it.
    @usableFromInline let owner: UnsafeMutablePointer<UInt>
    /// Nesting depth; only touched by the thread that holds the lock.
    @usableFromInline let depth: UnsafeMutablePointer<Int>
    #if ENGINE_LOCK_DIAGNOSTICS
        @usableFromInline let record: EngineLockRecord
    #endif

    public init(_ name: StaticString) {
        self.name = name
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
        owner = .allocate(capacity: 1)
        owner.initialize(to: 0)
        depth = .allocate(capacity: 1)
        depth.initialize(to: 0)
        #if ENGINE_LOCK_DIAGNOSTICS
            record = EngineLockDiagnostics.register(name: name, lock: unfairLock)
        #endif
    }

    deinit {
        #if ENGINE_LOCK_DIAGNOSTICS
            EngineLockDiagnostics.retire(record)
        #endif
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
        owner.deinitialize(count: 1)
        owner.deallocate()
        depth.deinitialize(count: 1)
        depth.deallocate()
    }

    @inlinable @inline(__always)
    public func lock(file: StaticString = #fileID, line: UInt = #line) {
        let current = UInt(bitPattern: pthread_self())
        if UEAtomicLoadRelaxed(owner) == current {
            depth.pointee &+= 1
            #if ENGINE_LOCK_DIAGNOSTICS
                record.reentered(file: file, line: line)
            #endif
            return
        }
        #if ENGINE_LOCK_DIAGNOSTICS
            record.lock(unfairLock, file: file, line: line)
        #else
            os_unfair_lock_lock(unfairLock)
        #endif
        UEAtomicStoreRelaxed(owner, current)
        depth.pointee = 1
    }

    @inlinable @inline(__always)
    public func unlock() {
        let remaining = depth.pointee &- 1
        depth.pointee = remaining
        if remaining == 0 {
            UEAtomicStoreRelaxed(owner, 0)
            #if ENGINE_LOCK_DIAGNOSTICS
                record.unlock(unfairLock)
            #else
                os_unfair_lock_unlock(unfairLock)
            #endif
        }
    }

    @inlinable @inline(__always)
    public func withLock<Result>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock(file: file, line: line)
        defer { unlock() }
        return try body()
    }
}
