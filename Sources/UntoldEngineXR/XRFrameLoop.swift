//
//  XRFrameLoop.swift
//  UntoldEngineXR
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import QuartzCore
import simd
import UntoldEngine

/// What the loop asks of the XR runtime around each frame, through which the headset's input
/// and position reach the engine. A loop without a runtime (a test on a Mac) skips these.
public protocol XRFrameLoopRuntime: AnyObject {
    /// Before the frame's update: the spatial input gathered since the last frame goes to the
    /// input system when `allowed` (the scene is ready and nothing is loading); otherwise it is
    /// cleared.
    func updateSpatialInput(allowed: Bool)
    /// The headset's position now, for the camera the streaming and LOD systems read, or nil
    /// while the headset has never been tracked.
    func headPositionForStreaming() -> simd_float3?
    /// A command buffer slot took `waitMs` to come free, at `phase` "initial-timeout" (the
    /// first wait timed out) or "acquired" (the slot came late): the runtime says what it knows.
    func noteCommandBufferStall(waitMs: Double, phase: String)
}

/// Draws the scene for a headset, frame after frame, on a thread of its own, from wherever
/// the frames come (`XRFrameSource`): for each frame, the update posed for the frame's
/// presentation instant, the wait for the presenter's drawing time, then for each target the
/// culling once, each eye, the depth pyramid, the presentation and the stats, in that order,
/// with the engine's in-flight semaphore. Nothing here belongs to one presenter.
public final class XRFrameLoop: @unchecked Sendable {
    private let renderer: UntoldRenderer
    private let source: any XRFrameSource
    private let runtime: (any XRFrameLoopRuntime)?

    private let lock = NSLock()
    private var running = false
    private var drawnFrames = 0

    // Reuse render pass descriptors to avoid allocation churn (2 eyes × 90 FPS = 180 allocs/sec)
    private let passDescriptorLeft = MTLRenderPassDescriptor()
    private let passDescriptorRight = MTLRenderPassDescriptor()

    public init(renderer: UntoldRenderer, source: any XRFrameSource, runtime: (any XRFrameLoopRuntime)?) {
        self.renderer = renderer
        self.source = source
        self.runtime = runtime
    }

