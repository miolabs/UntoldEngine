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

/// The half-rate pacing enters after two seconds of skipped refreshes or missed frames with no
/// wait left to skip, spaces the frames by the refreshes their GPU work with its encode needs,
/// aims the pose where the frames land past the deadline's margin, and leaves after two seconds
/// in which the frames' GPU work fitted most of a refresh.
final class XRHalfRatePolicyTests: XCTestCase {
    private let period = 10.0
    private let margin = 15.0

    private func lateSecond(_ policy: inout XRHalfRatePolicy, waitStillToSkip: Bool = false, meanGPU: Double = 12.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, missed: 30, skipped: 5, meanOverrunMs: 14.0, meanGPUDurationMs: meanGPU, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: waitStillToSkip)
    }

    private func goodSecond(_ policy: inout XRHalfRatePolicy, meanGPU: Double = 7.0) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 100, missed: 0, skipped: 0, meanOverrunMs: 0.2, meanGPUDurationMs: meanGPU, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false)
    }

    private func pacedSecond(_ policy: inout XRHalfRatePolicy, overrun: Double, meanGPU: Double) -> XRHalfRatePolicy.Change {
        policy.secondEnded(frames: 40, missed: 0, skipped: 0, meanOverrunMs: overrun, meanGPUDurationMs: meanGPU, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false)
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

    func testDoesNotEnterForFramesWithinTheDeadlinesMargin() {
        var policy = XRHalfRatePolicy()
        // Past the deadline but within its margin, nothing skipped: shown on time.
        for _ in 0 ..< 3 {
            XCTAssertEqual(policy.secondEnded(frames: 100, missed: 0, skipped: 0, meanOverrunMs: 4.0, meanGPUDurationMs: 10.2, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false), .none)
        }
        XCTAssertFalse(policy.active)
        // Fewer than one frame in ten missed or a refresh skipped: still below the bar.
        for _ in 0 ..< 3 {
            XCTAssertEqual(policy.secondEnded(frames: 100, missed: 9, skipped: 9, meanOverrunMs: 4.0, meanGPUDurationMs: 10.2, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false), .none)
        }
        XCTAssertFalse(policy.active)
    }

    func testEntersOnSkippedRefreshesAlone() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(policy.secondEnded(frames: 100, missed: 0, skipped: 10, meanOverrunMs: 2.0, meanGPUDurationMs: 10.5, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false), .none)
        XCTAssertEqual(policy.secondEnded(frames: 100, missed: 0, skipped: 10, meanOverrunMs: 2.0, meanGPUDurationMs: 10.5, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false), .entered)
        XCTAssertTrue(policy.active)
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
        // A mean of 14.5 ms: 20.4 ms, within the deadband past two refreshes, still two.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 14.5), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 2)
        // A mean of 16 ms: 22.2 ms, three.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 16.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        // Back to 14.5 ms, 20.4 ms, just under three refreshes but within the deadband of two: stays three.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 14.5), .none)
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 14.5), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 3)
        // Never more than four.
        XCTAssertEqual(pacedSecond(&policy, overrun: 8.0, meanGPU: 60.0), .none)
        XCTAssertEqual(policy.cadenceRefreshes, 4)
        // A shorter cadence is taken only after two seconds running that fit it clearly.
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

    func testThePoseAimsAtTheRefreshTheOverrunReachesBeyondTheMargin() {
        var policy = XRHalfRatePolicy()
        XCTAssertEqual(policy.landingRefreshes, 0)
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        // Finished 9 ms past the deadline, within its 15 ms margin less the safety: shown on time.
        XCTAssertEqual(pacedSecond(&policy, overrun: 9.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 0)
        // 14 ms past, a millisecond beyond the usable margin: one refresh after the prediction.
        XCTAssertEqual(pacedSecond(&policy, overrun: 14.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 1)
        // 28 ms past: two.
        XCTAssertEqual(pacedSecond(&policy, overrun: 28.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 2)
        // Never beyond three.
        XCTAssertEqual(pacedSecond(&policy, overrun: 90.0, meanGPU: 14.0), .none)
        XCTAssertEqual(policy.landingRefreshes, 3)
        XCTAssertEqual(XRHalfRatePolicy.usableMarginMs(deadlineMarginMs: 15.0), 13.0)
        XCTAssertEqual(XRHalfRatePolicy.usableMarginMs(deadlineMarginMs: 1.0), 0.0)
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
        XCTAssertEqual(policy.secondEnded(frames: 0, missed: 0, skipped: 0, meanOverrunMs: 0, meanGPUDurationMs: 0, periodMs: period, deadlineMarginMs: margin, waitStillToSkip: false), .none)
        _ = lateSecond(&policy)
        _ = lateSecond(&policy)
        policy.reset()
        XCTAssertEqual(policy, XRHalfRatePolicy())
    }
}
