//
//  EngineEyeStats.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// Where the frames' eyes have been, in the device anchor's frame, since the monitor was last
/// reset: for each eye the last position, the mean, and the lowest and highest value of each
/// axis, in metres. Compositor Services hands the engine each view's transform from the
/// device anchor per frame, and on a headset those are the user's TRACKED eyes: some
/// centimetres off the anchor, by the fit, and moving by millimetres with the gaze. The
/// RealityKit presenter has no such transforms and renders from nominal eyes at the anchor;
/// the headset showed the difference as kinks and shimmer along silhouettes drawn at a wrong
/// depth (2026-10-27), so these numbers, read off the Compositor path, are what its eyes
/// should be set to. Empty (no samples) where no presenter reports eyes.
public struct EngineEyeStats: Sendable, Equatable {
    public struct Eye: Sendable, Equatable {
        public var last: SIMD3<Float> = .zero
        public var sum: SIMD3<Float> = .zero
        public var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        public var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        public var samples = 0

        public init() {}

        public var mean: SIMD3<Float> {
            samples > 0 ? sum / Float(samples) : .zero
        }

        /// Half the range of each axis: how far the eye has strayed from the middle of where it
        /// has been.
        public var spread: SIMD3<Float> {
            samples > 0 ? (high - low) / 2 : .zero
        }

        mutating func add(_ position: SIMD3<Float>) {
            last = position
            sum += position
            low = simd_min(low, position)
            high = simd_max(high, position)
            samples += 1
        }
    }

    /// The eyes in the order the presenter hands them out (left, right on a headset).
    public var eyes: [Eye] = []

    public init() {}

    public var samples: Int {
        eyes.first?.samples ?? 0
    }

    /// The distance between the first two eyes' means, metres; zero with fewer than two.
    public var interpupillaryDistance: Float {
        eyes.count >= 2 ? simd_length(eyes[1].mean - eyes[0].mean) : 0
    }

    /// Adds a frame's eyes: each transform's translation, from the device anchor to the eye.
    public mutating func add(deviceFromViews: [simd_float4x4]) {
        while eyes.count < deviceFromViews.count {
            eyes.append(Eye())
        }
        for (index, transform) in deviceFromViews.enumerated() {
            let column = transform.columns.3
            eyes[index].add(SIMD3<Float>(column.x, column.y, column.z))
        }
    }

    /// The eyes as a person reads them on the headset: each eye's mean from the anchor in
    /// millimetres (x right, y up, z back), with half its range, then the distance between the
    /// two means and the frames counted. "eyes L (-31.7, -18.2, 12.4) ±(0.3, 0.8, 0.4) mm · R
    /// (31.9, -18.0, 12.6) ±(0.3, 0.7, 0.4) mm · IPD 63.6 mm · 2400 frames".
    public var description: String {
        guard samples > 0 else { return "eyes: none reported" }
        func mm(_ v: SIMD3<Float>) -> String {
            String(format: "(%.1f, %.1f, %.1f)", v.x * 1000, v.y * 1000, v.z * 1000)
        }
        let names = ["L", "R", "3", "4"]
        let parts = eyes.enumerated().map { index, eye in
            "\(index < names.count ? names[index] : String(index + 1)) \(mm(eye.mean)) ±\(mm(eye.spread)) mm"
        }
        var line = "eyes " + parts.joined(separator: " · ")
        if eyes.count >= 2 {
            line += String(format: " · IPD %.1f mm", interpupillaryDistance * 1000)
        }
        line += " · \(samples) frames"
        return line
    }
}
