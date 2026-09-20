//
//  EngineStatsMonitorTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    // MARK: - Compositor frame accounting

    func testRecordCompositorCompletion_publishesLatestMarginAndCumulativeCounts() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.recordCompositorCompletion(deadlineMarginMs: -1.5, presentationMarginMs: 2.0)
        EngineStatsMonitor.shared.recordCompositorCompletion(deadlineMarginMs: 3.0, presentationMarginMs: 5.5)
        EngineStatsMonitor.shared.completeFrame()

        let published = getEngineStatsSnapshot()
        XCTAssertEqual(published.compositor.deadlineMarginMs, 3.0)
        XCTAssertEqual(published.compositor.presentationMarginMs, 5.5)
        XCTAssertFalse(published.compositor.missedDeadline)
        XCTAssertEqual(published.compositor.missedDeadlineCount, 1)
        XCTAssertEqual(published.compositor.deadlineSampleCount, 2)
        XCTAssertEqual(published.compositor.missedDeadlineRate, 0.5, accuracy: 1e-9)
    }

    func testRecordCompositorCompletion_negativeMargin_flagsMissedDeadline() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.recordCompositorCompletion(deadlineMarginMs: -0.25, presentationMarginMs: 1.0)
        EngineStatsMonitor.shared.completeFrame()

        let published = getEngineStatsSnapshot()
        XCTAssertTrue(published.compositor.missedDeadline)
        XCTAssertEqual(published.compositor.missedDeadlineCount, 1)
        XCTAssertEqual(published.compositor.deadlineSampleCount, 1)
        XCTAssertEqual(published.compositor.missedDeadlineRate, 1.0, accuracy: 1e-9)
    }

    func testCompositorCounters_survive_beginFrame_butPerFrameFieldsReset() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { snapshot in
            snapshot.compositor.updateMs = 4.0
            snapshot.compositor.inputSlackMs = 1.25
            snapshot.compositor.viewCount = 2
        }
        EngineStatsMonitor.shared.recordMissingAnchor()
        EngineStatsMonitor.shared.recordCompositorCompletion(deadlineMarginMs: -2.0, presentationMarginMs: 0.5)
        EngineStatsMonitor.shared.completeFrame()

        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 2.0)
        let inProgress = getEngineStatsSnapshotInProgress()
        XCTAssertEqual(inProgress.compositor.updateMs, 0.0)
        XCTAssertEqual(inProgress.compositor.inputSlackMs, 0.0)
        XCTAssertEqual(inProgress.compositor.viewCount, 0)

        EngineStatsMonitor.shared.completeFrame()
        let published = getEngineStatsSnapshot()
        XCTAssertEqual(published.compositor.missedDeadlineCount, 1)
        XCTAssertEqual(published.compositor.deadlineSampleCount, 1)
        XCTAssertEqual(published.compositor.missingAnchorCount, 1)
        // The latest GPU sample carries over until a newer completion arrives.
        XCTAssertEqual(published.compositor.deadlineMarginMs, -2.0)
    }

    func testReset_clearsCompositorCounters() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.recordMissingAnchor()
        EngineStatsMonitor.shared.recordCompositorCompletion(deadlineMarginMs: -2.0, presentationMarginMs: 0.5)
        EngineStatsMonitor.shared.completeFrame()

        EngineStatsMonitor.shared.reset()
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 2.0)
        EngineStatsMonitor.shared.completeFrame()

        let published = getEngineStatsSnapshot()
        XCTAssertEqual(published.compositor.missedDeadlineCount, 0)
        XCTAssertEqual(published.compositor.deadlineSampleCount, 0)
        XCTAssertEqual(published.compositor.missingAnchorCount, 0)
        XCTAssertEqual(published.compositor.deadlineMarginMs, 0.0)
        XCTAssertFalse(published.compositor.missedDeadline)
    }

    func testFormatEngineStatsOverlay_containsSystemsLine() {
        var snapshot = EngineStatsSnapshot()
        snapshot.timing.animationMs = 1.5
        snapshot.timing.physicsMs = 0.75
        snapshot.timing.physicsStepCount = 2
        snapshot.timing.gameUpdateMs = 0.25

        let overlay = formatEngineStatsOverlay(snapshot)
        XCTAssertTrue(overlay.contains("Systems: "), overlay)
        XCTAssertTrue(overlay.contains("animation 1.50ms"), overlay)
        XCTAssertTrue(overlay.contains("physics 0.75ms (2 steps)"), overlay)
        XCTAssertTrue(overlay.contains("game 0.25ms"), overlay)
    }

    func testTimingSemaphoreWaitMs_roundTripsThroughSnapshot() {
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { snapshot in
            snapshot.timing.semaphoreWaitMs = 0.75
        }
        EngineStatsMonitor.shared.completeFrame()

        XCTAssertEqual(getEngineStatsSnapshot().timing.semaphoreWaitMs, 0.75)
    }

    func testFormatEngineStats_compositorLine_onlyForCompositorFrames() {
        var snapshot = EngineStatsSnapshot()
        XCTAssertFalse(formatEngineStatsOverlay(snapshot).contains("Compositor:"))

        snapshot.compositor.viewCount = 2
        snapshot.compositor.viewTextureWidth = 2048
        snapshot.compositor.viewTextureHeight = 1984
        snapshot.compositor.deadlineMarginMs = -0.5
        snapshot.compositor.missedDeadline = true
        snapshot.compositor.missedDeadlineCount = 3
        snapshot.compositor.deadlineSampleCount = 300
        snapshot.timing.semaphoreWaitMs = 0.1

        let overlay = formatEngineStatsOverlay(snapshot)
        XCTAssertTrue(overlay.contains("Compositor: views 2 @ 2048x1984"), overlay)
        XCTAssertTrue(overlay.contains("deadlineMargin -0.50ms MISSED"), overlay)
        XCTAssertTrue(overlay.contains("missed 3/300 (1.00%)"), overlay)
        XCTAssertTrue(overlay.contains("semWait 0.10ms"), overlay)
    }

    // MARK: - Hitch accounting

    func testHitches_countOverBudgetFramesAndFillHistogram() {
        EngineStatsMonitor.shared.frameBudgetMs = 10.0
        defer { EngineStatsMonitor.shared.frameBudgetMs = 1000.0 / 60.0 }

        for (index, frameMs) in [5.0, 12.0, 50.0].enumerated() {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: Double(index) * 0.01)
            EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = frameMs }
            EngineStatsMonitor.shared.completeFrame()
        }

        let hitches = getEngineStatsSnapshot().hitches
        XCTAssertEqual(hitches.frameBudgetMs, 10.0)
        XCTAssertEqual(hitches.framesSampled, 3)
        XCTAssertEqual(hitches.framesOverBudget, 2)
        XCTAssertEqual(hitches.overBudgetRate, 2.0 / 3.0, accuracy: 1e-9)
        // Buckets: <4, <8, <11.2, <16.8, <33.4, <100, >=100
        XCTAssertEqual(hitches.histogram, [0, 1, 0, 1, 0, 1, 0])
    }

    func testHitches_bucketIndex_boundaries() {
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 0.0), 0)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 3.99), 0)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 4.0), 1)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 11.1), 2)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 16.7), 3)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 100.0), 6)
        XCTAssertEqual(EngineHitchStats.bucketIndex(forFrameMs: 5000.0), 6)
    }

    func testHitches_oneSecondWindowRollsOver() {
        EngineStatsMonitor.shared.frameBudgetMs = 10.0
        defer { EngineStatsMonitor.shared.frameBudgetMs = 1000.0 / 60.0 }

        let frames: [(seconds: Double, ms: Double)] = [(0.0, 20.0), (0.5, 5.0), (1.2, 5.0)]
        for frame in frames {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: frame.seconds)
            EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = frame.ms }
            EngineStatsMonitor.shared.completeFrame()
        }

        let hitches = getEngineStatsSnapshot().hitches
        XCTAssertEqual(hitches.framesLastSecond, 2)
        XCTAssertEqual(hitches.framesOverBudgetLastSecond, 1)
        XCTAssertEqual(hitches.worstFrameMsLastSecond, 20.0)
        XCTAssertEqual(hitches.framesSampled, 3)
    }

    func testReset_clearsHitchesButKeepsBudget() {
        EngineStatsMonitor.shared.frameBudgetMs = 11.0
        defer { EngineStatsMonitor.shared.frameBudgetMs = 1000.0 / 60.0 }
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = 30.0 }
        EngineStatsMonitor.shared.completeFrame()

        EngineStatsMonitor.shared.reset()
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 2.0)
        EngineStatsMonitor.shared.completeFrame()

        let hitches = getEngineStatsSnapshot().hitches
        XCTAssertEqual(hitches.frameBudgetMs, 11.0)
        XCTAssertEqual(hitches.framesSampled, 1)
        XCTAssertEqual(hitches.framesOverBudget, 0)
    }

    func testFormatEngineStatsOverlay_containsHitchesAndThermal() {
        var snapshot = EngineStatsSnapshot()
        snapshot.hitches.framesSampled = 100
        snapshot.hitches.framesOverBudget = 4
        snapshot.hitches.frameBudgetMs = 11.11
        snapshot.memory.thermalState = 2
        snapshot.memory.gpuAllocatedBytes = 300 * 1024 * 1024

        let overlay = formatEngineStatsOverlay(snapshot)
        XCTAssertTrue(overlay.contains("Hitches: budget 11.11ms | over 4/100 (4.00%)"), overlay)
        XCTAssertTrue(overlay.contains("<11.2 "), overlay)
        XCTAssertTrue(overlay.contains("thermal serious"), overlay)
        XCTAssertTrue(overlay.contains("gpuAlloc 300mb"), overlay)
    }

    // MARK: - Codable and recording

    func testSnapshot_codableRoundTrip() throws {
        var snapshot = EngineStatsSnapshot()
        snapshot.frameIndex = 99
        snapshot.timing.animationMs = 1.25
        snapshot.culling.selectedHZBMipSize = simd_int2(256, 128)
        snapshot.compositor.deadlineMarginMs = -0.5
        snapshot.gpuPasses = GPUPassTimingSnapshot(frameIndex: 3, passes: [GPUPassTiming(label: "Light Pass", ms: 2.0, count: 2)], totalMs: 2.0)
        snapshot.hitches.histogram[2] = 7

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(EngineStatsSnapshot.self, from: data)

        XCTAssertEqual(decoded.frameIndex, 99)
        XCTAssertEqual(decoded.timing.animationMs, 1.25)
        XCTAssertEqual(decoded.culling.selectedHZBMipSize, simd_int2(256, 128))
        XCTAssertEqual(decoded.compositor.deadlineMarginMs, -0.5)
        XCTAssertEqual(decoded.gpuPasses, snapshot.gpuPasses)
        XCTAssertEqual(decoded.hitches.histogram[2], 7)
    }

    func testRecorder_perFrame_writesFramesAndSummary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("untold-stats-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        EngineStatsMonitor.shared.frameBudgetMs = 15.0
        defer { EngineStatsMonitor.shared.frameBudgetMs = 1000.0 / 60.0 }
        try startEngineStatsRecording(to: url, interval: .perFrame)

        for (index, frameMs) in [10.0, 20.0, 30.0].enumerated() {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: 100.0 + Double(index) * 0.5)
            EngineStatsMonitor.shared.update { snapshot in
                snapshot.timing.frameTotalMs = frameMs
                snapshot.gpuPasses = GPUPassTimingSnapshot(passes: [GPUPassTiming(label: "Model Pass", ms: frameMs / 4, count: 1)])
            }
            EngineStatsMonitor.shared.recordGPUCompletion(executionMs: frameMs / 2)
            EngineStatsMonitor.shared.completeFrame()
        }

        let summary = try XCTUnwrap(stopEngineStatsRecording())
        XCTAssertEqual(summary.frames, 3)
        XCTAssertEqual(summary.meanFrameMs, 20.0, accuracy: 1e-9)
        XCTAssertEqual(summary.worstFrameMs, 30.0)
        XCTAssertEqual(summary.p50FrameMs, 20.0)
        XCTAssertEqual(summary.framesOverBudget, 2)
        XCTAssertEqual(summary.frameBudgetMs, 15.0)
        XCTAssertEqual(summary.durationSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary.meanGPUExecutionMs, 10.0, accuracy: 1e-9)
        XCTAssertEqual(summary.gpuPassMeanMs["Model Pass"] ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(summary.gpuPassMinMs["Model Pass"] ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(summary.timingMeanMs["updateMs"] ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(summary.timingMeanMs["semaphoreWaitMs"] ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertNil(stopEngineStatsRecording(), "Stopping twice must not report a second recording")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4, "3 frame lines + 1 summary line")

        let decoder = JSONDecoder()
        struct Line: Decodable {
            var type: String
            var frame: EngineStatsSnapshot?
            var summary: EngineStatsRecordingSummary?
        }
        let decoded = try lines.map { try decoder.decode(Line.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map(\.type), ["frame", "frame", "frame", "summary"])
        XCTAssertEqual(decoded[1].frame?.timing.frameTotalMs, 20.0)
        XCTAssertEqual(decoded[3].summary, summary)
    }

    func testRecorder_perSecond_writesOneLinePerSecond() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("untold-stats-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try startEngineStatsRecording(to: url, interval: .perSecond)
        for seconds in [10.0, 10.3, 10.9, 11.1, 11.5] {
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: seconds)
            EngineStatsMonitor.shared.update { $0.timing.frameTotalMs = 8.0 }
            EngineStatsMonitor.shared.completeFrame()
        }
        let summary = try XCTUnwrap(stopEngineStatsRecording())
        XCTAssertEqual(summary.frames, 5, "The summary covers every frame, not only the written ones")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "one line for second 10, one for second 11, one summary")
    }

    // MARK: - Runtime collection switch

    func testCollectionOff_ignoresFrameCallsAndKeepsLastPublishedFrame() {
        let wasCollecting = isEngineStatsCollectionEnabled()
        defer { setEngineStatsCollection(enabled: wasCollecting) }

        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 1.0)
        EngineStatsMonitor.shared.update { $0.timing.updateMs = 2.5 }
        EngineStatsMonitor.shared.completeFrame()
        XCTAssertEqual(getEngineStatsSnapshot().frameIndex, 1)

        setEngineStatsCollection(enabled: false)
        XCTAssertFalse(isEngineStatsCollectionEnabled())
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 2.0)
        EngineStatsMonitor.shared.update { $0.timing.updateMs = 9.0 }
        EngineStatsMonitor.shared.recordGPUCompletion(executionMs: 4.0)
        EngineStatsMonitor.shared.completeFrame()

        let published = getEngineStatsSnapshot()
        XCTAssertEqual(published.frameIndex, 1, "Frames must not advance while collection is off")
        XCTAssertEqual(published.timing.updateMs, 2.5)
        XCTAssertEqual(published.timing.gpuExecutionMs, 0.0)

        setEngineStatsCollection(enabled: true)
        EngineStatsMonitor.shared.beginFrame(timestampSeconds: 3.0)
        EngineStatsMonitor.shared.update { $0.timing.updateMs = 1.0 }
        EngineStatsMonitor.shared.completeFrame()
        XCTAssertEqual(getEngineStatsSnapshot().frameIndex, 2)
        XCTAssertEqual(getEngineStatsSnapshot().timing.updateMs, 1.0)
    }

    func testSetEngineMetrics_alsoTogglesCollection() {
        let wasCollecting = isEngineStatsCollectionEnabled()
        let wasMetrics = enableEngineMetrics
        defer {
            setEngineStatsCollection(enabled: wasCollecting)
            enableEngineMetrics = wasMetrics
        }

        setEngine(.metrics(.disabled))
        XCTAssertFalse(isEngineStatsCollectionEnabled())
        XCTAssertFalse(enableEngineMetrics)

        setEngine(.metrics(.enabled))
        XCTAssertTrue(isEngineStatsCollectionEnabled())
        XCTAssertTrue(enableEngineMetrics)
    }
}
