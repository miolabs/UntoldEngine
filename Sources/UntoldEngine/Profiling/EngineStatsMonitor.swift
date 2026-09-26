//
//  EngineStatsMonitor.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os
import QuartzCore

public enum EngineStatsLoggingProfile: Equatable {
    case compact
    case verbose
}

public final class EngineStatsMonitor: @unchecked Sendable {
    public static let shared = EngineStatsMonitor()

    /// Runtime switch for stats collection. Read on every frame-loop call site without taking the
    /// monitor lock; defaults to on in debug builds and off in release builds, or to `UNTOLD_STATS=1`.
    private let collecting: OSAllocatedUnfairLock<Bool>

    #if ENGINE_STATS_ENABLED
        private let lock = NSLock()
        private var currentSnapshot: EngineStatsSnapshot = .init()
        private var publishedSnapshot: EngineStatsSnapshot = .init()
        private var _enableLogging: Bool = false
        private var _loggingProfile: EngineStatsLoggingProfile = .compact
        private var _loggingIntervalSeconds: Double = 1.0
        private var lastLogTime: Double = 0.0

        // GPU timing — written from addCompletedHandler (async), read at completeFrame()
        private var _latestGPUExecutionMs: Double = 0.0
        private var _latestGPUFrameCadenceMs: Double = 0.0
        private var _lastGPUCompletionTime: Double = 0.0 // 0 = no completion seen yet

        // Compositor deadline accounting (visionOS) — written from addCompletedHandler, read at completeFrame()
        private var _latestDeadlineMarginMs: Double = 0.0
        private var _latestPresentationMarginMs: Double = 0.0
        private var _latestMissedDeadline: Bool = false
        private var _missedDeadlineCount: Int = 0
        private var _deadlineSampleCount: Int = 0
        private var _missingAnchorCount: Int = 0

        // Hitch accounting (frame-time histogram, over-budget counts, one-second window)
        private var _frameBudgetMs: Double = 1000.0 / 60.0
        private var _hitches = EngineHitchStats()
        private var _windowStartSeconds: Double = 0.0
        private var _windowStarted = false
        private var _windowFrames: Int = 0
        private var _windowFramesOverBudget: Int = 0
        private var _windowWorstFrameMs: Double = 0.0
        private var _lastThermalState: Int = -1

        /// Optional JSON Lines recorder fed with every published snapshot.
        private var recorder: EngineStatsRecorder?

        // 30-frame rolling average for smoothed CPU frame time
        private let kSmoothingWindow = 30
        private var _frameMsBuffer: [Double] = .init(repeating: 0.0, count: 30)
        private var _frameMsBufferIndex: Int = 0
        private var _frameMsFilled: Int = 0
    #endif

    private init() {
        let environmentValue = ProcessInfo.processInfo.environment["UNTOLD_STATS"]
        let initialState: Bool
        if let environmentValue {
            initialState = environmentValue == "1"
        } else {
            #if DEBUG
                initialState = true
            #else
                initialState = false
            #endif
        }
        collecting = OSAllocatedUnfairLock(initialState: initialState)
        #if ENGINE_STATS_ENABLED
            lastLogTime = CACurrentMediaTime()
        #endif
    }

    /// Whether the monitor collects and publishes stats. When false every per-frame call returns
    /// at once and `snapshot()` keeps returning the last published frame.
    public var isCollecting: Bool {
        get { collecting.withLock { $0 } }
        set { collecting.withLock { $0 = newValue } }
    }

    public var enableLogging: Bool {
        get {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                defer { lock.unlock() }
                return _enableLogging
            #else
                return false
            #endif
        }
        set {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                _enableLogging = newValue
                lock.unlock()
            #endif
        }
    }

    /// Frame budget for the hitch counts (`EngineHitchStats`). Defaults to 60 Hz; the visionOS
    /// runtime sets it to the 90 Hz period. Changing it does not rewrite past counts.
    public var frameBudgetMs: Double {
        get {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                defer { lock.unlock() }
                return _frameBudgetMs
            #else
                return 1000.0 / 60.0
            #endif
        }
        set {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                _frameBudgetMs = max(0.1, newValue)
                lock.unlock()
            #endif
        }
    }

    /// Attaches a recorder that receives every published snapshot, replacing any earlier one.
    func attachRecorder(_ newRecorder: EngineStatsRecorder?) -> EngineStatsRecorder? {
        #if ENGINE_STATS_ENABLED
            lock.lock()
            let previous = recorder
            recorder = newRecorder
            lock.unlock()
            return previous
        #else
            return newRecorder
        #endif
    }

    public var loggingProfile: EngineStatsLoggingProfile {
        get {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                defer { lock.unlock() }
                return _loggingProfile
            #else
                return .compact
            #endif
        }
        set {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                _loggingProfile = newValue
                lock.unlock()
            #endif
        }
    }

    public var loggingIntervalSeconds: Double {
        get {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                defer { lock.unlock() }
                return _loggingIntervalSeconds
            #else
                return 1.0
            #endif
        }
        set {
            #if ENGINE_STATS_ENABLED
                lock.lock()
                _loggingIntervalSeconds = max(0.1, newValue)
                lock.unlock()
            #endif
        }
    }

