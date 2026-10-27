//
//  XREyeMeasurement.swift
//  UntoldEngineXR
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine

/// The headset's tracked eyes, measured off Compositor Services for a presenter that is not
/// told them. RealityKit renders from the device's tracked eyes and exposes no eye transform,
/// while Compositor Services hands each frame the transform from the ARKit device anchor to
/// each view (`LayerRenderer.Drawable.views[i].transform`): on the headset of 2026-10-27 the
/// left eye at (-30.9, -24.8, -10.3) mm and the right at (32.3, -24.6, -6.1) mm, x and y steady
/// to half a millimetre over the gaze, z loose by a centimetre. So an app opens a bare
/// compositor layer for a moment, runs this on it for some frames (it draws nothing: every
/// drawable is presented cleared, transparent), and hands the result's `eyeTransforms` to
/// `XRRealityKitPresenterConfiguration.eyeTransforms` for the presenter's space. The maths
/// (`Accumulator`, `average`) is on every platform, for the tests; the frame loop (`start`) is
/// the headset's.
public final class XREyeMeasurement: @unchecked Sendable {
    /// What a measurement found: the device anchor to each eye (left, then right), the
    /// translations averaged over the frames and the rotation the last frame's, with half the
    /// range of each axis of each eye's translation (the gaze's part and the tracker's noise,
    /// what a fixed pair cannot carry), the frames it is over, and for a settings line the
    /// distance between the first two eyes and their midpoint.
    public struct Result: Sendable, Equatable {
        public var eyeTransforms: [simd_float4x4]
        /// Half the range of each axis of each eye's translation over the frames, metres.
        public var spreads: [SIMD3<Float>]
        public var frames: Int

        public init(eyeTransforms: [simd_float4x4], spreads: [SIMD3<Float>], frames: Int) {
            self.eyeTransforms = eyeTransforms
            self.spreads = spreads
            self.frames = frames
        }

        /// Each eye's averaged translation, metres.
        public var positions: [SIMD3<Float>] {
            eyeTransforms.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        }

        /// The distance between the first two eyes, metres; zero with fewer than two.
        public var interpupillaryDistance: Float {
            let positions = positions
            return positions.count >= 2 ? simd_length(positions[1] - positions[0]) : 0
        }

        /// The midpoint of the first two eyes, metres (the view offset the nominal pair would
        /// need); the first eye's position with one, zero with none.
        public var midpoint: SIMD3<Float> {
            let positions = positions
            guard let first = positions.first else { return .zero }
            return positions.count >= 2 ? (first + positions[1]) / 2 : first
        }

        /// As a person reads it: "eyes L (-30.9, -24.8, -10.3) ±(0.4, 0.1, 12.3) mm · R (32.3,
        /// -24.6, -6.1) ±(0.0, 0.3, 14.1) mm · IPD 63.3 mm · 60 frames" (`EngineEyeStats`'s
        /// line, x right, y up, z back).
        public var description: String {
            var stats = EngineEyeStats()
            for (index, position) in positions.enumerated() {
                stats.eyes.append(EngineEyeStats.Eye())
                let spread = index < spreads.count ? spreads[index] : .zero
                stats.eyes[index].last = position
                stats.eyes[index].sum = position * Float(max(frames, 1))
                stats.eyes[index].low = position - spread
                stats.eyes[index].high = position + spread
                stats.eyes[index].samples = max(frames, 1)
            }
            return stats.description
        }
    }

    /// The running measurement: each frame's transforms added, the result read at any point.
    /// A frame with fewer eyes than an earlier one leaves the missing eyes as they were; one
    /// with more adds them.
    public struct Accumulator: Sendable, Equatable {
        private var stats = EngineEyeStats()
        private var lastTransforms: [simd_float4x4] = []

        public init() {}

        /// The frames added.
        public var frames: Int {
            stats.samples
        }

        /// Adds a frame's eyes, the device anchor to each view.
        public mutating func add(_ deviceFromViews: [simd_float4x4]) {
            guard !deviceFromViews.isEmpty else { return }
            stats.add(deviceFromViews: deviceFromViews)
            while lastTransforms.count < deviceFromViews.count {
                lastTransforms.append(matrix_identity_float4x4)
            }
            for (index, transform) in deviceFromViews.enumerated() {
                lastTransforms[index] = transform
            }
        }

        /// The eyes so far: each the last frame's transform with its translation replaced by
        /// the mean over the frames; nil before any frame.
        public var result: Result? {
            guard frames > 0 else { return nil }
            let transforms = stats.eyes.enumerated().map { index, eye -> simd_float4x4 in
                var transform = index < lastTransforms.count ? lastTransforms[index] : matrix_identity_float4x4
                transform.columns.3 = SIMD4<Float>(eye.mean.x, eye.mean.y, eye.mean.z, 1)
                return transform
            }
            return Result(eyeTransforms: transforms, spreads: stats.eyes.map(\.spread), frames: frames)
        }
    }

    /// The frames' eyes averaged: the translations' mean, the last frame's rotation, half
    /// the range of each axis; nil with no frame.
    public static func average(_ frames: [[simd_float4x4]]) -> Result? {
        var accumulator = Accumulator()
        for frame in frames {
            accumulator.add(frame)
        }
        return accumulator.result
    }

