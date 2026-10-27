//
//  XRPresenterEyeCalibrationTests.swift
//  UntoldEngineRenderTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
@testable import UntoldEngine
@testable import UntoldEngineXR
@testable import UntoldEngineXRRealityKit
import XCTest

/// The presenter's eyes: the nominal pair from the distance and the offset, the measured pair
/// through `eyeTransforms`, and the measurement's averaging (`XREyeMeasurement`).
final class XRPresenterEyeCalibrationTests: XCTestCase {
    /// The nominal pair the configuration computed before the override existed, from the
    /// distance and the offset: identity but for the translation.
    private func nominal(eye: Int, distance: Float, offset: SIMD3<Float>) -> simd_float4x4 {
        let x = eye == 0 ? -distance / 2 : distance / 2
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x + offset.x, offset.y, offset.z, 1)
        return transform
    }

    private func translation(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// A transform with a rotation about y and a translation, as a tracked eye's might be.
    private func eye(_ position: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        var transform = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }

    // MARK: - The configuration

    func test_withNoEyeTransforms_theNominalPair_isAsItWas() {
        var configuration = XRRealityKitPresenterConfiguration()
        XCTAssertNil(configuration.eyeTransforms, "no measured eyes by default")
        XCTAssertEqual(configuration.interpupillaryDistance, 0.063)
        XCTAssertEqual(configuration.viewOffsetMetres, .zero)
        for eye in 0 ... 1 {
            XCTAssertEqual(configuration.deviceFromView(eye: eye), nominal(eye: eye, distance: 0.063, offset: .zero), "the default pair, eye \(eye)")
        }

        configuration.interpupillaryDistance = 0.0633
        configuration.viewOffsetMetres = SIMD3<Float>(0.001, -0.025, -0.008)
        XCTAssertEqual(configuration.interpupillaryDistance, 0.0633, "the distance reads back as set")
        XCTAssertEqual(configuration.viewOffsetMetres, SIMD3<Float>(0.001, -0.025, -0.008), "the offset reads back as set")
        for eye in 0 ... 1 {
            XCTAssertEqual(
                configuration.deviceFromView(eye: eye),
                nominal(eye: eye, distance: 0.0633, offset: SIMD3<Float>(0.001, -0.025, -0.008)),
                "the pair from the distance and the offset, byte for byte, eye \(eye)"
            )
        }
    }

    func test_withEyeTransformsSet_deviceFromViewReturnsThem_andTheDistanceAndOffsetReadFromThem() {
        // The headset's eyes of 2026-10-27, with a small rotation each so that the whole
        // transform is seen to pass through.
        let left = eye(SIMD3<Float>(-0.0309, -0.0248, -0.0103), yaw: 0.01)
        let right = eye(SIMD3<Float>(0.0323, -0.0246, -0.0061), yaw: -0.01)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.eyeTransforms = [left, right]

        XCTAssertEqual(configuration.deviceFromView(eye: 0), left, "the left eye is the measured transform, rotation and all")
        XCTAssertEqual(configuration.deviceFromView(eye: 1), right, "the right eye too")
        XCTAssertEqual(configuration.interpupillaryDistance, simd_length(translation(right) - translation(left)), accuracy: 1e-7, "the distance between the two measured eyes")
        XCTAssertEqual(configuration.interpupillaryDistance, 0.0633, accuracy: 1e-4, "the headset's own reading")
        let midpoint = (translation(left) + translation(right)) / 2
        XCTAssertEqual(configuration.viewOffsetMetres, midpoint, "their midpoint")
        XCTAssertEqual(configuration.viewOffsetMetres.y, -0.0247, accuracy: 1e-6)
        XCTAssertNotEqual(configuration, XRRealityKitPresenterConfiguration(), "the override is part of the configuration's equality")
    }

    func test_theNominalPair_setUnderTheOverride_comesBackWhenTheOverrideIsCleared() {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.eyeTransforms = [eye(SIMD3<Float>(-0.03, -0.02, 0), yaw: 0), eye(SIMD3<Float>(0.03, -0.02, 0), yaw: 0)]
        configuration.interpupillaryDistance = 0.07
        configuration.viewOffsetMetres = SIMD3<Float>(0, 0.05, 0)
        XCTAssertEqual(configuration.interpupillaryDistance, 0.06, accuracy: 1e-7, "while the override is set, the measured distance is what reads")
        XCTAssertEqual(configuration.viewOffsetMetres, SIMD3<Float>(0, -0.02, 0), "and the measured midpoint")

        configuration.eyeTransforms = nil
        XCTAssertEqual(configuration.interpupillaryDistance, 0.07, "the nominal distance set meanwhile")
        XCTAssertEqual(configuration.viewOffsetMetres, SIMD3<Float>(0, 0.05, 0), "and the nominal offset")
        for eye in 0 ... 1 {
            XCTAssertEqual(configuration.deviceFromView(eye: eye), nominal(eye: eye, distance: 0.07, offset: SIMD3<Float>(0, 0.05, 0)))
        }
    }

    func test_aSingleTransform_overridesTheLeftEyeOnly_andReportsTheNominalPairsNumbers() {
        let left = eye(SIMD3<Float>(-0.03, -0.02, 0), yaw: 0.2)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.eyeTransforms = [left]
        XCTAssertEqual(configuration.deviceFromView(eye: 0), left)
        XCTAssertEqual(configuration.deviceFromView(eye: 1), nominal(eye: 1, distance: 0.063, offset: .zero), "the right eye stays nominal")
        XCTAssertEqual(configuration.interpupillaryDistance, 0.063, "one transform is no pair: the nominal numbers read")
        XCTAssertEqual(configuration.viewOffsetMetres, .zero)
        XCTAssertEqual(configuration.deviceFromView(eye: 2), nominal(eye: 2, distance: 0.063, offset: .zero), "an eye past the array is nominal, as a third eye always was")
    }

    // MARK: - The averaging

    func test_theAverage_isTheMeanTranslation_withTheLastFramesRotation_andHalfTheRangeOfEachAxis() throws {
        let frames: [[simd_float4x4]] = [
            [eye(SIMD3<Float>(-0.031, -0.025, -0.020), yaw: 0.1), eye(SIMD3<Float>(0.032, -0.024, -0.010), yaw: 0.1)],
            [eye(SIMD3<Float>(-0.030, -0.024, 0.000), yaw: 0.2), eye(SIMD3<Float>(0.033, -0.025, 0.000), yaw: 0.2)],
            [eye(SIMD3<Float>(-0.032, -0.026, -0.010), yaw: 0.3), eye(SIMD3<Float>(0.031, -0.023, -0.008), yaw: 0.3)],
        ]
        let result = try XCTUnwrap(XREyeMeasurement.average(frames))
        XCTAssertEqual(result.frames, 3)
        XCTAssertEqual(result.eyeTransforms.count, 2)
        XCTAssertEqual(result.spreads.count, 2)

        let meanLeft = SIMD3<Float>(-0.031, -0.025, -0.010)
        let meanRight = SIMD3<Float>(0.032, -0.024, -0.006)
        XCTAssertEqual(simd_length(translation(result.eyeTransforms[0]) - meanLeft), 0, accuracy: 1e-6, "the left translation is the mean: \(translation(result.eyeTransforms[0]))")
        XCTAssertEqual(simd_length(translation(result.eyeTransforms[1]) - meanRight), 0, accuracy: 1e-6, "the right translation is the mean: \(translation(result.eyeTransforms[1]))")
        XCTAssertEqual(simd_length(result.positions[0] - meanLeft), 0, accuracy: 1e-6, "positions reads the same")

        // The rotation is the last frame's: its upper 3 × 3 is the yaw of 0.3.
        let lastRotation = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 1, 0)))
        for eye in 0 ... 1 {
            for column in 0 ... 2 {
                XCTAssertEqual(simd_length(result.eyeTransforms[eye][column] - lastRotation[column]), 0, accuracy: 1e-6, "eye \(eye) column \(column) is the last frame's rotation")
            }
            XCTAssertEqual(result.eyeTransforms[eye].columns.3.w, 1)
        }

        // Half the range of each axis: the left eye's x ran -0.032 ... -0.030, its z -0.020 ... 0.
        XCTAssertEqual(simd_length(result.spreads[0] - SIMD3<Float>(0.001, 0.001, 0.010)), 0, accuracy: 1e-6, "the left spread: \(result.spreads[0])")
        XCTAssertEqual(simd_length(result.spreads[1] - SIMD3<Float>(0.001, 0.001, 0.005)), 0, accuracy: 1e-6, "the right spread: \(result.spreads[1])")

        // The pair's numbers for a settings line, and the configuration takes the transforms.
        XCTAssertEqual(result.interpupillaryDistance, simd_length(meanRight - meanLeft), accuracy: 1e-6)
        XCTAssertEqual(simd_length(result.midpoint - (meanLeft + meanRight) / 2), 0, accuracy: 1e-6)
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.eyeTransforms = result.eyeTransforms
        XCTAssertEqual(configuration.interpupillaryDistance, result.interpupillaryDistance, accuracy: 1e-7)
        XCTAssertEqual(configuration.viewOffsetMetres, result.midpoint)
        XCTAssertEqual(configuration.deviceFromView(eye: 1), result.eyeTransforms[1])
    }

    func test_theAverage_ofNoFrames_isNil_andTheAccumulatorAddedFrameByFrame_matchesIt() {
        XCTAssertNil(XREyeMeasurement.average([]))
        XCTAssertNil(XREyeMeasurement.average([[]]), "a frame with no view counts for nothing")
        XCTAssertNil(XREyeMeasurement.Accumulator().result)

        let frames: [[simd_float4x4]] = (0 ..< 10).map { index in
            let wobble = Float(index % 3) * 0.001
            return [eye(SIMD3<Float>(-0.03 + wobble, -0.02, -0.01), yaw: Float(index) * 0.01), eye(SIMD3<Float>(0.03, -0.02 - wobble, -0.01), yaw: Float(index) * 0.01)]
        }
        var accumulator = XREyeMeasurement.Accumulator()
        for frame in frames {
            accumulator.add(frame)
        }
        XCTAssertEqual(accumulator.frames, 10)
        XCTAssertEqual(accumulator.result, XREyeMeasurement.average(frames))

        // The measurement object does the same, and is complete at its frame count.
        let measurement = XREyeMeasurement(frames: 10)
        XCTAssertEqual(measurement.frameCount, 10)
        XCTAssertNil(measurement.result)
        for (index, frame) in frames.enumerated() {
            XCTAssertFalse(measurement.isComplete, "not yet, at frame \(index)")
            measurement.add(frame)
        }
        XCTAssertTrue(measurement.isComplete)
        XCTAssertEqual(measurement.result, XREyeMeasurement.average(frames))
        XCTAssertFalse(measurement.isStopped)
        measurement.stop()
        XCTAssertTrue(measurement.isStopped)
        XCTAssertEqual(XREyeMeasurement(frames: 0).frameCount, 1, "at least one frame")
    }

    func test_aFrameWithOneView_keepsTheOtherEyeAsItWas() throws {
        var accumulator = XREyeMeasurement.Accumulator()
        accumulator.add([eye(SIMD3<Float>(-0.03, 0, 0), yaw: 0), eye(SIMD3<Float>(0.03, 0, 0), yaw: 0)])
        accumulator.add([eye(SIMD3<Float>(-0.01, 0, 0), yaw: 0)])
        let result = try XCTUnwrap(accumulator.result)
        XCTAssertEqual(result.eyeTransforms.count, 2)
        XCTAssertEqual(result.positions[0].x, -0.02, accuracy: 1e-6, "the left eye averaged over both frames")
        XCTAssertEqual(result.positions[1].x, 0.03, accuracy: 1e-6, "the right eye over the one frame that had it")
    }

    func test_theResultsDescription_readsAsTheEnginesEyesLine() {
        let result = XREyeMeasurement.Result(
            eyeTransforms: [eye(SIMD3<Float>(-0.0309, -0.0248, -0.0103), yaw: 0), eye(SIMD3<Float>(0.0323, -0.0246, -0.0061), yaw: 0)],
            spreads: [SIMD3<Float>(0.0004, 0.0001, 0.0123), SIMD3<Float>(0, 0.0003, 0.0141)],
            frames: 60
        )
        XCTAssertEqual(result.description, "eyes L (-30.9, -24.8, -10.3) ±(0.4, 0.1, 12.3) mm · R (32.3, -24.6, -6.1) ±(0.0, 0.3, 14.1) mm · IPD 63.3 mm · 60 frames")
    }
}
