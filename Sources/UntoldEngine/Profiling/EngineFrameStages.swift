//
//  EngineFrameStages.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One frame's time from the loop beginning it to its command buffer completing on the GPU,
/// split into the stages it went through, in seconds: the CPU frame (from the frame's
/// beginning to the loop committing the command buffer, less any pacing the presenter asked
/// for in between), the wait (from the commit to the GPU starting on the buffer: the driver's
/// submission and the GPU's queue, where the compositor's own work goes first on a headset),
/// and the GPU span (from the GPU starting to its ending: the buffer's raw span, other
/// processes' work inside it included). The three sum to the completion, so a frame that
/// landed a refresh late can be read for where it spent its time. The same split the
/// RealityKit presenter's numbers line makes of its frames (`XRPresenterFrameStages`), here
/// for whatever presents the loop's frames.
public struct EngineFrameStages: Sendable, Equatable {
    public var cpu: TimeInterval = 0
    public var wait: TimeInterval = 0
    public var gpu: TimeInterval = 0
    /// Seconds the loop slept inside the frame for the presenter's drawing time (Compositor
    /// Services' optimal input time): the frame's pacing, not its work, so it is outside the
    /// CPU frame and the completion. Zero for a presenter that paces nothing.
    public var pacing: TimeInterval = 0

    public init(cpu: TimeInterval = 0, wait: TimeInterval = 0, gpu: TimeInterval = 0, pacing: TimeInterval = 0) {
        self.cpu = cpu
        self.wait = wait
        self.gpu = gpu
        self.pacing = pacing
    }

    /// From the frame's beginning, the pacing left out, to the GPU's completion: the stages'
    /// sum.
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

    public var pacingMs: Double {
        pacing * 1000
    }

    public var completionMs: Double {
        completion * 1000
    }

    /// The stages of a frame from its instants, all in the host's time base
    /// (`CACurrentMediaTime`): the loop's beginning of the frame, the seconds it then slept for
    /// the presenter's drawing time, the loop's commit, and the command buffer's GPU start and
    /// end as its completed handler reads them, with `now` the handler's own time. A GPU that
    /// reports no times (zeros, or an end before the beginning) gives a span of zero and a
    /// completion at the handler's time; the wait absorbs whatever the GPU's times leave, so
    /// the stages always sum to the completion.
    public init(begin: TimeInterval, pacing: TimeInterval = 0, committed: TimeInterval, gpuStart: TimeInterval, gpuEnd: TimeInterval, now: TimeInterval) {
        let pacing = max(0, pacing)
        let start = begin + pacing
        let cpu = max(0, committed - start)
        let reported = gpuEnd > start && gpuStart > 0
        let end = reported ? gpuEnd : now
        let completion = max(cpu, end - start)
        let gpu = reported ? min(max(0, gpuEnd - gpuStart), completion - cpu) : 0
        self.init(cpu: cpu, wait: max(0, completion - cpu - gpu), gpu: gpu, pacing: pacing)
    }

    /// The split as the stats print it, milliseconds: "16.6 = cpu 3.1 + wait 9.2 + gpu 4.3".
    public var splitDescription: String {
        String(format: "%.1f = cpu %.1f + wait %.1f + gpu %.1f", completionMs, cpuMs, waitMs, gpuMs)
    }
}

/// The frames' stages over a span of the loop's frames (a second by default): the maximum of
/// each stage, the frames that overran the refresh period measured from the frames' cadence,
/// and the worst frame's split. The numbers the RealityKit presenter's line prints per
/// second, kept here for the loop's frames whoever presents them, so that the two paths are
/// read against each other.
public struct EngineFrameStageStats: Sendable, Equatable {
    /// Seconds the span covers, by the loop's frame timestamps.
    public var seconds: Double = 0
    /// Frames the loop began in the span: its cadence, which on a headset is the display's
    /// (the compositor hands out one frame a refresh while the loop keeps up).
    public var framesBegun = 0
    /// Frames whose command buffer completed in the span.
    public var framesCompleted = 0
    /// The refresh period in force, milliseconds, measured from the frames' cadence: 100
    /// frames begun in a second say 10 ms, 90 say 11.1 ms. Zero without frames. A second in
    /// which the compositor handed out fewer frames than refreshes (the loop behind it) reads
    /// a longer period and under-counts the late frames.
    public var refreshMs = 0.0
    /// Frames whose completion exceeded the refresh period: each landed a refresh late.
    public var lateFrames = 0
    /// Frames whose GPU work ended after the presenter's rendering deadline, where the
    /// presenter sets one (Compositor Services does): the presenter's own verdict on the
    /// frame being late, beside the one against the refresh period.
    public var pastDeadline = 0
    /// Each stage's maximum over the span, milliseconds; the frames behind them may differ.
    public var cpuMsMax = 0.0
    public var waitMsMax = 0.0
    public var gpuMsMax = 0.0
    public var completionMsMax = 0.0
    /// The frame with the longest completion in the span, split into its stages; zeros
    /// without a frame.
    public var worstFrame = EngineFrameStages()

    public init() {}

    /// The frames completed per second of the span.
    public var framesPerSecond: Double {
        seconds > 0 ? Double(framesCompleted) / seconds : 0
    }

    /// The numbers as a person reads them on a headset: "gpu span max 20.0 ms · late 3 of 100
    /// (refresh 10.0 ms) · worst 24.8 = cpu 4.0 + wait 0.1 + gpu 20.0". A deadline count
    /// follows when a frame overran the presenter's deadline.
    public var description: String {
        var line = String(
            format: "gpu span max %.1f ms · late %d of %d (refresh %.1f ms) · worst %@",
            gpuMsMax, lateFrames, framesCompleted, refreshMs, worstFrame.splitDescription
        )
        if pastDeadline > 0 {
            line += " · \(pastDeadline) past the deadline"
        }
        return line
    }
}
