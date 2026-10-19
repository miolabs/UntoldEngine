//
//  GPUPassTimingTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import simd
@testable import UntoldEngine
import XCTest

/// The GPU times its own passes: with the timing on, a frame's passes come back with their
/// vertex and fragment milliseconds, which add up to no more than the frame; off, nothing.
@MainActor
final class GPUPassTimingTests: BaseRenderSetup {
    override func tearDown() async throws {
        setRendering(.gpuPassTiming(.disabled))
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 1, 4), target: .zero, up: simd_float3(0, 1, 0))
        let box = createEntity()
        setEntityMeshDirect(entityId: box, meshes: BasicPrimitives.createCube(extent: 1.0), assetName: "Box")
        translateTo(entityId: box, position: simd_float3(0, 0.5, 0))
        let sun = createEntity()
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, pitch: -40, yaw: 30, roll: 0)
        applyIBL = true
    }

    private func drawFrames(_ count: Int) -> Double {
        var span = 0.0
        for _ in 0 ..< count {
            renderer.draw(in: renderer.metalView)
            guard let cb = renderInfo.lastCommandBuffer else { continue }
            cb.waitUntilCompleted()
            span = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        return span
    }

    func testPassesAreTimedWhenOnAndNotWhenOff() throws {
        try XCTSkipUnless(renderInfo.device.supportsCounterSampling(.atStageBoundary), "no stage-boundary sampling here")
        _ = drawFrames(3)
        XCTAssertTrue(GPUPassTiming.shared.averages().isEmpty, "off by default")

        setRendering(.gpuPassTiming(.enabled))
        let frameMs = drawFrames(30)
        let passes = GPUPassTiming.shared.averages()
        XCTAssertFalse(passes.isEmpty, "the frame's passes are timed")
        // The frame's busy time: the union of the stages' spans, within the frame's span and
        // never more than the stages added up (which count an overlap twice).
        let busy = GPUPassTiming.shared.busy()
        XCTAssertGreaterThan(busy.lastFrameMs, 0, "the last frame's busy time")
        XCTAssertGreaterThan(busy.averageMs, 0, "the average busy time")
        XCTAssertLessThanOrEqual(busy.lastFrameMs, frameMs * 1.1 + 0.3, "the busy time lies within the frame's span (\(frameMs) ms)")
        XCTAssertLessThanOrEqual(busy.averageMs, passes.reduce(0) { $0 + $1.totalMs } + 0.01, "the union is no more than the stages added up")
        // The combined pass: the G-buffer's when the light pass lights, the forward one when the
        // geometry lights itself (the default).
        let gBuffer = try XCTUnwrap(passes.first { $0.label == "G-Buffer" || $0.label == "Forward" }, "the combined pass is timed: \(passes.map(\.label))")
        XCTAssertGreaterThan(gBuffer.fragmentMs, 0, "the combined pass shades")
        XCTAssertGreaterThanOrEqual(gBuffer.vertexMs, 0)
        let total = passes.reduce(0) { $0 + $1.totalMs }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(total, frameMs * 1.5 + 0.5, "the passes add up to no more than the frame (\(frameMs) ms): \(passes)")
        print("GPU pass timing (Mac): " + passes.map { String(format: "%@ v%.3f f%.3f", $0.label, $0.vertexMs, $0.fragmentMs) }.joined(separator: ", ") + String(format: " | frame %.3f", frameMs))

        setRendering(.gpuPassTiming(.disabled))
        _ = drawFrames(3)
        XCTAssertTrue(GPUPassTiming.shared.averages().isEmpty, "off again")
        XCTAssertEqual(GPUPassTiming.shared.busy().averageMs, 0, "no busy time when off")
    }

    func testTheBusyTimeIsTheUnionOfTheStagesSpans() {
        let ms = 0.001 // a tick of a microsecond
        // Two passes whose vertex and fragment stages overlap, then a compute pass apart.
        let intervals: [(start: UInt64, end: UInt64)] = [
            (1000, 1400), // pass 1 vertex
            (1200, 2000), // pass 1 fragment, over the vertex's end
            (1800, 2100), // pass 2 vertex, over the fragment's end
            (2100, 2600), // pass 2 fragment, touching
            (3000, 3300), // a compute pass, apart
        ]
        XCTAssertEqual(GPUPassTiming.unionMilliseconds(of: intervals, msPerTick: ms), (2600 - 1000 + 300) * ms, accuracy: 1e-9, "overlaps and the touching pair count once, the gap not at all")
        // Order does not matter, an inverted interval counts nothing, nothing is nothing.
        XCTAssertEqual(GPUPassTiming.unionMilliseconds(of: intervals.reversed(), msPerTick: ms), (2600 - 1000 + 300) * ms, accuracy: 1e-9)
        XCTAssertEqual(GPUPassTiming.unionMilliseconds(of: [(500, 400), (10, 20)], msPerTick: ms), 10 * ms, accuracy: 1e-9)
        XCTAssertEqual(GPUPassTiming.unionMilliseconds(of: [], msPerTick: ms), 0)
        // One interval inside another adds nothing.
        XCTAssertEqual(GPUPassTiming.unionMilliseconds(of: [(0, 1000), (100, 200), (900, 1000)], msPerTick: ms), 1000 * ms, accuracy: 1e-9)
    }
}
