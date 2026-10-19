//
//  XRPresenterRefresh.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The display's refresh period as RealityKit's update cadence measures it: RealityKit updates
/// once a refresh, so the interval between two updates is the period (10 ms at 100 Hz, 11.1 at
/// 90, 16.7 in the simulator), never assumed. The deeper pipeline poses a frame this much
/// further ahead for each refresh it plans past the first (`XRPresenterLead`); each ticket
/// carries the measure in force when it was posted.
///
/// An exponential average with a weight of one eighth on the latest interval, so a change of
/// display rate (the headset goes from 100 to 90 Hz under 50 Hz lighting) is followed within a
/// few updates. An interval outside `shortest ... longest` is not a refresh (a doubled update,
/// or a stall such as the space opening) and is left out; the next interval is measured from
/// its end.
public struct XRPresenterRefresh: Sendable, Equatable {
    /// The weight of the latest interval in the average.
    public static let latestWeight = 0.125
    /// No display refreshes faster: a shorter interval is a doubled update.
    public static let shortest: TimeInterval = 1.0 / 240
    /// No display refreshes slower: a longer interval is a stall.
    public static let longest: TimeInterval = 1.0 / 20

    /// The period, seconds; 0 until two updates have been noted.
    public private(set) var seconds: TimeInterval = 0
    /// When the last update was noted.
    public private(set) var lastUpdate: TimeInterval?

    public init() {}

    /// An update at `now` (`CACurrentMediaTime()`).
    public mutating func noteUpdate(at now: TimeInterval) {
        defer { lastUpdate = now }
        guard let last = lastUpdate else { return }
        let interval = now - last
        guard interval >= Self.shortest, interval <= Self.longest else { return }
        seconds = seconds == 0 ? interval : seconds + (interval - seconds) * Self.latestWeight
    }
}