    public func snapshot() -> EngineStatsSnapshot {
        #if ENGINE_STATS_ENABLED
            lock.lock()
            defer { lock.unlock() }
            // Prefer a fully completed frame snapshot once available.
            if publishedSnapshot.frameIndex > 0 {
                return publishedSnapshot
            }
            return currentSnapshot
        #else
            return .init()
        #endif
    }

    /// Returns the in-progress snapshot being filled for the current frame.
    public func currentSnapshotInProgress() -> EngineStatsSnapshot {
        #if ENGINE_STATS_ENABLED
            lock.lock()
            defer { lock.unlock() }
            return currentSnapshot
        #else
            return .init()
        #endif
    }

    public func beginFrame(timestampSeconds: Double = CACurrentMediaTime()) {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            lock.lock()
            currentSnapshot.frameIndex &+= 1
            currentSnapshot.timestampSeconds = timestampSeconds
            currentSnapshot.timing = .init()
            currentSnapshot.compositor = .init()
            lock.unlock()
        #endif
    }

    public func update(_ updater: (inout EngineStatsSnapshot) -> Void) {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            lock.lock()
            updater(&currentSnapshot)
            lock.unlock()
        #endif
    }

    /// Called from MTLCommandBuffer.addCompletedHandler to record true GPU timing.
    /// Safe to call from any thread.
    public func recordGPUCompletion(executionMs: Double) {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            let now = CACurrentMediaTime()
            lock.lock()
            let cadenceMs = _lastGPUCompletionTime > 0
                ? (now - _lastGPUCompletionTime) * 1000.0
                : executionMs // first frame: use execution time as best estimate
            _lastGPUCompletionTime = now
            _latestGPUExecutionMs = executionMs
            _latestGPUFrameCadenceMs = cadenceMs
            lock.unlock()
        #endif
    }

    /// Called from MTLCommandBuffer.addCompletedHandler on visionOS with the GPU completion time
    /// measured against the compositor's rendering deadline and presentation time for that frame.
    /// Safe to call from any thread.
    public func recordCompositorCompletion(deadlineMarginMs: Double, presentationMarginMs: Double) {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            lock.lock()
            _latestDeadlineMarginMs = deadlineMarginMs
            _latestPresentationMarginMs = presentationMarginMs
            _latestMissedDeadline = deadlineMarginMs < 0.0
            _deadlineSampleCount += 1
            if deadlineMarginMs < 0.0 {
                _missedDeadlineCount += 1
            }
            lock.unlock()
        #else
            _ = deadlineMarginMs
            _ = presentationMarginMs
        #endif
    }

    /// Called once per frame that is presented without a fresh device anchor (visionOS).
    public func recordMissingAnchor() {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            lock.lock()
            _missingAnchorCount += 1
            lock.unlock()
        #endif
    }

    /// Publishes the current frame so API readers can safely consume it next frame.
    public func completeFrame() {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            lock.lock()
            // Pull in latest GPU timing from async handler
            currentSnapshot.timing.gpuExecutionMs = _latestGPUExecutionMs
            currentSnapshot.timing.gpuFrameCadenceMs = _latestGPUFrameCadenceMs

            // Pull in the latest compositor deadline sample and the cumulative counters
            currentSnapshot.compositor.deadlineMarginMs = _latestDeadlineMarginMs
            currentSnapshot.compositor.presentationMarginMs = _latestPresentationMarginMs
            currentSnapshot.compositor.missedDeadline = _latestMissedDeadline
            currentSnapshot.compositor.missedDeadlineCount = _missedDeadlineCount
            currentSnapshot.compositor.deadlineSampleCount = _deadlineSampleCount
            currentSnapshot.compositor.missingAnchorCount = _missingAnchorCount

            // Update 30-frame rolling average for CPU frame time
            let frameMs = currentSnapshot.timing.frameTotalMs
            _frameMsBuffer[_frameMsBufferIndex] = frameMs
            _frameMsBufferIndex = (_frameMsBufferIndex + 1) % kSmoothingWindow
            if _frameMsFilled < kSmoothingWindow { _frameMsFilled += 1 }
            var sum = 0.0
            for i in 0 ..< _frameMsFilled {
                sum += _frameMsBuffer[i]
            }
            currentSnapshot.timing.smoothedFrameMs = _frameMsFilled > 0
                ? sum / Double(_frameMsFilled)
                : frameMs

            // Hitch accounting: cumulative histogram and over-budget count, plus a one-second window
            _hitches.frameBudgetMs = _frameBudgetMs
            _hitches.framesSampled += 1
            let overBudget = frameMs > _frameBudgetMs
            if overBudget {
                _hitches.framesOverBudget += 1
            }
            _hitches.histogram[EngineHitchStats.bucketIndex(forFrameMs: frameMs)] += 1

            let now = currentSnapshot.timestampSeconds
            if !_windowStarted {
                _windowStarted = true
                _windowStartSeconds = now
            }
            if now - _windowStartSeconds >= 1.0 {
                _hitches.framesLastSecond = _windowFrames
                _hitches.framesOverBudgetLastSecond = _windowFramesOverBudget
                _hitches.worstFrameMsLastSecond = _windowWorstFrameMs
                _windowFrames = 0
                _windowFramesOverBudget = 0
                _windowWorstFrameMs = 0.0
                _windowStartSeconds = now
            }
            _windowFrames += 1
            if overBudget {
                _windowFramesOverBudget += 1
            }
            _windowWorstFrameMs = max(_windowWorstFrameMs, frameMs)
            currentSnapshot.hitches = _hitches

            // Thermal transitions are rare and worth a mark on the Instruments timeline
            let thermalState = currentSnapshot.memory.thermalState
            let thermalChanged = _lastThermalState >= 0 && thermalState != _lastThermalState
            _lastThermalState = thermalState

            publishedSnapshot = currentSnapshot
            let recordedSnapshot = currentSnapshot
            let activeRecorder = recorder
            lock.unlock()

            if thermalChanged {
                EngineProfiler.shared.emitEvent(.thermalStateChanged)
            }
            activeRecorder?.enqueue(recordedSnapshot)
        #endif
    }