    /// Frames in which the display's eyes were drawn, for the tests.
    public var framesDrawn: Int {
        lock.lock()
        defer { lock.unlock() }
        return drawnFrames
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Lets `run` draw frames; without it, `run` returns at once.
    public func start() {
        lock.lock()
        running = true
        lock.unlock()
    }

    /// Ends the loop after the frame it is on. The source is left as it is: a stopped loop can
    /// be started and run again while the presenter still hands out frames.
    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Draws frames until the source ends or `stop()` is called. Blocking: call it on a thread
    /// of its own.
    public func run() {
        while true {
            var shouldExit = false
            autoreleasepool {
                guard isRunning, let frame = source.nextFrame() else {
                    shouldExit = true
                    return
                }
                draw(frame)
            }

            if shouldExit { break }
        }
    }

    /// Performs exactly one frame of rendering.
    private func draw(_ frame: any XRFrame) {
        // 3. Call startUpdate() to mark the start of the update phase
        frame.beginUpdate()
        #if ENGINE_STATS_ENABLED
            let xrFrameStartTime = CACurrentMediaTime()
            EngineStatsMonitor.shared.beginFrame(timestampSeconds: xrFrameStartTime)
            RenderStatsCollector.shared.reset()
        #endif

        // Snapshot loading gate once per frame to keep update/submission behavior consistent.
        let loading = AssetLoadingGate.shared.isLoadingAny
        let sceneReady = isSceneReady()
        let allowSpatialInputProcessing = !loading && sceneReady

        // Drive the progressive asset loader from the main thread.
        // run() runs on the visionOS compositor render thread, so tick() (which
        // requires the main thread via dispatchPrecondition) must be dispatched here.
        // This mirrors what UntoldEngine.swift does inside draw() on the MTKViewDelegate
        // main-thread path. Without this, progressive jobs never advance in XR.
        DispatchQueue.main.async {
            ProgressiveAssetLoader.shared.tick()
        }

        // 4. Update spatial input state from queued events
        runtime?.updateSpatialInput(allowed: allowSpatialInputProcessing)

        // 5. Perform any rendering-related work that doesn't rely on the device anchor info

        // Always sync the physical headset position into ECS camera components, even while
        // assets are loading. setXRCameraWorldPosition only writes three fields on the
        // camera entity — it never touches mesh entities being mutated by the loading pipeline,
        // so there is no race. Without this, the streaming systems resume from the pre-load
        // camera position after a long load, causing a one-tick position jump for any distance
        // that accumulated while the user was walking during the load.
        if let position = runtime?.headPositionForStreaming() {
            renderer.setXRCameraWorldPosition(position)
        }

        if !loading {
            renderer.updateXR(presentationTime: frame.timing.presentationTime, useExternalStatsLifecycle: true)
        }

        // 6. Call endupdate() to mark the end of the update phase
        frame.endUpdate()

        // 7. Wait until the presenter's optimal rendering time: the head pose is queried as late
        // as the frame allows.
        #if ENGINE_STATS_ENABLED
            let xrWaitStart = CACurrentMediaTime()
        #endif
        frame.waitForDrawingTime()
        #if ENGINE_STATS_ENABLED
            let xrWaitSeconds = CACurrentMediaTime() - xrWaitStart
            let xrWaitMs = xrWaitSeconds * 1000.0
            EngineStatsMonitor.shared.update { snapshot in
                snapshot.timing.xrWaitMs = xrWaitMs
            }
        #endif

        // The compositor or app state can transition while waiting. If not running anymore,
        // skip submission entirely to avoid using an invalid frame.
        #if ENGINE_STATS_ENABLED
            let drawableWaitStart = CACurrentMediaTime()
        #endif
        guard isRunning, frame.beginDrawing() else { return }

        // 8. The submission phase has begun
        #if ENGINE_STATS_ENABLED
            let xrSubmissionStart = CACurrentMediaTime()
            // The frame's pacing, for its stages: the two waits on the presenter, for its
            // drawing time and then for its drawables (Compositor Services hands both out at
            // a fixed phase of the refresh), which are not the frame's work.
            let xrPacingSeconds = xrWaitSeconds + (xrSubmissionStart - drawableWaitStart)
        #endif

        // 9. Encode any drawing commands that depend on the device position or orientation.
        let targets = frame.acquireEyes()
        guard !targets.isEmpty else {
            #if ENGINE_STATS_ENABLED
                renderer.finalizeXRStatsAndMonitors(frameStartTime: xrFrameStartTime)
            #else
                renderer.finalizeXRStatsAndMonitors(frameStartTime: 0.0)
            #endif
            // No targets (shutdown/teardown, or the compositor cancelled the frame): the
            // frame is already invalid and the drawing must not be ended.
            return
        }

        // Re-check loading state right before render pass to catch any mutations that started
        // after our initial snapshot. This provides a second layer of protection against races.
        let loadingNow = AssetLoadingGate.shared.isLoadingAny
        let effectiveLoading = loading || loadingNow

        for target in targets {
            #if ENGINE_STATS_ENABLED
                submit(target, frame: frame, loading: effectiveLoading, frameBegin: xrFrameStartTime, pacing: xrPacingSeconds)
            #else
                submit(target, frame: frame, loading: effectiveLoading, frameBegin: 0, pacing: 0)
            #endif
        }
        #if ENGINE_STATS_ENABLED
            let xrEncodeMs = (CACurrentMediaTime() - xrSubmissionStart) * 1000.0
            EngineStatsMonitor.shared.update { snapshot in
                snapshot.timing.encodeMs = xrEncodeMs
            }
            renderer.finalizeXRStatsAndMonitors(frameStartTime: xrFrameStartTime)
        #else
            renderer.finalizeXRStatsAndMonitors(frameStartTime: 0.0)
        #endif
        frame.endDrawing()
    }

    /// One target's pass: the culling once, each eye, the depth pyramid, the presentation,
    /// in one command buffer under the engine's in-flight semaphore. `frameBegin` is the
    /// instant the loop began the frame and `pacing` the seconds it then waited on the
    /// presenter, for its drawing time and for its drawables, for the frame's stages (zeros
    /// without stats).
    private func submit(_ target: XREyes, frame: any XRFrame, loading: Bool, frameBegin: CFTimeInterval, pacing: CFTimeInterval) {
        // A capture target (a recording or a stream of the view) is drawn from its own pose, so
        // it must not advance the frame-to-frame state the built-in display relies on: the
        // temporal history and the depth pyramid.
        TemporalAntiAliasing.shared.historyUpdatesEnabled = target.primary
        defer { TemporalAntiAliasing.shared.historyUpdatesEnabled = true }
        // Wait for available command buffer slot to prevent unbounded memory growth
        let semaphoreWaitStart = CACurrentMediaTime()
        let firstWaitResult = commandBufferSemaphore.wait(timeout: .now() + .milliseconds(100))
        if firstWaitResult == .timedOut {
            let waitMs = (CACurrentMediaTime() - semaphoreWaitStart) * 1000.0
            runtime?.noteCommandBufferStall(waitMs: waitMs, phase: "initial-timeout")
            commandBufferSemaphore.wait()
        }
        let semaphoreWaitMs = (CACurrentMediaTime() - semaphoreWaitStart) * 1000.0
        if semaphoreWaitMs > 16.0 {
            runtime?.noteCommandBufferStall(waitMs: semaphoreWaitMs, phase: "acquired")
        }

        // The presenter's own command buffer for the target when it has one, else one of ours.
        guard let commandBuffer = frame.makeCommandBuffer(for: target) ?? renderInfo.commandQueue.makeCommandBuffer() else {
            // Failed to create command buffer - release semaphore
            commandBufferSemaphore.signal()
            return
        }
        GPUPassTiming.shared.beginFrame(device: renderInfo.device)
        #if ENGINE_STATS_ENABLED
            let renderTotalStart = CACurrentMediaTime()
        #endif
        renderInfo.currentInFlightFrameSlot = acquireUniformFrameSlot()

        // Update viewport to match actual drawable size (per-eye texture dimensions). With
        // foveation on, that is the rate map's physical size: every texture of the frame is
        // allocated at it, while viewports and clip space live in the map's screen size.
        if let firstColorTexture = target.eyes.first?.colorTexture {
            let actualViewPort = simd_float2(Float(firstColorTexture.width), Float(firstColorTexture.height))
            if renderInfo.viewPort != actualViewPort {
                renderInfo.viewPort = actualViewPort
                renderer.initSizeableResources()
                print("✓ Updated VisionOS viewport to: \(actualViewPort)")
            }
        }

        // Update visible entity list only when not loading (avoids reading mutating ECS data).
        // When loading, we render from the last-known-good visible list.
        if !loading {
            visibleEntityIds = tripleVisibleEntities.snapshotForRead(frame: cullFrameIndex)
        }

        // Skip render prep (culling, gaussian, bitonic) while loading.
        // The render graph still executes using the stale visibleEntityIds.
        if !loading {
            SceneRootTransform.shared.updateIfNeeded()
            #if ENGINE_STATS_ENABLED
                let renderPrepStart = CACurrentMediaTime()
                let cullingStart = CACurrentMediaTime()
            #endif
            EngineProfiler.shared.beginScope(.renderPrep)
            performFrustumCulling(commandBuffer: commandBuffer)
            #if ENGINE_STATS_ENABLED
                let cullingMs = (CACurrentMediaTime() - cullingStart) * 1000.0
                EngineStatsMonitor.shared.update { snapshot in
                    snapshot.timing.cullingMs += cullingMs
                }
            #endif
            EngineProfiler.shared.beginScope(.gaussianCull)
            executeGaussianFrustumCulling(commandBuffer)
            EngineProfiler.shared.endScope(.gaussianCull)

            executeGaussianPreprocess(commandBuffer)

            EngineProfiler.shared.beginScope(.gaussianSort)
            executeRadixSort(commandBuffer)
            EngineProfiler.shared.endScope(.gaussianSort)
            EngineProfiler.shared.endScope(.renderPrep)
            #if ENGINE_STATS_ENABLED
                let renderPrepMs = (CACurrentMediaTime() - renderPrepStart) * 1000.0
                EngineStatsMonitor.shared.update { snapshot in
                    snapshot.timing.renderPrepMs += renderPrepMs
                }
            #endif
        }

        // No pose: the pass still runs and the target is presented, with no eye drawn.
        if let originFromDevice = target.originFromDevice {
            for (viewIndex, eye) in target.eyes.enumerated() {
                let deviceFromView: simd_float4x4 = eye.deviceFromView
                var cameraMatrix: simd_float4x4 = matrix_multiply(originFromDevice, deviceFromView)

                cameraMatrix = simd_inverse(cameraMatrix)

                let projection: simd_float4x4 = eye.projection

                // Reuse pre-allocated pass descriptor to avoid allocation churn
                let passDescriptor = viewIndex == 0 ? passDescriptorLeft : passDescriptorRight
                passDescriptor.colorAttachments[0].texture = eye.colorTexture
                passDescriptor.colorAttachments[0].storeAction = .store
                passDescriptor.colorAttachments[0].loadAction = .clear

                passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: Double(getAlphaForImmersionMode()))

                passDescriptor.depthAttachment.texture = eye.depthTexture
                passDescriptor.depthAttachment.loadAction = .clear
                passDescriptor.depthAttachment.storeAction = .store
                passDescriptor.depthAttachment.clearDepth = 0.0

                renderInfo.currentEye = viewIndex
                // The eye's rasterization rate map (foveation), for the passes that draw the
                // scene; the final pass into the presenter's textures copies physical pixels
                // one to one and keeps passDescriptor without it.
                renderInfo.xrFoveation = eye.foveation

                #if ENGINE_STATS_ENABLED
                    let encodeStart = CACurrentMediaTime()
                #endif
                EngineProfiler.shared.beginScope(.encode)
                // call the visionXR render graph
                renderer.renderXR(commandBuffer: commandBuffer, passDescriptor: passDescriptor, viewMatrix: cameraMatrix, projectionMatrix: projection, eyeIndex: viewIndex)
                EngineProfiler.shared.endScope(.encode)
                #if ENGINE_STATS_ENABLED
                    let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000.0
                    EngineStatsMonitor.shared.update { snapshot in
                        snapshot.timing.encodeMs += encodeMs
                    }
                #endif
            }
        }

        // Build the HZB depth pyramid once after both eyes are rendered.
        // In stereo mode the mono pyramid (from the last eye rendered) is used
        // for both per-eye VP occlusion tests in executeFrustumCulling. A capture
        // target's depth is seen from its own pose and does not replace it.
        if target.primary {
            buildHZBDepthPyramid(commandBuffer)
        }

        frame.present(target, commandBuffer: commandBuffer)

        EngineProfiler.shared.attach(to: commandBuffer, label: "XRFrame")

        // Add completion handler to signal semaphore when GPU work is done
        commandBuffer.addCompletedHandler { cb in
            #if ENGINE_STATS_ENABLED
                // The frame's GPU time beyond the previous frame's: the two overlap on the
                // GPU, and the command buffer's own span would count the overlap twice.
                EngineStatsMonitor.shared.recordGPUCompletion(gpuStartTime: cb.gpuStartTime, gpuEndTime: cb.gpuEndTime)
            #else
                _ = cb
            #endif
            commandBufferSemaphore.signal()
        }

        GPUPassTiming.shared.endFrame(commandBuffer)
        frame.willCommit(commandBuffer)
        #if ENGINE_STATS_ENABLED
            let submitStart = CACurrentMediaTime()
            if target.primary {
                // The display's frame split into its stages, as the RealityKit presenter
                // splits its own: the CPU frame from the loop's beginning of the frame (the
                // pacing left out) to this commit, the wait to the GPU's start, the GPU's raw
                // span. The handler, added after the commit instant is stamped, carries it by
                // value; whether the GPU ended past the presenter's rendering deadline is the
                // presenter's own verdict on the frame being late.
                let deadline = frame.timing.renderingDeadline
                commandBuffer.addCompletedHandler { cb in
                    let now = CACurrentMediaTime()
                    let stages = EngineFrameStages(
                        begin: frameBegin, pacing: pacing, committed: submitStart,
                        gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime, now: now
                    )
                    let ended = cb.gpuEndTime > 0 ? cb.gpuEndTime : now
                    EngineStatsMonitor.shared.recordFrameCompletion(stages, pastDeadline: deadline.map { ended > $0 } ?? false)
                }
            }
        #else
            _ = frameBegin
            _ = pacing
        #endif
        commandBuffer.commit()
        #if ENGINE_STATS_ENABLED
            let submitMs = (CACurrentMediaTime() - submitStart) * 1000.0
            let renderTotalMs = (CACurrentMediaTime() - renderTotalStart) * 1000.0
            EngineStatsMonitor.shared.update { snapshot in
                snapshot.timing.submitMs += submitMs
                snapshot.timing.renderTotalMs += renderTotalMs
            }
        #endif

        if target.primary, target.originFromDevice != nil, !target.eyes.isEmpty {
            lock.lock()
            drawnFrames += 1
            lock.unlock()
        }
    }
}
