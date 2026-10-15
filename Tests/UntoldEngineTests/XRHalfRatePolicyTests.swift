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

    private func lateSecond(_ policy: inout XRHalfRatePolicy, waitStillToSkip: Bool = false, meanGPU: Double = 12.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, late: 80, meanOverrunMs: 3.0, meanGPUDurationMs: meanGPU, periodMs: period, waitStillToSkip: waitStillToSkip)
    }

    private func goodSecond(_ policy: inout XRHalfRatePolicy, meanGPU: Double = 7.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, late: 2, meanOverrunMs: 0.2, meanGPUDurationMs: meanGPU, periodMs: period, waitStillToSkip: false)
    }

    private func pacedSecond(_ policy: inout XRHalfRatePolicy, overrun: Double, meanGPU: Double) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 40, late: 40, meanOverrunMs: overrun, meanGPUDurationMs: meanGPU, periodMs: period, waitStillToSkip: false)
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
            XCTAssertEqual(policy.secondEnded(frames: 100, late: 60, meanOverrunMs: 0.4, meanGPUDurationMs: 10.2, periodMs: period, waitStillToSkip: false), .none)
        }
        XCTAssertFalse(policy.active)
    }

    func testWhileActiveTheCadenceFollowsTheTypicalGPUCostWithItsEncode() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // A mean of 14 ms, a fifth more and 3 ms of encode: 19.8 ms, two refreshes of 10 ms.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // A mean of 16 ms: 22.2 ms, three.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 16.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        // Never more than four.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 60.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 4)
        // A shorter cadence is taken only after two seconds running that fit it.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 9.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 4)
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 9.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // A longer one at once, and a single fitting second between two needing it does not shorten it.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 16.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 12.0), .none)
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 16.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        XCTAssertTrue(policy.active)
    }

    func testThePoseAimsAtTheRefreshTheOverrunReaches() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(policy.landingRefreshes, 0)
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        // Finished 9 ms past the deadline: shown one refresh after the prediction.
        XCTAssertEqual(pacedSecond(&policy, overrun: 9.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 1)
        // 15 ms past: two.
        XCTAssertEqual(pacedSecond(&policy, overrun: 15.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 2)
        // Within a millisecond: the predicted one.
        XCTAssertEqual(pacedSecond(&policy, overrun: 0.5, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 0)
        // Never beyond three.
        XCTAssertEqual(pacedSecond(&policy, overrun: 80.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 3)
        XCTAssertEqual(goodSecond(&policy), .none)
        XCTAssertEqual(goodSecond(&policy), .left)
        XCTAssertEqual(policy.landingRefreshes, 0)
    }

    func testLeavesAfterTwoSecondsThatFitMostOfARefresh() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 7.9), .none)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 7.9), .left)
        XCTAssertFalse(policy.active)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
    }

    func testAHeavySecondWhileActiveStartsTheFitCountAgain() {
        var policy = XRHalfRatePolicy()
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 7.0), .none)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 9.0), .none)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 7.0), .none)
        XCTAssertTrue(policy.active)
        XCTAssertEqual(goodSecond(&policy, meanGPU: 7.0), .left)
    }

    func testAnEmptySecondChangesNothingAndResetForgetsEverything() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(policy.secondEnded(frames: 0, late: 0, meanOverrunMs: 0, meanGPUDurationMs: 0, periodMs: period, waitStillToSkip: false), .none)
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        policy.reset()
        XCTAssertEqual(policy, XRHalfRatePolicy())
    }
}
