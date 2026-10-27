//
//  XRLightingParityLimbTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import simd
@testable import UntoldEngine
import XCTest

/// How the engine lights a glossy sphere's body and its limb, in the two configurations a
/// game meets on the headset (docs/proposals/XRLightingParity.md):
///
/// - as the RealityKit presenter example lights it (2026-10-27): an authored sun of strength
///   3 straight above and nothing else chosen, which leaves the engine's defaults in force,
///   the bundled `teatro_massimo_2k.hdr` as the static environment at an ambient of 0.4 with
///   the image light off (`applyIBL` false: the irradiance alone, no reflection). The sphere's
///   top is the sun's, its bottom the bundled picture's floor, and the room the wearer sits in
///   plays no part;
/// - as a game that chose the room estimate (`.realWorldEstimate`) is lit: the probe,
///   pre-filtered as the headset's is, published as the sole environment, here an even one.
///
/// The scene is the example's: a sphere of radius 6 cm at (0, 1.45, -1.6), roughness 0.2, seen
/// from an eye at (0, 1.5, 0) through the presenter's frustum into its eye texture, under 4x
/// MSAA on the forward path the headset takes; the resolved lit colour is read back before the
/// look pass (linear, premultiplied by the coverage, the coverage in alpha). What is read: the
/// body near the top and near the bottom, and along the bottom arc the lowest fully covered
/// texel of every column against the texel two rows in (a limb that reflects more than the
/// body shows there), and the lowest partly covered texel against it (what a compositor blends
/// by its coverage).
@MainActor
final class XRLightingParityLimbTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)
    private var drawableSizeBefore = CGSize.zero
    private var modeBefore: AntiAliasingMode = .fxaa
    private var pathBefore: RenderPath = .deferred
    private var ambientBefore: Float = 0.4
    private var sphere: EntityID = .invalid
    private var sun: EntityID = .invalid

    // MARK: - The scene and the eye

    /// The presenter's eye texture and frustum (XRRealityKitPresenterConfiguration's defaults).
    private nonisolated static let eyeTextureSize = SIMD2<Int>(1920, 1824)
    private nonisolated static let frustumTangents = SIMD4<Float>(1.30, 1.30, 1.15, 1.30)
    private nonisolated static let nearPlane: Float = 0.05
    private nonisolated static let farPlane: Float = 1000
    private nonisolated static let eyePosition = simd_float3(0, 1.5, 0)
    private nonisolated static let sphereCentre = simd_float3(0, 1.45, -1.6)
    private nonisolated static let sphereRadius: Float = 0.06

    /// The even probe's radiance: what a white matte surface under it shows, as the
    /// irradiance map stores it (over pi).
    private nonisolated static let probeRadiance: Float = 0.5
    /// The RealityKit control sphere's colour (`ControlCube.color`, sRGB 0.70, 0.78, 0.92) in
    /// linear light, as RealityKit reads a UIColor.
    private nonisolated static let controlColor = simd_float3(0.448, 0.571, 0.831)

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: Self.eyePosition, target: Self.eyePosition + simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))

        sphere = createEntity()
        setEntityName(entityId: sphere, name: "Sphere")
        setEntityMeshDirect(entityId: sphere, meshes: BasicPrimitives.createSphere(extent: Self.sphereRadius * 2), assetName: "Sphere")
        translateTo(entityId: sphere, position: Self.sphereCentre)
        updateMaterialRoughness(entityId: sphere, roughness: 0.2)
        updateMaterialMetallic(entityId: sphere, metallic: 0)
        updateMaterialColor(entityId: sphere, color: .white)

        // The example's sun: straight above (createDirLight's default elevation), strength 3.
        // The renderer brings a light of its own, straight overhead at strength 1, and a new
        // light takes over only when there is none: retire it first.
        LightingSystem.shared.activeDirectionalLight = nil
        sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        setLight(entityId: sun, .strength(3))
        XCTAssertEqual(LightingSystem.shared.activeDirectionalLight, sun, "the example's sun lights the scene")

        // Nothing behind the sphere: its coverage is read from the alpha.
        renderSkyBackground = false
        renderEnvironment = false
    }

    override func setUp() async throws {
        try await super.setUp()
        viewportBefore = renderInfo.viewPort
        drawableSizeBefore = renderer.metalView.drawableSize
        modeBefore = antiAliasingMode
        pathBefore = getRenderPath()
        ambientBefore = ambientIntensity
        // The headset's path, and the eye texture's size and the presenter's projection in
        // place of the window's.
        setRendering(.renderPath(.forward))
        let size = CGSize(width: Self.eyeTextureSize.x, height: Self.eyeTextureSize.y)
        renderer.metalView.drawableSize = size
        renderer.mtkView(renderer.metalView, drawableSizeWillChange: size)
        renderInfo.viewPort = simd_float2(Float(size.width), Float(size.height))
        renderInfo.perspectiveSpace = Self.reverseZProjection(tangents: Self.frustumTangents, near: Self.nearPlane, far: Self.farPlane)
        TemporalAntiAliasing.shared.projectionDidChange()
        renderer.initSizeableResources()
        renderer.pendingResize = false
    }

    override func tearDown() async throws {
        RuntimeEnvironmentLightingStore.shared.publishXRLighting(nil)
        RuntimeEnvironmentLightingStore.shared.setMode(.staticIBL)
        RuntimeEnvironmentLightingStore.shared.realWorldLightingContribution = 1
        ambientIntensity = ambientBefore
        applyIBL = false
        antiAliasingMode = modeBefore
        updateOpaqueSampleCountForCurrentState()
        setRendering(.renderPath(pathBefore))
        renderer.metalView.drawableSize = drawableSizeBefore
        renderInfo.viewPort = viewportBefore
        renderer.initSizeableResources()
        destroyAllEntities()
        sphere = .invalid
        sun = .invalid
        try await super.tearDown()
    }

    /// The presenter's projection: right-handed, reverse Z, from the half-angle tangents.
    private nonisolated static func reverseZProjection(tangents: SIMD4<Float>, near: Float, far: Float) -> simd_float4x4 {
        let width = tangents.x + tangents.y
        let height = tangents.z + tangents.w
        let zs = near / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>((tangents.y - tangents.x) / width, (tangents.z - tangents.w) / height, zs, -1),
            SIMD4<Float>(0, 0, zs * far, 0)
        ))
    }

    // MARK: - The lighting

    /// The example's lighting as the device has it: the engine's defaults (the bundled HDR's
    /// irradiance at the default ambient, no reflection) and the sun at a strength.
    private func lightAsTheExampleDoes(sun strength: Float) {
        RuntimeEnvironmentLightingStore.shared.publishXRLighting(nil)
        RuntimeEnvironmentLightingStore.shared.setMode(.staticIBL)
        applyIBL = false
        ambientIntensity = 0.4
        setLight(entityId: sun, .strength(strength))
    }

    /// The room estimate's lighting with an even room: a probe of one radiance on every face,
    /// pre-filtered as the headset's room probe is, published as the environment at a scale of
    /// 1 and the full contribution, the ambient at 1 so that the probe is applied as it is;
    /// and the sun at a strength (0 for the room alone).
    private func lightWithAnEvenRoom(sun strength: Float) throws {
        let device = try XCTUnwrap(renderInfo.device)
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let cube = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let value = Float16(Self.probeRadiance)
        var texels = [UInt16](repeating: 0, count: 8 * 8 * 4)
        for i in 0 ..< 64 {
            texels[i * 4] = value.bitPattern
            texels[i * 4 + 1] = value.bitPattern
            texels[i * 4 + 2] = value.bitPattern
            texels[i * 4 + 3] = Float16(1.0).bitPattern
        }
        for face in 0 ..< 6 {
            texels.withUnsafeBytes { bytes in
                cube.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, slice: face, withBytes: bytes.baseAddress!, bytesPerRow: 8 * 8, bytesPerImage: 8 * 8 * 8)
            }
        }
        let set = try XCTUnwrap(makeRuntimeEnvironmentLightingTextureSet(labelPrefix: "Even room"))
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        XCTAssertTrue(executeXRIBLCubePreFilterPass(commandBuffer: commandBuffer, environmentCubeTexture: cube, target: set))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        print("XR lighting parity: the probe's pre-filter (harmonics, 256 by 256 maps, six specular levels) took \(String(format: "%.2f", (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)) ms of GPU time")
        RuntimeEnvironmentLightingStore.shared.publishXRLighting(RuntimeEnvironmentLighting(
            irradianceMap: set.irradianceMap, specularMap: set.specularMap, brdfMap: set.brdfMap, intensityScale: 1, isValid: true
        ))
        RuntimeEnvironmentLightingStore.shared.realWorldLightingContribution = 1
        RuntimeEnvironmentLightingStore.shared.setMode(.realWorldEstimate)
        ambientIntensity = 1
        setLight(entityId: sun, .strength(strength))
    }

    // MARK: - The eye texture

    /// Linear rgba floats, rows from the top: the resolved lit colour (premultiplied by the
    /// coverage) and the coverage in alpha.
    private struct Picture {
        let width: Int
        let height: Int
        var pixels: [Float]

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Float {
            pixels[(y * width + x) * 4 + c]
        }

        func alpha(_ x: Int, _ y: Int) -> Float {
            channel(x, y, 3)
        }

        /// The colour over the coverage: what the surface was shaded.
        func straightColor(_ x: Int, _ y: Int) -> simd_float3 {
            let a = alpha(x, y)
            guard a > 0.001 else { return .zero }
            return simd_float3(channel(x, y, 0), channel(x, y, 1), channel(x, y, 2)) / a
        }

        func luminance(_ x: Int, _ y: Int) -> Float {
            let c = straightColor(x, y)
            return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }
    }

    /// The eye drawn under 4x MSAA (three frames, so that nothing of a previous frame's
    /// resources is read), the resolved lit colour read back.
    private func drawEye() throws -> Picture {
        guard renderInfo.device.supportsTextureSampleCount(4) else { throw XCTSkip("this GPU has no 4x MSAA") }
        antiAliasingMode = .msaa
        updateOpaqueSampleCountForCurrentState()
        XCTAssertEqual(renderInfo.opaqueSampleCount, 4, "the opaque pass is multisampled")
        for _ in 0 ..< 3 {
            setVisibleEntities()
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        let texture = try XCTUnwrap(textureResources.deferredColorMap, "the resolved lit colour")
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
        XCTAssertEqual(texture.width, Self.eyeTextureSize.x)
        XCTAssertEqual(texture.height, Self.eyeTextureSize.y)
        var halves = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return Picture(width: texture.width, height: texture.height, pixels: halves.map { Float(Float16(bitPattern: $0)) })
    }

    // MARK: - The readings

    /// Where the sphere stands on the centre column: the first run of coverage from the top.
    private struct SphereRows {
        let column: Int
        let top: Int
        let bottom: Int
        var centre: Int {
            (top + bottom) / 2
        }
    }

    private func findSphere(in eye: Picture) throws -> SphereRows {
        let column = eye.width / 2
        var top: Int?
        var bottom = 0
        for y in 0 ..< eye.height {
            if eye.alpha(column, y) > 0 {
                if top == nil {
                    top = y
                }
                bottom = y
            } else if top != nil {
                break
            }
        }
        let topRow = try XCTUnwrap(top, "the sphere covers the centre column")
        let rows = SphereRows(column: column, top: topRow, bottom: bottom)
        let height = bottom - topRow + 1
        // Radius 6 cm at 1.6 m, 744 texels per unit tangent: about 56 texels across.
        XCTAssertGreaterThan(height, 40, "the run on the centre column is the sphere (\(height) rows)")
        XCTAssertLessThan(height, 80, "the run on the centre column is the sphere alone (\(height) rows)")
        return rows
    }

    /// The body: the centre column three rows inside the top, the centre, and three rows
    /// inside the bottom (fully covered texels, the surface itself).
    private struct Body {
        let top: Float
        let centre: Float
        let bottom: Float
        let topColor: simd_float3
        let bottomColor: simd_float3
    }

    private func readBody(of eye: Picture, sphere: SphereRows) -> Body {
        let x = sphere.column
        let topRow = sphere.top + 3, bottomRow = sphere.bottom - 3
        XCTAssertGreaterThanOrEqual(eye.alpha(x, topRow), 0.999, "the top body texel is fully covered")
        XCTAssertGreaterThanOrEqual(eye.alpha(x, bottomRow), 0.999, "the bottom body texel is fully covered")
        return Body(
            top: eye.luminance(x, topRow), centre: eye.luminance(x, sphere.centre), bottom: eye.luminance(x, bottomRow),
            topColor: eye.straightColor(x, topRow), bottomColor: eye.straightColor(x, bottomRow)
        )
    }

    /// One column's texel at the bottom edge against the texel two rows inside it.
    private struct EdgeReading {
        let column: Int
        let row: Int
        let coverage: Float
        let edge: Float
        let inside: Float
        var ratio: Float {
            edge / max(inside, 0.005)
        }
    }

    /// Along the bottom arc, for every column the sphere covers: the lowest fully covered
    /// texel against the one two rows up (`full`), and the lowest covered texel where it is
    /// partly covered against the fully covered texel two rows up (`partial`).
    private func readBottomArc(of eye: Picture, sphere: SphereRows) -> (full: [EdgeReading], partial: [EdgeReading], columns: Int) {
        var full: [EdgeReading] = []
        var partial: [EdgeReading] = []
        var columns = 0
        let halfWidth = (sphere.bottom - sphere.top) / 2 + 4
        for x in max(0, sphere.column - halfWidth) ... min(eye.width - 1, sphere.column + halfWidth) {
            var lowest: Int?
            for y in stride(from: min(eye.height - 1, sphere.bottom + 3), through: max(0, sphere.top - 3), by: -1) where eye.alpha(x, y) > 0 {
                lowest = y
                break
            }
            guard let row = lowest, row >= 4 else { continue }
            columns += 1
            if eye.alpha(x, row) < 0.999, eye.alpha(x, row - 2) >= 0.999 {
                partial.append(EdgeReading(column: x, row: row, coverage: eye.alpha(x, row), edge: eye.luminance(x, row), inside: eye.luminance(x, row - 2)))
            }
            var lowestFull: Int?
            for y in stride(from: row, through: max(0, sphere.top - 3), by: -1) where eye.alpha(x, y) >= 0.999 {
                lowestFull = y
                break
            }
            if let fullRow = lowestFull, fullRow >= 2, eye.alpha(x, fullRow - 2) >= 0.999 {
                full.append(EdgeReading(column: x, row: fullRow, coverage: 1, edge: eye.luminance(x, fullRow), inside: eye.luminance(x, fullRow - 2)))
            }
        }
        return (full, partial, columns)
    }

    private nonisolated static func format(_ value: Float, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    private nonisolated static func format(_ color: simd_float3) -> String {
        "(\(format(color.x)), \(format(color.y)), \(format(color.z)))"
    }

    private func report(_ label: String, body: Body, arc: (full: [EdgeReading], partial: [EdgeReading], columns: Int)) {
        let fullRatios = arc.full.map(\.ratio)
        let partialRatios = arc.partial.map(\.ratio)
        func summary(_ ratios: [Float]) -> String {
            guard !ratios.isEmpty else { return "none" }
            let mean = ratios.reduce(0, +) / Float(ratios.count)
            return "\(ratios.count), mean ratio \(Self.format(mean)), max \(Self.format(ratios.max() ?? 0)), min \(Self.format(ratios.min() ?? 0)), \(ratios.filter { $0 > 1.5 }.count) over 1.5x"
        }
        print("XR lighting parity [\(label)]: body top \(Self.format(body.top)) \(Self.format(body.topColor)), centre \(Self.format(body.centre)), bottom \(Self.format(body.bottom)) \(Self.format(body.bottomColor)); top/bottom \(Self.format(body.top / max(body.bottom, 0.0005), 2))")
        print("XR lighting parity [\(label)]: bottom arc over \(arc.columns) columns, lowest full texels against two rows in: \(summary(fullRatios)); partly covered edge texels: \(summary(partialRatios))")
    }

    // MARK: - As the example lights it

    /// The example's scene on the device: the sun from above makes the top and the bundled
    /// picture's floor the bottom, a tenth of the top, in the picture's colour and not the
    /// room's; the bottom limb shades like the surface beside it (a normal turned round into
    /// the sun would make a fully covered edge texel several times the texel two rows in).
    func testAsTheExampleLightsIt_theSunMakesTheTopAndTheBundledPictureTheBottom() throws {
        lightAsTheExampleDoes(sun: 3)
        let eye = try drawEye()
        let sphere = try findSphere(in: eye)
        let body = readBody(of: eye, sphere: sphere)
        let arc = readBottomArc(of: eye, sphere: sphere)
        report("example, sun 3, bundled picture at 0.4", body: body, arc: arc)

        // The sun alone gives 3 / pi = 0.95 to a white surface facing it; the bundled
        // picture's ceiling adds its share at 0.4.
        XCTAssertGreaterThan(body.top, 0.9, "the top is the sun's")
        // The bundled picture's floor over pi is (0.12, 0.16, 0.22) (its lower hemisphere's
        // irradiance), at 0.4: about 0.06 in luminance, bluer than it is bright.
        XCTAssertGreaterThan(body.bottom, 0.03, "the bottom is lit by the bundled picture's floor")
        XCTAssertLessThan(body.bottom, 0.15, "the bottom gets no sun")
        XCTAssertGreaterThan(body.bottomColor.z, body.bottomColor.x * 1.3, "the bottom carries the bundled picture's blue, not the room's")

        XCTAssertGreaterThan(arc.columns, 40, "the sphere spans the columns read")
        XCTAssertGreaterThan(arc.full.count, 20, "the bottom arc has fully covered edge texels")
        let fullOver = arc.full.filter { $0.ratio > 1.5 }
        XCTAssertEqual(fullOver.count, 0, "no fully covered texel at the bottom edge is over 1.5x the texel two rows in (\(fullOver.count) of \(arc.full.count); the first at column \(fullOver.first?.column ?? -1), \(Self.format(fullOver.first?.ratio ?? 0, 2))x)")
        let partialOver = arc.partial.filter { $0.ratio > 1.5 }
        XCTAssertEqual(partialOver.count, 0, "no partly covered edge texel at the bottom is over 1.5x the texel two rows in (\(partialOver.count) of \(arc.partial.count))")
    }

    /// The same scene with the sun at 0.5: the bottom is the same, the top loses most of the
    /// sun's share and keeps the bundled picture's ceiling (the contrast falls from eighteen to
    /// one to eight to one, measured).
    func testAsTheExampleLightsIt_aWeakerSunLowersTheContrastAndNothingElse() throws {
        lightAsTheExampleDoes(sun: 3)
        let strong = try drawEye()
        let strongSphere = try findSphere(in: strong)
        let strongBody = readBody(of: strong, sphere: strongSphere)
        lightAsTheExampleDoes(sun: 0.5)
        let weak = try drawEye()
        let weakSphere = try findSphere(in: weak)
        let weakBody = readBody(of: weak, sphere: weakSphere)
        report("example, sun 0.5, bundled picture at 0.4", body: weakBody, arc: readBottomArc(of: weak, sphere: weakSphere))

        XCTAssertEqual(weakBody.bottom, strongBody.bottom, accuracy: 0.01, "the bottom gets no sun at either strength")
        XCTAssertGreaterThan(strongBody.top / max(strongBody.bottom, 0.0005), 12, "sun 3: the top is over twelve times the bottom (18 measured)")
        // The sun's share of the top falls to a sixth; the bundled picture's ceiling keeps its
        // own (0.46, six times its floor), so the top stays several times the bottom.
        XCTAssertLessThan(weakBody.top, strongBody.top * 0.55, "sun 0.5: the top loses most of the sun's share")
        XCTAssertGreaterThan(weakBody.top, strongBody.top * 0.35, "sun 0.5: the top keeps the picture's ceiling and a sixth of the sun")
    }

    // MARK: - Under the room estimate

    /// A white glossy sphere in an even room, lit by the room estimate alone: it shows the
    /// room's radiance all over, the limb included (what the limb reflects it does not
    /// scatter; the two shares sum to one, Fresnel or not). The engine's environment term
    /// conserves energy at grazing angles, so a limb that stands out is a scene's contrast,
    /// not a fault of the term.
    func testUnderAnEvenRoom_aWhiteSphereIsTheRoomAllOverAndAtItsLimb() throws {
        try lightWithAnEvenRoom(sun: 0)
        let eye = try drawEye()
        let sphere = try findSphere(in: eye)
        let body = readBody(of: eye, sphere: sphere)
        let arc = readBottomArc(of: eye, sphere: sphere)
        report("even room 0.5, white, no sun", body: body, arc: arc)

        XCTAssertEqual(body.centre, Self.probeRadiance, accuracy: 0.04, "the body shows the room's radiance")
        XCTAssertEqual(body.top, Self.probeRadiance, accuracy: 0.04, "the top shows the room's radiance")
        XCTAssertEqual(body.bottom, Self.probeRadiance, accuracy: 0.04, "the bottom shows the room's radiance")
        XCTAssertGreaterThan(arc.full.count, 20, "the bottom arc has fully covered edge texels")
        let worst = arc.full.map(\.ratio).max() ?? 0
        let best = arc.full.map(\.ratio).min() ?? 0
        XCTAssertLessThan(worst, 1.12, "the limb reflects no more than the body gives back (the brightest edge texel against two rows in)")
        XCTAssertGreaterThan(best, 0.88, "the limb reflects no less than the body gives back")
    }

    /// The RealityKit control sphere's colour in the same even room: the limb is brighter than
    /// the body by the room's light the limb reflects instead of tinting, a few percent to a
    /// fifth (Fresnel at grazing incidence, which RealityKit's physically based material has
    /// too), and a sun of strength 3 above it makes the top twice the bottom and more.
    func testUnderAnEvenRoom_aColouredSphereShowsAFaintFresnelRimAndTheSunSetsTheContrast() throws {
        try lightWithAnEvenRoom(sun: 0)
        // The base colour as the shader takes it, linear.
        XCTAssertTrue(updateMaterial(entityId: sphere, mutate: { $0.baseColorValue = simd_float4(Self.controlColor, 1) }), "the sphere takes the control colour")
        let eye = try drawEye()
        let sphere = try findSphere(in: eye)
        let body = readBody(of: eye, sphere: sphere)
        let arc = readBottomArc(of: eye, sphere: sphere)
        report("even room 0.5, control colour, no sun", body: body, arc: arc)

        // A matte surface of this colour gives back its colour times the room; the glossy one
        // gives back a little more, and its limb more again.
        let matte = Self.probeRadiance * (0.2126 * Self.controlColor.x + 0.7152 * Self.controlColor.y + 0.0722 * Self.controlColor.z)
        XCTAssertGreaterThan(body.centre, matte * 0.95, "the body is the room times the colour, and a touch of reflection")
        XCTAssertLessThan(body.centre, matte * 1.15, "the body reflects only a little head on")
        let ratios = arc.full.map(\.ratio)
        let mean = ratios.reduce(0, +) / Float(max(ratios.count, 1))
        XCTAssertGreaterThan(mean, 1.02, "the limb reflects the room over the body's colour (the Fresnel rim)")
        XCTAssertLessThan(mean, 1.25, "the rim is faint: the limb reflects a fraction of the room")
        XCTAssertLessThan(ratios.max() ?? 0, 1.4, "no edge texel reflects more than a limb does")

        try lightWithAnEvenRoom(sun: 3)
        let sunlit = try drawEye()
        let sunlitSphere = try findSphere(in: sunlit)
        let sunlitBody = readBody(of: sunlit, sphere: sunlitSphere)
        report("even room 0.5, control colour, sun 3", body: sunlitBody, arc: readBottomArc(of: sunlit, sphere: sunlitSphere))
        XCTAssertGreaterThan(sunlitBody.top / max(sunlitBody.bottom, 0.0005), 2, "a sun of 3 over a room of 0.5 makes the top twice the bottom and more")

        try lightWithAnEvenRoom(sun: 0.5)
        let keyed = try drawEye()
        let keyedSphere = try findSphere(in: keyed)
        let keyedBody = readBody(of: keyed, sphere: keyedSphere)
        report("even room 0.5, control colour, sun 0.5", body: keyedBody, arc: readBottomArc(of: keyed, sphere: keyedSphere))
        XCTAssertLessThan(keyedBody.top / max(keyedBody.bottom, 0.0005), 1.6, "a sun of 0.5 over a room of 0.5 keeps the top within 1.6x the bottom")
    }
}
