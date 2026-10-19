//
//  XRFrameLoopTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import QuartzCore
import simd
@testable import UntoldEngine
@testable import UntoldEngineXR
import XCTest

/// The loop that draws for a headset (`XRFrameLoop`), run on the Mac with frames of a source
/// of the test's own: each frame's eyes are drawn in order from one command buffer that also
/// carries the frame's culling and its depth pyramid, the renderer's targets take the eyes'
/// size, a frame the source gives no targets for is neither drawn nor presented, a capture
/// target is drawn but advances nothing, and the loop ends when it is stopped or the source
/// ends.
@MainActor
final class XRFrameLoopTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)

    /// Lit cubes of a unit about the origin, and the active camera five units in front of
    /// them, looking at them, where the fake frames pose the headset: enough objects for the
    /// occlusion test to want its pyramid.
    override func initializeAssets() {
        for (index, x) in [Float(0), -1.5, 1.5].enumerated() {
            let cube = createEntity()
            setEntityName(entityId: cube, name: "Cube\(index)")
            setEntityMeshDirect(entityId: cube, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Cube\(index)")
            translateTo(entityId: cube, position: simd_float3(x, 0, 0))
        }
        if let camera = CameraSystem.shared.activeCamera {
            cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 5), target: .zero, up: simd_float3(0, 1, 0))
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        viewportBefore = renderInfo.viewPort
        // The engine's targets for a headset, as createXR sets them: stereo, the left eye first.
        renderInfo.isXRStereoMode = true
        renderInfo.currentEye = 0
        // The background is one colour, so that a corner tells the cubes from it.
        renderSkyBackground = false
    }

    override func tearDown() async throws {
        renderInfo.isXRStereoMode = false
        renderInfo.currentEye = 0
        renderInfo.xrFoveation = nil
        renderInfo.viewPort = viewportBefore
        renderer.initSizeableResources()
        TemporalAntiAliasing.shared.historyUpdatesEnabled = true
        destroyAllEntities()
        try await super.tearDown()
    }

    private func makeLoop(_ source: any XRFrameSource) -> XRFrameLoop {
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        loop.start()
        return loop
    }

    private func brightness(_ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int {
        Int(pixel.r) + Int(pixel.g) + Int(pixel.b)
    }

    private func assertShowsTheCubes(_ eye: MTLTexture, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let middle = FakeFrames.pixel(of: eye, x: eye.width / 2, y: eye.height / 2)
        let corner = FakeFrames.pixel(of: eye, x: 4, y: 4)
        let farCorner = FakeFrames.pixel(of: eye, x: eye.width - 5, y: eye.height - 5)
        // The corners show the background; the middle shows a lit cube.
        XCTAssertEqual(brightness(corner), brightness(farCorner), accuracy: 6, "\(name) shows the same background in both corners: \(corner), \(farCorner)", file: file, line: line)
        XCTAssertGreaterThan(abs(brightness(middle) - brightness(corner)), 40, "\(name) shows the cube in the middle: \(middle) over \(corner)", file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(5)
        while condition() == false {
            guard Date() < deadline else {
                throw XCTSkip("the loop did not get there in time", file: file, line: line)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Tests

    func test_theEyesOfEachFrame_areDrawnInOrder_fromOneCommandBuffer() throws {
        // The culling of one frame is drawn a frame or two later, as in the engine's own loop:
        // a few frames, and the last one is looked at.
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (256, 192), count: 6)
        let loop = makeLoop(frames)

        loop.run()
        try XCTUnwrap(frames.frames.last?.presentedIn.last).waitUntilCompleted()

        XCTAssertEqual(loop.framesDrawn, 6)
        XCTAssertEqual(renderInfo.viewPort, simd_float2(256, 192), "the engine's targets took the eye's size")
        XCTAssertTrue(renderInfo.isXRStereoMode)
        for (index, eye) in frames.colorTextures.enumerated() {
            assertShowsTheCubes(eye, "eye \(index)")
        }
        for frame in frames.frames {
            XCTAssertEqual(frame.phases, ["beginUpdate", "endUpdate", "wait", "beginDrawing", "acquire", "present 0", "willCommit", "endDrawing"])
            XCTAssertEqual(frame.presentedIn.count, 1, "one command buffer a frame: the culling, both eyes, the pyramid and the presentation")
        }
        // Each eye was drawn with its own view, the right eye after the left: what the renderer
        // keeps of the last frame.
        let expected = frames.expectedViewMatrices()
        XCTAssertTrue(compareMatrices(renderInfo.xrEye0View, expected[0]), "the left eye's view")
        XCTAssertTrue(compareMatrices(renderInfo.xrEye1View, expected[1]), "the right eye's view")
        XCTAssertFalse(compareMatrices(expected[0], expected[1]), "the eyes differ by their distance")
        XCTAssertEqual(renderInfo.currentEye, 1, "the right eye is drawn last")
        XCTAssertNil(renderInfo.xrFoveation, "the source draws uniformly")
    }

    func test_theDepthPyramid_isBuiltForTheDisplay_onceItsEyesAreDrawn() throws {
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (128, 96), count: 4)
        let loop = makeLoop(frames)
        renderInfo.hzbIsValid = false

        loop.run()
        try XCTUnwrap(frames.frames.last?.presentedIn.last).waitUntilCompleted()

        XCTAssertEqual(loop.framesDrawn, 4)
        XCTAssertTrue(renderInfo.hzbIsValid, "the pyramid was built after the eyes, for the next frame's occlusion test")
    }

    func test_aCaptureTarget_isDrawnFromItsOwnPose_andAdvancesNothing() throws {
        // A frame with the display and a capture of the view, then one with only a capture.
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (128, 96), count: 3)
        frames.captureTarget = true
        let loop = makeLoop(frames)
        loop.run()
        try XCTUnwrap(frames.frames.last?.presentedIn.last).waitUntilCompleted()
        XCTAssertEqual(loop.framesDrawn, 3)
        for frame in frames.frames {
            XCTAssertEqual(frame.phases, ["beginUpdate", "endUpdate", "wait", "beginDrawing", "acquire", "present 0", "willCommit", "present 1", "willCommit", "endDrawing"])
            XCTAssertEqual(frame.presentedIn.count, 2, "each target has a command buffer of its own")
        }
        XCTAssertTrue(renderInfo.hzbIsValid)

        renderInfo.hzbIsValid = false
        let capture = FakeFrames(device: renderInfo.device, eyeSize: (128, 96), count: 1)
        capture.captureTarget = true
        capture.displayTarget = false
        let captureLoop = makeLoop(capture)
        captureLoop.run()
        try XCTUnwrap(capture.frames.last?.presentedIn.last).waitUntilCompleted()

        XCTAssertEqual(captureLoop.framesDrawn, 0, "a capture target is not a frame of the display")
        XCTAssertEqual(capture.frames[0].phases, ["beginUpdate", "endUpdate", "wait", "beginDrawing", "acquire", "present 0", "willCommit", "endDrawing"])
        for (index, eye) in capture.captureColorTextures.enumerated() {
            assertShowsTheCubes(eye, "capture eye \(index)")
        }
        XCTAssertFalse(renderInfo.hzbIsValid, "no pyramid from a capture: its depth is seen from its own pose")
        XCTAssertTrue(TemporalAntiAliasing.shared.historyUpdatesEnabled, "the history updates are back on after the capture")
    }

    func test_aFrameWithoutTargets_isNeitherDrawnNorPresented() {
        let frame = FakeFrames.Frame(targets: [])
        let loop = makeLoop(SingleFrame(frame: frame))

        loop.run()

        XCTAssertEqual(frame.phases, ["beginUpdate", "endUpdate", "wait", "beginDrawing", "acquire"], "the drawing is not ended: the frame is already invalid")
        XCTAssertTrue(frame.presentedIn.isEmpty)
        XCTAssertEqual(loop.framesDrawn, 0)
    }

    func test_aFrameWithoutAPose_isPresentedWithNoEyeDrawn() throws {
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (64, 48), count: 1)
        frames.originFromDevice = nil
        let loop = makeLoop(frames)

        loop.run()
        try XCTUnwrap(frames.frames.last?.presentedIn.last).waitUntilCompleted()

        XCTAssertEqual(frames.frames[0].phases, ["beginUpdate", "endUpdate", "wait", "beginDrawing", "acquire", "present 0", "willCommit", "endDrawing"], "the presenter wants every target it handed out presented")
        XCTAssertEqual(loop.framesDrawn, 0)
        for (index, eye) in frames.colorTextures.enumerated() {
            let middle = FakeFrames.pixel(of: eye, x: 32, y: 24)
            XCTAssertEqual(brightness(middle), 0, "eye \(index) is left as it was: nothing drawn")
        }
    }

    func test_stopEndsTheLoop_afterTheFrameItIsOn() throws {
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (64, 48), count: nil)
        let loop = makeLoop(frames)
        let thread = Thread { loop.run() }
        thread.start()
        try waitUntil { loop.framesDrawn >= 2 }

        loop.stop()

        try waitUntil { thread.isFinished }
        let drawn = loop.framesDrawn
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(loop.framesDrawn, drawn, "no frame after the stop")
        XCTAssertFalse(frames.isStopped, "the source is left as it is")
    }

    func test_theSourceEnding_endsTheLoop() throws {
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (64, 48), count: nil)
        let loop = makeLoop(frames)
        let thread = Thread { loop.run() }
        thread.start()
        try waitUntil { loop.framesDrawn >= 1 }

        frames.stop()

        try waitUntil { thread.isFinished }
        XCTAssertNil(frames.nextFrame())
    }

    func test_withoutStart_theLoopTakesNoFrame() {
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (64, 48), count: 2)
        let loop = XRFrameLoop(renderer: renderer, source: frames, runtime: nil)

        loop.run()

        XCTAssertTrue(frames.frames.isEmpty)
        XCTAssertEqual(loop.framesDrawn, 0)
    }

    /// Each display frame's command buffer enters the engine's frame stages from the loop's
    /// own instants (the frame's beginning, the pacing, the commit) and the buffer's GPU
    /// times; a capture target's buffer is not a frame of the display and enters nothing.
    func test_theDisplaysFrames_enterTheFrameStages_aCaptureTargetsDoesNot() throws {
        EngineStatsMonitor.shared.reset()
        let frames = FakeFrames(device: renderInfo.device, eyeSize: (64, 48), count: 4)
        frames.captureTarget = true
        let loop = makeLoop(frames)

        loop.run()
        for frame in frames.frames {
            for buffer in frame.presentedIn {
                buffer.waitUntilCompleted()
            }
        }
        try waitUntil { EngineStatsMonitor.shared.frameStagesInProgress().framesCompleted >= 4 }

        let stages = EngineStatsMonitor.shared.frameStagesInProgress()
        XCTAssertEqual(stages.framesBegun, 4)
        XCTAssertEqual(stages.framesCompleted, 4, "one per display command buffer, none for the capture's")
        XCTAssertGreaterThan(stages.gpuMsMax, 0, "the buffer's GPU span")
        XCTAssertGreaterThan(stages.worstFrame.cpu, 0, "the loop's CPU frame")
        XCTAssertEqual(stages.worstFrame.completion, stages.worstFrame.cpu + stages.worstFrame.wait + stages.worstFrame.gpu, accuracy: 1e-12)
        XCTAssertEqual(stages.worstFrame.pacing, 0, accuracy: 0.002, "the fake frames wait for nothing")
        XCTAssertEqual(stages.pastDeadline, 0, "the fake frames set no deadline")
        EngineStatsMonitor.shared.reset()
    }

    // MARK: - Sources of the test's own

    /// One frame, then none.
    private final class SingleFrame: XRFrameSource, @unchecked Sendable {
        private var frame: FakeFrames.Frame?
        let colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        let depthPixelFormat = MTLPixelFormat.depth32Float
        let eyeSize = simd_float2(64, 48)

        init(frame: FakeFrames.Frame) {
            self.frame = frame
        }

        func nextFrame() -> XRFrame? {
            defer { frame = nil }
            return frame
        }

        func stop() {
            frame = nil
        }
    }
}

