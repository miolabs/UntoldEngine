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
import UntoldEngine

/// One frame's time from its ticket's pickup to its command buffer completing on the GPU,
/// split into the stages it went through, in seconds: the CPU frame (from the pickup to the
/// loop committing the command buffer), the wait (from the commit to the GPU starting on the
/// buffer: the driver's submission and the GPU's queue, where the compositor's and RealityKit's
/// own work go first), and the GPU span (from the GPU starting to its ending). The three sum to
/// the completion, so a frame that landed a refresh late can be read for where it spent its
/// time.
public struct XRPresenterFrameStages: Sendable, Equatable {
    public var cpu: TimeInterval = 0
    public var wait: TimeInterval = 0
    public var gpu: TimeInterval = 0

    public init(cpu: TimeInterval = 0, wait: TimeInterval = 0, gpu: TimeInterval = 0) {
        self.cpu = cpu
        self.wait = wait
        self.gpu = gpu
    }

    /// From the pickup to the GPU's completion: the stages' sum.
    public var completion: TimeInterval {
        cpu + wait + gpu
    }

    public var cpuMs: Double {
        cpu * 1000
    }

    public var waitMs: Double {
        wait * 1000
    }

    public var gpuMs: Double {
        gpu * 1000
    }

    public var completionMs: Double {
        completion * 1000
    }

    /// The stages of a frame from its instants, all in the host's time base
    /// (`CACurrentMediaTime`): the ticket's pickup, the loop's commit, and the command buffer's
    /// GPU start and end as its completed handler reads them, with `now` the handler's own
    /// time. A GPU that reports no times (zeros, or an end before the pickup) gives a span of
    /// zero and a completion at the handler's time; the wait absorbs whatever the GPU's times
    /// leave, so the stages always sum to the completion.
    public init(pickup: TimeInterval, committed: TimeInterval, gpuStart: TimeInterval, gpuEnd: TimeInterval, now: TimeInterval) {
        let cpu = max(0, committed - pickup)
        let reported = gpuEnd > pickup && gpuStart > 0
        let end = reported ? gpuEnd : now
        let completion = max(cpu, end - pickup)
        let gpu = reported ? min(max(0, gpuEnd - gpuStart), completion - cpu) : 0
        self.init(cpu: cpu, wait: max(0, completion - cpu - gpu), gpu: gpu)
    }

    /// The split as the numbers line prints it, milliseconds: "16.6 = cpu 3.1 + wait 9.2 + gpu 4.3".
    public var splitDescription: String {
        String(format: "%.1f = cpu %.1f + wait %.1f + gpu %.1f", completionMs, cpuMs, waitMs, gpuMs)
    }
}

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
    /// From a ticket's pickup to the loop committing its command buffer, milliseconds: the
    /// engine's CPU frame (`XRPresenterFrameStages.cpu`).
    public var frameMsAverage = 0.0
    public var frameMsMax = 0.0
    /// From the commit to the GPU starting on the command buffer, milliseconds: the driver's
    /// submission and the GPU's queue, where the compositor's and RealityKit's own work go
    /// first on a headset (`XRPresenterFrameStages.wait`).
    public var waitMsAverage = 0.0
    public var waitMsMax = 0.0
    /// From a ticket's pickup to its command buffer completing on the GPU, milliseconds: the
    /// CPU frame, the wait and the GPU span; the frame's time the adaptive lead averages
    /// (`XRPresenterLead`).
    public var completionMsAverage = 0.0
    public var completionMsMax = 0.0
    /// The lead in force, milliseconds: from a ticket's posting to the instant its frame was
    /// posed for, the fixed lead past the pickup or the measured one (`XRPresenterLead`).
    public var leadMsAverage = 0.0
    public var leadMsMax = 0.0
    /// The frame's GPU span, milliseconds: from the ticket's command buffer starting on the GPU
    /// to its ending. On a headset the GPU is shared with the compositor and RealityKit's own
    /// drawing, whose work inside that span counts too, and the span stretches when the GPU
    /// runs at a lower clock (a warm device, a lighter load): a number to read with the
    /// thermal state and the engine's own busy time beside it.
    public var gpuMsAverage = 0.0
    public var gpuMsMax = 0.0
    /// The refresh period in force, milliseconds, measured from the update rate: RealityKit
    /// updates once a refresh, so 100 updates/s says 10 ms and 90 updates/s 11.1 ms. Zero
    /// without updates.
    public var refreshMs = 0.0
    /// Frames whose completion exceeded the refreshes planned for them (`plannedRefreshes`
    /// times the refresh period): each lands a refresh later than planned, and RealityKit
    /// shows the previous frame again meanwhile. Zero without updates.
    public var lateFrames = 0
    /// The refreshes the frames of the span were planned to complete within: the pipeline's
    /// depth in force (`XRPresenterSettings.pipelineDepth`), the deepest of the span; 1 without
    /// frames.
    public var plannedRefreshes = 1
    /// The frame with the longest completion in the span, split into its stages; zeros
    /// without a frame.
    public var worstFrame = XRPresenterFrameStages()
    /// The GPU's time on the engine's own passes, milliseconds: the union of the passes'
    /// stage spans, read from the engine's GPU pass timing when it is on
    /// (`setRendering(.gpuPassTiming(.enabled))`); 0 when it is off. The part of the span that
    /// is the frame's own cost, whatever else the GPU ran in between.
    public var engineGPUMsAverage = 0.0
    /// The device's thermal state at the snapshot: under pressure, the GPU runs slower and
    /// every GPU number above grows.
    public var thermalState: ProcessInfo.ThermalState = .nominal
    /// Tickets dropped since the presenter started.
    public var ticketsDroppedTotal = 0

    public var updatesPerSecond: Double { seconds > 0 ? Double(updates) / seconds : 0 }

    public var framesPerSecond: Double { seconds > 0 ? Double(framesDrawn) / seconds : 0 }

    /// The thermal state as a word.
    public var thermalStateName: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// The late count's plan as the lines print it: nothing one refresh deep, the plan beyond.
    public var plannedRefreshesDescription: String {
        plannedRefreshes > 1 ? " (plan \(plannedRefreshes) refreshes)" : ""
    }

    /// One line with the numbers, for a log.
    public var description: String {
        String(
            format: "XR presenter: %.0f updates/s (refresh %.1f ms), %.0f frames/s, %d tickets dropped (%d in all), %d frames without a pose, %d late%@; replace %.2f ms (max %.2f), pickup age %.2f ms (max %.2f), CPU frame %.2f ms (max %.2f), wait %.2f ms (max %.2f), GPU span %.2f ms (max %.2f), to completion %.2f ms (max %.2f), worst %@, engine GPU %.2f ms, lead %.2f ms (max %.2f), thermal %@",
            updatesPerSecond, refreshMs, framesPerSecond, ticketsDropped, ticketsDroppedTotal, posesMissing, lateFrames, plannedRefreshesDescription,
            replaceMsAverage, replaceMsMax, pickupAgeMsAverage, pickupAgeMsMax,
            frameMsAverage, frameMsMax, waitMsAverage, waitMsMax, gpuMsAverage, gpuMsMax,
            completionMsAverage, completionMsMax, worstFrame.splitDescription, engineGPUMsAverage,
            leadMsAverage, leadMsMax, thermalStateName
        )
    }
}

