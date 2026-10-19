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
/// own busy time beside the span, and the device's thermal state.
final class XRPresenterStatisticsTests: XCTestCase {
    override func tearDown() {
        setRendering(.gpuPassTiming(.disabled))
        super.tearDown()
    }

    func testTheSnapshotCarriesTheSpanTheEnginesBusyTimeAndTheThermalState() {
        let statistics = XRPresenterStatistics()
        statistics.noteGPU(seconds: 0.004)
        statistics.noteGPU(seconds: 0.006)
        let off = statistics.snapshot()
        XCTAssertEqual(off.gpuMsAverage, 5, accuracy: 1e-9, "the span, averaged")
        XCTAssertEqual(off.gpuMsMax, 6, accuracy: 1e-9)
        XCTAssertEqual(off.engineGPUMsAverage, 0, "no busy time while the pass timing is off")
        XCTAssertEqual(off.thermalState, ProcessInfo.processInfo.thermalState)
        XCTAssertTrue(off.description.contains("GPU span 5.00 ms (max 6.00)"), off.description)
        XCTAssertTrue(off.description.contains("engine GPU 0.00 ms"), off.description)
        XCTAssertTrue(off.description.contains("thermal \(off.thermalStateName)"), off.description)
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(off.thermalStateName))

        // On, with no frame resolved yet: the busy time is still zero, and the span resets.
        setRendering(.gpuPassTiming(.enabled))
        let on = statistics.snapshot()
        XCTAssertEqual(on.engineGPUMsAverage, GPUPassTiming.shared.busy().averageMs, accuracy: 1e-9)
        XCTAssertEqual(on.gpuMsAverage, 0, "a snapshot starts a new span")
    }
}
