//
//  XRPresenterStatisticsTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import UntoldEngine
import UntoldEngineXRRealityKit
import XCTest

/// The presenter's numbers line names what makes its GPU span mean something: the engine's
/// own busy time beside the span, and the device's thermal state; it carries the lead in
/// force and the frames' time to completion, which the adaptive lead is built from; and it
/// splits the frames into their stages, counts the ones that overran the refresh and says
/// where the longest one spent its time.
final class XRPresenterStatisticsTests: XCTestCase {
    override func tearDown() {
        setRendering(.gpuPassTiming(.disabled))
        super.tearDown()
    }

    func testTheSnapshotCarriesTheSpanTheEnginesBusyTimeAndTheThermalState() {
        let statistics = XRPresenterStatistics()
        statistics.noteFrameCompleted(XRPresenterFrameStages(gpu: 0.004))
        statistics.noteFrameCompleted(XRPresenterFrameStages(gpu: 0.006))
        let off = statistics.snapshot()
        XCTAssertEqual(off.gpuMsAverage, 5, accuracy: 1e-9, "the span, averaged")
        XCTAssertEqual(off.gpuMsMax, 6, accuracy: 1e-9)
        XCTAssertEqual(off.engineGPUMsAverage, 0, "no busy time while the pass timing is off")
        XCTAssertEqual(off.thermalState, ProcessInfo.processInfo.thermalState)
        XCTAssertTrue(off.description.contains("GPU span 5.00 ms (max 6.00)"), off.description)
        XCTAssertTrue(off.description.contains("engine GPU 0.00 ms"), off.description)
        XCTAssertTrue(off.description.contains("thermal \(off.thermalStateName)"), off.description)
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(off.thermalStateName))
        XCTAssertEqual(off.leadMsAverage, 0, "no lead noted yet")
        XCTAssertEqual(off.completionMsAverage, 5, accuracy: 1e-9, "a frame of nothing but GPU completes with its span")