    /// The frames asked for.
    public let frameCount: Int
    private let lock = NSLock()
    private var accumulator = Accumulator()
    private var stopped = false

    /// A measurement over `frames` frames (60 by default, well under a second on the
    /// headset).
    public init(frames: Int = 60) {
        frameCount = max(1, frames)
    }

    /// Adds a frame's eyes; what the frame loop calls, and a test can.
    public func add(_ deviceFromViews: [simd_float4x4]) {
        lock.withLock { accumulator.add(deviceFromViews) }
    }

    /// The eyes so far (see `Accumulator.result`).
    public var result: Result? {
        lock.withLock { accumulator.result }
    }

    /// Whether the frames asked for have been measured.
    public var isComplete: Bool {
        lock.withLock { accumulator.frames >= frameCount }
    }

    /// Ends the measurement after the frame in hand; the completion gets what was measured.
    public func stop() {
        lock.withLock { stopped = true }
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }
}

#if os(visionOS)
    import CompositorServices
    import Metal

    public extension XREyeMeasurement {
        /// Runs the measurement on `layerRenderer` on a thread of its own and calls
        /// `completion` once, from that thread, with the eyes averaged over the frames asked
        /// for, or over the frames taken before the layer was invalidated (the space
        /// dismissed) or `stop()` was called, or nil when no frame gave a view; the result is
        /// printed too, so a console read off the headset has it. The frame loop
        /// is the compositor's minimal one: the next frame, its timing, an empty update, the
        /// wait for the optimal input time, the submission, the drawables, each built-in view's
        /// `transform` read, every drawable presented cleared to transparent (the room in a
        /// mixed space), the submission ended; a paused layer is waited on, as the engine's
        /// loop does. Nothing of the engine runs: no renderer, no ARKit session, no device
        /// anchor on the drawables.
        func start(layerRenderer: LayerRenderer, completion: @escaping @Sendable (Result?) -> Void) {
            let thread = Thread { [self] in
                run(layerRenderer: layerRenderer)
                let result = result
                print("XR eye measurement: " + (result.map { "\($0.description) (\($0.eyeTransforms.count) view\($0.eyeTransforms.count == 1 ? "" : "s"))" } ?? "no frame gave a view"))
                completion(result)
            }
            thread.name = "XR Eye Measurement"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        /// The frame loop, on the calling thread, until the frames asked for are measured, the
        /// layer is invalidated or `stop()` is called.
        func run(layerRenderer: LayerRenderer) {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                print("XR eye measurement: no Metal device; nothing measured")
                return
            }
            queue.label = "XR Eye Measurement"
            while !isStopped, !isComplete {
                switch layerRenderer.state {
                case .paused:
                    layerRenderer.waitUntilRunning()
                case .running:
                    measureFrame(layerRenderer: layerRenderer, queue: queue)
                case .invalidated:
                    return
                @unknown default:
                    return
                }
            }
        }

        /// One frame of the layer, through the compositor's phases (`CompositorFrameSource`
        /// has the same steps with the engine between): a frame without timing is let go as
        /// Apple's sample lets it go, one the compositor gives no drawables for was cancelled
        /// and is not ended, every other is presented cleared and ended whatever the layer's
        /// state meanwhile.
        private func measureFrame(layerRenderer: LayerRenderer, queue: MTLCommandQueue) {
            guard let frame = layerRenderer.queryNextFrame() else { return }
            guard let timing = frame.predictTiming() else { return }
            frame.startUpdate()
            frame.endUpdate()
            LayerRenderer.Clock().wait(until: timing.optimalInputTime, tolerance: .zero)
            frame.startSubmission()
            let drawables: [LayerRenderer.Drawable]
            if #available(visionOS 26.0, *) {
                drawables = frame.queryDrawables()
            } else {
                drawables = frame.queryDrawable().map { [$0] } ?? []
            }
            guard !drawables.isEmpty else { return }
            for drawable in drawables {
                var builtIn = true
                if #available(visionOS 26.0, *) {
                    builtIn = drawable.target == .builtIn
                }
                if builtIn {
                    add(drawable.views.map(\.transform))
                }
                Self.presentCleared(drawable, queue: queue)
            }
            frame.endSubmission()
        }

        /// Presents a drawable with every view's colour cleared to transparent and its depth
        /// cleared, drawing nothing: the compositor wants every drawable it handed out
        /// presented.
        private static func presentCleared(_ drawable: LayerRenderer.Drawable, queue: MTLCommandQueue) {
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            commandBuffer.label = "XR Eye Measurement Cleared Drawable"
            for viewIndex in drawable.views.indices
                where viewIndex < drawable.colorTextures.count && viewIndex < drawable.depthTextures.count
            {
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = drawable.colorTextures[viewIndex]
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                descriptor.depthAttachment.texture = drawable.depthTextures[viewIndex]
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .store
                descriptor.depthAttachment.clearDepth = 0.0
                if viewIndex < drawable.rasterizationRateMaps.count {
                    descriptor.rasterizationRateMap = drawable.rasterizationRateMaps[viewIndex]
                }
                commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }
#endif