    public func overwrite(with snapshot: EngineStatsSnapshot) {
        #if ENGINE_STATS_ENABLED
            lock.lock()
            currentSnapshot = snapshot
            publishedSnapshot = snapshot
            lock.unlock()
        #endif
    }

    public func reset() {
        #if ENGINE_STATS_ENABLED
            lock.lock()
            currentSnapshot = .init()
            publishedSnapshot = .init()
            lastLogTime = CACurrentMediaTime()
            _latestGPUExecutionMs = 0.0
            _latestGPUFrameCadenceMs = 0.0
            _lastGPUCompletionTime = 0.0
            _latestDeadlineMarginMs = 0.0
            _latestPresentationMarginMs = 0.0
            _latestMissedDeadline = false
            _missedDeadlineCount = 0
            _deadlineSampleCount = 0
            _missingAnchorCount = 0
            _hitches = EngineHitchStats(frameBudgetMs: _frameBudgetMs)
            _windowStartSeconds = 0.0
            _windowStarted = false
            _windowFrames = 0
            _windowFramesOverBudget = 0
            _windowWorstFrameMs = 0.0
            _lastThermalState = -1
            _frameMsBuffer = .init(repeating: 0.0, count: kSmoothingWindow)
            _frameMsBufferIndex = 0
            _frameMsFilled = 0
            lock.unlock()
        #endif
    }

    public func tick() {
        #if ENGINE_STATS_ENABLED
            guard isCollecting else { return }
            let now = CACurrentMediaTime()
            var shouldLog = false
            var snapshotToLog: EngineStatsSnapshot = .init()
            var profileToLog: EngineStatsLoggingProfile = .compact

            lock.lock()
            if _enableLogging, now - lastLogTime >= _loggingIntervalSeconds {
                lastLogTime = now
                snapshotToLog = publishedSnapshot.frameIndex > 0 ? publishedSnapshot : currentSnapshot
                profileToLog = _loggingProfile
                shouldLog = true
            }
            lock.unlock()

            guard shouldLog else { return }

            switch profileToLog {
            case .compact:
                Logger.log(
                    message: "[EngineStats] " + formatEngineStats(snapshotToLog, style: .compact),
                    category: LogCategory.engineStats.rawValue
                )
            case .verbose:
                Logger.log(
                    message: "[EngineStats]\n" + formatEngineStats(snapshotToLog, style: .expanded),
                    category: LogCategory.engineStats.rawValue
                )
            }
        #endif
    }
}

/// Returns the last completed frame snapshot for stable consumption from game `update()` loops.
public func getEngineStatsSnapshot() -> EngineStatsSnapshot {
    EngineStatsMonitor.shared.snapshot()
}

/// Returns the in-progress snapshot currently being populated for the active frame.
public func getEngineStatsSnapshotInProgress() -> EngineStatsSnapshot {
    EngineStatsMonitor.shared.currentSnapshotInProgress()
}

public func setEngineStatsLogging(enabled: Bool) {
    EngineStatsMonitor.shared.enableLogging = enabled
}

/// Turns stats collection on or off at runtime. Collection is on by default in debug builds and
/// off in release builds (`UNTOLD_STATS=1` in the environment turns it on anywhere). Turning it on
/// in a release build is how device measurements are taken.
public func setEngineStatsCollection(enabled: Bool) {
    EngineStatsMonitor.shared.isCollecting = enabled
}

public func isEngineStatsCollectionEnabled() -> Bool {
    EngineStatsMonitor.shared.isCollecting
}

public func setEngineStatsLogging(
    enabled: Bool,
    profile: EngineStatsLoggingProfile,
    intervalSeconds: Double = 1.0
) {
    EngineStatsMonitor.shared.enableLogging = enabled
    EngineStatsMonitor.shared.loggingProfile = profile
    EngineStatsMonitor.shared.loggingIntervalSeconds = intervalSeconds
}