/// Counters written from the main thread (updates, replace calls, drops), the engine's thread
/// (pickups, poses, leads) and the GPU's completion thread (the frames' stages), read as a
/// snapshot.
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

    /// The most completions kept for the late count between two snapshots (eleven minutes at
    /// 100 frames/s): beyond it, frames still enter the averages and maxima but not the count.
    public static let completionsKept = 65536

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var since: TimeInterval
    private var updates = 0
    private var posted = 0
    private var dropped = 0
    private var droppedTotal = 0
    private var frames = 0
    private var posesMissing = 0
    private var replace = Span()
    private var pickupAge = Span()
    private var frame = Span()
    private var wait = Span()
    private var gpu = Span()
    private var completion = Span()
    /// Each frame's completion with the refreshes it was planned within, for the late count.
    private var completions: [(seconds: TimeInterval, refreshes: Int)] = []
    private var plannedRefreshes = 1
    private var worst = XRPresenterFrameStages()
    private var lead = Span()

    /// Counters from now, by the host's clock; a test gives a clock of its own.
    public init(clock: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() }) {
        self.clock = clock
        since = clock()
    }

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

    /// A frame's stages, as its command buffer's completion resolves them: into each stage's
    /// average and maximum, the late count (against the refreshes the frame was planned
    /// within: the pipeline's depth) and the worst frame of the span.
    public func noteFrameCompleted(_ stages: XRPresenterFrameStages, plannedRefreshes: Int = 1) {
        lock.withLock {
            frame.add(stages.cpu)
            wait.add(stages.wait)
            gpu.add(stages.gpu)
            completion.add(stages.completion)
            let refreshes = max(1, plannedRefreshes)
            self.plannedRefreshes = max(self.plannedRefreshes, refreshes)
            if completions.count < Self.completionsKept {
                completions.append((stages.completion, refreshes))
            }
            if stages.completion > worst.completion {
                worst = stages
            }
        }
    }

    public func noteLead(seconds: Double) {
        lock.withLock { lead.add(seconds) }
    }

    /// The numbers since the last snapshot, which starts a new span.
    public func snapshot() -> XRPresenterStatisticsSnapshot {
        lock.withLock {
            let now = clock()
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
            snapshot.waitMsAverage = wait.averageMs
            snapshot.waitMsMax = wait.maxMs
            snapshot.gpuMsAverage = gpu.averageMs
            snapshot.gpuMsMax = gpu.maxMs
            snapshot.completionMsAverage = completion.averageMs
            snapshot.completionMsMax = completion.maxMs
            snapshot.worstFrame = worst
            if updates > 0, snapshot.seconds > 0 {
                let period = snapshot.seconds / Double(updates)
                snapshot.refreshMs = period * 1000
                snapshot.lateFrames = completions.reduce(0) { $0 + ($1.seconds > Double($1.refreshes) * period ? 1 : 0) }
            }
            snapshot.plannedRefreshes = plannedRefreshes
            snapshot.leadMsAverage = lead.averageMs
            snapshot.leadMsMax = lead.maxMs
            snapshot.engineGPUMsAverage = GPUPassTiming.shared.isEnabled ? GPUPassTiming.shared.busy().averageMs : 0
            snapshot.thermalState = ProcessInfo.processInfo.thermalState
            since = now
            updates = 0
            posted = 0
            dropped = 0
            frames = 0
            posesMissing = 0
            replace = Span()
            pickupAge = Span()
            frame = Span()
            wait = Span()
            gpu = Span()
            completion = Span()
            completions.removeAll(keepingCapacity: true)
            plannedRefreshes = 1
            worst = XRPresenterFrameStages()
            lead = Span()
            return snapshot
        }
    }
}
