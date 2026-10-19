//
//  CompositorFrameSource.swift
//  UntoldEngineXR
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
    import ARKit
    import CompositorServices
    import Foundation
    import Metal
    import QuartzCore
    import simd
    import SwiftUI
    import UntoldEngine

    /// The headset's frames through Compositor Services: the `LayerRenderer`'s frames and their
    /// timing, the wait for the optimal input time and the half-rate pacing, the drawables with
    /// the runtime's device anchors and the capture-target rule, the foveation frames from the
    /// rasterization rate maps, the presentation, and the deadline accounting. `XRFrameLoop`
    /// drives it through `XRFrameSource` and knows none of this.
    public final class CompositorFrameSource: XRFrameSource, @unchecked Sendable {
        let layerRenderer: LayerRenderer
        let runtime: XRRuntime
        private let stopLock = NSLock()
        private var stopped = false

        // Foveation: the parameter data of each eye's rasterization rate map, copied every frame
        // (the maps follow the gaze) into a ring two slots deeper than the frames in flight —
        // the depth pyramid built on a frame carries its last eye's data into the culls of the
        // frame after (HZBPyramidFrame.rateMapData), which may still run when this frame's
        // slot comes round again with only the usual in-flight depth; and the copy is made as
        // the frame's eyes are acquired, before its pass takes its slot of the in-flight
        // semaphore, so one more frame than the semaphore's count may be in flight then.
        private var rateMapParameterBuffers: [[MTLBuffer?]] = Array(repeating: [nil, nil], count: maxInFlightCommandBuffers + 2)
        private var rateMapFrameCounter = 0
        private var loggedFoveationState: Bool?
        private var loggedCaptureTargetSkip = false
        private var loggedDrawableCount = 0
        /// Whether the compositor's frame timing budget has been printed (once per space).
        private var loggedFrameTimingBudget = false
        /// Whether the compositor clock's base has been checked against the media time (once).
        private var loggedClockBases = false
        /// Frames whose drawable's presentation time differed from the one predicted at the
        /// update: the game posed those frames for a slightly different instant than the head.
        public private(set) var presentationTimeRevisions = 0
        private var lastPresentationRevisionLogTime: CFTimeInterval = 0
        /// Frames whose GPU work finished after the compositor's rendering deadline. The deadline
        /// sits well before the presentation (15 ms on the headset), so a frame a few
        /// milliseconds past it is still shown on time; one past that margin has the display
        /// show the previous frame again and this one a refresh late, posed for an instant
        /// already past — a hop in a moving object that no counter of the loop's pacing sees.
        public var deadlineMisses: Int { deadlineLock.withLock { deadlineMissCount } }
        /// The longest a frame's GPU work finished after its deadline, in milliseconds.
        public var worstDeadlineOverrunMs: Double { deadlineLock.withLock { worstOverrunMs } }
        private let deadlineLock = NSLock()
        private var deadlineMissCount = 0
        private var worstOverrunMs = 0.0
        private var lastDeadlineLogTime: CFTimeInterval = 0
        /// The last second's frames: how many, how many late, their worst and summed overruns,
        /// the least slack any had before the deadline, and the longest wait skipped.
        private var secondFrames = 0
        private var secondLate = 0
        private var secondWorstMs = 0.0
        private var secondOverrunSumMs = 0.0
        private var secondLeastSlackMs = Double.infinity
        private var secondSkippedWaitMaxMs = 0.0
        private var secondGPUSumMs = 0.0
        /// The frames' GPU time after the frame before finished: the span of a frame's command
        /// buffer starts when the GPU takes it, which with frames queued is before the frame
        /// before is done, so the span overstates the frame's own work.
        private var secondOwnGPUSumMs = 0.0
        private var lastGPUEndTime: CFTimeInterval = 0
        private var secondPacedWaitSumMs = 0.0
        private var secondPacedWaits = 0
        /// The last second's frames past the deadline by more than its usable margin before the
        /// presentation (shown a refresh late), and the refreshes the display skipped beyond
        /// the pacing's cadence, from the spacing of the predicted presentations.
        private var secondMissed = 0
        private var secondSkipped = 0
        /// The automatic mode's current choice: waiting for the optimal input time, or not.
        private var automaticWaits = true
        /// The half-rate pacing: its policy, whether this frame is paced, the last second's
        /// longest GPU span, and its anchors: the refresh grid the frames are taken on, and the
        /// instant the last paced frame was taken at.
        private var halfRate = XRHalfRatePolicy()
        private var pacingActiveNow = false
        private var secondMaxGPUMs = 0.0
        /// When the compositor handed the loop its last frame, and the pacing's own grid: the
        /// instant it started from, on which the paced queries fall every cadence.
        private var lastFrameHandedAt: LayerRenderer.Clock.Instant?
        private var pacingOrigin: LayerRenderer.Clock.Instant?
        /// The last frame's predicted presentation, and the last second's spacing between
        /// consecutive ones: its sum, shortest and longest, the evenness of the frames shown.
        private var lastPredictedPresentation: LayerRenderer.Clock.Instant?
        private var secondSpacingSumMs = 0.0
        private var secondSpacingMinMs = Double.infinity
        private var secondSpacingMaxMs = 0.0
        private var secondSpacings = 0
        /// The last second's loop: how long the query for a frame blocked, how long the loop
        /// took from one handed frame to the next query, how far after the query the compositor
        /// predicted the presentation, and how far before it the rendering deadline sat.
        private var secondQueryBlockSumMs = 0.0
        private var secondLoopSumMs = 0.0
        private var secondPredictedAheadSumMs = 0.0
        private var secondDeadlineMarginSumMs = 0.0
        private var secondTimedFrames = 0
        /// Whether the loop is rendering every other refresh at the moment.
        public var halfRatePacingActive: Bool { deadlineLock.withLock { pacingActiveNow } }
        /// Whether the last frame waited for the compositor's optimal input time: the setting,
        /// or in the automatic mode what the measured deadline allowed.
        public var optimalInputWaitActive: Bool { deadlineLock.withLock { lastFrameWaited } }
        private var lastFrameWaited = true
        /// Whether the layer's depth format and the drawable's depth range have been printed.
        private var loggedDepthSetup = false
        /// The layer's depth format and the drawable's depth range (far, near), once a drawable
        /// has been seen: what the depth test can tell apart at a distance.
        public private(set) var depthSetupDescription = ""

        /// The frames of `layerRenderer`, posed by `runtime`, whose spatial input bridge the
        /// layer's spatial events feed from here on.
        @MainActor
        public init(layerRenderer: LayerRenderer, runtime: XRRuntime) {
            self.layerRenderer = layerRenderer
            self.runtime = runtime
            // Through the source, which is Sendable, and not the layer: the closure is called
            // off the main actor (the runtime's session monitor, the loop's thread).
            runtime.presenterStateDescription = { [weak self] in self?.layerStateDescription ?? "nil" }
            configureSpatialEventBridge()
        }

        @MainActor
        private func configureSpatialEventBridge() {
            let runtime = runtime
            layerRenderer.onSpatialEvent = { [weak runtime] events in
                runtime?.enqueueSpatialEvents(events)
            }
        }

        /// The layer's state as a word, for the runtime's diagnostics; read from any thread,
        /// as the loop reads the state.
        var layerStateDescription: String {
            String(describing: layerRenderer.state)
        }

        // MARK: - XRFrameSource

        public var colorPixelFormat: MTLPixelFormat { layerRenderer.configuration.colorFormat }
        public var depthPixelFormat: MTLPixelFormat { layerRenderer.configuration.depthFormat }
        /// The size the renderer's targets are first made at. The layer says nothing of its
        /// drawables' size before it hands one out, so this is a nominal size for the headset's
        /// eye textures; the loop fits the targets to the first drawable's.
        public var eyeSize: simd_float2 { simd_float2(2048, 1984) }

        private var isStopped: Bool {
            stopLock.lock()
            defer { stopLock.unlock() }
            return stopped
        }

        /// The next frame the compositor hands out, waiting while the layer is paused; nil once
        /// the layer is invalidated or the source was stopped.
        public func nextFrame() -> XRFrame? {
            while !isStopped {
                switch layerRenderer.state {
                case .paused:
                    layerRenderer.waitUntilRunning()

                case .running:
                    if let frame = takeFrame() {
                        return frame
                    }

                case .invalidated:
                    return nil

                @unknown default:
                    return nil
                }
            }
            return nil
        }

        public func stop() {
            stopLock.lock()
            stopped = true
            stopLock.unlock()
        }

        /// Takes a frame from the running layer: the half-rate pacing, the query, the timing
        /// prediction and the loop's measurements; nil when the compositor gives none, or no
        /// timing for it.
        private func takeFrame() -> Frame? {
            // The half-rate pacing waits here, before a frame is taken, so that the frames
            // rendered land on every other refresh, evenly, when one refresh is not enough for
            // a frame's GPU work; the display shows the previous frame again meanwhile.
            paceForHalfRate()

            // 1. Call queryNextFrame() to fetch the next frame to use for drawing
            let queryStart = LayerRenderer.Clock().now
            guard let frame = layerRenderer.queryNextFrame() else { return nil }
            let handedAt = LayerRenderer.Clock().now
            let loopMs = lastFrameHandedAt.map { Self.milliseconds($0.duration(to: queryStart)) } ?? 0
            lastFrameHandedAt = handedAt

            // 2. Call predictTiming to get the predicted render deadlines for code
            guard let timing = frame.predictTiming() else { return nil }

            // The instant the compositor predicts the frame will be shown, in the media-time
            // base: the game poses the frame for it in the update phase, and the head is posed
            // for the same instant at submission (the drawable's frameTiming, normally this
            // very value; notePresentationRevision counts the frames where it is not).
            let compositorPresentationTime = Self.mediaTime(of: timing.presentationTime)
            let predictedPresentationTime = compositorPresentationTime + presentationLeadSeconds()
            logClockBasesOnce()
            if let last = lastPredictedPresentation {
                let spacingMs = Self.milliseconds(last.duration(to: timing.presentationTime))
                deadlineLock.lock()
                secondSpacingSumMs += spacingMs
                secondSpacingMinMs = min(secondSpacingMinMs, spacingMs)
                secondSpacingMaxMs = max(secondSpacingMaxMs, spacingMs)
                secondSpacings += 1
                let periodMs = currentFrameTime.period * 1000.0
                if periodMs > 0 {
                    let expected = pacingActiveNow ? halfRate.cadenceRefreshes : 1
                    secondSkipped += max(0, Int((spacingMs / periodMs).rounded()) - expected)
                }
                deadlineLock.unlock()
            }
            lastPredictedPresentation = timing.presentationTime
            deadlineLock.lock()
            secondQueryBlockSumMs += Self.milliseconds(queryStart.duration(to: handedAt))
            secondLoopSumMs += loopMs
            secondPredictedAheadSumMs += Self.milliseconds(handedAt.duration(to: timing.presentationTime))
            secondDeadlineMarginSumMs += Self.milliseconds(timing.renderingDeadline.duration(to: timing.presentationTime))
            secondTimedFrames += 1
            deadlineLock.unlock()

            return Frame(
                frame: frame,
                prediction: timing,
                compositorPresentationTime: compositorPresentationTime,
                timing: XRFrameTiming(
                    presentationTime: predictedPresentationTime,
                    optimalInputTime: Self.mediaTime(of: timing.optimalInputTime),
                    renderingDeadline: Self.mediaTime(of: timing.renderingDeadline)
                ),
                source: self
            )
        }

        // MARK: - The wait and the pacing

        /// Whether this frame waits for the optimal input time, by the setting and, in the
        /// automatic mode, by what the last seconds' deadlines allowed. `skippedWaitMs` is how
        /// long the wait would be, kept for the automatic mode to know what resuming costs.
        private func waitsForOptimalInput(skippedWaitMs: Double) -> Bool {
            let waits: Bool
            deadlineLock.lock()
            switch xrOptimalInputWaitMode {
            case .always: waits = true
            case .never: waits = false
            case .automatic: waits = automaticWaits
            }
            if !waits {
                secondSkippedWaitMaxMs = max(secondSkippedWaitMaxMs, skippedWaitMs)
            }
            lastFrameWaited = waits
            deadlineLock.unlock()
            return waits
        }

        /// The half-rate pacing, before the next compositor frame is taken. With the pacing
        /// active, by the setting or by the policy when the frames run late, the queries fall
        /// on the pacing's own grid: the instant it started from, every `cadenceRefreshes`
        /// refreshes, exactly. The compositor hands out a frame on demand and predicts its
        /// presentation a fixed time after the query, so queries spaced an exact number of
        /// refreshes apart are shown an exact number of refreshes apart. (A wait aimed at the
        /// previous frame's presentation instant made every cadence three refreshes, the
        /// compositor predicting three ahead; a wait of a cadence less a lead spaced the frames
        /// unevenly.) A query up to a quarter refresh late still takes its slot. Nothing waits
        /// for the GPU: the next frame's work queues behind the previous one's, so the GPU
        /// stays busy and keeps its clock. Every frame taken is submitted: a frame taken and
        /// let go is never released by the compositor, and three of them abort the app.
        private func paceForHalfRate() {
            let active: Bool
            let cadence: Int
            deadlineLock.lock()
            switch xrFramePacing {
            case .fullRate: active = false
            case .halfRate: active = true
            case .halfRateWhenLate: active = halfRate.active
            }
            cadence = halfRate.cadenceRefreshes
            pacingActiveNow = active
            deadlineLock.unlock()
            guard active, let handed = lastFrameHandedAt else {
                pacingOrigin = nil
                return
            }
            let period = currentFrameTime.period
            guard period > 0 else { return }
            let clock = LayerRenderer.Clock()
            guard let origin = pacingOrigin else {
                pacingOrigin = handed
                return
            }
            let step = Double(cadence) * period
            let elapsed = Self.seconds(origin.duration(to: clock.now))
            let slots = max(1, ((elapsed - 0.25 * period) / step).rounded(.up))
            let target = origin.advanced(by: .seconds(slots * step))
            let waitMs = max(0, Self.milliseconds(clock.now.duration(to: target)))
            if waitMs > 0 {
                clock.wait(until: target, tolerance: .zero)
            }
            deadlineLock.lock()
            secondPacedWaitSumMs += waitMs
            secondPacedWaits += 1
            deadlineLock.unlock()
        }

        /// How far past the compositor's predicted presentation the frame is posed for: the
        /// refreshes the paced frames were measured to land after it, from how far past their
        /// deadline they finish; nothing without the pacing.
        private func presentationLeadSeconds() -> TimeInterval {
            deadlineLock.withLock { pacingActiveNow ? Double(halfRate.landingRefreshes) * currentFrameTime.period : 0 }
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000.0 + Double(parts.attoseconds) / 1e15
        }

        /// An instant of the compositor's clock as seconds in the `CACurrentMediaTime()` base:
        /// both count mach absolute time from the boot, the compositor clock's epoch.
        private static func mediaTime(of instant: LayerRenderer.Clock.Instant) -> TimeInterval {
            seconds(LayerRenderer.Clock.Instant.epoch.duration(to: instant))
        }

        private static func seconds(_ duration: Duration) -> TimeInterval {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }

        /// Prints once how far the compositor clock's epoch conversion is from the media time
        /// read at the same moment: the gap between the two reads, and nothing more, if the
        /// clocks share their base as the engine assumes.
        private func logClockBasesOnce() {
            guard !loggedClockBases else { return }
            loggedClockBases = true
            let epochBased = Self.mediaTime(of: LayerRenderer.Clock().now)
            let mediaTime = CACurrentMediaTime()
            print(String(format: "XR clock: the compositor epoch's time differs from the media time by %.3f ms", (epochBased - mediaTime) * 1000.0))
        }

        #if ENGINE_STATS_ENABLED
            /// Prints once how the compositor spaces a frame's optimal input time, rendering
            /// deadline and presentation.
            private func logFrameTimingBudgetOnce(_ timing: LayerRenderer.Frame.Timing) {
                guard !loggedFrameTimingBudget else { return }
                loggedFrameTimingBudget = true
                let toDeadline = timing.optimalInputTime.duration(to: timing.renderingDeadline)
                let toPresentation = timing.optimalInputTime.duration(to: timing.presentationTime)
                print(String(format: "XR frame timing: optimal input to rendering deadline %.2f ms, to presentation %.2f ms", Self.milliseconds(toDeadline), Self.milliseconds(toPresentation)))
            }
        #endif

        // MARK: - Drawables

        private func noteDrawableCount(_ drawables: [LayerRenderer.Drawable]) {
            if drawables.count != loggedDrawableCount {
                loggedDrawableCount = drawables.count
                let targets = drawables.map { drawable -> String in
                    if #available(visionOS 26.0, *) {
                        return drawable.target == .builtIn ? "built-in" : "capture"
                    }
                    return "built-in"
                }
                print("XR: \(drawables.count) drawable(s) per frame (\(targets.joined(separator: ", ")))")
            }
        }

        /// Whether the scene is drawn into a drawable. The built-in display always; another
        /// target (a capture of the view for recording or streaming) only while its textures are
        /// the size the frame's resources are allocated at — every sizeable resource is sized
        /// to one viewport, and a second size would reallocate them twice a frame.
        private func drawsScene(into drawable: LayerRenderer.Drawable) -> Bool {
            if #available(visionOS 26.0, *), drawable.target != .builtIn,
               let texture = drawable.colorTextures.first,
               renderInfo.viewPort != simd_float2(Float(texture.width), Float(texture.height))
            {
                if !loggedCaptureTargetSkip {
                    loggedCaptureTargetSkip = true
                    print("XR: a \(texture.width)×\(texture.height) capture drawable differs from the \(Int(renderInfo.viewPort.x))×\(Int(renderInfo.viewPort.y)) frame resources; presenting it cleared")
                }
                return false
            }
            return true
        }

        /// Presents a drawable with its colour cleared (the immersion mode's alpha) and its depth
        /// cleared, without drawing the scene: the compositor wants every drawable it handed out
        /// presented.
        private func presentCleared(_ drawable: LayerRenderer.Drawable) {
            guard let commandBuffer = renderInfo.commandQueue.makeCommandBuffer() else { return }
            commandBuffer.label = "XR Cleared Drawable"
            for viewIndex in drawable.views.indices
                where viewIndex < drawable.colorTextures.count && viewIndex < drawable.depthTextures.count
            {
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = drawable.colorTextures[viewIndex]
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: Double(getAlphaForImmersionMode()))
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

        /// Prints once what the depth test can tell apart: the layer's depth format and the
        /// drawable's depth range (far, near) the projection is built from.
        private func logDepthSetupOnce(_ drawable: LayerRenderer.Drawable) {
            if !loggedDepthSetup, let depthTexture = drawable.depthTextures.first {
                loggedDepthSetup = true
                let format: String
                switch depthTexture.pixelFormat {
                case .depth16Unorm: format = "depth16Unorm"
                case .depth32Float: format = "depth32Float"
                case .depth32Float_stencil8: format = "depth32Float_stencil8"
                default: format = "pixel format \(depthTexture.pixelFormat.rawValue)"
                }
                depthSetupDescription = String(format: "%@, range far %.3f near %.3f", format, drawable.depthRange.x, drawable.depthRange.y)
                print("XR depth: \(depthSetupDescription)")
            }
        }

        /// The ring slot of the next target's rate map parameters.
        private func nextRateMapSlot() -> Int {
            let rateMapSlot = rateMapFrameCounter % rateMapParameterBuffers.count
            rateMapFrameCounter += 1
            return rateMapSlot
        }

        /// The rasterization rate map the compositor made for a view, as the renderer draws
        /// through it, or nil when the frame is drawn uniformly: the layer configured without
        /// foveation (no maps; also the simulator) or `setRendering(.foveatedRendering(.disabled))`.
        /// The map's parameters go into this frame's slot of the ring for the shaders that decode
        /// them; the viewport is the view's in the map's screen space.
        private func makeFoveationFrame(
            drawable: LayerRenderer.Drawable,
            viewport: MTLViewport,
            viewIndex: Int,
            slot: Int
        ) -> XRFoveationFrame? {
            let rateMaps = drawable.rasterizationRateMaps
            let available = xrFoveatedRenderingEnabled && viewIndex < rateMaps.count && viewIndex < stereoEyeCount
            if loggedFoveationState != available {
                loggedFoveationState = available
                if available {
                    let rateMap = rateMaps[viewIndex]
                    let screen = rateMap.screenSize
                    let physical = rateMap.physicalSize(layer: 0)
                    print("✓ XR foveation: drawing through the compositor's rasterization rate maps, screen \(screen.width)×\(screen.height), textures \(physical.width)×\(physical.height) per eye; view texture map viewport \(viewport.originX),\(viewport.originY) \(viewport.width)×\(viewport.height)")
                } else if rateMaps.isEmpty {
                    print("XR foveation off: the layer provides no rasterization rate maps (isFoveationEnabled is false, or the simulator); drawing uniformly")
                } else {
                    print("XR foveation off by setting (.foveatedRendering(.disabled)); the layer's rate maps are ignored and the picture will be warped")
                }
            }
            guard available else { return nil }

            let rateMap = rateMaps[viewIndex]
            let sizeAndAlign = rateMap.parameterDataSizeAndAlign
            let align = max(1, sizeAndAlign.align)
            let length = max(16, (sizeAndAlign.size + align - 1) / align * align)
            if rateMapParameterBuffers[slot][viewIndex].map({ $0.length < length }) ?? true {
                let buffer = renderInfo.device.makeBuffer(length: length, options: .storageModeShared)
                buffer?.label = "XR Rate Map Parameters eye \(viewIndex) slot \(slot)"
                rateMapParameterBuffers[slot][viewIndex] = buffer
            }
            guard let buffer = rateMapParameterBuffers[slot][viewIndex],
                  let data = XRRasterizationRateMapData(rateMap: rateMap, buffer: buffer)
            else {
                Logger.logWarning(message: "XR foveation: could not copy the rate map parameters for eye \(viewIndex); drawing this eye uniformly")
                return nil
            }
            if let texture = drawable.colorTextures.indices.contains(viewIndex) ? drawable.colorTextures[viewIndex] : nil,
               Int(data.physicalSize.x) != texture.width || Int(data.physicalSize.y) != texture.height
            {
                Logger.logWarning(message: "XR foveation: eye \(viewIndex) rate map physical size \(data.physicalSize) differs from its texture \(texture.width)×\(texture.height)")
            }
            // The eye's viewport in the map's screen space. In the dedicated layout the view
            // is the whole texture, so it is the map's screen size at the origin; the view's own
            // texture map viewport is logged above for the day another layout needs it.
            let screenViewport = MTLViewport(
                originX: 0, originY: 0,
                width: Double(data.screenSize.x), height: Double(data.screenSize.y),
                znear: 0, zfar: 1
            )
            return XRFoveationFrame(rateMap: rateMap, viewport: screenViewport, rateMapData: data)
        }

        // MARK: - Deadlines

        /// Counts a frame whose GPU work finished after the compositor's rendering deadline, keeps
        /// the longest overrun, and prints once a second how many of that second's frames were
        /// late and by how much. Runs on the GPU's completion thread.
        private func noteGPUCompletion(at gpuEnd: CFTimeInterval, start gpuStart: CFTimeInterval, deadline: TimeInterval, presentation: TimeInterval) {
            let overrunMs = (gpuEnd - deadline) * 1000.0
            let usableMarginMs = XRHalfRatePolicy.usableMarginMs(deadlineMarginMs: (presentation - deadline) * 1000.0)
            let now = CACurrentMediaTime()
            var report: String?
            deadlineLock.lock()
            secondFrames += 1
            secondLeastSlackMs = min(secondLeastSlackMs, -overrunMs)
            let gpuMs = (gpuEnd - gpuStart) * 1000.0
            secondMaxGPUMs = max(secondMaxGPUMs, gpuMs)
            secondGPUSumMs += gpuMs
            secondOwnGPUSumMs += max(0, (gpuEnd - max(gpuStart, lastGPUEndTime)) * 1000.0)
            lastGPUEndTime = max(lastGPUEndTime, gpuEnd)
            if overrunMs > 0 {
                deadlineMissCount += 1
                secondLate += 1
                secondOverrunSumMs += overrunMs
                secondWorstMs = max(secondWorstMs, overrunMs)
                worstOverrunMs = max(worstOverrunMs, overrunMs)
                if overrunMs > usableMarginMs {
                    secondMissed += 1
                }
            }
            if lastDeadlineLogTime == 0 {
                lastDeadlineLogTime = now
            } else if now - lastDeadlineLogTime >= 1.0 {
                if secondLate > 0 || secondSkipped > 0 {
                    let mode: String
                    switch xrOptimalInputWaitMode {
                    case .always: mode = "always"
                    case .never: mode = "never"
                    case .automatic: mode = "automatic"
                    }
                    let meanOverrunMs = secondLate > 0 ? secondOverrunSumMs / Double(secondLate) : 0
                    report = String(format: "XR frame timing: the GPU finished after the rendering deadline on %d of %d frames in the last second (worst +%.2f ms, mean +%.2f ms; %d late frames so far; input-time wait %@, %@%@)", secondLate, secondFrames, secondWorstMs, meanOverrunMs, deadlineMissCount, mode, lastFrameWaited ? "waited" : "not waited", pacingActiveNow ? String(format: "; half rate, every %d refreshes, landing +%d", halfRate.cadenceRefreshes, halfRate.landingRefreshes) : "")
                    report = (report ?? "") + String(format: "; GPU %.1f ms a frame (%.1f ms its own after the frame before), longest %.1f%@", secondGPUSumMs / Double(secondFrames), secondOwnGPUSumMs / Double(secondFrames), secondMaxGPUMs, secondPacedWaits > 0 ? String(format: ", paced wait %.1f ms", secondPacedWaitSumMs / Double(secondPacedWaits)) : "")
                    report = (report ?? "") + String(format: "; %d past the deadline's margin, %d refreshes skipped", secondMissed, secondSkipped)
                    if secondTimedFrames > 0 {
                        let timed = Double(secondTimedFrames)
                        report = (report ?? "") + String(format: "; the query blocked %.1f ms, the loop took %.1f ms between frames, the presentation was predicted %.1f ms after the query, the deadline %.1f ms before it", secondQueryBlockSumMs / timed, secondLoopSumMs / timed, secondPredictedAheadSumMs / timed, secondDeadlineMarginSumMs / timed)
                    }
                    if secondSpacings > 0 {
                        report = (report ?? "") + String(format: "; presentations spaced %.1f ms (%.1f to %.1f)", secondSpacingSumMs / Double(secondSpacings), secondSpacingMinMs, secondSpacingMaxMs)
                    }
                    // With the GPU pass timing on, every pass of the last resolved frame, heaviest
                    // first, with their sum: what a second of frames well past the deadline spent
                    // its time on, and how much of the frame's span lies between passes.
                    if meanOverrunMs > 2.0, GPUPassTiming.shared.isEnabled {
                        let passes = GPUPassTiming.shared.lastFrame().passes.sorted { $0.totalMs > $1.totalMs }
                        if !passes.isEmpty {
                            let sum = passes.reduce(0.0) { $0 + $1.totalMs }
                            let list = passes.map { String(format: "%@ %.2f", $0.label, $0.totalMs) }.joined(separator: ", ")
                            report = (report ?? "") + String(format: "\nXR frame timing: the last frame's passes, %.1f ms in all (a label sums both eyes): ", sum) + list
                        }
                    }
                }
                // The automatic mode: stop waiting once a second had late frames (one in
                // twenty or more); wait again once a second's least slack would have covered
                // the longest wait skipped, with a margin.
                if xrOptimalInputWaitMode == .automatic, secondFrames > 0 {
                    if automaticWaits, secondLate * 20 >= secondFrames {
                        automaticWaits = false
                        let line = String(format: "XR frame timing: %d of %d frames late: encoding without the wait for the optimal input time", secondLate, secondFrames)
                        report = report.map { $0 + "\n" + line } ?? line
                    } else if !automaticWaits, secondLeastSlackMs.isFinite, secondLeastSlackMs > secondSkippedWaitMaxMs + 1.5 {
                        automaticWaits = true
                        let line = String(format: "XR frame timing: the least slack of %.2f ms covers the skipped wait of %.2f ms: waiting for the optimal input time again", secondLeastSlackMs, secondSkippedWaitMaxMs)
                        report = report.map { $0 + "\n" + line } ?? line
                    }
                }
                // The half-rate pacing, by its policy when the setting leaves it to the frames.
                if xrFramePacing == .halfRateWhenLate {
                    let waitStillToSkip = xrOptimalInputWaitMode == .automatic && automaticWaits
                    let meanLateMs = secondLate > 0 ? secondOverrunSumMs / Double(secondLate) : 0
                    let periodMs = currentFrameTime.period * 1000.0
                    let marginMs = secondTimedFrames > 0 ? secondDeadlineMarginSumMs / Double(secondTimedFrames) : 0
                    switch halfRate.secondEnded(frames: secondFrames, missed: secondMissed, skipped: secondSkipped, meanOverrunMs: meanLateMs, meanGPUDurationMs: secondGPUSumMs / Double(secondFrames), periodMs: periodMs, deadlineMarginMs: marginMs, waitStillToSkip: waitStillToSkip) {
                    case .entered:
                        let line = String(format: "XR frame timing: %d of %d frames past the deadline's margin, %d refreshes skipped, no wait left to skip: rendering every other refresh", secondMissed, secondFrames, secondSkipped)
                        report = report.map { $0 + "\n" + line } ?? line
                    case .left:
                        let line = String(format: "XR frame timing: the frame's GPU work of %.2f ms fits the refresh of %.2f ms: rendering every refresh again", secondGPUSumMs / Double(secondFrames), periodMs)
                        report = report.map { $0 + "\n" + line } ?? line
                    case .none:
                        break
                    }
                } else {
                    halfRate.reset()
                }
                secondFrames = 0
                secondLate = 0
                secondWorstMs = 0
                secondOverrunSumMs = 0
                secondLeastSlackMs = .infinity
                secondSkippedWaitMaxMs = 0
                secondMaxGPUMs = 0
                secondGPUSumMs = 0
                secondOwnGPUSumMs = 0
                secondPacedWaitSumMs = 0
                secondPacedWaits = 0
                secondMissed = 0
                secondSkipped = 0
                secondQueryBlockSumMs = 0
                secondLoopSumMs = 0
                secondPredictedAheadSumMs = 0
                secondDeadlineMarginSumMs = 0
                secondTimedFrames = 0
                secondSpacingSumMs = 0
                secondSpacingMinMs = .infinity
                secondSpacingMaxMs = 0
                secondSpacings = 0
                lastDeadlineLogTime = now
            }
            deadlineLock.unlock()
            if let report {
                print(report)
            }
        }

        /// Counts the frames whose final presentation time (the drawable's) differs from the
        /// one predicted at the update, which the game posed the frame for.
        private func notePresentationRevision(predicted: TimeInterval, final: TimeInterval) {
            let difference = final - predicted
            guard abs(difference) > 0.0005 else { return }
            presentationTimeRevisions += 1
            let now = CACurrentMediaTime()
            if presentationTimeRevisions == 1 || now - lastPresentationRevisionLogTime >= 1.0 {
                lastPresentationRevisionLogTime = now
                print(String(format: "XR frame timing: the drawable's presentation time differs from the predicted one by %.2f ms (%d frames so far)", difference * 1000.0, presentationTimeRevisions))
            }
        }

        // MARK: - A frame

        /// One of the compositor's frames: its update, the wait for its optimal input time, its
        /// drawables as targets, their presentation.
        final class Frame: XRFrame {
            let timing: XRFrameTiming
            private let frame: LayerRenderer.Frame
            private let prediction: LayerRenderer.Frame.Timing
            /// The presentation the compositor predicted, in the media-time base, without the
            /// pacing's lead: what the drawable's own timing is checked against.
            private let compositorPresentationTime: TimeInterval
            private let source: CompositorFrameSource
            private var drawables: [LayerRenderer.Drawable] = []
            /// Which drawables were handed to the loop as targets; the rest are presented cleared.
            private var handedOut: [Bool] = []

            init(frame: LayerRenderer.Frame, prediction: LayerRenderer.Frame.Timing, compositorPresentationTime: TimeInterval, timing: XRFrameTiming, source: CompositorFrameSource) {
                self.frame = frame
                self.prediction = prediction
                self.compositorPresentationTime = compositorPresentationTime
                self.timing = timing
                self.source = source
            }

            func beginUpdate() {
                // 3. Call startUpdate() to mark the start of the update phase
                frame.startUpdate()
            }

            func endUpdate() {
                // 6. Call endupdate() to mark the end of the update phase
                frame.endUpdate()
            }

            func waitForDrawingTime() {
                // 7. Call wait(until:tolerace) to puase your render loop until the optimal rendering time
                // The wait for the compositor's optimal input time: the head pose is queried as late
                // as the frame allows. Without it the frame is encoded now, so the GPU starts about
                // the wait's length earlier and the head is predicted from earlier; the automatic
                // mode waits while the frames meet the deadline and not while they do not.
                let waitLengthMs = max(0, CompositorFrameSource.milliseconds(LayerRenderer.Clock().now.duration(to: prediction.optimalInputTime)))
                if source.waitsForOptimalInput(skippedWaitMs: waitLengthMs) {
                    LayerRenderer.Clock().wait(until: prediction.optimalInputTime, tolerance: .zero)
                }
                #if ENGINE_STATS_ENABLED
                    source.logFrameTimingBudgetOnce(prediction)
                #endif
            }

            func beginDrawing() -> Bool {
                guard source.layerRenderer.state == .running else { return false }
                // 8. Call startSubmission() to mark the start of submission phase
                frame.startSubmission()
                return true
            }

            func acquireEyes() -> [XREyes] {
                // 9. visionOS 26 hands a frame one drawable per target (the built-in display, and a
                // capture target while the view is recorded or streamed); a layer with foveation
                // or a render quality set aborts the app if the single-drawable query is used.
                if #available(visionOS 26.0, *) {
                    drawables = frame.queryDrawables()
                } else {
                    drawables = frame.queryDrawable().map { [$0] } ?? []
                }
                handedOut = Array(repeating: false, count: drawables.count)
                // No drawables (shutdown/teardown, or the compositor cancelled the frame): the
                // frame is already invalid and the loop must not end the drawing.
                guard !drawables.isEmpty else { return [] }
                source.noteDrawableCount(drawables)

                // The frame's presentation time is checked on its first drawable (the built-in
                // display); a capture drawable shares the timing.
                var presentationChecked = false
                var targets: [XREyes] = []
                for (index, drawable) in drawables.enumerated() {
                    // 10. Fetch the predicted device anchor from ARKit using the frameTiming information, and
                    // apply the anchor to your frame
                    let presentationInstant = drawable.frameTiming.presentationTime
                    let presentationTimeCA: TimeInterval = CompositorFrameSource.mediaTime(of: presentationInstant)
                    if !presentationChecked {
                        presentationChecked = true
                        source.notePresentationRevision(predicted: compositorPresentationTime, final: presentationTimeCA)
                    }
                    // The runtime's anchor for the instant, or its cached one. With neither,
                    // drawable.deviceAnchor stays nil: the target is presented with no eye drawn.
                    let deviceAnchor = source.runtime.deviceAnchor(forPresentationAt: presentationTimeCA)
                    if let deviceAnchor {
                        drawable.deviceAnchor = deviceAnchor
                    }

                    // A drawable the scene is not drawn into is presented cleared at endDrawing.
                    guard source.drawsScene(into: drawable) else { continue }
                    handedOut[index] = true
                    source.logDepthSetupOnce(drawable)
                    // A capture drawable (a recording or a stream of the view) is drawn from
                    // its own pose, so it must not advance the frame-to-frame state the
                    // built-in display relies on: the temporal history and the depth pyramid.
                    var primary = true
                    if #available(visionOS 26.0, *) {
                        primary = drawable.target == .builtIn
                    }
                    let rateMapSlot = source.nextRateMapSlot()
                    let eyes = drawable.views.enumerated().map { viewIndex, view in
                        XREye(
                            colorTexture: drawable.colorTextures[viewIndex],
                            depthTexture: drawable.depthTextures[viewIndex],
                            deviceFromView: view.transform,
                            projection: drawable.computeProjection(convention: .rightUpBack, viewIndex: viewIndex),
                            viewport: view.textureMap.viewport,
                            foveation: source.makeFoveationFrame(
                                drawable: drawable,
                                viewport: view.textureMap.viewport,
                                viewIndex: viewIndex,
                                slot: rateMapSlot
                            )
                        )
                    }
                    targets.append(XREyes(
                        originFromDevice: deviceAnchor?.originFromAnchorTransform,
                        eyes: eyes,
                        primary: primary,
                        index: index
                    ))
                }
                return targets
            }

            func present(_ target: XREyes, commandBuffer: MTLCommandBuffer) {
                let drawable = drawables[target.index]
                drawable.encodePresent(commandBuffer: commandBuffer)
                guard target.primary else { return }

                // The instant the GPU must have finished by for the compositor to show this frame at
                // its presentation time, in the base of the command buffer's own timestamps.
                let deadline = CompositorFrameSource.mediaTime(of: drawable.frameTiming.renderingDeadline)
                let presentation = CompositorFrameSource.mediaTime(of: drawable.frameTiming.presentationTime)
                let source = source
                commandBuffer.addCompletedHandler { [weak source] cb in
                    source?.noteGPUCompletion(at: cb.gpuEndTime, start: cb.gpuStartTime, deadline: deadline, presentation: presentation)
                }
            }

            func endDrawing() {
                for (index, drawable) in drawables.enumerated() where !handedOut[index] {
                    source.presentCleared(drawable)
                }
                guard source.layerRenderer.state == .running else { return }
                frame.endSubmission()
            }
        }
    }
#endif
