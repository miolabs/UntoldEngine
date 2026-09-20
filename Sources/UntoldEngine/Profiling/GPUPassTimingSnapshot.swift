//
//  GPUPassTimingSnapshot.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The per-pass GPU times of the last frame `GPUPassTiming` resolved, as the engine stats
/// carry them: a copy taken when the frame's stats are published.
public struct GPUPassTimingSnapshot: Codable, Equatable, Sendable {
    /// A number that changes with each resolved frame; zero before the first.
    public var frameIndex: Int = 0
    /// The frame's passes, heaviest first. Empty when the timer is off.
    public var passes: [GPUPassTiming.PassTime] = []
    /// Sum of the passes' times. Passes can overlap on the GPU, so this is an upper bound on
    /// the frame's GPU time.
    public var totalMs: Double = 0.0

    public init(frameIndex: Int = 0, passes: [GPUPassTiming.PassTime] = []) {
        self.frameIndex = frameIndex
        self.passes = passes
        totalMs = passes.reduce(0) { $0 + $1.totalMs }
    }

    /// The time of the pass with this label, or nil when the frame had none.
    public func ms(for label: String) -> Double? {
        passes.first { $0.label == label }?.totalMs
    }

    /// The timer's last resolved frame.
    public static func current() -> GPUPassTimingSnapshot {
        let frame = GPUPassTiming.shared.lastFrame()
        return GPUPassTimingSnapshot(frameIndex: frame.index, passes: frame.passes)
    }
}
