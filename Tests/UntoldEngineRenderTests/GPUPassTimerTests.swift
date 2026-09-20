//
//  GPUPassTimerTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
@testable import UntoldEngine
import XCTest

final class GPUPassTimerTests: BaseRenderSetup {
    override func setUp() async throws {
        try await super.setUp()
        GPUPassTimer.shared.reset()
        GPUPassTimer.shared.isEnabled = false
    }

    override func tearDown() async throws {
        GPUPassTimer.shared.isEnabled = false
        GPUPassTimer.shared.reset()
        try await super.tearDown()
    }

    /// Blocks until every command buffer committed so far on the engine queue has completed,
    /// so the timer's completion handlers have resolved their samples.
    private func drainGPU() throws {
        guard let commandBuffer = renderInfo.commandQueue.makeCommandBuffer() else {
            throw XCTSkip("Could not create a command buffer")
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func testTimerOff_leavesSnapshotEmpty() throws {
        guard renderer != nil else { throw XCTSkip("Renderer not initialized") }

        for _ in 0 ..< 3 {
            renderer.draw(in: renderer.metalView)
        }
        try drainGPU()

        let snapshot = GPUPassTimer.shared.snapshot()
        XCTAssertTrue(snapshot.passes.isEmpty)
        XCTAssertEqual(snapshot.frameIndex, 0)
        XCTAssertEqual(snapshot.totalMs, 0.0)
    }

    func testTimerOn_reportsEveryFramePassWithPositiveTime() throws {
        guard renderer != nil else { throw XCTSkip("Renderer not initialized") }

        GPUPassTimer.shared.isEnabled = true
        for _ in 0 ..< 5 {
            renderer.draw(in: renderer.metalView)
        }
        try drainGPU()

        guard GPUPassTimer.shared.isSupported else {
            throw XCTSkip("Stage-boundary counter sampling is not supported on this device")
        }

        let snapshot = GPUPassTimer.shared.snapshot()
        XCTAssertGreaterThan(snapshot.frameIndex, 0, "No frame was resolved")
        XCTAssertFalse(snapshot.passes.isEmpty, "No passes were timed")
        XCTAssertEqual(snapshot.passesSkipped, 0)
        XCTAssertGreaterThan(snapshot.totalMs, 0.0)

        for pass in snapshot.passes {
            XCTAssertGreaterThanOrEqual(pass.ms, 0.0, pass.label)
            XCTAssertGreaterThanOrEqual(pass.count, 1, pass.label)
            XCTAssertFalse(pass.label.isEmpty)
        }

        // The deferred lighting pass is encoded on every frame path, so it must be present.
        let labels = snapshot.passes.map(\.label)
        XCTAssertTrue(
            labels.contains { $0.contains("Light Pass") || $0.contains("G-buffer") },
            "Expected a lighting pass among: \(labels)"
        )
        XCTAssertEqual(Set(labels).count, labels.count, "Labels must be merged, not repeated: \(labels)")
    }

    func testTimerOn_passTotalIsConsistentWithCommandBufferTime() throws {
        guard renderer != nil else { throw XCTSkip("Renderer not initialized") }

        let previousMetricsState = enableEngineMetrics
        enableEngineMetrics = true
        defer { enableEngineMetrics = previousMetricsState }
        EngineProfiler.shared.reset()
        GPUPassTimer.shared.isEnabled = true

        // The clock calibration needs two frames more than 100 ms apart.
        for _ in 0 ..< 10 {
            renderer.draw(in: renderer.metalView)
            try drainGPU()
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard GPUPassTimer.shared.isSupported else {
            throw XCTSkip("Stage-boundary counter sampling is not supported on this device")
        }

        let passes = GPUPassTimer.shared.snapshot()
        let commandBufferMs = EngineProfiler.shared.snapshot().gpuCommandBuffer.meanMs
        guard commandBufferMs > 0 else { throw XCTSkip("gpuStartTime/gpuEndTime not reported on this device") }

        // Passes may overlap on the GPU, so the sum can exceed the buffer time, but not by an
        // order of magnitude; and the sum cannot be far below it either.
        XCTAssertLessThan(passes.totalMs, commandBufferMs * 4.0,
                          "pass sum \(passes.totalMs) ms vs command buffer \(commandBufferMs) ms: \(passes.passes)")
        XCTAssertGreaterThan(passes.totalMs, commandBufferMs * 0.2,
                             "pass sum \(passes.totalMs) ms vs command buffer \(commandBufferMs) ms")
        for pass in passes.passes {
            XCTAssertLessThan(pass.ms, commandBufferMs * 2.0, "\(pass.label) \(pass.ms) ms exceeds the whole command buffer")
        }
    }

    func testTimerOn_feedsEngineStatsSnapshot() throws {
        guard renderer != nil else { throw XCTSkip("Renderer not initialized") }

        GPUPassTimer.shared.isEnabled = true
        for _ in 0 ..< 5 {
            renderer.draw(in: renderer.metalView)
        }
        try drainGPU()
        // One more frame publishes the resolved timings into the engine stats.
        renderer.draw(in: renderer.metalView)
        try drainGPU()

        guard GPUPassTimer.shared.isSupported else {
            throw XCTSkip("Stage-boundary counter sampling is not supported on this device")
        }

        let stats = getEngineStatsSnapshot()
        XCTAssertFalse(stats.gpuPasses.passes.isEmpty, "Engine stats did not pick up the GPU pass timings")
        XCTAssertTrue(formatEngineStatsOverlay(stats).contains("GPU passes ("), formatEngineStatsOverlay(stats))
    }

    func testDisablingTimer_stopsNewResultsAndKeepsDescriptorsUsable() throws {
        guard renderer != nil else { throw XCTSkip("Renderer not initialized") }

        GPUPassTimer.shared.isEnabled = true
        for _ in 0 ..< 3 {
            renderer.draw(in: renderer.metalView)
        }
        try drainGPU()
        guard GPUPassTimer.shared.isSupported else {
            throw XCTSkip("Stage-boundary counter sampling is not supported on this device")
        }
        let resolvedWhileOn = GPUPassTimer.shared.snapshot().frameIndex
        XCTAssertGreaterThan(resolvedWhileOn, 0)

        GPUPassTimer.shared.isEnabled = false
        for _ in 0 ..< 3 {
            renderer.draw(in: renderer.metalView)
        }
        try drainGPU()

        XCTAssertEqual(GPUPassTimer.shared.snapshot().frameIndex, resolvedWhileOn,
                       "Frames rendered with the timer off must not resolve")
    }

    func testHelpers_withoutRegisteredFrame_behaveLikePlainMetalCalls() throws {
        guard let device = renderInfo.device, let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else { throw XCTSkip("Metal device not available") }

        GPUPassTimer.shared.isEnabled = true
        // No beginFrame for this command buffer: the helpers must still hand out labelled encoders.
        let compute = commandBuffer.makeComputeCommandEncoder(passLabel: "Test Compute")
        XCTAssertEqual(compute?.label, "Test Compute")
        compute?.endEncoding()

        let blit = commandBuffer.makeBlitCommandEncoder(passLabel: "Test Blit")
        XCTAssertEqual(blit?.label, "Test Blit")
        blit?.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertTrue(GPUPassTimer.shared.snapshot().passes.isEmpty)
    }
}
