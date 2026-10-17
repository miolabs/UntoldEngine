//
//  XRFrameSource.swift
//  UntoldEngineXR
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import simd
import UntoldEngine

/// One eye of a frame's target: the textures to draw it into, where the eye sits on the
/// headset, its projection, its viewport in the texture, and the rasterization rate map it is
/// drawn through when the presenter foveates.
public struct XREye {
    public let colorTexture: MTLTexture
    public let depthTexture: MTLTexture
    /// The eye's transform in the headset's own space: the offset from the device's centre
    /// (the compositor's `view.transform`). With the target's `originFromDevice` it makes the
    /// view matrix the renderer draws with, `(originFromDevice × deviceFromView)⁻¹`.
    public let deviceFromView: simd_float4x4
    /// The projection the presenter wants for this eye (asymmetric per eye on a headset).
    public let projection: simd_float4x4
    /// The eye's viewport in its texture: the whole texture in the dedicated layout, or, under
    /// a rate map, the view's rectangle in the map's screen space.
    public let viewport: MTLViewport
    /// The rate map the eye is drawn through, or nil when it is drawn uniformly.
    public let foveation: XRFoveationFrame?

    public init(
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        deviceFromView: simd_float4x4,
        projection: simd_float4x4,
        viewport: MTLViewport,
        foveation: XRFoveationFrame? = nil
    ) {
        self.colorTexture = colorTexture
        self.depthTexture = depthTexture
        self.deviceFromView = deviceFromView
        self.projection = projection
        self.viewport = viewport
        self.foveation = foveation
    }
}

/// One target of a frame to draw: where the headset is, from its origin, and the eyes. No
/// pose while the headset is not tracked (`originFromDevice` nil): the target's pass still
/// runs and the target is presented, but no eye is drawn into it, as the compositor asks.
public struct XREyes {
    /// The headset's pose for the frame's presentation instant, in the space its tracking
    /// began in, or nil when no pose is known.
    public let originFromDevice: simd_float4x4?
    public let eyes: [XREye]
    /// The headset's own display, whose eyes advance the frame-to-frame state the display
    /// relies on (the temporal history, the depth pyramid). False for another target the
    /// presenter hands over, a capture of the view for a recording or a stream: drawn from
    /// its own pose, it advances nothing.
    public let primary: Bool
    /// The target's place among the frame's targets, for the presenter to tell them apart at
    /// `present`.
    public let index: Int

    public init(originFromDevice: simd_float4x4?, eyes: [XREye], primary: Bool = true, index: Int = 0) {
        self.originFromDevice = originFromDevice
        self.eyes = eyes
        self.primary = primary
        self.index = index
    }
}

/// When a frame is predicted to be shown and the moments the presenter sets for it, in the
/// `CACurrentMediaTime()` base.
public struct XRFrameTiming: Sendable, Equatable {
    /// Seconds at which the frame is posed for: the presentation the presenter predicts, plus
    /// any lead the source adds for where its frames land.
    public let presentationTime: TimeInterval
    /// Seconds at which the presenter wants the drawing to begin, or nil when it has no such
    /// moment.
    public let optimalInputTime: TimeInterval?
    /// Seconds by which the GPU work must be done for the frame to be shown on time, or nil
    /// when the presenter sets none.
    public let renderingDeadline: TimeInterval?

    public init(presentationTime: TimeInterval, optimalInputTime: TimeInterval? = nil, renderingDeadline: TimeInterval? = nil) {
        self.presentationTime = presentationTime
        self.optimalInputTime = optimalInputTime
        self.renderingDeadline = renderingDeadline
    }
}

/// One frame a presenter asked for, through the phases a compositor wants them in: an update,
/// a wait for the right moment, then the drawing of each target and its presentation.
public protocol XRFrame: AnyObject {
    var timing: XRFrameTiming { get }
    func beginUpdate()
    func endUpdate()
    /// Waits until the moment the presenter wants the drawing to begin, if it has one.
    func waitForDrawingTime()
    /// Begins the drawing; false when the frame is no longer wanted.
    func beginDrawing() -> Bool
    /// The targets to draw, the headset's display first. Empty when the presenter gives none
    /// for this frame: nothing is drawn or presented then, and the drawing is not ended.
    func acquireEyes() -> [XREyes]
    /// The command buffer a target is drawn in, when the presenter has one of its own for the
    /// frame (RealityKit binds a frame's textures to the command buffer its replace calls were
    /// made on); nil, the default, and the loop makes one on the engine's queue. The loop
    /// commits it after the target's presentation.
    func makeCommandBuffer(for target: XREyes) -> MTLCommandBuffer?
    /// Hands a target to the presenter, encoded after its eyes.
    func present(_ target: XREyes, commandBuffer: MTLCommandBuffer)
    func endDrawing()
}

public extension XRFrame {
    func makeCommandBuffer(for _: XREyes) -> MTLCommandBuffer? { nil }
}

/// Where the frames come from: the headset through Compositor Services, another presenter,
/// or a test with textures of its own.
public protocol XRFrameSource: AnyObject {
    /// The formats of the targets' textures, known before the first frame so that the
    /// renderer's own targets can be made to match.
    var colorPixelFormat: MTLPixelFormat { get }
    var depthPixelFormat: MTLPixelFormat { get }
    /// The size of one eye's textures as far as the source knows it before its first frame;
    /// the loop fits the renderer's targets to the first eye it draws.
    var eyeSize: simd_float2 { get }
    /// The next frame, waiting for the presenter to ask for one; nil once the presenter is
    /// gone or the source was stopped.
    func nextFrame() -> XRFrame?
    /// Ends the source: `nextFrame` returns nil from now on.
    func stop()
}
