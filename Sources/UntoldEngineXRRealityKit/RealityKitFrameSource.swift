//
//  RealityKitFrameSource.swift
//  UntoldEngineXRRealityKit
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
import UntoldEngineXR

/// The engine's frames from a `XRRealityKitPresenter`: each ticket the presenter posts is one
/// frame, posed for a lead past the moment it is taken; its eyes are the ticket's textures with
/// the presenter's depth, placed a nominal eye distance apart on the headset's pose for that
/// instant; the frame is drawn in the ticket's own command buffer, which after the eyes carries
/// the grids' unprojection and, committed by the loop, hands RealityKit the frame. No wait and
/// no deadline: RealityKit shows the previous frame again while a frame takes longer than its
/// refresh. With the presenter's rate map, every eye carries it (`XREye.foveation`) with the
/// map's screen as its viewport, and the grids are unprojected through it.
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
public final class RealityKitFrameSource: XRFrameSource, @unchecked Sendable {
    /// The headset's pose (the origin from the device) for a presentation instant, or nil while
    /// it is not tracked: the runtime's device anchor on a headset, a test's own pose on a Mac.
    public typealias PoseProvider = @Sendable (_ presentationTime: TimeInterval) -> simd_float4x4?

    let mailbox: XRTicketMailbox
    let depthTextures: [MTLTexture]
    let nearestDepthBuffers: [MTLBuffer]
    let unproject: XRGridUnprojectPass
    let grid: XRPresenterGrid
    let foveation: XRPresenterFoveation?
    let textureSize: SIMD2<Int>
    let configuration: XRRealityKitPresenterConfiguration
    let statistics: XRPresenterStatistics
    let pose: PoseProvider
    let projection: simd_float4x4

    /// The frames of `presenter`, posed by `pose`.
    @MainActor
    public init(presenter: XRRealityKitPresenter, pose: @escaping PoseProvider) {
        mailbox = presenter.mailbox
        depthTextures = presenter.depthTextures
        nearestDepthBuffers = presenter.nearestDepthBuffers
        unproject = presenter.unproject
        grid = presenter.grid
        foveation = presenter.foveation
        textureSize = presenter.textureSize
        configuration = presenter.configuration
        statistics = presenter.statistics
        projection = presenter.configuration.projection
        self.pose = pose
    }

    // MARK: - XRFrameSource

    public var colorPixelFormat: MTLPixelFormat { .bgra8Unorm_srgb }

    public var depthPixelFormat: MTLPixelFormat { .depth32Float }

    /// The presenter's textures' size: the rate map's physical size when it has one, since the
    /// loop sizes the renderer's targets from the eyes' textures.
    public var eyeSize: simd_float2 { simd_float2(Float(textureSize.x), Float(textureSize.y)) }

    /// The next ticket as a frame, waiting for the presenter to post one; nil once the presenter
    /// stopped or the source was.
    public func nextFrame() -> XRFrame? {
        guard let ticket = mailbox.take() else { return nil }
        let takenAt = CACurrentMediaTime()
        statistics.noteTicketTaken(ageSeconds: takenAt - ticket.postedAt)
        return Frame(ticket: ticket, takenAt: takenAt, source: self)
    }

    public func stop() {
        mailbox.close()
    }

    // MARK: - A frame

    /// One ticket's frame. Its command buffer is committed exactly once: by the loop after the
    /// drawing, or here when the frame is let go before it (the loop stopped, no drawing).
    final class Frame: XRFrame {
        let timing: XRFrameTiming
        private let ticket: XRPresenterTicket
        private let takenAt: TimeInterval
        private let source: RealityKitFrameSource
        private var handedOut = false

        init(ticket: XRPresenterTicket, takenAt: TimeInterval, source: RealityKitFrameSource) {
            self.ticket = ticket
            self.takenAt = takenAt
            self.source = source
            timing = XRFrameTiming(presentationTime: takenAt + ticket.settings.leadSeconds)
        }

        deinit {
            if !handedOut {
                ticket.commandBuffer.commit()
            }
        }

        func beginUpdate() {}

        func endUpdate() {}

        /// RealityKit sets no moment for the drawing to begin.
        func waitForDrawingTime() {}

        func beginDrawing() -> Bool { true }

