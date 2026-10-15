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
/// for the optimal input time left to skip, half the frames or more were late by over a
/// millisecond on average for two seconds running; leave when the rendered frames' GPU work
/// has fitted 80% of the refresh for two seconds running.
public struct XRHalfRatePolicy: Equatable, Sendable {
    /// Whether the frames are being paced to every other refresh.
    public private(set) var active = false
    /// Whether the last second's rendered frames mostly landed a refresh late: the pose then
    /// aims one refresh later, where the display shows them.
    public private(set) var framesLandLate = false
    private(set) var lateSeconds = 0
    private(set) var fitSeconds = 0

    public init() {}

    /// What a second's measurements changed.
    public enum Change: Equatable, Sendable {
        case none
        case entered
        case left
    }

    /// The share of a refresh the rendered frames' GPU work must fit for the pacing to end.
    public static let fitShare = 0.8

    /// A second of frames ended: `frames` rendered, `late` of them past the deadline by
    /// `meanOverrunMs` on average, the longest GPU span among them `maxGPUDurationMs`, the
    /// display's refresh `periodMs`, and whether the loop still has a wait it could skip first.
    public mutating func secondEnded(frames: Int, late: Int, meanOverrunMs: Double, maxGPUDurationMs: Double, periodMs: Double, waitStillToSkip: Bool) -> Change {
        guard frames > 0 else { return .none }
        let mostlyLate = late * 2 >= frames
        if !active {
            framesLandLate = false
            if !waitStillToSkip, mostlyLate, meanOverrunMs > 1.0 {
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
        framesLandLate = mostlyLate
        if periodMs > 0, maxGPUDurationMs < Self.fitShare * periodMs {
            fitSeconds += 1
        } else {
            fitSeconds = 0
        }
        if fitSeconds >= 2 {
            active = false
            fitSeconds = 0
            framesLandLate = false
            return .left
        }
        return .none
    }

    public mutating func reset() {
        self = XRHalfRatePolicy()
    }
}
