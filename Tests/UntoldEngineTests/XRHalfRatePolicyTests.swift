//
//  XRHalfRatePolicyTests.swift
//  UntoldEngineTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import UntoldEngine
import XCTest

/// The half-rate pacing enters after two seconds of mostly late frames with no wait left to
/// skip, spaces the frames by the refreshes their GPU work with its encode needs, and leaves
/// after two seconds in which the frames' GPU work fitted most of a refresh.
final class XRHalfRatePolicyTests: XCTestCase {
    private let period = 10.0

    private func lateSecond(_ policy: inout XRHalfRatePolicy, waitStillToSkip: Bool = false, maxGPU: Double = 12.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, late: 80, meanOverrunMs: 3.0, maxGPUDurationMs: maxGPU, periodMs: period, waitStillToSkip: waitStillToSkip)
    }

    private func goodSecond(_ policy: inout XRHalfRatePolicy, maxGPU: Double = 7.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, late: 2, meanOverrunMs: 0.2, maxGPUDurationMs: maxGPU, periodMs: period, waitStillToSkip: false)
    }

    func testEntersAfterTwoLateSecondsNotOne() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(lateSecond(&policy), .none)
        XCTAssertFalse(policy.active)
        XCTAssertEqual(lateSecond(&policy), .entered)
        XCTAssertTrue(policy.active)
    }

    func testAGoodSecondBetweenTwoLateOnesStartsTheCountAgain() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(lateSecond(&policy), .none)
        XCTAssertEqual(goodSecond(&policy), .none)
        XCTAssertEqual(lateSecond(&policy), .none)
        XCTAssertFalse(policy.active)
    }

    func testDoesNotEnterWhileAWaitCouldStillBeSkipped() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(lateSecond(&policy, waitStillToSkip: true), .none)
        XCTAssertEqual(lateSecond(&policy, waitStillToSkip: true), .none)
        XCTAssertFalse(policy.active)
    }

    func testDoesNotEnterForSlightlyLateFrames() {
        var policy = XRHalfRatePolicy()
        for _ in 0 ..< 3 {
            XCTAssertEqual(policy.secondEnded(frames: 100, late: 60, meanOverrunMs: 0.4, maxGPUDurationMs: 10.2, periodMs: period, waitStillToSkip: false), .none)
        }
        XCTAssertFalse(policy.active)
    }

    func testWhileActiveTheCadenceFollowsTheGPUCostWithItsEncode() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // 12 ms of GPU work and 3 ms of encode fit two refreshes of 10 ms.
        XCTAssertEqual(policy.secondEnded(frames: 50, late: 50, meanOverrunMs: 8.0, maxGPUDurationMs: 12.0, periodMs: period, waitStillToSkip: false), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // 18 ms and 3 ms need three.
        XCTAssertEqual(policy.secondEnded(frames: 33, late: 33, meanOverrunMs: 8.0, maxGPUDurationMs: 18.0, periodMs: period, waitStillToSkip: false), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        // Never more than four.
        XCTAssertEqual(policy.secondEnded(frames: 20, late: 20, meanOverrunMs: 8.0, maxGPUDurationMs: 60.0, periodMs: period, waitStillToSkip: false), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 4)
        // Never fewer than two while active.
        XCTAssertEqual(policy.secondEnded(frames: 50, late: 50, meanOverrunMs: 8.0, maxGPUDurationMs: 9.0, periodMs: period, waitStillToSkip: false), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        XCTAssertTrue(policy.active)
    }

    func testLeavesAfterTwoSecondsThatFitMostOfARefresh() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 7.9), .none)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 7.9), .left)
        XCTAssertFalse(policy.active)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
    }

    func testAHeavySecondWhileActiveStartsTheFitCountAgain() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 7.0), .none)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 9.0), .none)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 7.0), .none)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(goodSecond(&policy, maxGPU: 7.0), .left)
    }

    func testAnEmptySecondChangesNothingAndResetForgetsEverything() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(policy.secondEnded(frames: 0, late: 0, meanOverrunMs: 0, maxGPUDurationMs: 0, periodMs: period, waitStillToSkip: false), .none)
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        policy.reset()
        XCTAssertEqual(policy, XRHalfRatePolicy())
    }
}
