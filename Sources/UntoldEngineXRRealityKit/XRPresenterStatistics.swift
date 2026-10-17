//
//  XRPresenterStatistics.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import QuartzCore

/// The presenter's numbers over the span since the last snapshot: how RealityKit's cadence and
/// the engine's frames meet.
public struct XRPresenterStatisticsSnapshot: Sendable, Equatable {
    /// Seconds the snapshot covers.
    public var seconds: Double = 0
    /// RealityKit updates (the main thread's chances to post a ticket).
    public var updates = 0
    /// Tickets posted, and tickets not posted because the engine had not taken the previous one.
    public var ticketsPosted = 0
    public var ticketsDropped = 0
    /// Frames the engine drew (tickets taken), and the pose queries that found no pose.
    public var framesDrawn = 0
    public var posesMissing = 0
    /// The main thread inside the replace calls per update, milliseconds.
    public var replaceMsAverage = 0.0
    public var replaceMsMax = 0.0
    /// How long a ticket waited to be taken, milliseconds.
    public var pickupAgeMsAverage = 0.0
    public var pickupAgeMsMax = 0.0
    /// From a ticket's pickup to its frame being encoded, milliseconds: the engine's CPU frame.
    public var frameMsAverage = 0.0
    public var frameMsMax = 0.0
    /// The frame's GPU span, milliseconds.
    public var gpuMsAverage = 0.0
    public var gpuMsMax = 0.0
    /// Tickets dropped since the presenter started.
    public var ticketsDroppedTotal = 0

    public var updatesPerSecond: Double { seconds > 0 ? Double(updates) / seconds : 0 }
    public var framesPerSecond: Double { seconds > 0 ? Double(framesDrawn) / seconds : 0 }

    /// One line with the numbers, for a log.
    public var description: String {
        String(
            format: "XR presenter: %.0f updates/s, %.0f frames/s, %d tickets dropped (%d in all), %d frames without a pose; replace %.2f ms (max %.2f), pickup age %.2f ms (max %.2f), frame %.2f ms (max %.2f), GPU %.2f ms (max %.2f)",
            updatesPerSecond, framesPerSecond, ticketsDropped, ticketsDroppedTotal, posesMissing,
            replaceMsAverage, replaceMsMax, pickupAgeMsAverage, pickupAgeMsMax,
            frameMsAverage, frameMsMax, gpuMsAverage, gpuMsMax
        )
    }
}

/// Counters written from the main thread (updates, replace calls, drops), the engine's thread
/// (pickups, poses, frames) and the GPU's completion thread (GPU spans), read as a snapshot.
public final class XRPresenterStatistics: @unchecked Sendable {
    private struct Span {
        var sum = 0.0
        var max = 0.0
        var count = 0

        mutating func add(_ seconds: Double) {
            sum += seconds
            max = Swift.max(max, seconds)
            count += 1
        }

        var averageMs: Double { count > 0 ? sum / Double(count) * 1000 : 0 }
        var maxMs: Double { max * 1000 }
    }

    private let lock = NSLock()
    private var since = CACurrentMediaTime()
    private var updates = 0
    private var posted = 0
    private var dropped = 0
    private var droppedTotal = 0
    private var frames = 0
    private var posesMissing = 0
    private var replace = Span()
    private var pickupAge = Span()
    private var frame = Span()
    private var gpu = Span()

    public init() {}

    public func noteUpdate() {
        lock.withLock { updates += 1 }
    }

    public func noteTicketPosted(replaceSeconds: Double) {
        lock.withLock {
            posted += 1
            replace.add(replaceSeconds)
        }
    }

    public func noteTicketDropped() {
        lock.withLock {
            dropped += 1
            droppedTotal += 1
        }
    }

    public func noteTicketTaken(ageSeconds: Double) {
        lock.withLock {
            frames += 1
            pickupAge.add(ageSeconds)
        }
    }

    public func notePoseMissing() {
        lock.withLock { posesMissing += 1 }
    }

    public func noteFrameEncoded(seconds: Double) {
        lock.withLock { frame.add(seconds) }
    }

    public func noteGPU(seconds: Double) {
        lock.withLock { gpu.add(seconds) }
    }

    /// The numbers since the last snapshot, which starts a new span.
    public func snapshot() -> XRPresenterStatisticsSnapshot {
        lock.withLock {
            let now = CACurrentMediaTime()
            var snapshot = XRPresenterStatisticsSnapshot()
            snapshot.seconds = now - since
            snapshot.updates = updates
            snapshot.ticketsPosted = posted
            snapshot.ticketsDropped = dropped
            snapshot.ticketsDroppedTotal = droppedTotal
            snapshot.framesDrawn = frames
            snapshot.posesMissing = posesMissing
            snapshot.replaceMsAverage = replace.averageMs
            snapshot.replaceMsMax = replace.maxMs
            snapshot.pickupAgeMsAverage = pickupAge.averageMs
            snapshot.pickupAgeMsMax = pickupAge.maxMs
            snapshot.frameMsAverage = frame.averageMs
            snapshot.frameMsMax = frame.maxMs
            snapshot.gpuMsAverage = gpu.averageMs
            snapshot.gpuMsMax = gpu.maxMs
            since = now
            updates = 0
            posted = 0
            dropped = 0
            frames = 0
            posesMissing = 0
            replace = Span()
            pickupAge = Span()
            frame = Span()
            gpu = Span()
            return snapshot
        }
    }
}
