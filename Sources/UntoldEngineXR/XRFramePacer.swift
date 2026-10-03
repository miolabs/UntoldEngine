//
//  XRFramePacer.swift
//  UntoldEngineXR
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os

/// Starts the Compositor Services submission phase ahead of `optimalInputTime` when the GPU has
/// been finishing frames after the rendering deadline.
///
/// The compositor leaves about one display period between `optimalInputTime` and
/// `renderingDeadline`, and the CPU encode and the GPU execution of a frame have to fit in that
/// window back to back. When they do not, the compositor shows an older frame reprojected to the
/// new head pose, which reads as shaking near the viewer even at a steady 90 Hz. Starting the
/// submission phase earlier trades a few milliseconds of pose age for a frame that lands before
/// its deadline: the device anchor is predicted for the presentation time regardless of when it
/// is queried, and the compositor corrects the remaining difference.
///
/// The pacer is a small controller. Every GPU completion reports its deadline margin; when the
/// margin is below `targetMarginMs` the early start grows quickly, and when there is surplus it
/// shrinks slowly. It stops growing once the update phase is the limit (the frame cannot start
/// before its own update ends), so it does not wind up while the frame is CPU-bound.
///
/// Set the `UNTOLD_XR_PACER` environment variable to `0` to disable it for an A/B run.
public final class XRFramePacer: @unchecked Sendable {
    public static let shared = XRFramePacer()

    private struct State {
        var isEnabled: Bool
        var targetMarginMs: Double = 1.5
        var maxEarlyStartMs: Double = 8.0
        var earlyStartMs: Double = 0.0
        /// The early start the last frame actually got. Smaller than `earlyStartMs` when the update
        /// phase ended after the requested start time.
        var achievedEarlyStartMs: Double = 0.0
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Fraction of the shortfall added to the early start per late frame.
    private let attackGain = 0.3
    /// Fraction of the surplus removed from the early start per early frame.
    private let releaseGain = 0.05
    /// Slack below which the last frame counts as having started as early as requested.
    private let saturationToleranceMs = 0.25

    private init() {
        let raw = ProcessInfo.processInfo.environment["UNTOLD_XR_PACER"]?.lowercased()
        let enabled = raw.map { $0 != "0" && $0 != "false" && $0 != "off" } ?? true
        state = OSAllocatedUnfairLock(initialState: State(isEnabled: enabled))
    }

    /// Whether the pacer moves the submission start. Off, the loop waits for `optimalInputTime` exactly.
    public var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set {
            state.withLock { current in
                current.isEnabled = newValue
                if !newValue {
                    current.earlyStartMs = 0.0
                    current.achievedEarlyStartMs = 0.0
                }
            }
        }
    }

    /// Deadline margin the pacer aims for, in milliseconds. Larger absorbs more GPU noise at the
    /// cost of pose age.
    public var targetMarginMs: Double {
        get { state.withLock { $0.targetMarginMs } }
        set { state.withLock { $0.targetMarginMs = max(0.0, newValue) } }
    }

    /// Upper bound on how far ahead of `optimalInputTime` a submission phase may start, in milliseconds.
    public var maxEarlyStartMs: Double {
        get { state.withLock { $0.maxEarlyStartMs } }
        set { state.withLock { $0.maxEarlyStartMs = max(0.0, newValue) } }
    }

    /// How far ahead of `optimalInputTime` the next submission phase starts, in milliseconds.
    public var earlyStartMs: Double {
        state.withLock { $0.isEnabled ? $0.earlyStartMs : 0.0 }
    }

    /// Records how far ahead of `optimalInputTime` the frame really resumed. Negative when the
    /// update phase ran past the requested start time.
    func noteAchievedEarlyStart(_ milliseconds: Double) {
        state.withLock { $0.achievedEarlyStartMs = milliseconds }
    }

    /// Feeds one GPU completion into the controller. `marginMs` is the time between the GPU
    /// finishing the frame and the compositor's rendering deadline; negative means a miss.
    func recordDeadlineMargin(_ marginMs: Double) {
        state.withLock { current in
            guard current.isEnabled else { return }
            let shortfall = current.targetMarginMs - marginMs
            if shortfall > 0.0 {
                // The update phase is the limit when the last frame could not start as early as
                // asked; pushing the request further would not move the GPU start.
                guard current.achievedEarlyStartMs >= current.earlyStartMs - saturationToleranceMs else { return }
                current.earlyStartMs = min(current.maxEarlyStartMs, current.earlyStartMs + attackGain * shortfall)
            } else {
                current.earlyStartMs = max(0.0, current.earlyStartMs + releaseGain * shortfall)
            }
        }
    }
}
