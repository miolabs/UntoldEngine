//
//  XRPresenterLeadTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UntoldEngineXRRealityKit
import XCTest

/// The frame's lead from synthetic ages and frame times: the fixed lead as it was, the
/// measured one from the average frame and the display latency, the fallback before any
/// frame completed, the clamps.
final class XRPresenterLeadTests: XCTestCase {
    private func settings(adaptive: Bool, lead: TimeInterval = 2.0 / 90.0, displayLatency: TimeInterval = 0.016) -> XRPresenterSettings {
        var settings = XRPresenterSettings()
        settings.adaptiveLead = adaptive
        settings.leadSeconds = lead
        settings.displayLatencySeconds = displayLatency
        return settings
    }

    func test_theSettings_startFromTheConfiguration_withTheAdaptiveLeadOff() {
        let configuration = XRRealityKitPresenterConfiguration()
        XCTAssertFalse(configuration.adaptiveLead, "nothing changes until the headset confirms")
        XCTAssertEqual(configuration.displayLatencySeconds, 0.016)
        XCTAssertEqual(configuration.leadSeconds, 2.0 / 90.0, accuracy: 1e-12)
        var changed = configuration
        changed.adaptiveLead = true
        changed.displayLatencySeconds = 0.011
        let settings = XRPresenterSettings(configuration: changed)
        XCTAssertTrue(settings.adaptiveLead)
        XCTAssertEqual(settings.displayLatencySeconds, 0.011)
        XCTAssertEqual(settings.leadSeconds, 2.0 / 90.0, accuracy: 1e-12)
    }

    func test_theFixedLead_isTheAgePlusLeadSeconds_whateverTheHistory() {
        var lead = XRPresenterLead()
        XCTAssertNil(lead.frameSecondsAverage)
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: false, lead: 0.02), ageSeconds: 0.001), 0.021, accuracy: 1e-12)
        lead.noteFrame(seconds: 0.05)
        lead.noteFrame(seconds: 0.05)
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: false, lead: 0.02), ageSeconds: 0.001), 0.021, accuracy: 1e-12, "the frames seen do not bear on the fixed lead")
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: false, lead: 0.3), ageSeconds: 0), 0.3, accuracy: 1e-12, "the fixed lead is not clamped: what was set is what the frame gets")
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: false, lead: 0.02), ageSeconds: -0.001), 0.02, accuracy: 1e-12, "a clock oddity never shortens it")
    }

    func test_theAdaptiveLead_fallsBackOnTheFixedOne_untilAFrameCompletes() {
        var lead = XRPresenterLead()
        let adaptive = settings(adaptive: true, lead: 0.02, displayLatency: 0.016)
        XCTAssertEqual(lead.seconds(settings: adaptive, ageSeconds: 0.0005), 0.0205, accuracy: 1e-12, "no frame has completed: the fixed lead")
        XCTAssertEqual(lead.framesNoted, 0)
        lead.noteFrame(seconds: 0.006)
        XCTAssertEqual(lead.framesNoted, 1)
        XCTAssertEqual(lead.seconds(settings: adaptive, ageSeconds: 0.0005), 0.0005 + 0.006 + 0.016, accuracy: 1e-12, "the first frame is the average")
        lead.reset()
        XCTAssertNil(lead.frameSecondsAverage)
        XCTAssertEqual(lead.framesNoted, 0)
        XCTAssertEqual(lead.seconds(settings: adaptive, ageSeconds: 0.0005), 0.0205, accuracy: 1e-12, "forgotten: the fixed lead again")
    }

    func test_theAdaptiveLead_isTheAgePlusTheAverageFramePlusTheDisplayLatency() {
        var lead = XRPresenterLead()
        let adaptive = settings(adaptive: true, lead: 0.02, displayLatency: 0.016)
        lead.noteFrame(seconds: 0.006)
        lead.noteFrame(seconds: 0.008)
        // An exponential average, an eighth on the latest frame: 6 + (8 - 6) / 8 ms.
        XCTAssertEqual(try XCTUnwrap(lead.frameSecondsAverage), 0.00625, accuracy: 1e-12)
        XCTAssertEqual(lead.seconds(settings: adaptive, ageSeconds: 0.0003), 0.0003 + 0.00625 + 0.016, accuracy: 1e-12)
        // Steady frames settle the average on them.
        for _ in 0 ..< 80 {
            lead.noteFrame(seconds: 0.008)
        }
        XCTAssertEqual(try XCTUnwrap(lead.frameSecondsAverage), 0.008, accuracy: 1e-6)
        XCTAssertEqual(lead.seconds(settings: adaptive, ageSeconds: 0), 0.024, accuracy: 1e-6)
        // The same from the pure function, for a caller with its own average.
        XCTAssertEqual(XRPresenterLead.seconds(settings: adaptive, ageSeconds: 0.001, frameSecondsAverage: 0.005), 0.022, accuracy: 1e-12)
        XCTAssertEqual(XRPresenterLead.seconds(settings: adaptive, ageSeconds: 0.001, frameSecondsAverage: nil), 0.021, accuracy: 1e-12)
    }

    func test_aStall_entersTheAverageClamped_andIsForgottenInAFewFrames() {
        var lead = XRPresenterLead()
        for _ in 0 ..< 40 {
            lead.noteFrame(seconds: 0.006)
        }
        lead.noteFrame(seconds: 1.0)
        // Clamped to the maximum before it enters: 6 + (100 - 6) / 8 ms, not 6 + (1000 - 6) / 8.
        XCTAssertEqual(try XCTUnwrap(lead.frameSecondsAverage), 0.01775, accuracy: 1e-9)
        for _ in 0 ..< 24 {
            lead.noteFrame(seconds: 0.006)
        }
        XCTAssertEqual(try XCTUnwrap(lead.frameSecondsAverage), 0.006, accuracy: 0.0005, "within half a millisecond after two dozen frames")
        lead.noteFrame(seconds: -0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(lead.frameSecondsAverage), 0, "a negative time counts as zero")
    }

    func test_theAdaptiveLead_isClampedToItsRange() {
        var lead = XRPresenterLead()
        lead.noteFrame(seconds: 0.006)
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: true, displayLatency: 0.5), ageSeconds: 0), XRPresenterLead.maximumSeconds, accuracy: 1e-12, "no further ahead than the maximum")
        XCTAssertEqual(lead.seconds(settings: settings(adaptive: true, displayLatency: -0.5), ageSeconds: 0), 0, accuracy: 1e-12, "never behind the posting")
        XCTAssertEqual(XRPresenterLead.maximumSeconds, 0.1)
    }

    func test_theDefaultDisplayLatency_makesTheTwoLeadsAgree_atTheHeadsetsNumbers() {
        // The Release reading of 2026-10-19 on the headset: the ticket's age at pickup 0.03 ms,
        // the engine's CPU frame 2.8 ms and its GPU 3.6 ms, so a frame completes about 6.4 ms
        // after its pickup; the fixed lead is two refreshes at 90 Hz.
        var lead = XRPresenterLead()
        for _ in 0 ..< 16 {
            lead.noteFrame(seconds: 0.0064)
        }
        let fixed = lead.seconds(settings: settings(adaptive: false), ageSeconds: 0.00003)
        let adaptive = lead.seconds(settings: settings(adaptive: true), ageSeconds: 0.00003)
        XCTAssertEqual(fixed, 0.00003 + 2.0 / 90.0, accuracy: 1e-12)
        XCTAssertEqual(adaptive, fixed, accuracy: 0.0003, "within a third of a millisecond: \(adaptive * 1000) against \(fixed * 1000) ms")
    }
}