/// Frames for the loop without a headset: targets of textures of the test's own, from a pose
/// the test gives, a set number of times; or, kept open, a frame every 20 ms until the source
/// is stopped.
final class FakeFrames: XRFrameSource, @unchecked Sendable {
    final class Frame: XRFrame {
        let timing = XRFrameTiming(presentationTime: CACurrentMediaTime() + 0.011)
        private let targets: [XREyes]
        private let lock = NSLock()
        private var recordedPhases: [String] = []
        private var buffers: [MTLCommandBuffer] = []

        init(targets: [XREyes]) {
            self.targets = targets
        }

        /// The calls the loop made, in order.
        var phases: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedPhases
        }

        /// The command buffers the targets were presented in, one per target.
        var presentedIn: [MTLCommandBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return buffers
        }

        private func record(_ phase: String) {
            lock.lock()
            recordedPhases.append(phase)
            lock.unlock()
        }

        func beginUpdate() {
            record("beginUpdate")
        }

        func endUpdate() {
            record("endUpdate")
        }

        func waitForDrawingTime() {
            record("wait")
        }

        func beginDrawing() -> Bool {
            record("beginDrawing")
            return true
        }

        func acquireEyes() -> [XREyes] {
            record("acquire")
            return targets
        }

        func present(_ target: XREyes, commandBuffer: MTLCommandBuffer) {
            lock.lock()
            recordedPhases.append("present \(target.index)")
            buffers.append(commandBuffer)
            lock.unlock()
        }

