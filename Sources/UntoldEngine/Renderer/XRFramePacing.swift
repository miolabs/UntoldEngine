//
//  XRFramePacing.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How the XR loop paces its frames against the display's refreshes. A frame whose GPU work
/// does not fit one refresh is shown a refresh late, sometimes, which hops; rendered every
/// other refresh it is shown two refreshes apart, evenly, posed for that instant, with the
/// compositor reprojecting the head in between. See `RenderingProperty.framePacing`.
public enum XRFramePacing: Sendable, Equatable {
    /// Every refresh, whatever the frames' cost.
    case fullRate
    /// Every refresh while the frames meet the deadline; every other one while they do not.
    case halfRateWhenLate
    /// Every other refresh, always.
    case halfRate
}

/// The half-rate decision from each second's deadline measurements. Enter when, with no wait
/// for the optimal input time left to skip, the display skipped a refresh for one frame in
/// ten or more, or one frame in ten or more missed its presentation (finishing past the
/// compositor's deadline by more than the deadline's margin before the presentation, less a
/// safety), for two seconds running: fewer hops than that are fewer than the steps the half
/// rate would add. Leave when the rendered frames' mean GPU work has fitted 80% of the
/// refresh for two seconds running. While active, the refreshes
/// between two frames follow the measured GPU cost: two, or more when a frame's typical work
/// (the mean span plus a fifth) with its encode does not fit two. The mean, not the longest
/// span: a GPU used on half the refreshes runs at a lower clock, and its longest spans would
/// never earn back the shorter cadence that would raise the clock again.
public struct XRHalfRatePolicy: Equatable, Sendable {
    /// Whether the frames are being paced to every other refresh (or more).
    public private(set) var active = false
    /// Refreshes between two frames while active: the fewest the frame's typical GPU work
    /// with its encode fits, two at least, four at most.
    public private(set) var cadenceRefreshes = 2
    /// Refreshes after the compositor's predicted presentation at which the paced frames are
    /// shown, from how far past their deadline they finish beyond the deadline's margin before
    /// the presentation: the pose aims there.
    public private(set) var landingRefreshes = 0
    private(set) var lateSeconds = 0
    private(set) var fitSeconds = 0
    /// Seconds running in which a shorter cadence than the current one would have done.
    private(set) var shorterSeconds = 0

    public init() {}

    /// What a second's measurements changed.
    public enum Change: Equatable, Sendable {
        case none
        case entered
        case left
    }

    /// The share of a refresh the rendered frames' GPU work must fit for the pacing to end.
    public static let fitShare = 0.8
    /// The CPU encode allowed for between the frame's query and its GPU work, in milliseconds,
    /// when the cadence is chosen.
    public static let encodeAllowanceMs = 3.0
    /// The share above the mean GPU span the cadence allows for the longer frames.
    public static let spanMargin = 0.2
    public static let mostRefreshes = 4
    /// How far past a cadence's boundary the typical frame must be for the cadence to change,
    /// in milliseconds: a frame on the boundary would otherwise change it every few seconds.
    public static let cadenceDeadbandMs = 1.0
    /// The part of the deadline's margin before the presentation not counted on, in
    /// milliseconds: a frame past the deadline by less than the margin less this is taken as
    /// shown on time.
    public static let marginSafetyMs = 2.0

    /// How far past the deadline a frame may finish and still be taken as shown on time.
    public static func usableMarginMs(deadlineMarginMs: Double) -> Double {
        max(0, deadlineMarginMs - marginSafetyMs)
    }

    /// A second of frames ended: `frames` rendered, `missed` of them past the deadline by more
    /// than its usable margin, `skipped` refreshes the display showed no new frame at beyond
    /// the cadence, the frames past the deadline by `meanOverrunMs` on average, their GPU
    /// spans `meanGPUDurationMs` on average, the display's refresh `periodMs`, the deadline
    /// `deadlineMarginMs` before the presentation, and whether the loop still has a wait it
    /// could skip first.
    public mutating func secondEnded(frames: Int, missed: Int, skipped: Int, meanOverrunMs: Double, meanGPUDurationMs: Double, periodMs: Double, deadlineMarginMs: Double, waitStillToSkip: Bool) -> Change {
        guard frames > 0 else { return .none }
        let hopping = skipped * 10 >= frames || missed * 10 >= frames
        if !active {
            cadenceRefreshes = 2
            landingRefreshes = 0
            if !waitStillToSkip, hopping {
                lateSeconds += 1
            } else {
                lateSeconds = 0
            }
            if lateSeconds >= 2 {
                active = true
                lateSeconds = 0
                return .entered
            }
            return .none
        }
        if periodMs > 0 {
            // Where the frames land: a frame finished past its deadline by more than the
            // deadline's usable margin is shown at the next refresh the rest reaches; one
            // within the margin makes its predicted one.
            let beyond = meanOverrunMs - Self.usableMarginMs(deadlineMarginMs: deadlineMarginMs)
            landingRefreshes = beyond > 0 ? min(Self.mostRefreshes - 1, Int((beyond / periodMs).rounded(.up))) : 0
            // The cadence rises at once when the frame's work needs more refreshes, and falls
            // only after two seconds running that fit the shorter one: a cadence that changed
            // every second would itself be a hop. Both ways with a deadband past the boundary.
            let typical = meanGPUDurationMs * (1 + Self.spanMargin) + Self.encodeAllowanceMs
            let current = Double(cadenceRefreshes) * periodMs
            if typical > current + Self.cadenceDeadbandMs {
                cadenceRefreshes = min(Self.mostRefreshes, Int(((typical - Self.cadenceDeadbandMs) / periodMs).rounded(.up)))
                shorterSeconds = 0
            } else if cadenceRefreshes > 2, typical < current - periodMs - Self.cadenceDeadbandMs {
                shorterSeconds += 1
                if shorterSeconds >= 2 {
                    cadenceRefreshes = max(2, Int(((typical + Self.cadenceDeadbandMs) / periodMs).rounded(.up)))
                    shorterSeconds = 0
                }
            } else {
                shorterSeconds = 0
            }
        }
        if periodMs > 0, meanGPUDurationMs < Self.fitShare * periodMs {
            fitSeconds += 1
        } else {
            fitSeconds = 0
        }
        if fitSeconds >= 2 {
            active = false
            fitSeconds = 0
            shorterSeconds = 0
            cadenceRefreshes = 2
            landingRefreshes = 0
            return .left
        }
        return .none
    }

    public mutating func reset() {
        self = XRHalfRatePolicy()
    }
}