        // On, with no frame resolved yet: the busy time is still zero, and the span resets.
        setRendering(.gpuPassTiming(.enabled))
        let on = statistics.snapshot()
        XCTAssertEqual(on.engineGPUMsAverage, GPUPassTiming.shared.busy().averageMs, accuracy: 1e-9)
        XCTAssertEqual(on.gpuMsAverage, 0, "a snapshot starts a new span")
    }

    func testTheSnapshotCarriesTheLeadInForce_andTheFramesTimeToCompletion() {
        let statistics = XRPresenterStatistics()
        statistics.noteLead(seconds: 0.022)
        statistics.noteLead(seconds: 0.024)
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.002))
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.002, gpu: 0.003))
        let numbers = statistics.snapshot()
        XCTAssertEqual(numbers.leadMsAverage, 23, accuracy: 1e-9, "the lead in force, averaged")
        XCTAssertEqual(numbers.leadMsMax, 24, accuracy: 1e-9)
        XCTAssertEqual(numbers.completionMsAverage, 7, accuracy: 1e-9, "from pickup to the GPU's completion, averaged")
        XCTAssertEqual(numbers.completionMsMax, 8, accuracy: 1e-9)
        XCTAssertTrue(numbers.description.contains("to completion 7.00 ms (max 8.00)"), numbers.description)
        XCTAssertTrue(numbers.description.contains("lead 23.00 ms (max 24.00)"), numbers.description)
        let next = statistics.snapshot()
        XCTAssertEqual(next.leadMsAverage, 0, "a snapshot starts a new span")
        XCTAssertEqual(next.completionMsMax, 0)
    }

    // MARK: - The stages

    /// The stages from a frame's instants: the GPU's times split the time past the commit
    /// into the wait and the span; a GPU that reports none leaves it all in the wait, ending
    /// at the handler's time. Either way the three sum to the completion.
    func testTheStagesFromTheInstants_sumToTheCompletion() {
        // Pickup at 100 s; committed 3.1 ms later; the GPU starts 9.2 ms after that and runs 4.3 ms.
        let reported = XRPresenterFrameStages(pickup: 100, committed: 100.0031, gpuStart: 100.0123, gpuEnd: 100.0166, now: 100.0170)
        XCTAssertEqual(reported.cpu, 0.0031, accuracy: 1e-9)
        XCTAssertEqual(reported.wait, 0.0092, accuracy: 1e-9)
        XCTAssertEqual(reported.gpu, 0.0043, accuracy: 1e-9)
        XCTAssertEqual(reported.completion, 0.0166, accuracy: 1e-9, "the GPU's end, not the handler's time")
        XCTAssertEqual(reported.splitDescription, "16.6 = cpu 3.1 + wait 9.2 + gpu 4.3")

        // No GPU times: the completion is the handler's time, the wait the rest.
        let unreported = XRPresenterFrameStages(pickup: 100, committed: 100.003, gpuStart: 0, gpuEnd: 0, now: 100.008)
        XCTAssertEqual(unreported.cpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(unreported.gpu, 0)
        XCTAssertEqual(unreported.wait, 0.005, accuracy: 1e-9)
        XCTAssertEqual(unreported.completion, 0.008, accuracy: 1e-9)

        // A GPU span said to start before the commit (clocks apart): the span is cut to what
        // follows the CPU frame, and the sum holds.
        let skewed = XRPresenterFrameStages(pickup: 100, committed: 100.003, gpuStart: 100.001, gpuEnd: 100.006, now: 100.0061)
        XCTAssertEqual(skewed.cpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(skewed.gpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(skewed.wait, 0, accuracy: 1e-9)
        XCTAssertEqual(skewed.completion, 0.006, accuracy: 1e-9)

        XCTAssertEqual(XRPresenterFrameStages().completion, 0)
    }

    /// Each stage's maximum is its own (the longest wait and the longest GPU span may be
    /// different frames'); the worst frame is the one with the longest completion, kept whole.
    func testTheSnapshotCarriesEachStagesMaximum_andTheWorstFramesSplit() {
        let statistics = XRPresenterStatistics()
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.0028, wait: 0.0005, gpu: 0.0036)) // 6.9: a usual frame
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.0040, wait: 0.0002, gpu: 0.0060)) // 10.2: the longest GPU span
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043)) // 16.6: the longest wait, the worst
        let numbers = statistics.snapshot()
        XCTAssertEqual(numbers.frameMsMax, 4.0, accuracy: 1e-9, "the CPU frame's maximum")
        XCTAssertEqual(numbers.waitMsMax, 9.2, accuracy: 1e-9, "the wait's")
        XCTAssertEqual(numbers.gpuMsMax, 6.0, accuracy: 1e-9, "the GPU span's")
        XCTAssertEqual(numbers.completionMsMax, 16.6, accuracy: 1e-9, "the completion's")
        XCTAssertEqual(numbers.frameMsAverage, 3.3, accuracy: 1e-9)
        XCTAssertEqual(numbers.waitMsAverage, 3.3, accuracy: 1e-9)
        XCTAssertEqual(numbers.gpuMsAverage, 4.6333333, accuracy: 1e-6)
        XCTAssertEqual(numbers.completionMsAverage, 11.2333333, accuracy: 1e-6)
        XCTAssertEqual(numbers.worstFrame, XRPresenterFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043), "the longest frame, with its own stages")
        XCTAssertEqual(numbers.worstFrame.splitDescription, "16.6 = cpu 3.1 + wait 9.2 + gpu 4.3")
        XCTAssertTrue(numbers.description.contains("CPU frame 3.30 ms (max 4.00), wait 3.30 ms (max 9.20), GPU span 4.63 ms (max 6.00), to completion 11.23 ms (max 16.60), worst 16.6 = cpu 3.1 + wait 9.2 + gpu 4.3"), numbers.description)
        let next = statistics.snapshot()
        XCTAssertEqual(next.worstFrame, XRPresenterFrameStages(), "a snapshot starts a new span")
        XCTAssertEqual(next.waitMsMax, 0)
    }

    /// A clock the test sets.
    private final class TestClock: @unchecked Sendable {
        var now: TimeInterval

        init(_ now: TimeInterval) {
            self.now = now
        }
    }

    /// The refresh period is measured from the updates (RealityKit updates once a refresh),
    /// not assumed: the same frames are late against 100 updates/s and not against 90.
    func testLateFrames_areCountedAgainstTheRefreshMeasuredFromTheUpdates() {
        let clock = TestClock(1000)
        let statistics = XRPresenterStatistics(clock: { clock.now })
        func second(updates: Int) -> XRPresenterStatisticsSnapshot {
            for _ in 0 ..< updates {
                statistics.noteUpdate()
            }
            statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.005)) // 9.0 ms
            statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.0025, gpu: 0.005)) // 10.5 ms
            statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043)) // 16.6 ms
            clock.now += 1
            return statistics.snapshot()
        }

        // 100 updates in the second: a 10 ms refresh, and two frames over it.
        let hundred = second(updates: 100)
        XCTAssertEqual(hundred.updatesPerSecond, 100, accuracy: 1e-9)
        XCTAssertEqual(hundred.refreshMs, 10, accuracy: 1e-9)
        XCTAssertEqual(hundred.lateFrames, 2)
        XCTAssertTrue(hundred.description.hasPrefix("XR presenter: 100 updates/s (refresh 10.0 ms), 0 frames/s"), hundred.description + " (frames/s counts the tickets taken, none here)")
        XCTAssertTrue(hundred.description.contains("0 frames without a pose, 2 late;"), hundred.description)

        // 90 updates: 11.1 ms, and only the 16.6 ms frame is over it.
        let ninety = second(updates: 90)
        XCTAssertEqual(ninety.refreshMs, 11.111111, accuracy: 1e-5)
        XCTAssertEqual(ninety.lateFrames, 1)
        XCTAssertTrue(ninety.description.contains("(refresh 11.1 ms)"), ninety.description)
        XCTAssertTrue(ninety.description.contains("1 late;"), ninety.description)

        // No updates (no RealityKit cadence to measure): no refresh, nothing is late.
        let none = second(updates: 0)
        XCTAssertEqual(none.refreshMs, 0)
        XCTAssertEqual(none.lateFrames, 0)
        XCTAssertEqual(none.completionMsMax, 16.6, accuracy: 1e-9, "the frames still enter the maxima")
    }

    /// The late count keeps a bounded list of completions between snapshots: past the bound
    /// the frames still enter the averages and maxima.
    func testTheLateCount_isBounded_theMaximaAreNot() {
        let clock = TestClock(0)
        let statistics = XRPresenterStatistics(clock: { clock.now })
        statistics.noteUpdate()
        for _ in 0 ..< XRPresenterStatistics.completionsKept {
            statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.02))
        }
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.03))
        clock.now = 0.01
        let numbers = statistics.snapshot()
        XCTAssertEqual(numbers.refreshMs, 10, accuracy: 1e-9)
        XCTAssertEqual(numbers.lateFrames, XRPresenterStatistics.completionsKept, "the frame past the bound is not counted")
        XCTAssertEqual(numbers.completionMsMax, 30, accuracy: 1e-9, "but it is the worst")
        XCTAssertEqual(numbers.worstFrame.cpuMs, 30, accuracy: 1e-9)
    }
}