        /// Recorded as "willCommit" while the buffer is still the loop's to commit; a hook
        /// called after the commit would record it late.
        func willCommit(_ commandBuffer: MTLCommandBuffer) {
            let late = commandBuffer.status.rawValue >= MTLCommandBufferStatus.committed.rawValue
            record(late ? "willCommit after the commit" : "willCommit")
        }

        func endDrawing() {
            record("endDrawing")
        }
    }

    /// Half the distance between the eyes, as on a headset.
    static let halfEyeDistance: Float = 0.032

    let colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
    let depthPixelFormat = MTLPixelFormat.depth32Float
    let eyeSize: simd_float2
    /// The display's textures, one per eye.
    let colorTextures: [MTLTexture]
    let depthTextures: [MTLTexture]
    /// A capture target's textures, one per eye, the display's size.
    let captureColorTextures: [MTLTexture]
    let captureDepthTextures: [MTLTexture]
    /// Where the headset is, from its origin, for the frames to come: five units back from
    /// the origin, looking at it (the headset looks down -Z); nil for a headset not tracked.
    var originFromDevice: simd_float4x4? = matrix4x4Translation(0, 0, 5)
    /// Whether the frames carry the display's target, and a capture target after it.
    var displayTarget = true
    var captureTarget = false

    private let lock = NSLock()
    private var handed: [Frame] = []
    private var left: Int
    private let keepsOpen: Bool
    private var stopped = false
    private let opened = DispatchSemaphore(value: 0)

    /// Textures of `eyeSize` for `count` frames; `count` nil keeps the source open with a
    /// frame every 20 ms until it is stopped.
    init(device: MTLDevice, eyeSize: (width: Int, height: Int), count: Int?) {
        self.eyeSize = simd_float2(Float(eyeSize.width), Float(eyeSize.height))
        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: eyeSize.width, height: eyeSize.height, mipmapped: false
        )
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .shared
        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: eyeSize.width, height: eyeSize.height, mipmapped: false
        )
        depth.usage = [.renderTarget, .shaderRead]
        depth.storageMode = .private
        colorTextures = (0 ..< stereoEyeCount).compactMap { _ in device.makeTexture(descriptor: color) }
        depthTextures = (0 ..< stereoEyeCount).compactMap { _ in device.makeTexture(descriptor: depth) }
        captureColorTextures = (0 ..< stereoEyeCount).compactMap { _ in device.makeTexture(descriptor: color) }
        captureDepthTextures = (0 ..< stereoEyeCount).compactMap { _ in device.makeTexture(descriptor: depth) }
        left = count ?? 0
        keepsOpen = count == nil
    }

    /// The frames handed to the loop so far.
    var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return handed
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func nextFrame() -> XRFrame? {
        if keepsOpen {
            // A headset at its own rate: a frame now and then.
            _ = opened.wait(timeout: .now() + .milliseconds(20))
            guard isStopped == false else { return nil }
            return hand(Frame(targets: targets()))
        }
        guard isStopped == false, left > 0 else { return nil }
        left -= 1
        return hand(Frame(targets: targets()))
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        opened.signal()
    }

    private func hand(_ frame: Frame) -> Frame {
        lock.lock()
        handed.append(frame)
        lock.unlock()
        return frame
    }

    private func targets() -> [XREyes] {
        var targets: [XREyes] = []
        if displayTarget {
            targets.append(XREyes(originFromDevice: originFromDevice, eyes: eyes(colorTextures, depthTextures), primary: true, index: targets.count))
        }
        if captureTarget {
            targets.append(XREyes(originFromDevice: originFromDevice, eyes: eyes(captureColorTextures, captureDepthTextures), primary: false, index: targets.count))
        }
        return targets
    }

    /// The eyes' places on the headset: a half eye distance to each side.
    private func deviceFromView(_ index: Int) -> simd_float4x4 {
        matrix4x4Translation(index == 0 ? -Self.halfEyeDistance : Self.halfEyeDistance, 0, 0)
    }

    private func eyes(_ color: [MTLTexture], _ depth: [MTLTexture]) -> [XREye] {
        let aspect = Float(color[0].width) / Float(color[0].height)
        let projection = matrixPerspectiveRightHandReverseZ(fovyRadians: .pi / 2, aspectRatio: aspect, nearZ: 0.1, farZ: 100)
        return color.indices.map { index in
            XREye(
                colorTexture: color[index],
                depthTexture: depth[index],
                deviceFromView: deviceFromView(index),
                projection: projection,
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(color[index].width), height: Double(color[index].height), znear: 0, zfar: 1)
            )
        }
    }

    /// The view matrices the loop is expected to draw the eyes with, from the pose given.
    func expectedViewMatrices() -> [simd_float4x4] {
        let origin = originFromDevice ?? matrix_identity_float4x4
        return colorTextures.indices.map { simd_inverse(simd_mul(origin, deviceFromView($0))) }
    }

    /// A pixel of a color texture as red, green, blue, alpha from 0 to 255.
    static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        // The texture is BGRA.
        return (bytes[2], bytes[1], bytes[0], bytes[3])
    }
}