        /// One target: the headset's pose for the frame's instant, and the two eyes a nominal
        /// distance apart on it, drawn into the ticket's textures and the presenter's depth.
        /// Through the presenter's rate map, each eye carries it and its viewport is the map's
        /// screen (the loop's scene passes draw through the map in that space; the final pass
        /// into the texture copies physical pixels one to one); without one, the texture.
        func acquireEyes() -> [XREyes] {
            let originFromDevice = source.pose(timing.presentationTime)
            if originFromDevice == nil {
                source.statistics.notePoseMissing()
            }
            let foveation = source.foveation?.frame
            let eyes = ticket.colorTextures.indices.map { eye in
                let color = ticket.colorTextures[eye]
                return XREye(
                    colorTexture: color,
                    depthTexture: source.depthTextures[eye],
                    deviceFromView: source.configuration.deviceFromView(eye: eye),
                    projection: source.projection,
                    viewport: foveation?.viewport ?? MTLViewport(originX: 0, originY: 0, width: Double(color.width), height: Double(color.height), znear: 0, zfar: 1),
                    foveation: foveation
                )
            }
            return [XREyes(originFromDevice: originFromDevice, eyes: eyes, primary: true, index: 0)]
        }

        /// The ticket's own command buffer: RealityKit's replace calls bound the frame's textures
        /// and grid buffers to it.
        func makeCommandBuffer(for _: XREyes) -> MTLCommandBuffer? {
            handedOut = true
            ticket.commandBuffer.label = "XR presenter frame \(ticket.serial)"
            return ticket.commandBuffer
        }

        /// After the eyes: each grid placed from its eye's depth, and the edge band's mesh with
        /// it when the ticket carries one, in the same command buffer, which the loop commits;
        /// RealityKit shows the frame when it completes. Without a pose nothing was drawn, so the
        /// eyes' textures are cleared to transparent instead and the grids keep their places (the
        /// band's indices, blitted degenerate when the ticket was posted, draw nothing).
        func present(_ target: XREyes, commandBuffer: MTLCommandBuffer) {
            if let originFromDevice = target.originFromDevice {
                for (index, eye) in target.eyes.enumerated() where index < ticket.gridBuffers.count {
                    source.unproject.encode(
                        commandBuffer: commandBuffer,
                        depth: eye.depthTexture,
                        nearestDepths: source.nearestDepthBuffers[index],
                        vertices: ticket.gridBuffers[index],
                        indices: ticket.settings.adaptiveDiagonal && index < ticket.indexBuffers.count ? ticket.indexBuffers[index] : nil,
                        bandVertices: index < ticket.bandBuffers.count ? ticket.bandBuffers[index] : nil,
                        bandIndices: index < ticket.bandIndexBuffers.count ? ticket.bandIndexBuffers[index] : nil,
                        grid: source.grid,
                        originFromEye: simd_mul(originFromDevice, eye.deviceFromView),
                        projection: eye.projection,
                        farShell: source.configuration.farShellMetres,
                        tearThreshold: ticket.settings.tearThresholdMetres,
                        skirtTexels: ticket.settings.skirtTexels,
                        adaptiveDiagonal: ticket.settings.adaptiveDiagonal,
                        rateMapData: source.foveation?.rateMapData,
                        cellTexels: Float(source.foveation?.cellTexels ?? 0),
                        label: "XR grid unproject eye \(index)"
                    )
                }
            } else {
                for eye in target.eyes {
                    let descriptor = MTLRenderPassDescriptor()
                    descriptor.colorAttachments[0].texture = eye.colorTexture
                    descriptor.colorAttachments[0].loadAction = .clear
                    descriptor.colorAttachments[0].storeAction = .store
                    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
                }
            }
            let statistics = source.statistics
            statistics.noteFrameEncoded(seconds: CACurrentMediaTime() - takenAt)
            commandBuffer.addCompletedHandler { buffer in
                statistics.noteGPU(seconds: max(0, buffer.gpuEndTime - buffer.gpuStartTime))
            }
        }

        func endDrawing() {}
    }
}

#if os(visionOS)
    @available(visionOS 2.0, *)
    public extension RealityKitFrameSource {
        /// The frames of `presenter`, posed by the runtime's device anchors: the predicted one for
        /// the frame's instant, else the runtime's fallbacks.
        @MainActor
        convenience init(presenter: XRRealityKitPresenter, runtime: XRRuntime) {
            self.init(presenter: presenter) { presentationTime in
                runtime.deviceAnchor(forPresentationAt: presentationTime)?.originFromAnchorTransform
            }
        }
    }
#endif
