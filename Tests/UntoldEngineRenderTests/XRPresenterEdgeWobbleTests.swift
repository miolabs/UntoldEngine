//
//  XRPresenterEdgeWobbleTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import RealityKit
import simd
@testable import UntoldEngine
@testable import UntoldEngineXR
@testable import UntoldEngineXRRealityKit
import XCTest

/// How much a silhouette wobbles as the DISPLAY sees it, measured on a Mac in picture pixels at
/// the headset's magnification (a texel of the default eye is 2.6 display pixels at the centre
/// of view; the picture's pixels per degree are held at the display's whatever the eye's
/// density), so that the numbers compare with the headset's captures (cube_tops2.py in the
/// plan's tools: the topmost pixel of the object per column, a line fitted, the residual's rms,
/// peak to peak and the periodogram's dominant period, 0.35 to 0.66 capture pixels rms with
/// 20 to 40 pixel periods on the cubes' top edges, a capture pixel being about 1.9 display
/// pixels; that amount did not change when the eye's texel density was doubled, so the fault
/// lives after the texture, at the display's scale). The scene and the pose are the
/// straightness test's (XRPresenterEdgeStraightnessTests): the example's slab, cubes and
/// sphere, the eye 3.5 cm above the middle cube's top, the head rolled so a level edge crosses
/// a texture row every 25 columns. Three silhouettes against the passthrough are read:
/// the far edges of the cubes' top faces (slivers, the headset's rim), the outer cubes' outer
/// vertical edges, and the sphere's outline. RealityKit draws the presenter's grids over a
/// black and a white room, which gives every pixel's opacity; the engine's own eye resampled
/// bilinearly into the same picture (no grid, no material) is the floor the chain could reach,
/// and the same resample cut at 0.9 at the pixel centres is what a plain raster of the cut
/// would show. One knob at a time from the shipped configuration: the core's cut, the band,
/// RealityRenderer's own MSAA, a view 3 mm from the drawing eye, the grid's cell under the rate
/// map and the uniform grid's size, the render scale, the rate map, the skirt, and eight poses
/// a tenth of a texel apart (what motion does). The study is slow and runs when
/// `XR_PRESENTER_WOBBLE_STUDY` is set; the shipped configuration's numbers are asserted always.
///
/// What it found (Apple M4 Max, 2026-10-19; the table is in the plan's notes): from the drawing
/// eye the shipped chain is the resampled texture to a hundredth of a pixel on all three
/// silhouettes (0.20 / 0.21 / 0.27 px rms against the floor's 0.19 / 0.21 / 0.27) at 2.6, 1.9,
/// 1.73 and 1.26 picture pixels per texel alike, and 3 mm off the drawing eye too; the cut's
/// height does not matter with the band, and without the band the edge is exactly a test at the
/// pixel centres (0.60 px rms), which RealityRenderer's 4x MSAA leaves as it is; eight poses a
/// tenth of a texel apart average the texel staircase out (0.21 to 0.05 px). Cells under 4
/// texels (the 512 x 480 grid, the map's cells of 4) are worse (0.44 / 0.70 / 0.35 px, hard
/// stretches and notches), with the skirt at 3 or 1.5 alike. So no knob of the presenter moves
/// a display-scale wobble at the shipped configuration: the headset's density-independent
/// wobble is in what the Mac cannot run, the device's own RealityKit render and compositor,
/// or in the captures' recompression; a native RealityKit cube beside the engine's, in the
/// same capture, tells which.
@MainActor
final class XRPresenterEdgeWobbleTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)
    private var styleBefore: UntoldImmersionMode = .none
    private var modeBefore: AntiAliasingMode = .fxaa

    nonisolated static let studyVariable = "XR_PRESENTER_WOBBLE_STUDY"

    // MARK: - The scene and the eye

    private nonisolated static let cubeExtent: Float = 0.2
    private nonisolated static let cubeCentreY: Float = 1.025
    private nonisolated static let cubeZ: Float = -1.6
    private nonisolated static let cubeXs: [Float] = [-0.35, 0, 0.35]
    private nonisolated static let slabCentre = simd_float3(0, 0.9, -1.6)
    private nonisolated static let slabHalfExtent = simd_float3(0.6, 0.025, 0.3)
    private nonisolated static let sphereCentre = simd_float3(0, 1.45, -1.6)
    private nonisolated static let sphereRadius: Float = 0.06
    private nonisolated static func cubeAngle(_ index: Int) -> Float { Float(index) * 20 - 20 }
    private nonisolated static let eyeAboveTopMetres: Float = 0.035
    private nonisolated static let rollSlope: Float = 0.04
    /// Display pixels per texel of the default eye at the centre of view: the display's 34
    /// pixels per degree over the default eye's 12.9 texels per degree. The picture's pixels
    /// per unit tangent follow from it and the default configuration, and stay fixed for every
    /// other eye, as the display's do.
    private nonisolated static let displayPixelsPerDefaultTexel: Float = 2.6
    private nonisolated static let pictureSize = SIMD2<Int>(2560, 1152)
    /// The reading window across an edge, picture pixels: from this far outside the predicted
    /// edge (room) to this far inside (object).
    private nonisolated static let windowOutside: Float = 8
    private nonisolated static let windowInside: Float = 4
    /// Columns or rows left out at each end of a stretch, in screen pixels (texels of the
    /// uniform eye): the corners' rounding.
    private nonisolated static let endMargin: Float = 1.5
    /// Periods the periodogram looks between, picture pixels, as cube_tops2.py does (6 to 120).
    private nonisolated static let periodRange: ClosedRange<Float> = 6 ... 120

    private nonisolated static var pixelsPerTangent: Float {
        let defaults = XRRealityKitPresenterConfiguration()
        return displayPixelsPerDefaultTexel * Float(defaults.textureSize.x) / (defaults.frustumTangents.x + defaults.frustumTangents.y)
    }

    /// The example scene of RealityKitPresenterExample, as its ExampleScene builds it.
    override func initializeAssets() {
        let slab = createEntity()
        setEntityName(entityId: slab, name: "Slab")
        setEntityMeshDirect(entityId: slab, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Slab")
        scaleTo(entityId: slab, scale: Self.slabHalfExtent * 2)
        translateTo(entityId: slab, position: Self.slabCentre)
        updateMaterialRoughness(entityId: slab, roughness: 0.8)
        for (index, x) in Self.cubeXs.enumerated() {
            let cube = createEntity()
            setEntityName(entityId: cube, name: "Cube\(index)")
            setEntityMeshDirect(entityId: cube, meshes: BasicPrimitives.createCube(extent: Self.cubeExtent), assetName: "Cube\(index)")
            translateTo(entityId: cube, position: simd_float3(x, Self.cubeCentreY, Self.cubeZ))
            rotateTo(entityId: cube, angle: Self.cubeAngle(index), axis: simd_float3(0, 1, 0))
            updateMaterialRoughness(entityId: cube, roughness: 0.4)
            updateMaterialMetallic(entityId: cube, metallic: Float(index) * 0.4)
        }
        let sphere = createEntity()
        setEntityName(entityId: sphere, name: "Sphere")
        setEntityMeshDirect(entityId: sphere, meshes: BasicPrimitives.createSphere(extent: Self.sphereRadius * 2), assetName: "Sphere")
        translateTo(entityId: sphere, position: Self.sphereCentre)
        updateMaterialRoughness(entityId: sphere, roughness: 0.2)
        let sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        setLight(entityId: sun, .strength(3))
    }

    override func setUp() async throws {
        try await super.setUp()
        viewportBefore = renderInfo.viewPort
        styleBefore = renderInfo.immersionStyle
        modeBefore = antiAliasingMode
        renderInfo.isXRStereoMode = true
        renderInfo.currentEye = 0
        renderSkyBackground = false
        renderInfo.immersionStyle = .mixed
    }

    override func tearDown() async throws {
        renderInfo.isXRStereoMode = false
        renderInfo.currentEye = 0
        renderInfo.xrFoveation = nil
        applyXRFoveationToSceneRenderPassDescriptors()
        renderInfo.immersionStyle = styleBefore
        renderInfo.viewPort = viewportBefore
        renderer.initSizeableResources()
        setRendering(.antiAliasing(modeBefore))
        destroyAllEntities()
        try await super.tearDown()
    }

    /// The headset's pose: over the middle cube, the eyes just above its top, the head rolled;
    /// turned further by `pitch` and `yaw` radians for the poses of the motion study.
    private nonisolated static func headPose(pitch: Float = 0, yaw: Float = 0) -> simd_float4x4 {
        let height = cubeCentreY + cubeExtent / 2 + eyeAboveTopMetres
        var pose = matrix4x4Translation(0, height, 0) * matrix4x4Rotation(radians: atan(rollSlope), axis: simd_float3(0, 0, 1))
        if pitch != 0 { pose = pose * matrix4x4Rotation(radians: pitch, axis: simd_float3(1, 0, 0)) }
        if yaw != 0 { pose = pose * matrix4x4Rotation(radians: yaw, axis: simd_float3(0, 1, 0)) }
        return pose
    }

    /// The four corners of a cube's top face, in the world.
    private nonisolated static func topCorners(ofCube index: Int) -> [simd_float3] {
        let half = cubeExtent / 2
        let turn = simd_quatf(angle: degreesToRadians(degrees: cubeAngle(index)), axis: simd_float3(0, 1, 0))
        let centre = simd_float3(cubeXs[index], cubeCentreY, cubeZ)
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { sx, sz in
            centre + turn.act(simd_float3(Float(sx) * half, half, Float(sz) * half))
        }
    }

    // MARK: - Where things land on the screen and in the picture

    /// A world point as the eye's screen and RealityKit's picture see it: the screen's pixel
    /// coordinates (the uniform eye's texels, or the rate map's screen; the pixel at column u
    /// spans u ..< u + 1, rows from the top), and the picture's pixel coordinates (the same
    /// convention). Both are perspective projections from the same point along the same axes,
    /// so each axis maps affinely from one to the other.
    private struct Projected {
        let u: Float
        let v: Float
        let column: Float
        let row: Float
    }

    private struct Frames {
        let configuration: XRRealityKitPresenterConfiguration
        let screenSize: SIMD2<Int>
        let pose: simd_float4x4
        let viewFromWorld: simd_float4x4
        let worldFromView: simd_float4x4
        let eye: simd_float3
        let tanHalf: Float
        let aspect: Float

        /// `pose` is the head's; the view is the left eye's, moved by `viewOffset` metres along
        /// the eye's own axes (zero for the eye the engine drew from).
        init(configuration: XRRealityKitPresenterConfiguration, screenSize: SIMD2<Int>, pose: simd_float4x4, viewOffset: simd_float3 = .zero) {
            self.configuration = configuration
            self.screenSize = screenSize
            self.pose = pose
            worldFromView = pose * configuration.deviceFromView(eye: 0) * matrix4x4Translation(viewOffset.x, viewOffset.y, viewOffset.z)
            viewFromWorld = simd_inverse(worldFromView)
            eye = simd_float3(worldFromView.columns.3.x, worldFromView.columns.3.y, worldFromView.columns.3.z)
            tanHalf = Float(pictureSize.y) / 2 / pixelsPerTangent
            aspect = Float(pictureSize.x) / Float(pictureSize.y)
        }

        /// RealityKit's vertical field of view for the picture's pixels per tangent.
        var fieldOfViewDegrees: Float { 2 * atan(tanHalf) * 180 / .pi }

        /// Picture pixels per screen pixel at the centre of view.
        var pictureScale: Float {
            pixelsPerTangent / (Float(screenSize.x) / (configuration.frustumTangents.x + configuration.frustumTangents.y))
        }

        func project(_ world: simd_float3) -> Projected {
            let clip = configuration.projection * viewFromWorld * simd_float4(world, 1)
            let ndc = simd_float3(clip.x, clip.y, clip.z) / clip.w
            let tangents = configuration.frustumTangents
            let tx = (ndc.x * (tangents.x + tangents.y) + (tangents.y - tangents.x)) / 2
            let ty = (ndc.y * (tangents.z + tangents.w) + (tangents.z - tangents.w)) / 2
            return Projected(
                u: (ndc.x + 1) / 2 * Float(screenSize.x),
                v: (1 - ndc.y) / 2 * Float(screenSize.y),
                column: (tx / (tanHalf * aspect) + 1) / 2 * Float(pictureSize.x),
                row: (1 - ty / tanHalf) / 2 * Float(pictureSize.y)
            )
        }

        /// The tangents of the view ray through a picture position.
        func tangents(ofPicture column: Float, row: Float) -> simd_float2 {
            simd_float2(
                (column / Float(pictureSize.x) * 2 - 1) * tanHalf * aspect,
                (1 - row / Float(pictureSize.y) * 2) * tanHalf
            )
        }

        /// The screen position a picture position looks at.
        func screenPoint(ofPicture column: Float, row: Float) -> simd_float2 {
            let t = tangents(ofPicture: column, row: row)
            let tangents = configuration.frustumTangents
            let ndcX = (2 * t.x - (tangents.y - tangents.x)) / (tangents.x + tangents.y)
            let ndcY = (2 * t.y - (tangents.z - tangents.w)) / (tangents.z + tangents.w)
            return simd_float2((ndcX + 1) / 2 * Float(screenSize.x), (1 - ndcY) / 2 * Float(screenSize.y))
        }

        /// The world direction of the view ray through a picture position.
        func direction(ofPicture column: Float, row: Float) -> simd_float3 {
            let t = tangents(ofPicture: column, row: row)
            let view = simd_normalize(simd_float3(t.x, t.y, -1))
            let world = worldFromView * simd_float4(view, 0)
            return simd_normalize(simd_float3(world.x, world.y, world.z))
        }
    }

    // MARK: - The silhouettes

    /// Which way a stretch runs, and so how it is read.
    private enum Axis {
        /// Near horizontal: read down each picture column.
        case alongColumns
        /// Near vertical: read along each picture row.
        case alongRows
    }

    /// One straight stretch of a silhouette, from one projected end to the other, with the
    /// passthrough on the outward side.
    private struct Stretch {
        let name: String
        let from: Projected
        let to: Projected
        let axis: Axis
        /// +1 when the room lies at increasing row (alongColumns) or column (alongRows), else -1.
        let outward: Float

        var screenLength: Float {
            switch axis {
            case .alongColumns: return abs(to.u - from.u)
            case .alongRows: return abs(to.v - from.v)
            }
        }

        /// Rows per column (alongColumns) or columns per row (alongRows), on the screen.
        var slope: Float {
            switch axis {
            case .alongColumns: return (to.v - from.v) / (to.u - from.u)
            case .alongRows: return (to.u - from.u) / (to.v - from.v)
            }
        }

        /// The picture's along-coordinate at each end, ordered.
        var pictureSpan: ClosedRange<Float> {
            switch axis {
            case .alongColumns: return min(from.column, to.column) ... max(from.column, to.column)
            case .alongRows: return min(from.row, to.row) ... max(from.row, to.row)
            }
        }

        /// The predicted across-coordinate (row or column) at an along-coordinate.
        func predicted(at along: Float) -> Float {
            switch axis {
            case .alongColumns: return from.row + (to.row - from.row) * (along - from.column) / (to.column - from.column)
            case .alongRows: return from.column + (to.column - from.column) * (along - from.row) / (to.row - from.row)
            }
        }
    }

    /// The upper outline of each cube's top face: the corners' upper hull, the stretches that
    /// are long and shallow enough to carry a staircase (the short steep sides are left out).
    private nonisolated static func topStretches(_ frames: Frames) -> [Stretch] {
        var stretches: [Stretch] = []
        for cube in cubeXs.indices {
            let corners = topCorners(ofCube: cube).map(frames.project).sorted { $0.u < $1.u }
            var hull: [Projected] = []
            for corner in corners {
                while hull.count >= 2 {
                    let a = hull[hull.count - 2], b = hull[hull.count - 1]
                    let cross = (b.u - a.u) * (corner.v - a.v) - (b.v - a.v) * (corner.u - a.u)
                    if cross <= 0 { hull.removeLast() } else { break }
                }
                hull.append(corner)
            }
            for index in 0 ..< hull.count - 1 {
                let stretch = Stretch(name: "top of cube \(cube)", from: hull[index], to: hull[index + 1], axis: .alongColumns, outward: -1)
                if stretch.screenLength >= 20, abs(stretch.slope) < 0.3 {
                    stretches.append(stretch)
                }
            }
        }
        return stretches
    }

    /// The ray from the eye through `point`, continued: whether it clears the slab (so the
    /// room lies behind the point).
    private nonisolated static func roomBehind(_ point: simd_float3, eye: simd_float3) -> Bool {
        let slabTop = slabCentre.y + slabHalfExtent.y
        guard eye.y > point.y else { return true }
        let s = (eye.y - slabTop) / (eye.y - point.y)
        guard s > 0 else { return true }
        let hit = eye + s * (point - eye)
        let inside = abs(hit.x - slabCentre.x) <= slabHalfExtent.x && abs(hit.z - slabCentre.z) <= slabHalfExtent.z
        return !inside
    }

    /// The outer cubes' outermost vertical edges, from the top corner down to where the slab
    /// appears behind them (the part against the room).
    private nonisolated static func sideStretches(_ frames: Frames) -> [Stretch] {
        var stretches: [Stretch] = []
        for (cube, outward) in [(0, Float(-1)), (2, Float(1))] {
            let corners = topCorners(ofCube: cube)
            let projected = corners.map(frames.project)
            guard let outermost = projected.indices.max(by: { outward * projected[$0].u < outward * projected[$1].u }) else { continue }
            let top = corners[outermost]
            var bottom = simd_float3(top.x, cubeCentreY - cubeExtent / 2, top.z)
            if !roomBehind(bottom, eye: frames.eye) {
                var low = bottom.y, high = top.y
                for _ in 0 ..< 40 {
                    let mid = (low + high) / 2
                    if roomBehind(simd_float3(top.x, mid, top.z), eye: frames.eye) { high = mid } else { low = mid }
                }
                bottom.y = high
            }
            let stretch = Stretch(name: "side of cube \(cube)", from: frames.project(top), to: frames.project(bottom), axis: .alongRows, outward: outward)
            if stretch.screenLength >= 20 {
                stretches.append(stretch)
            }
        }
        return stretches
    }

    /// The sphere's outline as the picture sees it: for each angle about the projected centre,
    /// the predicted radius in picture pixels (the ray at that radius grazes the sphere).
    private struct Outline {
        let centre: SIMD2<Float>
        let angles: [Float]
        let radii: [Float]

        var meanRadius: Float { radii.reduce(0, +) / Float(radii.count) }

        /// Picture pixels of arc between neighbouring samples.
        var spacing: Float { 2 * .pi * meanRadius / Float(angles.count) }
    }

    private nonisolated static func outline(_ frames: Frames, samples: Int) -> Outline {
        let projectedCentre = frames.project(sphereCentre)
        let centre = SIMD2<Float>(projectedCentre.column, projectedCentre.row)
        let toSphere = sphereCentre - frames.eye
        let grazing = asin(sphereRadius / simd_length(toSphere))
        let axis = simd_normalize(toSphere)
        var angles: [Float] = []
        var radii: [Float] = []
        for index in 0 ..< samples {
            let angle = Float(index) / Float(samples) * 2 * .pi
            let step = SIMD2<Float>(cos(angle), sin(angle))
            /// The angle off the sphere's axis grows with the radius; the outline is where it
            /// reaches the grazing angle.
            func offAxis(_ radius: Float) -> Float {
                let position = centre + radius * step
                let direction = frames.direction(ofPicture: position.x, row: position.y)
                return acos(min(max(simd_dot(direction, axis), -1), 1))
            }
            var low: Float = 0, high: Float = 1
            while offAxis(high) < grazing, high < Float(pictureSize.x) { high *= 2 }
            for _ in 0 ..< 40 {
                let mid = (low + high) / 2
                if offAxis(mid) < grazing { low = mid } else { high = mid }
            }
            angles.append(angle)
            radii.append((low + high) / 2)
        }
        return Outline(centre: centre, angles: angles, radii: radii)
    }

    // MARK: - Pictures

    /// Linear rgba floats, rows from the top.
    private struct Picture {
        let width: Int
        let height: Int
        var pixels: [Float]

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Float { pixels[(y * width + x) * 4 + c] }

        func alpha(_ x: Int, _ y: Int) -> Float { channel(x, y, 3) }

        /// The alpha at a position in pixel coordinates, bilinear between the pixel centres,
        /// clamped at the edges.
        func alpha(at x: Float, _ y: Float) -> Float {
            let fx = min(max(x - 0.5, 0), Float(width - 1))
            let fy = min(max(y - 0.5, 0), Float(height - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let top = alpha(x0, y0) * (1 - tx) + alpha(x1, y0) * tx
            let bottom = alpha(x0, y1) * (1 - tx) + alpha(x1, y1) * tx
            return top * (1 - ty) + bottom * ty
        }
    }

    private enum PictureError: Swift.Error { case stalled(String) }

    private func reach(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw PictureError.stalled(what) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The head pose the engine draws from, read on the engine's thread.
    private final class PoseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pose: simd_float4x4

        init(_ pose: simd_float4x4) { self.pose = pose }

        var value: simd_float4x4 {
            get { lock.withLock { pose } }
            set { lock.withLock { pose = newValue } }
        }
    }

    /// A presenter drawing the engine's eye under MSAA for a head pose, the loop on its own
    /// thread, which blocks between tickets so that the grids stay as the last frame placed
    /// them while RealityKit pictures them; the pose can be changed and the eye drawn again.
    @available(macOS 15.0, *)
    @MainActor
    private final class EyeSession {
        let presenter: XRRealityKitPresenter
        let loop: XRFrameLoop
        let thread: Thread
        let poseBox: PoseBox
        private var framesWanted = 0
        private let reach: (String, () -> Bool) throws -> Void
        private let readTexture: (MTLTexture) throws -> Picture

        init(renderer: UntoldRenderer, device: MTLDevice, commandQueue: MTLCommandQueue, configuration: XRRealityKitPresenterConfiguration, pose: simd_float4x4, reach: @escaping (String, () -> Bool) throws -> Void, readTexture: @escaping (MTLTexture) throws -> Picture) async throws {
            presenter = try await XRRealityKitPresenter(device: device, configuration: configuration)
            presenter.reportInterval = 0
            guard presenter.usesShaderGraphMaterial else { throw XCTSkip("the eye material did not load") }
            guard presenter.hasEdgeBand else { throw XCTSkip("the band's graph did not load") }
            poseBox = PoseBox(pose)
            let box = poseBox
            let source = RealityKitFrameSource(presenter: presenter) { _ in box.value }
            loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
            self.reach = reach
            self.readTexture = readTexture
            setRendering(.antiAliasing(.msaa))
            loop.start()
            let loop = loop
            thread = Thread { loop.run() }
            thread.start()
            presenter.start(commandQueue: commandQueue)
        }

        /// Six more frames from the pose in force; the left eye's texture once the last completed.
        func draw() throws -> Picture {
            framesWanted += 6
            let wanted = framesWanted
            try reach("\(wanted) frames drawn") {
                presenter.update()
                return loop.framesDrawn >= wanted
            }
            let lastTicket = try XCTUnwrap(presenter.lastTicket)
            try reach("the last ticket completed") { lastTicket.commandBuffer.status == .completed }
            return try readTexture(lastTicket.colorTextures[0])
        }

        func stop() throws {
            presenter.stop()
            try reach("the loop's thread finished") { thread.isFinished }
        }
    }

    /// The texture's pixels, linear floats, rgba, rows from the top (the display's encoding of
    /// the premultiplied colour decoded, the alpha as it is).
    private func linearPixels(ofSRGB texture: MTLTexture) throws -> Picture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(renderInfo.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        try reach("the texture copied") { commandBuffer.status == .completed }
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        var table = [Float](repeating: 0, count: 256)
        for byte in 0 ..< 256 {
            let value = Float(byte) / 255
            table[byte] = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var pixels = [Float](repeating: 0, count: texture.width * texture.height * 4)
        for index in 0 ..< texture.width * texture.height {
            let base = index * 4
            // bgra in memory.
            pixels[base] = table[Int(bytes[base + 2])]
            pixels[base + 1] = table[Int(bytes[base + 1])]
            pixels[base + 2] = table[Int(bytes[base])]
            pixels[base + 3] = Float(bytes[base + 3]) / 255
        }
        return Picture(width: texture.width, height: texture.height, pixels: pixels)
    }

    /// RealityKit's renderer looking out of the left eye (or a view offset from it) with the
    /// display's pixels per degree.
    @available(macOS 15.0, *)
    @MainActor
    private final class Camera {
        let renderer: RealityRenderer
        let output: MTLTexture
        let cameraOutput: RealityRenderer.CameraOutput

        /// `scene` in place of the presenter's root: a control drawn by RealityKit alone.
        init(presenter: XRRealityKitPresenter?, scene: Entity? = nil, frames: Frames, multisampled: Bool, device: MTLDevice) throws {
            renderer = try RealityRenderer()
            renderer.cameraSettings.isToneMappingEnabled = false
            renderer.cameraSettings.antialiasing = multisampled ? .multisample4X : .none
            let camera = Entity()
            camera.components.set(PerspectiveCameraComponent(near: frames.configuration.nearPlane, far: frames.configuration.farPlane, fieldOfViewInDegrees: frames.fieldOfViewDegrees))
            camera.transform = Transform(matrix: frames.worldFromView)
            renderer.activeCamera = camera
            renderer.entities.replaceAll([camera] + [scene ?? presenter?.root].compactMap { $0 })
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: pictureSize.x, height: pictureSize.y, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let output = device.makeTexture(descriptor: descriptor) else { throw PictureError.stalled("no output texture") }
            self.output = output
            cameraOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: output))
        }

        /// The picture over a room of one grey, read back once it has stopped changing.
        func picture(background: CGFloat) async throws -> Picture {
            renderer.cameraSettings.colorBackground = .color(CGColor(red: background, green: background, blue: background, alpha: 1))
            var previous: [Float] = []
            var shown: [Float] = []
            var unchanged = 0
            for _ in 0 ..< 60 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    do {
                        try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: cameraOutput, onComplete: { _ in continuation.resume() })
                    } catch { continuation.resume(throwing: error) }
                }
                try await Task.sleep(nanoseconds: 20_000_000)
                shown = halfPixels(of: output)
                unchanged = shown == previous ? unchanged + 1 : 0
                if unchanged >= 2 { break }
                previous = shown
            }
            return Picture(width: pictureSize.x, height: pictureSize.y, pixels: shown)
        }

        private func halfPixels(of texture: MTLTexture) -> [Float] {
            var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
            halves.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return halves.map { Float($0) }
        }
    }

    /// What RealityKit drew, as opacity and straight colour per pixel, from the picture over
    /// black and the picture over white.
    private func composite(black: Picture, white: Picture) -> Picture {
        var result = Picture(width: black.width, height: black.height, pixels: [Float](repeating: 0, count: black.pixels.count))
        for index in 0 ..< black.width * black.height {
            let base = index * 4
            var alpha: Float = 0
            for c in 0 ..< 3 { alpha += 1 - (white.pixels[base + c] - black.pixels[base + c]) }
            alpha = min(max(alpha / 3, 0), 1)
            for c in 0 ..< 3 { result.pixels[base + c] = alpha > 0.001 ? black.pixels[base + c] / alpha : 0 }
            result.pixels[base + 3] = alpha
        }
        return result
    }

    /// The engine's eye resampled into the picture as RealityKit's sampler would read it
    /// with no grid and no material: bilinear between texel centres at each picture pixel's
    /// centre, through the rate map's screen when the eye has one; `cut` leaves each pixel's
    /// alpha at 1 or 0 about it, what a plain raster of the cut at the pixel centres shows.
    private func resampledEye(_ eye: Picture, frames: Frames, foveation: XRPresenterFoveation?, cut: Float?) -> Picture {
        var result = Picture(width: Self.pictureSize.x, height: Self.pictureSize.y, pixels: [Float](repeating: 0, count: Self.pictureSize.x * Self.pictureSize.y * 4))
        for row in 0 ..< Self.pictureSize.y {
            for column in 0 ..< Self.pictureSize.x {
                var screen = frames.screenPoint(ofPicture: Float(column) + 0.5, row: Float(row) + 0.5)
                if let foveation {
                    let physical = foveation.rateMap.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: screen.x, y: screen.y), layer: 0)
                    screen = simd_float2(physical.x, physical.y)
                }
                var alpha = eye.alpha(at: screen.x, screen.y)
                if let cut { alpha = alpha >= cut ? 1 : 0 }
                let base = (row * Self.pictureSize.x + column) * 4
                result.pixels[base] = alpha
                result.pixels[base + 1] = alpha
                result.pixels[base + 2] = alpha
                result.pixels[base + 3] = alpha
            }
        }
        return result
    }

    // MARK: - The variants

    private struct Variant {
        let name: String
        /// The core's opacity cut; nil leaves the core out.
        let cut: Float?
        /// Whether the band is drawn, at the coverage, as shipped.
        let band: Bool
        /// The band over every cell of the grid instead of the cells along silhouettes.
        var wholeGrid = false
        /// RealityKit's view this far from the eye the engine drew from, metres, along the
        /// eye's axes.
        var viewOffset = simd_float3.zero
        /// Whether RealityRenderer draws the picture with its own 4x MSAA.
        var multisampled = false

        static let shipped = Variant(name: "cut 0.9, band (shipped)", cut: 0.9, band: true)
    }

    /// The shipped graphs with one thing changed, written next to the test for RealityKit to load.
    @available(macOS 15.0, *)
    private final class Graphs {
        private var files: [String: URL] = [:]
        private let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("XRPresenterEdgeWobble-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        private func text(ofResource name: String) throws -> String {
            guard let url = XRPresenterMaterial.resourceURL(name) else { throw PictureError.stalled("\(name).usda is not in the bundle") }
            return try String(contentsOf: url, encoding: .utf8)
        }

        private func write(_ text: String, as name: String) throws -> URL {
            if let url = files[name] { return url }
            let url = folder.appendingPathComponent("\(name).usda")
            try text.write(to: url, atomically: true, encoding: .utf8)
            files[name] = url
            return url
        }

        /// The core's graph with its opacity threshold at `cut`.
        func core(cut: Float) throws -> URL {
            let original = "float inputs:opacityThreshold = 0.9"
            var text = try text(ofResource: XRPresenterMaterial.resourceName)
            guard text.contains(original) else { throw PictureError.stalled("the core's graph has no opacity threshold of 0.9") }
            text = text.replacingOccurrences(of: original, with: "float inputs:opacityThreshold = \(cut)")
            return try write(text, as: "core-\(cut)")
        }

        /// The band's graph as shipped.
        func band() throws -> URL {
            try write(text(ofResource: XRPresenterMaterial.edgeResourceName), as: "band")
        }
    }

    /// The presenter's entities per eye, and the materials to put on them per variant.
    @available(macOS 15.0, *)
    @MainActor
    private final class Stage {
        let cores: [ModelEntity]
        let bands: [ModelEntity]
        let bandMeshes: [RealityKit.MeshResource]
        let textures: [TextureResource]
        let graphs: Graphs
        private var materials: [String: ShaderGraphMaterial] = [:]

        init(presenter: XRRealityKitPresenter) throws {
            let entities = presenter.root.children.compactMap { $0 as? ModelEntity }
            cores = entities.filter { !$0.name.hasSuffix("edge") }
            bands = entities.filter { $0.name.hasSuffix("edge") }
            guard cores.count == 2, bands.count == 2 else { throw PictureError.stalled("the presenter has \(cores.count) core and \(bands.count) band entities") }
            bandMeshes = try bands.map { band in
                guard let mesh = band.model?.mesh else { throw PictureError.stalled("a band entity has no mesh") }
                return mesh
            }
            textures = try cores.map { core in
                guard let material = core.model?.materials.first as? ShaderGraphMaterial,
                      case let .textureResource(texture)? = material.getParameter(name: XRPresenterMaterial.colorTextureParameter)
                else { throw PictureError.stalled("a core entity has no texture") }
                return texture
            }
            graphs = try Graphs()
        }

        private func material(_ url: URL, prim: String, key: String, eye: Int) async throws -> ShaderGraphMaterial {
            let cacheKey = "\(key)-\(eye)"
            if let material = materials[cacheKey] { return material }
            var material = try await ShaderGraphMaterial(named: prim, from: url)
            material.faceCulling = .none
            try XRPresenterMaterial.configure(&material, eye: eye, texture: textures[eye])
            materials[cacheKey] = material
            return material
        }

        /// The left eye's entities take the variant: the picture is a mono view, which the eye
        /// switch shows the left eye's grid in.
        func apply(_ variant: Variant) async throws {
            let eye = 0
            if let cut = variant.cut {
                cores[eye].model?.materials = try await [material(graphs.core(cut: cut), prim: XRPresenterMaterial.primPath, key: "core-\(cut)", eye: eye)]
            }
            cores[eye].isEnabled = variant.cut != nil
            if variant.band {
                bands[eye].model?.materials = try await [material(graphs.band(), prim: XRPresenterMaterial.edgePrimPath, key: "band", eye: eye)]
                if variant.wholeGrid, let core = cores[eye].model?.mesh {
                    bands[eye].model?.mesh = core
                } else {
                    bands[eye].model?.mesh = bandMeshes[eye]
                }
            }
            bands[eye].isEnabled = variant.band
        }
    }

    // MARK: - The measurement

    /// An edge read along one stretch, in picture pixels: for each along-coordinate, the
    /// across-coordinate where the opacity crosses one half (from outside), where a hard edge
    /// with the same coverage would lie (the outer end of the window less the opacity
    /// missing), and the first whole pixel with opacity at one half or more (what a mask of
    /// the object gives, as cube_tops2.py reads the captures).
    private struct EdgeReading {
        var along: [Float] = []
        var crossings: [Float] = []
        var integrals: [Float] = []
        var masks: [Float] = []
    }

    /// Per sample across an edge: positions `s` in picture pixels, positive outward from the
    /// predicted edge, from +windowOutside inward to -windowInside in steps of `step`.
    private static func readAcross(alpha: (Float) -> Float, step: Float) -> (crossing: Float, integral: Float) {
        var missing: Float = 0
        var crossing: Float?
        var previous: Float = 0
        var previousS = windowOutside
        var s = windowOutside
        while s >= -windowInside - step / 2 {
            let a = alpha(s)
            missing += (1 - a) * step
            if crossing == nil, a >= 0.5 {
                let t = a > previous ? (0.5 - previous) / (a - previous) : 1
                crossing = previousS + (s - previousS) * t
            }
            previous = a
            previousS = s
            s -= step
        }
        return (crossing ?? -windowInside, windowOutside - missing)
    }

    /// The edge along `stretch` in a picture, one sample per picture column (or row).
    private func read(_ picture: Picture, along stretch: Stretch, margin: Float) -> EdgeReading {
        var reading = EdgeReading()
        let span = stretch.pictureSpan
        let first = Int((span.lowerBound + margin).rounded(.up))
        let last = Int((span.upperBound - margin).rounded(.down))
        guard first < last else { return reading }
        for index in first ... last {
            let along = Float(index) + 0.5
            let predicted = stretch.predicted(at: along)
            let outside = predicted + stretch.outward * Self.windowOutside
            let inside = predicted - stretch.outward * Self.windowInside
            let limit: Float = stretch.axis == .alongColumns ? Float(picture.height) : Float(picture.width)
            guard min(outside, inside) >= 0, max(outside, inside) < limit else { continue }
            func alpha(_ s: Float) -> Float {
                let across = predicted + stretch.outward * s
                switch stretch.axis {
                case .alongColumns: return picture.alpha(at: along, across)
                case .alongRows: return picture.alpha(at: across, along)
                }
            }
            let (crossing, integral) = Self.readAcross(alpha: alpha, step: 1)
            // The mask: whole pixels from the outside in, the first at one half or more.
            var mask = -Self.windowInside
            var pixel = Int(outside.rounded(.down))
            let end = Int(inside.rounded(.down))
            let direction = stretch.outward > 0 ? -1 : 1
            while direction > 0 ? pixel <= end : pixel >= end {
                let a: Float
                switch stretch.axis {
                case .alongColumns: a = picture.alpha(index, min(max(pixel, 0), picture.height - 1))
                case .alongRows: a = picture.alpha(min(max(pixel, 0), picture.width - 1), index)
                }
                if a >= 0.5 {
                    mask = stretch.outward * (Float(pixel) - predicted)
                    break
                }
                pixel += direction
            }
            reading.along.append(along)
            reading.crossings.append(crossing)
            reading.integrals.append(integral)
            reading.masks.append(mask)
        }
        return reading
    }

    /// The sphere's outline in a picture, one sample per angle, read along the ray from the
    /// predicted centre in quarter-pixel steps.
    private func read(_ picture: Picture, around outline: Outline) -> EdgeReading {
        var reading = EdgeReading()
        for (angle, radius) in zip(outline.angles, outline.radii) {
            let step = SIMD2<Float>(cos(angle), sin(angle))
            func alpha(_ s: Float) -> Float {
                let position = outline.centre + (radius + s) * step
                return picture.alpha(at: position.x, position.y)
            }
            let (crossing, integral) = Self.readAcross(alpha: alpha, step: 0.25)
            reading.along.append(angle * outline.meanRadius)
            reading.crossings.append(crossing)
            reading.integrals.append(integral)
            reading.masks.append(crossing)
        }
        return reading
    }

    /// A series' deviation about its fit, picture pixels: rms, peak to peak, and the period of
    /// the periodogram's strongest line between 6 and 120 pixels.
    private struct Wobble {
        let rms: Float
        let peakToPeak: Float
        let period: Float
    }

    /// Residuals of a least-squares line through (x, y).
    private static func lineResiduals(_ xs: [Float], _ ys: [Float]) -> [Float] {
        let n = Float(xs.count)
        guard n >= 2 else { return [] }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx: Float = 0, sxy: Float = 0
        for (x, y) in zip(xs, ys) {
            sxx += (x - mx) * (x - mx)
            sxy += (x - mx) * (y - my)
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        let intercept = my - slope * mx
        return zip(xs, ys).map { x, y in y - (intercept + slope * x) }
    }

    /// Residuals of a fit of the mean and the first two harmonics (the centre's offset and the
    /// outline's ellipticity) to a closed series over `angles`.
    private static func harmonicResiduals(_ angles: [Float], _ ys: [Float]) -> [Float] {
        let n = Float(ys.count)
        guard n >= 8 else { return [] }
        var residuals = ys
        let mean = ys.reduce(0, +) / n
        for index in residuals.indices { residuals[index] -= mean }
        for harmonic in 1 ... 2 {
            var c: Float = 0, s: Float = 0
            for (angle, y) in zip(angles, residuals) {
                c += y * cos(Float(harmonic) * angle)
                s += y * sin(Float(harmonic) * angle)
            }
            c *= 2 / n
            s *= 2 / n
            for (index, angle) in angles.enumerated() {
                residuals[index] -= c * cos(Float(harmonic) * angle) + s * sin(Float(harmonic) * angle)
            }
        }
        return residuals
    }

    /// The period, in picture pixels, of the strongest line of the periodogram of `residuals`
    /// (spaced `spacing` pixels apart) between the periods looked at, as cube_tops2.py finds it.
    private static func dominantPeriod(_ residuals: [Float], spacing: Float) -> Float {
        let n = residuals.count
        guard n >= 16 else { return .nan }
        let mean = residuals.reduce(0, +) / Float(n)
        var best: (power: Float, period: Float) = (-1, .nan)
        for k in 1 ... n / 2 {
            let period = Float(n) * spacing / Float(k)
            guard periodRange.contains(period) else { continue }
            var re: Float = 0, im: Float = 0
            for (index, value) in residuals.enumerated() {
                let phase = 2 * Float.pi * Float(k * index) / Float(n)
                re += (value - mean) * cos(phase)
                im += (value - mean) * sin(phase)
            }
            let power = re * re + im * im
            if power > best.power { best = (power, period) }
        }
        return best.period
    }

    private static func wobble(pooled residualSets: [[Float]], periodOf series: [Float], spacing: Float) -> Wobble {
        let residuals = residualSets.flatMap { $0 }
        guard !residuals.isEmpty else { return Wobble(rms: 0, peakToPeak: 0, period: .nan) }
        return Wobble(
            rms: sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Float(residuals.count)),
            peakToPeak: residuals.max()! - residuals.min()!,
            period: dominantPeriod(series, spacing: spacing)
        )
    }

    /// One silhouette's numbers: by the mask, by the one-half crossing, by the coverage.
    private struct EdgeNumbers {
        let mask: Wobble
        let crossing: Wobble
        let integral: Wobble
        let samples: Int
        /// The mean of the crossing about the prediction, picture pixels, positive outward:
        /// where the edge lies against where the view's own projection puts it.
        let offset: Float
    }

    /// The numbers of a set of stretches (residuals pooled; the period from the longest).
    private static func numbers(of readings: [EdgeReading]) -> EdgeNumbers {
        let longest = readings.max { $0.along.count < $1.along.count } ?? EdgeReading()
        func series(_ pick: (EdgeReading) -> [Float]) -> Wobble {
            wobble(pooled: readings.map { lineResiduals($0.along, pick($0)) }, periodOf: lineResiduals(longest.along, pick(longest)), spacing: 1)
        }
        let crossings = readings.flatMap(\.crossings)
        return EdgeNumbers(
            mask: series(\.masks), crossing: series(\.crossings), integral: series(\.integrals),
            samples: crossings.count,
            offset: crossings.isEmpty ? 0 : crossings.reduce(0, +) / Float(crossings.count)
        )
    }

    private static func numbers(of reading: EdgeReading, around outline: Outline) -> EdgeNumbers {
        func series(_ pick: (EdgeReading) -> [Float]) -> Wobble {
            let residuals = harmonicResiduals(outline.angles, pick(reading))
            return wobble(pooled: [residuals], periodOf: residuals, spacing: outline.spacing)
        }
        return EdgeNumbers(
            mask: series(\.masks), crossing: series(\.crossings), integral: series(\.integrals),
            samples: reading.crossings.count,
            offset: reading.crossings.isEmpty ? 0 : reading.crossings.reduce(0, +) / Float(reading.crossings.count)
        )
    }

    /// A row of the table: one picture's three silhouettes.
    private struct Row {
        let name: String
        /// Picture pixels per texel at the centre of view for the eye the row was read from.
        let pixelsPerTexel: Float
        let top: EdgeNumbers
        let side: EdgeNumbers
        let sphere: EdgeNumbers
    }

    private struct Silhouettes {
        let frames: Frames
        let tops: [Stretch]
        let sides: [Stretch]
        let outline: Outline

        init(frames: Frames) {
            self.frames = frames
            tops = topStretches(frames)
            sides = sideStretches(frames)
            outline = XRPresenterEdgeWobbleTests.outline(frames, samples: 720)
        }
    }

    private func row(_ name: String, of picture: Picture, silhouettes: Silhouettes) -> Row {
        let margin = Self.endMargin * silhouettes.frames.pictureScale
        return Row(
            name: name,
            pixelsPerTexel: silhouettes.frames.pictureScale,
            top: Self.numbers(of: silhouettes.tops.map { read(picture, along: $0, margin: margin) }),
            side: Self.numbers(of: silhouettes.sides.map { read(picture, along: $0, margin: margin) }),
            sphere: Self.numbers(of: read(picture, around: silhouettes.outline), around: silhouettes.outline)
        )
    }

    private nonisolated static func format(_ value: Float, _ digits: Int = 2) -> String {
        value.isNaN ? "-" : String(format: "%.\(digits)f", value)
    }

    private nonisolated static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(width - text.count, 0))
        return left ? text + fill : fill + text
    }

    private nonisolated static var header: String {
        "  " + pad("picture", 58, left: true) + pad("px/texel", 9)
            + ["top: mask", "x rms", "int rms", "p-p", "period", "off"].map { pad($0, 10) }.joined()
            + ["side: x", "int", "period", "off"].map { pad($0, 8) }.joined()
            + ["sphere: x", "int", "period", "off"].map { pad($0, 10) }.joined()
    }

    private static func line(_ row: Row) -> String {
        "  " + pad(row.name, 58, left: true) + pad(format(row.pixelsPerTexel), 9)
            + [format(row.top.mask.rms), format(row.top.crossing.rms), format(row.top.integral.rms), format(row.top.crossing.peakToPeak), format(row.top.mask.period, 0), format(row.top.offset)].map { pad($0, 10) }.joined()
            + [format(row.side.crossing.rms), format(row.side.integral.rms), format(row.side.crossing.period, 0), format(row.side.offset)].map { pad($0, 8) }.joined()
            + [format(row.sphere.crossing.rms), format(row.sphere.integral.rms), format(row.sphere.crossing.period, 0), format(row.sphere.offset)].map { pad($0, 10) }.joined()
    }

    private func printTable(_ title: String, _ rows: [Row]) {
        print("XR presenter edge wobble: \(title); picture pixels, \(Int(Self.pixelsPerTangent.rounded())) per unit tangent (\(Self.format(Self.pixelsPerTangent * .pi / 180, 1)) per degree at the centre of view), rms and peak to peak about a line (the sphere: about its first two harmonics), the period of the periodogram's strongest line between 6 and 120 px")
        print(Self.header)
        for row in rows { print(Self.line(row)) }
    }

    // MARK: - A setup: one engine eye, its floors, its variants

    private struct Setup {
        let name: String
        var configuration: XRRealityKitPresenterConfiguration
        var variants: [Variant] = [.shipped]
        /// The floor rows: the eye resampled, blended and cut.
        var floors = true

        init(name: String, configure: (inout XRRealityKitPresenterConfiguration) -> Void = { _ in }) {
            self.name = name
            var configuration = XRRealityKitPresenterConfiguration()
            configuration.pipelineDepth = 1 // one set: the picture is read at the first render
            configure(&configuration)
            self.configuration = configuration
        }
    }

    private var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["XR_PRESENTER_DUMP"].map { URL(fileURLWithPath: $0) }
    }

    private func slug(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "-" }.reduce(into: "") { $0.append($1) }
    }

    /// Draws the engine's eye for `setup`, pictures each of its variants through RealityKit,
    /// reads the three silhouettes in each and in the resampled eye.
    @available(macOS 15.0, *)
    private func measure(_ setup: Setup, pose: simd_float4x4 = headPose()) async throws -> (rows: [Row], session: EyeSession, silhouettes: Silhouettes) {
        let session = try await EyeSession(renderer: renderer, device: renderInfo.device, commandQueue: renderInfo.commandQueue, configuration: setup.configuration, pose: pose, reach: reach, readTexture: linearPixels(ofSRGB:))
        let eye = try session.draw()
        let presenter = session.presenter
        let screenSize = presenter.foveation?.screenSize ?? presenter.textureSize
        let frames = Frames(configuration: setup.configuration, screenSize: screenSize, pose: pose)
        let silhouettes = Silhouettes(frames: frames)
        XCTAssertGreaterThanOrEqual(silhouettes.tops.count, 3, "\(setup.name): the three cubes' top faces each have a shallow far edge")
        XCTAssertEqual(silhouettes.sides.count, 2, "\(setup.name): the outer cubes each have an outer vertical edge against the room")
        let described = (silhouettes.tops + silhouettes.sides).map { "\($0.name) from (\(Self.format($0.from.column, 1)), \(Self.format($0.from.row, 1))) to (\(Self.format($0.to.column, 1)), \(Self.format($0.to.row, 1))), slope \(Self.format($0.slope, 3))" }
        print("XR presenter edge wobble: \(setup.name): \(Self.format(frames.pictureScale)) picture px per texel at the centre; \(described.joined(separator: "; ")); the sphere's outline about (\(Self.format(silhouettes.outline.centre.x, 1)), \(Self.format(silhouettes.outline.centre.y, 1))), radius \(Self.format(silhouettes.outline.meanRadius, 1)) px")
        var rows: [Row] = []
        let eyeName = "\(setup.name): "
        if setup.floors {
            let blended = resampledEye(eye, frames: frames, foveation: presenter.foveation, cut: nil)
            rows.append(row(eyeName + "the eye resampled, blended (floor)", of: blended, silhouettes: silhouettes))
            let cut = resampledEye(eye, frames: frames, foveation: presenter.foveation, cut: 0.9)
            rows.append(row(eyeName + "the eye resampled, cut at 0.9 per pixel (a raster)", of: cut, silhouettes: silhouettes))
            if let dumpFolder {
                try writePNG(blended, to: dumpFolder.appendingPathComponent("wobble-\(slug(setup.name))-eye-resampled.png"))
            }
        }
        let stage = try Stage(presenter: presenter)
        var cameras: [String: Camera] = [:]
        for variant in setup.variants {
            try await stage.apply(variant)
            let key = "\(variant.viewOffset)-\(variant.multisampled)"
            let camera: Camera
            if let made = cameras[key] {
                camera = made
            } else {
                let viewFrames = Frames(configuration: setup.configuration, screenSize: screenSize, pose: pose, viewOffset: variant.viewOffset)
                camera = try Camera(presenter: presenter, frames: viewFrames, multisampled: variant.multisampled, device: renderInfo.device)
                cameras[key] = camera
            }
            let black = try await camera.picture(background: 0)
            let white = try await camera.picture(background: 1)
            let shown = composite(black: black, white: white)
            let viewSilhouettes = variant.viewOffset == .zero ? silhouettes : Silhouettes(frames: Frames(configuration: setup.configuration, screenSize: screenSize, pose: pose, viewOffset: variant.viewOffset))
            rows.append(row(eyeName + variant.name, of: shown, silhouettes: viewSilhouettes))
            if let dumpFolder {
                try writePNG(black, to: dumpFolder.appendingPathComponent("wobble-\(slug(setup.name))-\(slug(variant.name)).png"))
            }
        }
        try await stage.apply(.shipped)
        return (rows, session, silhouettes)
    }

    // MARK: - The tests

    private func skipUnlessStudy() throws {
        guard ProcessInfo.processInfo.environment[Self.studyVariable] != nil else {
            throw XCTSkip("the wobble study runs when \(Self.studyVariable) is set (it takes minutes)")
        }
    }

    /// The shipped configuration at the display's scale, against the floor: the guard.
    func test_theShippedEdges_atTheDisplaysScale_areAsStraightAsTheEyeResampled() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let setup = Setup(name: "shipped")
        let (rows, session, silhouettes) = try await measure(setup)
        try session.stop()
        printTable("the shipped configuration", rows)
        let frames = silhouettes.frames
        XCTAssertEqual(frames.pictureScale, Self.displayPixelsPerDefaultTexel, accuracy: 0.01, "the default eye is shown at \(Self.displayPixelsPerDefaultTexel) picture pixels per texel")
        let middle = try XCTUnwrap(silhouettes.tops.first { $0.name == "top of cube 1" }, "the middle cube's far edge")
        XCTAssertEqual(middle.slope, Self.rollSlope, accuracy: 0.002, "the middle cube's level far edge crosses the rows at the roll's slope")
        let floor = try XCTUnwrap(rows.first { $0.name.hasSuffix("blended (floor)") })
        let raster = try XCTUnwrap(rows.first { $0.name.hasSuffix("(a raster)") })
        let shipped = try XCTUnwrap(rows.first { $0.name.hasSuffix("(shipped)") })
        // Where the edges lie: within a pixel of the view's own projection, in every reading.
        for row in [floor, shipped] {
            XCTAssertEqual(row.top.offset, 0, accuracy: 1, "\(row.name): the top edges lie where the projection puts them")
            XCTAssertEqual(row.side.offset, 0, accuracy: 1, "\(row.name): the side edges lie where the projection puts them")
            XCTAssertEqual(row.sphere.offset, 0, accuracy: 1, "\(row.name): the sphere's outline lies where the projection puts it")
        }
        // The floor: the texture's coverage ramp resampled at the display's scale, a fraction
        // of a picture pixel; a raster of the cut shows the picture's own staircase.
        XCTAssertLessThan(floor.top.crossing.rms, 0.3, "the resampled eye's top edges are straight to a fraction of a display pixel")
        XCTAssertGreaterThan(raster.top.mask.rms, 0.2, "a raster of the cut at the pixel centres shows a one-pixel staircase")
        // The shipped chain: as straight as the floor, to a tenth of a pixel, on all three
        // silhouettes, read sub-pixel; and by the mask no worse than the raster's quantisation.
        XCTAssertEqual(shipped.top.crossing.rms, floor.top.crossing.rms, accuracy: 0.1, "the shipped top edges are as straight as the eye resampled")
        XCTAssertEqual(shipped.side.crossing.rms, floor.side.crossing.rms, accuracy: 0.1, "the shipped side edges are as straight as the eye resampled")
        XCTAssertEqual(shipped.sphere.crossing.rms, floor.sphere.crossing.rms, accuracy: 0.1, "the shipped outline is as round as the eye resampled")
        XCTAssertLessThan(shipped.top.crossing.rms, 0.35, "the shipped top edges wobble under a third of a display pixel")
        XCTAssertLessThan(shipped.top.mask.rms, 0.45, "read by a mask the shipped top edges are within a raster's quantisation")
    }

    /// The silhouette cells on the sphere's outline, from the eye the engine drew from and from
    /// eyes displaced by the pupil's half millimetre and by three millimetres (to the right, and
    /// up): the shipped skirt against the alpha crossing (`XRPresenterSilhouetteCells`), the
    /// shipped materials on both, RealityRenderer drawing with its 4x MSAA as the device draws
    /// (the crossing's boundary is geometry, which the multisampling resolves; the skirt's is
    /// the alpha test and the band, which it leaves as they are). Every reading is in picture
    /// pixels along the ray from the sphere's projected centre, against the view's own
    /// projection of the outline, so a cell drawn at the wrong depth shows as a shift of its
    /// crossing between the drawing eye and the displaced one (the parallax of its depth error:
    /// a texel a quarter of a metre behind the limb moves 0.6 picture pixels under 3 mm at
    /// 1.6 m), while a cell at the true depth holds its crossing. Printed per rule and view:
    /// where the outline lies against the projection (off), its wobble about the first two
    /// harmonics (rms), and each angle's shift from the drawing eye's reading (mean, rms, the
    /// worst), the shift being what breathes with the gaze on the headset; two rows without the
    /// multisampling show the crossing's boundary as a plain raster. A third source is the
    /// control: a RealityKit sphere of the same radius at the same place, geometry at the true
    /// depth drawn by RealityKit alone (the headset's control sphere), read the same way, which
    /// says how steady a geometric edge reads in this picture at all (the multisampling's
    /// quarter steps quantise the one-half crossing of a hard edge, whatever its depth). The
    /// crossing rule must hold the outline as the control holds it (within a twentieth of a
    /// picture pixel rms of the control's shift), and both rules lie where the projection puts
    /// the outline.
    func test_theSilhouetteCells_holdTheSphereOutline_fromADisplacedEye() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        struct View {
            let name: String
            let offset: simd_float3
            var multisampled = true
            var crossingOnly = false
        }
        let views = [
            View(name: "the drawing eye", offset: .zero),
            View(name: "0.5 mm right", offset: simd_float3(0.0005, 0, 0)),
            View(name: "3 mm right", offset: simd_float3(0.003, 0, 0)),
            View(name: "3 mm up", offset: simd_float3(0, 0.003, 0)),
            View(name: "the drawing eye, no MSAA", offset: .zero, multisampled: false, crossingOnly: true),
            View(name: "3 mm right, no MSAA", offset: simd_float3(0.003, 0, 0), multisampled: false, crossingOnly: true),
        ]
        struct Reading {
            let rule: String
            let view: String
            let offset: Float
            let rms: Float
            let shiftMean: Float
            let shiftRms: Float
            let shiftMax: Float
        }
        var readings: [Reading] = []
        let pose = Self.headPose()
        let controlName = "RealityKit sphere (control)"
        let sources: [XRPresenterSilhouetteCells?] = XRPresenterSilhouetteCells.allCases + [nil]
        for rule in sources {
            let name = rule?.label ?? controlName
            let setup = Setup(name: name) { $0.silhouetteCells = rule ?? .skirt }
            var session: EyeSession?
            var control: Entity?
            if let rule {
                let made = try await EyeSession(renderer: renderer, device: renderInfo.device, commandQueue: renderInfo.commandQueue, configuration: setup.configuration, pose: pose, reach: reach, readTexture: linearPixels(ofSRGB:))
                _ = try made.draw()
                XCTAssertEqual(made.presenter.settings.silhouetteCells, rule, "the rule rides in the settings")
                XCTAssertEqual(made.presenter.lastTicket?.indexBuffers.count ?? 0, rule == .alphaCrossing ? 2 : 0, "the crossing rewrites the index buffers each frame, the skirt keeps the mesh's")
                session = made
            } else {
                // The control: RealityKit's own sphere, unlit, at the engine sphere's place.
                let sphere = ModelEntity(mesh: .generateSphere(radius: Self.sphereRadius), materials: [UnlitMaterial(color: .white)])
                sphere.position = Self.sphereCentre
                let root = Entity()
                root.addChild(sphere)
                control = root
            }
            let screenSize = session?.presenter.textureSize ?? setup.configuration.textureSize
            var drawingEye: [Float]?
            var drawingEyeUnsampled: [Float]?
            for view in views where !view.crossingOnly || rule == .alphaCrossing {
                let frames = Frames(configuration: setup.configuration, screenSize: screenSize, pose: pose, viewOffset: view.offset)
                let outline = Self.outline(frames, samples: 720)
                let camera = try Camera(presenter: session?.presenter, scene: control, frames: frames, multisampled: view.multisampled, device: renderInfo.device)
                let black = try await camera.picture(background: 0)
                let white = try await camera.picture(background: 1)
                let shown = composite(black: black, white: white)
                let reading = read(shown, around: outline)
                let numbers = Self.numbers(of: reading, around: outline)
                // Each view against the drawing eye's reading drawn the same way.
                let reference: [Float]
                if view.multisampled {
                    reference = drawingEye ?? reading.crossings
                    if drawingEye == nil { drawingEye = reading.crossings }
                } else {
                    reference = drawingEyeUnsampled ?? reading.crossings
                    if drawingEyeUnsampled == nil { drawingEyeUnsampled = reading.crossings }
                }
                let shifts = zip(reading.crossings, reference).map { $0 - $1 }
                let count = Float(shifts.count)
                readings.append(Reading(
                    rule: name, view: view.name, offset: numbers.offset, rms: numbers.crossing.rms,
                    shiftMean: shifts.reduce(0, +) / count,
                    shiftRms: sqrt(shifts.map { $0 * $0 }.reduce(0, +) / count),
                    shiftMax: shifts.map { abs($0) }.max() ?? 0
                ))
                if let dumpFolder {
                    try writePNG(black, to: dumpFolder.appendingPathComponent("silhouette-cells-\(slug(name))-\(slug(view.name)).png"))
                }
            }
            try session?.stop()
        }
        print("XR presenter silhouette cells: the sphere's outline (radius 0.06 m at 1.6 m, 720 rays) at the display's scale, picture pixels: off = the one-half crossing's mean against the view's projection, rms = about its first two harmonics, shift = each ray's crossing against the drawing eye's reading (mean / rms / worst)")
        print("  " + Self.pad("source", 28) + Self.pad("view", 26) + ["off", "rms", "shift mean", "shift rms", "shift max"].map { Self.pad($0, 12) }.joined())
        for reading in readings {
            print("  " + Self.pad(reading.rule, 28) + Self.pad(reading.view, 26) + [reading.offset, reading.rms, reading.shiftMean, reading.shiftRms, reading.shiftMax].map { Self.pad(Self.format($0, 3), 12) }.joined())
        }
        func reading(_ rule: String, _ view: String) throws -> Reading {
            try XCTUnwrap(readings.first { $0.rule == rule && $0.view == view })
        }
        let skirtName = XRPresenterSilhouetteCells.skirt.label, crossingName = XRPresenterSilhouetteCells.alphaCrossing.label
        let skirt = try reading(skirtName, "the drawing eye")
        let crossing = try reading(crossingName, "the drawing eye")
        let control = try reading(controlName, "the drawing eye")
        XCTAssertEqual(skirt.offset, 0, accuracy: 1, "the skirt's outline lies where the projection puts it")
        XCTAssertEqual(crossing.offset, 0, accuracy: 1, "the crossing's outline lies where the projection puts it")
        XCTAssertEqual(control.offset, 0, accuracy: 1, "the control's outline lies where the projection puts it")
        for view in views.dropFirst() where view.multisampled {
            let displaced = try reading(crossingName, view.name)
            let controlDisplaced = try reading(controlName, view.name)
            XCTAssertLessThan(displaced.shiftRms, controlDisplaced.shiftRms + 0.05, "from \(view.name) the crossing rule holds the outline as RealityKit's own sphere holds its")
        }
    }

    /// The core's cut, the band, RealityRenderer's own MSAA and a view off the drawing eye,
    /// on the default eye.
    func test_wobbleStudy_theCutTheBandTheRasterAndTheView() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        try skipUnlessStudy()
        var setup = Setup(name: "default")
        setup.variants = [
            .shipped,
            Variant(name: "cut 0.9, no band", cut: 0.9, band: false),
            Variant(name: "cut 0.97, band", cut: 0.97, band: true),
            Variant(name: "cut 0.97, no band", cut: 0.97, band: false),
            Variant(name: "cut 0.99, band", cut: 0.99, band: true),
            Variant(name: "cut 0.99, no band", cut: 0.99, band: false),
            Variant(name: "no core, band over the whole grid", cut: nil, band: true, wholeGrid: true),
            Variant(name: "cut 0.9, band, RealityRenderer MSAA 4x", cut: 0.9, band: true, multisampled: true),
            Variant(name: "cut 0.9, no band, RealityRenderer MSAA 4x", cut: 0.9, band: false, multisampled: true),
            Variant(name: "cut 0.9, band, the view 3 mm above the drawing eye", cut: 0.9, band: true, viewOffset: simd_float3(0, 0.003, 0)),
            Variant(name: "cut 0.9, band, the view 3 mm right of the drawing eye", cut: 0.9, band: true, viewOffset: simd_float3(0.003, 0, 0)),
        ]
        let (rows, session, _) = try await measure(setup)
        try session.stop()
        printTable("the cut, the band, RealityKit's raster and the view", rows)
    }

    /// The grid's cell under the rate map, the uniform grid's size, the render scale, the rate
    /// map and the skirt, each with the shipped materials; each eye with its own floors.
    func test_wobbleStudy_theGridTheTextureAndTheSkirt() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        try skipUnlessStudy()
        let hasRateMaps = renderInfo.device.supportsRasterizationRateMap(layerCount: 1)
        var setups: [Setup] = [
            Setup(name: "uniform grid 512 x 480") {
                $0.gridColumns = 512
                $0.gridRows = 480
            },
            Setup(name: "uniform grid 512 x 480, skirt 1.5") {
                $0.gridColumns = 512
                $0.gridRows = 480
                $0.skirtTexels = 1.5
            },
            Setup(name: "skirt 0") { $0.skirtTexels = 0 },
            Setup(name: "render scale 1.5") { $0.renderScale = 1.5 },
        ]
        if hasRateMaps {
            setups += [
                Setup(name: "rate map, cells of 8") { $0.foveation = .equiAngular },
                Setup(name: "rate map, cells of 4") {
                    $0.foveation = .equiAngular
                    $0.foveatedCellTexels = 4
                },
                Setup(name: "rate map, render scale 1.5, cells of 8 (16 at 1.5)") {
                    $0.foveation = .equiAngular
                    $0.renderScale = 1.5
                },
                Setup(name: "rate map, render scale 1.5, cells of 4 (8 at 1.5)") {
                    $0.foveation = .equiAngular
                    $0.renderScale = 1.5
                    $0.foveatedCellTexels = 4
                },
            ]
        }
        var rows: [Row] = []
        for setup in setups {
            let (setupRows, session, _) = try await measure(setup)
            print("XR presenter edge wobble: \(setup.name): textures \(session.presenter.textureSize.x) x \(session.presenter.textureSize.y), grid \(session.presenter.grid.columns) x \(session.presenter.grid.rows)\(session.presenter.foveation.map { ", \($0.description)" } ?? "")")
            try session.stop()
            rows += setupRows
        }
        printTable("the grid, the texture and the skirt", rows)
        if !hasRateMaps { print("XR presenter edge wobble: this GPU has no rasterization rate maps; the rate map's rows were not measured") }
    }

    /// Eight poses a tenth of a texel apart: each picture's wobble, and the wobble of the
    /// residuals averaged over the eight (what an eye tracking the edge integrates as the head
    /// moves; a pattern locked to the display or the texels averages out, one locked to the
    /// grid's cells stays).
    func test_wobbleStudy_motion() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        try skipUnlessStudy()
        let setup = Setup(name: "motion")
        let defaults = setup.configuration
        let texelRadians = (defaults.frustumTangents.z + defaults.frustumTangents.w) / Float(defaults.textureSize.y)
        let stepRadians = 0.1 * texelRadians
        let poses = (0 ..< 8).map { Self.headPose(pitch: Float($0) * stepRadians, yaw: Float($0) * stepRadians) }
        let session = try await EyeSession(renderer: renderer, device: renderInfo.device, commandQueue: renderInfo.commandQueue, configuration: setup.configuration, pose: poses[0], reach: reach, readTexture: linearPixels(ofSRGB:))
        let stage = try Stage(presenter: session.presenter)
        let screenSize = session.presenter.textureSize
        var rows: [Row] = []
        // The middle cube's top edge, the right cube's side edge and the sphere, per pose:
        // the one-half crossing's residuals, of the picture and of the resampled eye.
        var residuals: [String: [[Float]]] = [:]
        var outlineSpacing: Float = 1
        func collect(_ picture: Picture, silhouettes: Silhouettes, as key: String) {
            let margin = Self.endMargin * silhouettes.frames.pictureScale
            let middle = silhouettes.tops.first { $0.name == "top of cube 1" } ?? silhouettes.tops[0]
            let top = read(picture, along: middle, margin: margin)
            residuals["\(key) top", default: []].append(Self.lineResiduals(top.along, top.crossings))
            let side = read(picture, along: silhouettes.sides[1], margin: margin)
            residuals["\(key) side", default: []].append(Self.lineResiduals(side.along, side.crossings))
            let sphere = read(picture, around: silhouettes.outline)
            residuals["\(key) sphere", default: []].append(Self.harmonicResiduals(silhouettes.outline.angles, sphere.crossings))
            outlineSpacing = silhouettes.outline.spacing
        }
        for (index, pose) in poses.enumerated() {
            session.poseBox.value = pose
            let eye = try session.draw()
            let frames = Frames(configuration: setup.configuration, screenSize: screenSize, pose: pose)
            let silhouettes = Silhouettes(frames: frames)
            try await stage.apply(.shipped)
            let camera = try Camera(presenter: session.presenter, frames: frames, multisampled: false, device: renderInfo.device)
            let black = try await camera.picture(background: 0)
            let white = try await camera.picture(background: 1)
            let shown = composite(black: black, white: white)
            let floor = resampledEye(eye, frames: frames, foveation: nil, cut: nil)
            collect(shown, silhouettes: silhouettes, as: "shipped")
            collect(floor, silhouettes: silhouettes, as: "floor")
            let name = "pose \(index) (+\(Self.format(Float(index) * 0.1, 1)) texel)"
            if index == 0 {
                rows.append(row("motion, \(name): the eye resampled, blended (floor)", of: floor, silhouettes: silhouettes))
            }
            rows.append(row("motion, \(name): cut 0.9, band (shipped)", of: shown, silhouettes: silhouettes))
        }
        try session.stop()
        printTable("eight poses a tenth of a texel apart", rows)
        // The residuals averaged over the poses, column by column (the edge moves a quarter of
        // a picture pixel per pose, so the columns line up).
        func averaged(_ sets: [[Float]], spacing: Float) -> (single: Float, averaged: Float, period: Float) {
            let count = sets.map(\.count).min() ?? 0
            guard count > 0 else { return (0, 0, .nan) }
            let single = sets.map { set in sqrt(set.prefix(count).map { $0 * $0 }.reduce(0, +) / Float(count)) }.reduce(0, +) / Float(sets.count)
            var mean = [Float](repeating: 0, count: count)
            for set in sets {
                for index in 0 ..< count { mean[index] += set[index] / Float(sets.count) }
            }
            return (single, sqrt(mean.map { $0 * $0 }.reduce(0, +) / Float(count)), Self.dominantPeriod(mean, spacing: spacing))
        }
        for key in ["shipped", "floor"] {
            let top = averaged(residuals["\(key) top"] ?? [], spacing: 1)
            let side = averaged(residuals["\(key) side"] ?? [], spacing: 1)
            let sphere = averaged(residuals["\(key) sphere"] ?? [], spacing: outlineSpacing)
            print("XR presenter edge wobble: motion, \(key), by the one-half crossing, a single pose -> the eight poses' residuals averaged, px rms: the middle cube's top edge \(Self.format(top.single)) -> \(Self.format(top.averaged)) (the average's period \(Self.format(top.period, 0)) px), the right cube's side edge \(Self.format(side.single)) -> \(Self.format(side.averaged)), the sphere \(Self.format(sphere.single)) -> \(Self.format(sphere.averaged))")
        }
    }

    // MARK: - PNGs

    /// A picture as an 8-bit sRGB PNG, for looking at what a test measured.
    private func writePNG(_ picture: Picture, to url: URL) throws {
        func encoded(_ value: Float) -> UInt8 {
            let clamped = min(max(value, 0), 1)
            let srgb = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt8((srgb * 255).rounded())
        }
        let width = picture.width, height = picture.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0 ..< width * height {
            for channel in 0 ..< 3 { bytes[index * 4 + channel] = encoded(picture.pixels[index * 4 + channel]) }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw XCTSkip("no PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
