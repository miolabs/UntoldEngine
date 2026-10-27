//
//  EngineStatsMonitorTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import QuartzCore
import simd
@testable import UntoldEngine
import XCTest

@MainActor
final class EngineStatsMonitorTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        EngineStatsMonitor.shared.reset()
        setEngineStatsLogging(enabled: false)
    }

    override func tearDown() async throws {
        setEngineStatsLogging(enabled: false)
        EngineStatsMonitor.shared.reset()
        try await super.tearDown()
    }

    func testPublicAPI_returnsDefaultSnapshot() {
        let snapshot = getEngineStatsSnapshot()

        XCTAssertEqual(snapshot.frameIndex, 0)
        XCTAssertEqual(snapshot.timestampSeconds, 0.0)
        XCTAssertEqual(snapshot.timing.frameTotalMs, 0.0)
        XCTAssertEqual(snapshot.render.drawCallsTotal, 0)
        XCTAssertEqual(snapshot.culling.frustumTested, 0)
        XCTAssertEqual(snapshot.streaming.activeLoads, 0)
        XCTAssertEqual(snapshot.batching.batchGroupCount, 0)
    }

    func testMonitorUpdate_changesSnapshotValues() {
        EngineStatsMonitor.shared.update { snapshot in
            snapshot.frameIndex = 42
            snapshot.timestampSeconds = 12.5
            snapshot.timing.updateMs = 3.7
            snapshot.render.drawCallsTotal = 17
            snapshot.culling.frustumPassed = 91
            snapshot.streaming.activeLoads = 2
            snapshot.batching.batchGroupCount = 5
        }

        let snapshot = getEngineStatsSnapshot()

        XCTAssertEqual(snapshot.frameIndex, 42)
        XCTAssertEqual(snapshot.timestampSeconds, 12.5)
        XCTAssertEqual(snapshot.timing.updateMs, 3.7)
        XCTAssertEqual(snapshot.render.drawCallsTotal, 17)
        XCTAssertEqual(snapshot.culling.frustumPassed, 91)
        XCTAssertEqual(snapshot.streaming.activeLoads, 2)
        XCTAssertEqual(snapshot.batching.batchGroupCount, 5)
    }

    func testSetEngineStatsLogging_togglesMonitor() {
        setEngineStatsLogging(enabled: true)
        XCTAssertTrue(EngineStatsMonitor.shared.enableLogging)

        setEngineStatsLogging(enabled: false)
        XCTAssertFalse(EngineStatsMonitor.shared.enableLogging)
    }

    func testSetEngineStatsLogging_configuresProfileAndInterval() {
        setEngineStatsLogging(enabled: true, profile: .verbose, intervalSeconds: 0.25)

        XCTAssertTrue(EngineStatsMonitor.shared.enableLogging)
        XCTAssertEqual(EngineStatsMonitor.shared.loggingProfile, .verbose)
        XCTAssertEqual(EngineStatsMonitor.shared.loggingIntervalSeconds, 0.25)

        setEngineStatsLogging(enabled: true, profile: .compact, intervalSeconds: 0.0)
        XCTAssertEqual(EngineStatsMonitor.shared.loggingProfile, .compact)
        XCTAssertEqual(EngineStatsMonitor.shared.loggingIntervalSeconds, 0.1)
    }

    func testBeginFrame_incrementsFrameAndResetsTiming() {
        EngineStatsMonitor.shared.update { snapshot in
            snapshot.timing.frameTotalMs = 10.0
            snapshot.timing.updateMs = 5.0
            snapshot.timing.renderTotalMs = 4.0
            snapshot.timing.cullingMs = 2.0
        }

        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 99.0)

        let snapshot = getEngineStatsSnapshot()
        XCTAssertEqual(snapshot.frameIndex, 1)
        XCTAssertEqual(snapshot.timestampSeconds, 99.0)
        XCTAssertEqual(snapshot.timing.frameTotalMs, 0.0)
        XCTAssertEqual(snapshot.timing.updateMs, 0.0)
        XCTAssertEqual(snapshot.timing.renderTotalMs, 0.0)
        XCTAssertEqual(snapshot.timing.cullingMs, 0.0)
    }

    func testSnapshot_returnsLastCompletedFrameForNextFrameReads() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { snapshot in
            snapshot.timing.frameTotalMs = 16.6
            snapshot.timing.updateMs = 4.2
        }
        EngineStatsMonitor.shared.completeFrame()

        // Start next frame; current in-progress timing is reset.
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 2.0)

        let published = getEngineStatsSnapshot()
        XCTAssertEqual(published.frameIndex, 1)
        XCTAssertEqual(published.timing.frameTotalMs, 16.6)
        XCTAssertEqual(published.timing.updateMs, 4.2)

        let inProgress = getEngineStatsSnapshotInProgress()
        XCTAssertEqual(inProgress.frameIndex, 2)
        XCTAssertEqual(inProgress.timing.frameTotalMs, 0.0)
    }

    func testFormatEngineStatsOverlay_containsCoreSections() {
        var snapshot = EngineStatsSnapshot()
        snapshot.frameIndex = 7
        snapshot.timing.frameTotalMs = 16.0
        snapshot.timing.updateMs = 5.0
        snapshot.timing.renderTotalMs = 8.0
        snapshot.render.drawCallsTotal = 42
        snapshot.render.trianglesTotal = 12000
        snapshot.culling.frustumPassed = 90
        snapshot.culling.frustumTested = 100

        let overlay = formatEngineStatsOverlay(snapshot)
        let compact = formatEngineStatsCompact(snapshot)

        XCTAssertTrue(overlay.contains("Frame 7"))
        XCTAssertTrue(overlay.contains("Timing:"))
        XCTAssertTrue(overlay.contains("Render:"))
        XCTAssertTrue(overlay.contains("Culling:"))
        XCTAssertTrue(compact.contains("frame=7"))
        XCTAssertTrue(compact.contains("drawCalls=42"))
    }

    // MARK: - Smoothing cold-start

    func testCompleteFrame_smoothing_singleFrame_equalsRawValue() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = 12.0 }
        EngineStatsMonitor.shared.completeFrame()

        let snapshot = getEngineStatsSnapshot()
        XCTAssertEqual(snapshot.timing.smoothedFrameMs, 12.0, accuracy: 0.001)
    }

    func testCompleteFrame_smoothing_uniformFrames_staysAtValue() {
        // All frames at the same value — smoothed should converge to that value.
        for i in 1 ... 10 {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: Double(i))
            EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = 16.0 }
            EngineStatsMonitor.shared.completeFrame()
        }

        let snapshot = getEngineStatsSnapshot()
        XCTAssertEqual(snapshot.timing.smoothedFrameMs, 16.0, accuracy: 0.001)
    }

    // MARK: - GPU completion first-frame cadence

    func testRecordGPUCompletion_firstFrame_cadenceEqualsExecutionMs() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.recordGPUCompletion(executionMs: 5.0)
        EngineStatsMonitor.shared.completeFrame()

        let snapshot = getEngineStatsSnapshot()
        XCTAssertEqual(snapshot.timing.gpuExecutionMs, 5.0, accuracy: 0.001)
        // First call: cadence falls back to executionMs.
        XCTAssertEqual(snapshot.timing.gpuFrameCadenceMs, 5.0, accuracy: 0.001)
    }

    // MARK: - GPU time beyond the previous frame's

    func testGPUTimeExcludingOverlap_countsOnlyTheTimeAfterThePreviousFrame() {
        // Back to back: the frame began before the previous one ended.
        XCTAssertEqual(gpuTimeExcludingOverlap(gpuStartTime: 0.008, gpuEndTime: 0.018, previousGPUEndTime: 0.010), 0.008, accuracy: 1e-9)
        // Apart: the whole span.
        XCTAssertEqual(gpuTimeExcludingOverlap(gpuStartTime: 0.020, gpuEndTime: 0.025, previousGPUEndTime: 0.018), 0.005, accuracy: 1e-9)
        // Finished before the previous one: nothing.
        XCTAssertEqual(gpuTimeExcludingOverlap(gpuStartTime: 0.001, gpuEndTime: 0.004, previousGPUEndTime: 0.010), 0, accuracy: 1e-9)
    }

    func testRecordGPUCompletion_timestamps_excludeThePreviousFramesTail() {
        let base = CACurrentMediaTime() + 1000 // past anything an earlier test recorded
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.recordGPUCompletion(gpuStartTime: base, gpuEndTime: base + 0.020)
        EngineStatsMonitor.shared.completeFrame()
        XCTAssertEqual(getEngineStatsSnapshot().timing.gpuExecutionMs, 20.0, accuracy: 0.01)

        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.02)
        EngineStatsMonitor.shared.recordGPUCompletion(gpuStartTime: base + 0.015, gpuEndTime: base + 0.035)
        EngineStatsMonitor.shared.completeFrame()
        XCTAssertEqual(getEngineStatsSnapshot().timing.gpuExecutionMs, 15.0, accuracy: 0.01, "the 5 ms the two frames shared on the GPU count once")
    }

    // MARK: - Formatter bottleneck label

    func testFormatEngineStats_cpuBoundLabel() {
        // smoothedFrameMs >= gpuFrameCadenceMs * 0.9 → CPU-bound
        var snapshot = EngineStatsSnapshot()
        snapshot.timing.smoothedFrameMs = 16.0
        snapshot.timing.gpuFrameCadenceMs = 10.0 // 10 * 0.9 = 9.0; 16 >= 9 → CPU-bound

        let overlay = formatEngineStatsOverlay(snapshot)
        XCTAssertTrue(overlay.contains("CPU-bound"), "Expected CPU-bound label")
        XCTAssertFalse(overlay.contains("GPU-bound"), "Should not show GPU-bound")
    }

    func testFormatEngineStats_gpuBoundLabel() {
        // smoothedFrameMs < gpuFrameCadenceMs * 0.9 → GPU-bound
        var snapshot = EngineStatsSnapshot()
        snapshot.timing.smoothedFrameMs = 5.0
        snapshot.timing.gpuFrameCadenceMs = 20.0 // 20 * 0.9 = 18.0; 5 < 18 → GPU-bound

        let overlay = formatEngineStatsOverlay(snapshot)
        XCTAssertTrue(overlay.contains("GPU-bound"), "Expected GPU-bound label")
        XCTAssertFalse(overlay.contains("CPU-bound"), "Should not show CPU-bound")
    }

    func testFormatEngineStats_zeroFrameMs_doesNotCrash() {
        // smoothedFrameMs == 0 should not produce NaN or divide-by-zero.
        var snapshot = EngineStatsSnapshot()
        snapshot.timing.smoothedFrameMs = 0.0
        snapshot.timing.gpuFrameCadenceMs = 0.0

        let overlay = formatEngineStatsOverlay(snapshot)
        let compact = formatEngineStatsCompact(snapshot)

        XCTAssertFalse(overlay.isEmpty)
        XCTAssertFalse(compact.isEmpty)
        XCTAssertFalse(overlay.contains("nan"), "Output should not contain NaN")
        XCTAssertFalse(compact.contains("nan"), "Output should not contain NaN")
    }

    // MARK: - The frames' stages

    /// The stages from a frame's instants, the pacing left out: the GPU's times split the
    /// time past the commit into the wait and the span; a GPU that reports none leaves it all
    /// in the wait, ending at the handler's time. Either way the three sum to the completion.
    func testFrameStages_fromTheInstants_sumToTheCompletion_withThePacingLeftOut() {
        // Begun at 100 s; 2 ms asleep for the drawing time; committed 6 ms after the
        // beginning; the GPU starts 0.1 ms after the commit and runs 20 ms.
        let reported = EngineFrameStages(begin: 100, pacing: 0.002, committed: 100.006, gpuStart: 100.0061, gpuEnd: 100.0261, now: 100.0265)
        XCTAssertEqual(reported.cpu, 0.004, accuracy: 1e-9, "the CPU frame, the pacing left out")
        XCTAssertEqual(reported.wait, 0.0001, accuracy: 1e-9)
        XCTAssertEqual(reported.gpu, 0.020, accuracy: 1e-9)
        XCTAssertEqual(reported.pacing, 0.002, accuracy: 1e-9)
        XCTAssertEqual(reported.completion, 0.0241, accuracy: 1e-9, "the GPU's end, not the handler's time, from the beginning less the pacing")
        XCTAssertEqual(reported.splitDescription, "24.1 = cpu 4.0 + wait 0.1 + gpu 20.0")

        // No GPU times: the completion is the handler's time, the wait the rest.
        let unreported = EngineFrameStages(begin: 100, committed: 100.003, gpuStart: 0, gpuEnd: 0, now: 100.008)
        XCTAssertEqual(unreported.cpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(unreported.gpu, 0)
        XCTAssertEqual(unreported.wait, 0.005, accuracy: 1e-9)
        XCTAssertEqual(unreported.completion, 0.008, accuracy: 1e-9)

        // A GPU span said to start before the commit (clocks apart): the span is cut to what
        // follows the CPU frame, and the sum holds.
        let skewed = EngineFrameStages(begin: 100, committed: 100.003, gpuStart: 100.001, gpuEnd: 100.006, now: 100.0061)
        XCTAssertEqual(skewed.cpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(skewed.gpu, 0.003, accuracy: 1e-9)
        XCTAssertEqual(skewed.wait, 0, accuracy: 1e-9)
        XCTAssertEqual(skewed.completion, 0.006, accuracy: 1e-9)

        XCTAssertEqual(EngineFrameStages().completion, 0)
    }

    /// Begins `frames` frames evenly over a second from `start`, three of them completing
    /// at 9.0, 10.5 and 16.6 ms.
    private func second(from start: Double, frames: Int) {
        for index in 0 ..< frames {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: start + Double(index) / Double(frames))
            EngineStatsMonitor.shared.completeFrame()
        }
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.005)) // 9.0 ms
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.003, wait: 0.0025, gpu: 0.005)) // 10.5 ms
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043)) // 16.6 ms
    }

    /// A span is the loop's frames from one timestamp to the first at least a span later,
    /// which opens the next; the snapshot carries the last span closed. The refresh period
    /// is measured from the frames begun in the span, not assumed: the same frames are late
    /// against 100 frames in a second and not against 90.
    func testFrameStages_areTheLastSpansClosed_withTheRefreshFromTheCadence() {
        XCTAssertEqual(EngineStatsMonitor.shared.frameStageSpanSeconds, 1.0)

        // 100 frames in the second: a 10 ms refresh, and two frames over it.
        second(from: 1000, frames: 100)
        XCTAssertEqual(getEngineStatsSnapshot().frameStages, EngineFrameStageStats(), "no span closed yet")
        let open = EngineStatsMonitor.shared.frameStagesInProgress()
        XCTAssertEqual(open.framesBegun, 100)
        XCTAssertEqual(open.framesCompleted, 3)
        XCTAssertEqual(open.completionMsMax, 16.6, accuracy: 1e-9)

        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1001) // a second on: closes the span
        EngineStatsMonitor.shared.completeFrame()
        let hundred = getEngineStatsSnapshot().frameStages
        XCTAssertEqual(hundred.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(hundred.framesBegun, 100)
        XCTAssertEqual(hundred.framesCompleted, 3)
        XCTAssertEqual(hundred.framesPerSecond, 3, accuracy: 1e-9)
        XCTAssertEqual(hundred.refreshMs, 10, accuracy: 1e-9)
        XCTAssertEqual(hundred.lateFrames, 2)
        XCTAssertEqual(hundred.gpuMsMax, 5, accuracy: 1e-9)
        XCTAssertEqual(hundred.worstFrame, EngineFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043))
        XCTAssertEqual(hundred.description, "gpu span max 5.0 ms · late 2 of 3 (refresh 10.0 ms) · worst 16.6 = cpu 3.1 + wait 9.2 + gpu 4.3")
        XCTAssertEqual(EngineStatsMonitor.shared.frameStagesInProgress().framesBegun, 1, "the closing frame opened the next span")

        // 90 frames: 11.1 ms, and only the 16.6 ms frame is over it. The closed span stays
        // in the snapshot meanwhile.
        second(from: 1001 + 1.0 / 90, frames: 89)
        XCTAssertEqual(getEngineStatsSnapshot().frameStages, hundred, "the last span closed, while the next is open")
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1002)
        EngineStatsMonitor.shared.completeFrame()
        let ninety = getEngineStatsSnapshot().frameStages
        XCTAssertEqual(ninety.framesBegun, 90)
        XCTAssertEqual(ninety.refreshMs, 11.111111, accuracy: 1e-5)
        XCTAssertEqual(ninety.lateFrames, 1)
        XCTAssertTrue(ninety.description.contains("late 1 of 3 (refresh 11.1 ms)"), ninety.description)

        // A shorter span, set by the reader.
        EngineStatsMonitor.shared.frameStageSpanSeconds = 0.25
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1002.1)
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.001))
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1002.26)
        EngineStatsMonitor.shared.completeFrame()
        let quarter = getEngineStatsSnapshot().frameStages
        XCTAssertEqual(quarter.seconds, 0.26, accuracy: 1e-9, "from the first frame at 1002 to the first a quarter later")
        XCTAssertEqual(quarter.framesBegun, 2)
        XCTAssertEqual(quarter.framesCompleted, 1)
        EngineStatsMonitor.shared.frameStageSpanSeconds = 0
        XCTAssertEqual(EngineStatsMonitor.shared.frameStageSpanSeconds, 0.1, "at least a tenth of a second")
        EngineStatsMonitor.shared.frameStageSpanSeconds = 1.0
    }

    /// Each stage's maximum is its own (the longest wait and the longest GPU span may be
    /// different frames'); the worst frame is the one with the longest completion, kept whole
    /// with its pacing; the frames past the presenter's deadline are counted apart, and
    /// printed only when there are any.
    func testFrameStages_carryEachStagesMaximum_theWorstFrameWhole_andTheDeadlineCount() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 10)
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.0028, wait: 0.0005, gpu: 0.0036)) // 6.9: a usual frame
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.0040, wait: 0.0002, gpu: 0.0060), pastDeadline: true) // 10.2: the longest GPU span
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043, pacing: 0.002)) // 16.6: the longest wait, the worst
        EngineStatsMonitor.shared.recordFrameLetGo() // a frame taken and let go undrawn
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 11)
        EngineStatsMonitor.shared.completeFrame()

        let stages = getEngineStatsSnapshot().frameStages
        XCTAssertEqual(stages.cpuMsMax, 4.0, accuracy: 1e-9, "the CPU frame's maximum")
        XCTAssertEqual(stages.waitMsMax, 9.2, accuracy: 1e-9, "the wait's")
        XCTAssertEqual(stages.gpuMsMax, 6.0, accuracy: 1e-9, "the GPU span's")
        XCTAssertEqual(stages.completionMsMax, 16.6, accuracy: 1e-9, "the completion's")
        XCTAssertEqual(stages.worstFrame, EngineFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043, pacing: 0.002), "the longest frame, with its own stages and its pacing")
        XCTAssertEqual(stages.pastDeadline, 1)
        XCTAssertEqual(stages.letGo, 1)
        XCTAssertEqual(stages.letGoTotal, 1)
        XCTAssertEqual(stages.framesBegun, 1, "one frame begun in the span: a refresh of a second, nothing late against it")
        XCTAssertEqual(stages.refreshMs, 1000, accuracy: 1e-9)
        XCTAssertEqual(stages.lateFrames, 0)
        XCTAssertEqual(stages.description, "gpu span max 6.0 ms · late 0 of 3 (refresh 1000.0 ms) · worst 16.6 = cpu 3.1 + wait 9.2 + gpu 4.3 · 1 past the deadline · 1 let go (1 in all)")

        let compact = formatEngineStatsCompact(getEngineStatsSnapshot())
        XCTAssertTrue(compact.hasSuffix(" | " + stages.description), compact)
        let overlay = formatEngineStatsOverlay(getEngineStatsSnapshot())
        XCTAssertTrue(overlay.contains("Stages: " + stages.description + " | cpu max 4.00ms | wait max 9.20ms | completion max 16.60ms | worst's pacing 2.00ms | 3 frames in 1.00s"), overlay)
        XCTAssertEqual(formatEngineFrameStages(getEngineStatsSnapshot()), stages.description)
    }

    /// The late count keeps a bounded list of completions in a span: past the bound the
    /// frames still enter the maxima and the worst frame.
    func testFrameStages_theLateCountIsBounded_theMaximaAreNot() {
        for index in 0 ..< 100 {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: 50 + Double(index) / 100)
        }
        for _ in 0 ..< EngineStatsMonitor.completionsKept {
            EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.02))
        }
        EngineStatsMonitor.shared.recordFrameCompletion(EngineFrameStages(cpu: 0.03))
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 51)
        EngineStatsMonitor.shared.completeFrame()

        let stages = getEngineStatsSnapshot().frameStages
        XCTAssertEqual(stages.refreshMs, 10, accuracy: 1e-9)
        XCTAssertEqual(stages.framesCompleted, EngineStatsMonitor.completionsKept + 1)
        XCTAssertEqual(stages.lateFrames, EngineStatsMonitor.completionsKept, "the frame past the bound is not counted")
        XCTAssertEqual(stages.completionMsMax, 30, accuracy: 1e-9, "but it is the worst")
        XCTAssertEqual(stages.worstFrame.cpuMs, 30, accuracy: 1e-9)
    }

    /// Nothing recorded: the stages print as zeros, with no deadline count.
    func testFrameStages_withoutFrames_printZeros() {
        let compact = formatEngineStatsCompact(EngineStatsSnapshot())
        XCTAssertTrue(compact.hasSuffix(" | gpu span max 0.0 ms · late 0 of 0 (refresh 0.0 ms) · worst 0.0 = cpu 0.0 + wait 0.0 + gpu 0.0"), compact)
        XCTAssertFalse(compact.contains("deadline"))
    }

    /// The eyes a presenter reports (each view's transform from the device anchor) accumulate
    /// since the reset: the last, the mean, half the range of each axis, the distance between
    /// the two means; the snapshot carries them from the next completed frame; the reset
    /// forgets them.
    func testEyes_accumulateFromTheDeviceAnchor_andReadInMillimetres() {
        var left = matrix_identity_float4x4
        var right = matrix_identity_float4x4
        left.columns.3 = SIMD4<Float>(-0.0317, -0.0182, 0.0124, 1)
        right.columns.3 = SIMD4<Float>(0.0319, -0.0180, 0.0126, 1)
        EngineStatsMonitor.shared.recordEyes(deviceFromViews: [left, right])
        // A glance: both eyes a millimetre lower and half a millimetre to the right.
        left.columns.3 += SIMD4<Float>(0.0005, -0.001, 0, 0)
        right.columns.3 += SIMD4<Float>(0.0005, -0.001, 0, 0)
        EngineStatsMonitor.shared.recordEyes(deviceFromViews: [left, right])

        XCTAssertEqual(getEngineStatsSnapshot().eyes.samples, 0, "the snapshot carries the eyes from the next completed frame")
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 10)
        EngineStatsMonitor.shared.completeFrame()
        let eyes = getEngineStatsSnapshot().eyes
        XCTAssertEqual(eyes.samples, 2)
        XCTAssertEqual(eyes.eyes.count, 2)
        XCTAssertEqual(eyes.eyes[0].mean.x, -0.03145, accuracy: 1e-6)
        XCTAssertEqual(eyes.eyes[0].mean.y, -0.0187, accuracy: 1e-6)
        XCTAssertEqual(eyes.eyes[0].spread.x, 0.00025, accuracy: 1e-6)
        XCTAssertEqual(eyes.eyes[0].spread.y, 0.0005, accuracy: 1e-6)
        XCTAssertEqual(eyes.eyes[0].spread.z, 0, accuracy: 1e-6)
        XCTAssertEqual(eyes.eyes[1].last.x, 0.0324, accuracy: 1e-6)
        XCTAssertEqual(eyes.interpupillaryDistance, 0.0636, accuracy: 1e-5, "the distance between the two means")
        XCTAssertEqual(eyes.description, "eyes L (-31.4, -18.7, 12.4) ±(0.2, 0.5, 0.0) mm · R (32.2, -18.5, 12.6) ±(0.3, 0.5, 0.0) mm · IPD 63.6 mm · 2 frames")
        XCTAssertEqual(formatEngineEyes(getEngineStatsSnapshot()), eyes.description)
        XCTAssertTrue(formatEngineStatsCompact(getEngineStatsSnapshot()).hasSuffix(" | " + eyes.description), "the eyes end the compact log line, to be copied off a console")
        XCTAssertTrue(formatEngineStatsOverlay(getEngineStatsSnapshot()).contains("Eyes: eyes L (-31.4"))

        EngineStatsMonitor.shared.reset()
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 11)
        EngineStatsMonitor.shared.completeFrame()
        XCTAssertEqual(getEngineStatsSnapshot().eyes, EngineEyeStats(), "the reset forgets the eyes")
        XCTAssertEqual(EngineEyeStats().description, "eyes: none reported")
    }
}
