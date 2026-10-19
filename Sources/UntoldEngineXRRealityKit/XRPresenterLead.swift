//
//  XRPresenterLead.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A frame's lead: the seconds from its ticket's posting to the instant the frame is expected
/// on the display, which its pose is predicted for. RealityKit gives no presentation time, so
/// the lead is an estimate, in one of two ways the ticket's settings choose:
///
/// - fixed: the ticket's age at pickup plus `leadSeconds`, so the frame is posed `leadSeconds`
///   past the moment its ticket was taken;
/// - adaptive: the ticket's age at pickup, plus the engine's frame averaged over the last
///   frames (from the pickup to the ticket's command buffer completing on the GPU: the CPU
///   frame, the GPU's, and whatever waited in between), plus `displayLatencySeconds` for what
///   follows the completion (RealityKit noticing the replace, its frame, the compositor's),
///   which only the headset can calibrate. Until a frame has completed there is no average
///   and the fixed lead stands in.
///
/// The average is exponential with a weight of one eighth on the latest frame (about the last
/// eight frames, 90 ms at 90 Hz), with no margin of its own: the display latency constant
/// absorbs one, so that the fixed and the adaptive lead agree at the numbers the constant was
/// chosen from. A frame's time is clamped to `maximumSeconds` before it enters the average, so
/// a stall is forgotten in a few frames, and the adaptive lead is clamped to the same range.
public struct XRPresenterLead: Sendable, Equatable {
    /// The most a frame may be posed ahead of its ticket with the adaptive lead, and the most
    /// a frame's time counts for in the average: nine refreshes at 90 Hz.
    public static let maximumSeconds: TimeInterval = 0.1
    /// The weight of the latest frame in the average.
    public static let latestFrameWeight = 0.125

    /// The frames' time from pickup to completion, averaged; nil before the first frame.
    public private(set) var frameSecondsAverage: TimeInterval?
    /// How many frames the average has seen.
    public private(set) var framesNoted = 0

    public init() {}

    /// A frame's time from its ticket's pickup to its command buffer completing on the GPU.
    public mutating func noteFrame(seconds: TimeInterval) {
        let seconds = min(max(0, seconds), Self.maximumSeconds)
        if let average = frameSecondsAverage {
            frameSecondsAverage = average + (seconds - average) * Self.latestFrameWeight
        } else {
            frameSecondsAverage = seconds
        }
        framesNoted += 1
    }

    /// Forgets the frames seen: the fixed lead stands in again until the next frame completes.
    public mutating func reset() {
        frameSecondsAverage = nil
        framesNoted = 0
    }

    /// The lead for a ticket taken `ageSeconds` after its posting, under `settings`.
    public func seconds(settings: XRPresenterSettings, ageSeconds: TimeInterval) -> TimeInterval {
        Self.seconds(settings: settings, ageSeconds: ageSeconds, frameSecondsAverage: frameSecondsAverage)
    }

    /// The lead for a ticket taken `ageSeconds` after its posting, under `settings`, with the
    /// frames' average time at hand (nil before any frame): the fixed lead unless the settings
    /// ask for the adaptive one and the average exists.
    public static func seconds(settings: XRPresenterSettings, ageSeconds: TimeInterval, frameSecondsAverage: TimeInterval?) -> TimeInterval {
        let age = max(0, ageSeconds)
        guard settings.adaptiveLead, let frame = frameSecondsAverage else {
            return age + settings.leadSeconds
        }
        return min(max(0, age + frame + settings.displayLatencySeconds), maximumSeconds)
    }
}
