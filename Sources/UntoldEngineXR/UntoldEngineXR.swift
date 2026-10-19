//
//  UntoldEngineXR.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
    import CompositorServices
    import Foundation
    import Metal
    import simd
    import UntoldEngine

    public enum UntoldImmersionMode {
        case none
        case mixed
        case full
    }

    /// The same enum under a name of its own: the module and the class `UntoldEngineXR` share a
    /// name, so another module that also imports `UntoldEngine` (which has an `UntoldImmersionMode`
    /// too) cannot spell `UntoldEngineXR.UntoldImmersionMode` to tell this one apart.
    public typealias XRImmersionMode = UntoldImmersionMode

    /// The engine on a headset, in three pieces: the runtime (`XRRuntime`: the ARKit session,
    /// the device anchors, the lighting probe, the spatial input), the source of its frames
    /// (`XRFrameSource`: Compositor Services through `CompositorFrameSource`, or another
    /// presenter) and the loop that draws each frame (`XRFrameLoop`). A game uses it as it
    /// always has: `init(layerRenderer:)`, `setupCallbacks`, `start`, `runLoop` on a thread of
    /// its own, `stop`.
    public final class UntoldEngineXR: @unchecked Sendable {
        private var renderer: UntoldRenderer?
        private let runtime: XRRuntime
        private let frameSource: any XRFrameSource
        private var loop: XRFrameLoop?

        /// The compositor's pacing and deadlines, when the frames come from Compositor
        /// Services; the counters below read it, and are 0 (false, empty) for another source.
        private var compositor: CompositorFrameSource? {
            frameSource as? CompositorFrameSource
        }

        /// The headset's most recent pose (origin-from-device transform, the
        /// ARKit world origin), or nil before tracking runs. Readable from
        /// any thread; updated every rendered frame.
        public var currentDevicePose: simd_float4x4? {
            runtime.currentDevicePose
        }

        /// The headset's pose predicted for `presentationTime`: the instant the frame being
        /// updated is posed for (`frameTime.presentationTime` inside the game's update), so
        /// that something a game places on the head sits where the frame's eyes look. The
        /// most recent pose while the prediction has no answer; nil before tracking runs.
        public func devicePose(forPresentationAt presentationTime: TimeInterval) -> simd_float4x4? {
            runtime.devicePose(predictedFor: presentationTime)
        }

        /// Frames whose drawable's presentation time differed from the one predicted at the
        /// update: the game posed those frames for a slightly different instant than the head.
        public var presentationTimeRevisions: Int { compositor?.presentationTimeRevisions ?? 0 }
        /// Frames whose GPU work finished after the compositor's rendering deadline. The deadline
        /// sits well before the presentation (15 ms on the headset), so a frame a few
        /// milliseconds past it is still shown on time; one past that margin has the display
        /// show the previous frame again and this one a refresh late, posed for an instant
        /// already past — a hop in a moving object that no counter of the loop's pacing sees.
        public var deadlineMisses: Int { compositor?.deadlineMisses ?? 0 }
        /// The longest a frame's GPU work finished after its deadline, in milliseconds.
        public var worstDeadlineOverrunMs: Double { compositor?.worstDeadlineOverrunMs ?? 0 }
        /// Whether the loop is rendering every other refresh at the moment.
        public var halfRatePacingActive: Bool { compositor?.halfRatePacingActive ?? false }
        /// Whether the last frame waited for the compositor's optimal input time: the setting,
        /// or in the automatic mode what the measured deadline allowed.
        public var optimalInputWaitActive: Bool { compositor?.optimalInputWaitActive ?? true }
        /// The layer's depth format and the drawable's depth range (far, near), once a drawable
        /// has been seen: what the depth test can tell apart at a distance.
        public var depthSetupDescription: String { compositor?.depthSetupDescription ?? "" }

        /// The engine presenting through Compositor Services: the layer's frames, the headset's
        /// runtime. Nil without a Metal device or a command queue.
        @MainActor
        public convenience init?(layerRenderer: LayerRenderer, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
            guard let device else { return nil }
            let runtime = XRRuntime()
            let source = CompositorFrameSource(layerRenderer: layerRenderer, runtime: runtime)
            self.init(frameSource: source, runtime: runtime, device: device)
        }

        /// The engine drawing the frames of `frameSource`, posed by `runtime`: the renderer's
        /// targets take the source's formats and eye size. Nil without a command queue; with
        /// one, the runtime's observers and ARKit providers are started here.
        @MainActor
        public init?(frameSource: any XRFrameSource, runtime: XRRuntime, device: MTLDevice) {
            guard let commandQueue = device.makeCommandQueue() else { return nil }
            self.frameSource = frameSource
            self.runtime = runtime

            // The headset's render path, forward, wherever this loop renders: the platform's
            // default on visionOS, and what a Mac rendering a remote immersive space takes too,
            // unless the game chose a path.
            adoptXRRenderPathUnlessChosen()
            runtime.start()

            guard let untoldrenderer = UntoldRenderer.createXR(
                configuration: nil,
                device: device,
                commandQueue: commandQueue,
                colorPixelFormat: frameSource.colorPixelFormat,
                depthPixelFormat: frameSource.depthPixelFormat,
                viewPort: frameSource.eyeSize
            ) else {
                print("Failed to initialize the renderer")
                return
            }

            renderer = untoldrenderer
            loop = XRFrameLoop(renderer: untoldrenderer, source: frameSource, runtime: runtime)
        }

        @MainActor
        public func setupCallbacks(
            gameUpdate: @escaping (_ deltaTime: Float) -> Void,
            handleInput: @escaping () -> Void
        ) {
            renderer?.setupCallbacks(gameUpdate: gameUpdate, handleInput: handleInput)
        }

        /// Installs the game's per-frame callbacks with the frame's time: the instant the
        /// compositor predicts the frame will be shown, which the head pose is predicted for
        /// too, so an object posed for it keeps step with the head.
        public func setupCallbacks(
            frameUpdate: @escaping (_ frame: FrameTime) -> Void,
            handleInput: @escaping () -> Void
        ) {
            renderer?.setupCallbacks(frameUpdate: frameUpdate, handleInput: handleInput)
        }

        public func enqueueSpatialInputSnapshot(_ snapshot: XRSpatialInputSnapshot) {
            runtime.enqueueSpatialInputSnapshot(snapshot)
        }

        public func clearSpatialInput() {
            runtime.clearSpatialInput()
        }

        /// Lets `runLoop` draw frames; nothing without a renderer.
        public func start() {
            loop?.start()
        }

        /// Ends the loop after the frame it is on, and the runtime's monitors, probe and planes.
        public func stop() {
            loop?.stop()
            runtime.stop()
        }

        /// Draws frames until the presenter is gone or `stop()` is called. Blocking: call it on
        /// a thread of its own, after `start()`.
        public func runLoop() {
            loop?.run()
        }

        public func setImmersionMode(xrImmersionMode: UntoldImmersionMode) {
            switch xrImmersionMode {
            case .full:
                renderInfo.immersionStyle = .full
            case .mixed:
                renderInfo.immersionStyle = .mixed
            default:
                break
            }
        }

        public func setXRLightingMode(_ mode: RuntimeEnvironmentLightingMode) {
            runtime.setXRLightingMode(mode)
        }

        public func setXRLightingContribution(_ factor: Float) {
            runtime.setXRLightingContribution(factor)
        }

        public func xrEnvironmentLightingDiagnostics() -> XREnvironmentLightingDiagnostics {
            runtime.xrEnvironmentLightingDiagnostics()
        }
    }

#endif
