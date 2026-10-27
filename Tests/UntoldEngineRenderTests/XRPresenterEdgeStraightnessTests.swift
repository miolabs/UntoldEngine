//
//  XRPresenterEdgeStraightnessTests.swift
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

/// How straight a silhouette comes out of the RealityKit presenter, measured on a Mac. The
/// example scene (a slab, three cubes, a sphere) is drawn into the headset's eye texture with
/// the eye 3.5 cm above the middle cube's top, so that the top face is a sliver one to two
/// texels tall whose far edge, against the passthrough, crosses the texture's rows at a shallow
/// slope (the head rolled by it): the edge the headset showed as a wavy rim. RealityKit then
/// draws the presenter's grids from that eye, magnified as the display magnifies them, over a
/// black and over a white room, which gives every output pixel's opacity and colour. The edge's
/// position per column is read two ways, where its opacity crosses one half and as the sum of
/// the opacity missing above it (where a hard edge with the same coverage would lie), a line is
/// fitted and the deviation about it reported in eye texels, for the core material's opacity
/// cut at several heights with and without the edge band, and for the band carrying the partly
/// covered texels at more than their coverage. The texture's own edge is measured the same way
/// as the reference: its coverage, and its staircase read as a hard edge.
@MainActor
final class XRPresenterEdgeStraightnessTests: BaseRenderSetup {
    private var viewportBefore = simd_float2(0, 0)
    private var styleBefore: UntoldImmersionMode = .none
    private var modeBefore: AntiAliasingMode = .fxaa

    // MARK: - The scene and the eye

    private nonisolated static let cubeExtent: Float = 0.2
    private nonisolated static let cubeCentreY: Float = 1.025
    private nonisolated static let cubeZ: Float = -1.6
    private nonisolated static let cubeXs: [Float] = [-0.35, 0, 0.35]
    /// The outer cubes turned about the vertical, degrees, as the example turns them.
    private nonisolated static func cubeAngle(_ index: Int) -> Float { Float(index) * 20 - 20 }
    /// The eye this far above the cubes' tops: the top faces are slivers of one to two texels.
    private nonisolated static let eyeAboveTopMetres: Float = 0.035
    /// The head rolled so that a level edge crosses one texture row every 25 columns: the
    /// staircase's period, as the headset's rim showed it.
    private nonisolated static let rollSlope: Float = 0.04
    /// RealityKit's picture is this many pixels per eye texel (the headset shows about 2.6).
    private nonisolated static let magnification: Float = 4
    private nonisolated static let pictureSize = SIMD2<Int>(2560, 640)

    /// The example scene of RealityKitPresenterExample, as its ExampleScene builds it.
    override func initializeAssets() {
        let slab = createEntity()
        setEntityName(entityId: slab, name: "Slab")
        setEntityMeshDirect(entityId: slab, meshes: BasicPrimitives.createCube(extent: 1), assetName: "Slab")
        scaleTo(entityId: slab, scale: simd_float3(1.2, 0.05, 0.6))
        translateTo(entityId: slab, position: simd_float3(0, 0.9, Self.cubeZ))
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
        setEntityMeshDirect(entityId: sphere, meshes: BasicPrimitives.createSphere(extent: 0.12), assetName: "Sphere")
        translateTo(entityId: sphere, position: simd_float3(0, 1.45, Self.cubeZ))
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

    /// The headset's pose: over the middle cube, the eyes just above its top, the head rolled.
    private nonisolated static var headPose: simd_float4x4 {
        let height = cubeCentreY + cubeExtent / 2 + eyeAboveTopMetres
        return matrix4x4Translation(0, height, 0) * matrix4x4Rotation(radians: atan(rollSlope), axis: simd_float3(0, 0, 1))
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

    // MARK: - Where things land in the texture and in the picture

    /// A world point as the left eye's texture and RealityKit's picture see it: the texel
    /// coordinates (the texel at column u spans u ..< u + 1, rows from the top), and the
    /// picture's pixel coordinates (the same convention). Both are perspective projections
    /// from the eye along its own axes, so each axis maps affinely from one to the other.
    private struct Projected {
        let u: Float
        let v: Float
        let column: Float
        let row: Float
    }

    private struct Frames {
        let configuration: XRRealityKitPresenterConfiguration
        let viewFromWorld: simd_float4x4
        let tanHalf: Float
        let aspect: Float

        init(configuration: XRRealityKitPresenterConfiguration, pose: simd_float4x4) {
            self.configuration = configuration
            viewFromWorld = simd_inverse(pose * configuration.deviceFromView(eye: 0))
            let texelsPerTangent = Float(configuration.textureSize.y) / (configuration.frustumTangents.z + configuration.frustumTangents.w)
            tanHalf = Float(pictureSize.y) / 2 / (texelsPerTangent * magnification)
            aspect = Float(pictureSize.x) / Float(pictureSize.y)
        }

        /// RealityKit's vertical field of view for the picture's magnification.
        var fieldOfViewDegrees: Float { 2 * atan(tanHalf) * 180 / .pi }

        func project(_ world: simd_float3) -> Projected {
            let clip = configuration.projection * viewFromWorld * simd_float4(world, 1)
            let ndc = simd_float3(clip.x, clip.y, clip.z) / clip.w
            let tangents = configuration.frustumTangents
            let tx = (ndc.x * (tangents.x + tangents.y) + (tangents.y - tangents.x)) / 2
            let ty = (ndc.y * (tangents.z + tangents.w) + (tangents.z - tangents.w)) / 2
            return Projected(
                u: (ndc.x + 1) / 2 * Float(configuration.textureSize.x),
                v: (1 - ndc.y) / 2 * Float(configuration.textureSize.y),
                column: (tx / (tanHalf * aspect) + 1) / 2 * Float(pictureSize.x),
                row: (1 - ty / tanHalf) / 2 * Float(pictureSize.y)
            )
        }
    }

    /// One straight stretch of a top face's upper silhouette: from a corner to the next along
    /// the top of the face's outline, where the passthrough lies above and the cube below.
    private struct Segment {
        let cube: Int
        let from: Projected
        let to: Projected

        var texelLength: Float { to.u - from.u }

        var slope: Float { (to.v - from.v) / (to.u - from.u) }

        func row(atColumn x: Float) -> Float {
            from.row + (to.row - from.row) * (x - from.column) / (to.column - from.column)
        }

        func v(atU x: Float) -> Float {
            from.v + (to.v - from.v) * (x - from.u) / (to.u - from.u)
        }
    }

    /// The upper outline of each cube's top face: the corners' upper hull, the stretches that
    /// are long and shallow enough to carry a staircase (the short steep sides are left out).
    private nonisolated static func segments(_ frames: Frames) -> [Segment] {
        var segments: [Segment] = []
        for cube in cubeXs.indices {
            let corners = topCorners(ofCube: cube).map(frames.project).sorted { $0.u < $1.u }
            // The upper hull, left to right: a corner is dropped while the chain turns upward
            // through it would leave a point of the face above the chain.
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
                let segment = Segment(cube: cube, from: hull[index], to: hull[index + 1])
                if segment.texelLength >= 20, abs(segment.slope) < 0.3 {
                    segments.append(segment)
                }
            }
        }
        return segments
    }

    // MARK: - Pictures

    /// Linear rgba floats, rows from the top.
    private struct Picture {
        let width: Int
        let height: Int
        var pixels: [Float]

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Float { pixels[(y * width + x) * 4 + c] }

        func alpha(_ x: Int, _ y: Int) -> Float { channel(x, y, 3) }

        func luminance(_ x: Int, _ y: Int) -> Float { 0.2126 * channel(x, y, 0) + 0.7152 * channel(x, y, 1) + 0.0722 * channel(x, y, 2) }
    }

    private enum PictureError: Swift.Error { case stalled(String) }

    private func reach(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw PictureError.stalled(what) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The engine's left eye for the head pose, drawn by the loop under MSAA, and the presenter
    /// stopped with its grids as the last frame placed them.
    @available(macOS 15.0, *)
    private func drawEngineEye(_ configuration: XRRealityKitPresenterConfiguration, pose: simd_float4x4) async throws -> (presenter: XRRealityKitPresenter, eye: Picture) {
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        guard presenter.usesShaderGraphMaterial else { throw XCTSkip("the eye material did not load") }
        guard presenter.hasEdgeBand else { throw XCTSkip("the band's graph did not load") }
        let source = RealityKitFrameSource(presenter: presenter) { _ in pose }
        let loop = XRFrameLoop(renderer: renderer, source: source, runtime: nil)
        setRendering(.antiAliasing(.msaa))
        loop.start()
        let thread = Thread { loop.run() }
        thread.start()
        presenter.start(commandQueue: renderInfo.commandQueue)
        try reach("six frames drawn") {
            presenter.update()
            return loop.framesDrawn >= 6
        }
        let lastTicket = try XCTUnwrap(presenter.lastTicket)
        try reach("the last ticket completed") { lastTicket.commandBuffer.status == .completed }
        presenter.stop()
        try reach("the loop's thread finished") { thread.isFinished }
        return try (presenter, linearPixels(ofSRGB: lastTicket.colorTextures[0]))
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

    /// RealityKit's renderer looking out of the left eye with the magnifying field of view.
    @available(macOS 15.0, *)
    @MainActor
    private final class Camera {
        let renderer: RealityRenderer
        let output: MTLTexture
        let cameraOutput: RealityRenderer.CameraOutput

        init(presenter: XRRealityKitPresenter, frames: Frames, pose: simd_float4x4, device: MTLDevice) throws {
            renderer = try RealityRenderer()
            renderer.cameraSettings.isToneMappingEnabled = false
            renderer.cameraSettings.antialiasing = .none
            let camera = Entity()
            camera.components.set(PerspectiveCameraComponent(near: frames.configuration.nearPlane, far: frames.configuration.farPlane, fieldOfViewInDegrees: frames.fieldOfViewDegrees))
            camera.transform = Transform(matrix: pose * frames.configuration.deviceFromView(eye: 0))
            renderer.activeCamera = camera
            renderer.entities.replaceAll([camera, presenter.root])
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
    /// black and the picture over white: over black a pixel is its colour times its opacity,
    /// over white that plus what the room adds through the rest.
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

    // MARK: - The variants

    /// How the band weights a texel's coverage.
    private enum BandWeight: String {
        /// The texel's alpha, the coverage: as shipped.
        case coverage
        /// Twice the coverage, at most 1: a half-covered texel opaque, a quarter at a half.
        case double
        /// 1 wherever the texel holds anything (alpha above 0.001): every touched texel opaque.
        case full
    }

    private struct Variant {
        let name: String
        /// The core's opacity cut; nil leaves the core out.
        let cut: Float?
        /// The band's weighting; nil leaves the band out.
        let band: BandWeight?
        /// The band over every cell of the grid instead of the cells along silhouettes.
        var wholeGrid = false
    }

    /// The shipped graphs with one thing changed, written next to the test for RealityKit to load.
    @available(macOS 15.0, *)
    private final class Graphs {
        private var files: [String: URL] = [:]
        private let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("XRPresenterEdgeStraightness-\(UUID().uuidString)", isDirectory: true)
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

        /// The band's graph weighting the coverage by `weight`.
        func band(weight: BandWeight) throws -> URL {
            var text = try text(ofResource: XRPresenterMaterial.edgeResourceName)
            let prim = XRPresenterMaterial.edgePrimPath
            let nodes: String
            switch weight {
            case .coverage:
                return try write(text, as: "band-coverage")
            case .double:
                nodes = """
                        def Shader "Doubled"
                        {
                            uniform token info:id = "ND_multiply_float"
                            float inputs:in1.connect = <\(prim)/Channels.outputs:outa>
                            float inputs:in2 = 2
                            float outputs:out
                        }
                """ + "\n" + """
                        def Shader "Weight"
                        {
                            uniform token info:id = "ND_min_float"
                            float inputs:in1.connect = <\(prim)/Doubled.outputs:out>
                            float inputs:in2 = 1
                            float outputs:out
                        }
                """
            case .full:
                nodes = """
                        def Shader "Weight"
                        {
                            uniform token info:id = "ND_ifgreater_float"
                            float inputs:in1 = 1
                            float inputs:in2 = 0
                            float inputs:value1.connect = <\(prim)/Channels.outputs:outa>
                            float inputs:value2 = 0.001
                            float outputs:out
                        }
                """
            }
            // The Shown node takes the weight instead of the alpha; the Straight node, which
            // divides the colour by the alpha, keeps the alpha.
            guard let shown = text.range(of: "        def Shader \"Shown\"\n") else { throw PictureError.stalled("the band's graph has no Shown node") }
            guard let end = text.range(of: "        }\n", range: shown.upperBound ..< text.endIndex) else { throw PictureError.stalled("the band's Shown node does not end") }
            let alphaInput = "float inputs:in1.connect = <\(prim)/Channels.outputs:outa>"
            let block = String(text[shown.lowerBound ..< end.upperBound])
            guard block.contains(alphaInput) else { throw PictureError.stalled("the band's Shown node does not take the alpha") }
            text.replaceSubrange(shown.lowerBound ..< end.upperBound, with: block.replacingOccurrences(of: alphaInput, with: "float inputs:in1.connect = <\(prim)/Weight.outputs:out>"))
            text.insert(contentsOf: nodes + "\n", at: text.range(of: "        def Shader \"Shown\"\n")!.lowerBound)
            return try write(text, as: "band-\(weight.rawValue)")
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
        /// switch shows the left eye's grid in, and the right eye's keep the shipped materials.
        func apply(_ variant: Variant) async throws {
            let eye = 0
            if let cut = variant.cut {
                cores[eye].model?.materials = try await [material(graphs.core(cut: cut), prim: XRPresenterMaterial.primPath, key: "core-\(cut)", eye: eye)]
            }
            cores[eye].isEnabled = variant.cut != nil
            if let weight = variant.band {
                bands[eye].model?.materials = try await [material(graphs.band(weight: weight), prim: XRPresenterMaterial.edgePrimPath, key: "band-\(weight.rawValue)", eye: eye)]
                if variant.wholeGrid, let core = cores[eye].model?.mesh {
                    bands[eye].model?.mesh = core
                } else {
                    bands[eye].model?.mesh = bandMeshes[eye]
                }
            }
            bands[eye].isEnabled = variant.band != nil
        }
    }

    // MARK: - The measurement

    /// An edge read along one stretch: its position per column two ways, in texels, and the
    /// opacity profiles the positions were read from.
    private struct EdgeReading {
        var columns: [Float] = []
        /// Where the opacity crosses one half, from above.
        var crossings: [Float] = []
        /// Where a hard edge with the window's total opacity would lie: the window's top plus the
        /// opacity missing above the edge.
        var integrals: [Float] = []
    }

    private struct LineFit {
        let rms: Float
        let peakToPeak: Float
        let slope: Float
        /// The fitted position at the stretch's middle column.
        let middle: Float
    }

    /// Residuals of a least-squares line through (x, y).
    private static func fit(_ xs: [Float], _ ys: [Float]) -> (residuals: [Float], slope: Float, intercept: Float) {
        let n = Float(xs.count)
        guard n >= 2 else { return ([], 0, ys.first ?? 0) }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx: Float = 0, sxy: Float = 0
        for (x, y) in zip(xs, ys) {
            sxx += (x - mx) * (x - mx)
            sxy += (x - mx) * (y - my)
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        let intercept = my - slope * mx
        return (zip(xs, ys).map { x, y in y - (intercept + slope * x) }, slope, intercept)
    }

    private static func lineFit(_ xs: [Float], _ ys: [Float]) -> LineFit {
        let (residuals, slope, intercept) = fit(xs, ys)
        let rms = residuals.isEmpty ? 0 : sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Float(residuals.count))
        let peakToPeak = residuals.isEmpty ? 0 : residuals.max()! - residuals.min()!
        let middle = intercept + slope * ((xs.first ?? 0) + (xs.last ?? 0)) / 2
        return LineFit(rms: rms, peakToPeak: peakToPeak, slope: slope, middle: middle)
    }

    /// Texels above the predicted edge the reading window starts, and below it it ends: the
    /// window is passthrough at its top and the cube at its bottom in every variant.
    private static let windowAbove: Float = 3
    private static let windowBelow: Float = 1.5
    /// Columns left out at each end of a stretch, texels: the corners' rounding.
    private static let endMargin: Float = 1.5

    /// The edge along `segment` in RealityKit's picture, per output column.
    private func read(_ picture: Picture, along segment: Segment) -> EdgeReading {
        let m = Self.magnification
        var reading = EdgeReading()
        let first = Int((segment.from.column + Self.endMargin * m).rounded(.up))
        let last = Int((segment.to.column - Self.endMargin * m).rounded(.down))
        guard first < last else { return reading }
        for column in first ... last {
            let x = Float(column) + 0.5
            let predicted = segment.row(atColumn: x)
            let top = Int((predicted - Self.windowAbove * m).rounded(.down))
            let bottom = Int((predicted + Self.windowBelow * m).rounded(.up))
            guard top >= 0, bottom < picture.height else { continue }
            var missing: Float = 0
            var crossing: Float?
            var previous: Float = 0
            for y in top ... bottom {
                let alpha = picture.alpha(column, y)
                missing += 1 - alpha
                if crossing == nil, alpha >= 0.5 {
                    // Between the pixel centres above and here.
                    let t = alpha > previous ? (0.5 - previous) / (alpha - previous) : 1
                    crossing = Float(y) - 0.5 + t
                }
                previous = alpha
            }
            reading.columns.append(x / m)
            reading.crossings.append((crossing ?? Float(bottom) + 0.5) / m)
            reading.integrals.append((Float(top) + missing) / m)
        }
        return reading
    }

    /// The texture's own edge along `segment`, per texel column: its coverage (the alpha summed),
    /// its one-half crossing between texel centres, and the coverage read as a hard edge at the
    /// shipped cut (texels at 0.9 or above opaque, the rest not).
    private func readTexture(_ eye: Picture, along segment: Segment, hardCut: Float) -> (coverage: EdgeReading, hard: EdgeReading) {
        var coverage = EdgeReading()
        var hard = EdgeReading()
        let first = Int((segment.from.u + Self.endMargin).rounded(.up))
        let last = Int((segment.to.u - Self.endMargin).rounded(.down))
        guard first < last else { return (coverage, hard) }
        for column in first ... last {
            let x = Float(column) + 0.5
            let predicted = segment.v(atU: x)
            let top = Int((predicted - Self.windowAbove).rounded(.down))
            let bottom = Int((predicted + Self.windowBelow).rounded(.up))
            guard top >= 0, bottom < eye.height else { continue }
            var missing: Float = 0, missingHard: Float = 0
            var crossing: Float?
            var previous: Float = 0
            for y in top ... bottom {
                let alpha = eye.alpha(column, y)
                missing += 1 - alpha
                missingHard += alpha >= hardCut ? 0 : 1
                if crossing == nil, alpha >= 0.5 {
                    let t = alpha > previous ? (0.5 - previous) / (alpha - previous) : 1
                    crossing = Float(y) - 0.5 + t
                }
                previous = alpha
            }
            coverage.columns.append(x)
            coverage.crossings.append(crossing ?? Float(bottom) + 0.5)
            coverage.integrals.append(Float(top) + missing)
            hard.columns.append(x)
            hard.crossings.append(Float(top) + missingHard)
            hard.integrals.append(Float(top) + missingHard)
        }
        return (coverage, hard)
    }

    /// A variant's numbers over every stretch.
    private struct VariantResult {
        let name: String
        /// Deviation about the fitted line, pooled over the stretches, texels rms and peak to peak.
        let integralRMS: Float
        let integralPeakToPeak: Float
        let crossingRMS: Float
        let crossingPeakToPeak: Float
        /// The rim pixels' luminance behind their opacity over the top face's, mean.
        let rimOverFace: Float
        let rimPixels: Int
        /// The edge's mean move against the reference, texels: negative is outward (the cube grown
        /// over the room, a halo of lost background), positive inward (the cube cut).
        let bias: Float
        /// Opaque pixels where the reference shows mostly room, per column, texels.
        let haloWidth: Float
    }

    private static func pooled(_ readings: [EdgeReading], _ pick: (EdgeReading) -> [Float]) -> (rms: Float, peakToPeak: Float) {
        var residuals: [Float] = []
        for reading in readings {
            residuals += fit(reading.columns, pick(reading)).residuals
        }
        guard !residuals.isEmpty else { return (0, 0) }
        return (sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Float(residuals.count)), residuals.max()! - residuals.min()!)
    }

    private static func format(_ value: Float, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }

    func test_theEdgeOfATopFaceSliver_throughTheCoreCutAndTheBand() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.pipelineDepth = 1 // one set: the picture is read at the first render
        configuration.silhouette = .cutAndBand // the test reads the cut and its band
        let pose = Self.headPose
        let frames = Frames(configuration: configuration, pose: pose)
        let segments = Self.segments(frames)
        XCTAssertGreaterThanOrEqual(segments.count, 3, "the three cubes' top faces each have a shallow upper edge")
        let middle = try XCTUnwrap(segments.first { $0.cube == 1 }, "the middle cube's far edge")
        XCTAssertEqual(middle.slope, Self.rollSlope, accuracy: 0.002, "the middle cube's level far edge crosses the rows at the roll's slope")
        XCTAssertGreaterThan(middle.texelLength, 60, "the middle cube's far edge is long enough for a few staircase periods")

        // The engine's eye under MSAA: the top faces' partly covered texels are the coverage.
        let (presenter, eye) = try await drawEngineEye(configuration, pose: pose)
        XCTAssertEqual(eye.width, configuration.textureSize.x)
        let fullyCovered = stride(from: 3, to: eye.pixels.count, by: 4).filter { eye.pixels[$0] >= 1 }.count
        let partlyCovered = stride(from: 3, to: eye.pixels.count, by: 4).filter { eye.pixels[$0] > 0 && eye.pixels[$0] < 1 }.count
        XCTAssertGreaterThan(fullyCovered, 10000, "the engine drew the scene into the eye")
        XCTAssertGreaterThan(partlyCovered, 200, "MSAA left partly covered texels along the silhouettes")

        // The texture's own edge: its coverage, and its staircase read as a hard edge.
        let textureReadings = segments.map { readTexture(eye, along: $0, hardCut: 0.9) }
        let textureCoverage = Self.pooled(textureReadings.map(\.coverage), \.integrals)
        let textureCrossing = Self.pooled(textureReadings.map(\.coverage), \.crossings)
        let textureHard = Self.pooled(textureReadings.map(\.hard), \.integrals)
        let middleIndex = try XCTUnwrap(segments.firstIndex { $0.cube == 1 })
        let middleTexture = textureReadings[middleIndex].coverage
        let middleFit = Self.lineFit(middleTexture.columns, middleTexture.integrals)
        print("XR presenter edge: the texture's far edge of the middle cube's top at row \(Self.format(middleFit.middle, 2)) (predicted \(Self.format(middle.v(atU: (middle.from.u + middle.to.u) / 2), 2))), slope \(Self.format(middleFit.slope, 4)) rows per column over \(middleTexture.columns.count) columns")
        print("XR presenter edge: the texture's coverage edge deviates \(Self.format(textureCoverage.rms)) texel rms (\(Self.format(textureCoverage.peakToPeak, 2)) peak to peak) about a line, its one-half crossing \(Self.format(textureCrossing.rms)) (\(Self.format(textureCrossing.peakToPeak, 2))), its staircase read as a hard edge at 0.9 \(Self.format(textureHard.rms)) (\(Self.format(textureHard.peakToPeak, 2)))")
        XCTAssertEqual(middleFit.middle, middle.v(atU: (middle.from.u + middle.to.u) / 2), accuracy: 1, "the texture's edge lies where the projection puts it")
        XCTAssertLessThan(textureCoverage.rms, 0.12, "read through its coverage the texture's edge is straight to the quarter steps' quantisation")
        XCTAssertGreaterThan(textureHard.rms, 0.2, "read as a hard edge the texture's edge is a one-texel staircase")

        // The top face's colour, from the texture: one texel below the far edge, inside the sliver.
        var faceLuminance: Float = 0
        var faceTexels = 0
        for column in Int((middle.from.u + Self.endMargin).rounded(.up)) ... Int((middle.to.u - Self.endMargin).rounded(.down)) {
            let row = Int((middle.v(atU: Float(column) + 0.5) + 1).rounded(.down))
            guard eye.alpha(column, row) >= 0.99 else { continue }
            faceLuminance += eye.luminance(column, row)
            faceTexels += 1
        }
        faceLuminance /= Float(max(faceTexels, 1))
        XCTAssertGreaterThan(faceTexels, 40, "the sliver has fully covered texels one row under its far edge")
        XCTAssertGreaterThan(faceLuminance, 0.05, "the top face is lit")
        // The texture's own rim texels over the face: one after the look pass's fix.
        var textureRim: Float = 0
        var textureRimTexels = 0
        for column in Int((middle.from.u + Self.endMargin).rounded(.up)) ... Int((middle.to.u - Self.endMargin).rounded(.down)) {
            let predicted = middle.v(atU: Float(column) + 0.5)
            for row in Int((predicted - 2).rounded(.down)) ... Int((predicted + 1).rounded(.up)) {
                let alpha = eye.alpha(column, row)
                guard alpha >= 0.1, alpha <= 0.9 else { continue }
                textureRim += eye.luminance(column, row) / alpha / faceLuminance
                textureRimTexels += 1
            }
        }
        textureRim /= Float(max(textureRimTexels, 1))
        print("XR presenter edge: the texture's \(textureRimTexels) rim texels under the middle cube's far edge are \(Self.format(textureRim)) times the face's luminance behind their coverage (face \(Self.format(faceLuminance)))")

        // RealityKit's pictures per variant.
        let stage = try Stage(presenter: presenter)
        let camera = try Camera(presenter: presenter, frames: frames, pose: pose, device: renderInfo.device)
        let reference = Variant(name: "reference: no core, band at coverage over the whole grid", cut: nil, band: .coverage, wholeGrid: true)
        let variants: [Variant] = [
            Variant(name: "cut 0.9, band at coverage (shipped)", cut: 0.9, band: .coverage),
            Variant(name: "cut 0.9, band at coverage over the whole grid", cut: 0.9, band: .coverage, wholeGrid: true),
            Variant(name: "cut 0.9, no band", cut: 0.9, band: nil),
            Variant(name: "cut 0.5, band at coverage", cut: 0.5, band: .coverage),
            Variant(name: "cut 0.5, no band", cut: 0.5, band: nil),
            Variant(name: "cut 0.25, band at coverage", cut: 0.25, band: .coverage),
            Variant(name: "cut 0.25, no band", cut: 0.25, band: nil),
            Variant(name: "cut 0.1, band at coverage", cut: 0.1, band: .coverage),
            Variant(name: "cut 0.1, no band", cut: 0.1, band: nil),
            Variant(name: "cut 0.9, band at double coverage", cut: 0.9, band: .double),
            Variant(name: "cut 0.9, band at full weight", cut: 0.9, band: .full),
        ]
        let dumpFolder = ProcessInfo.processInfo.environment["XR_PRESENTER_DUMP"].map { URL(fileURLWithPath: $0) }
        if let dumpFolder {
            try writePNG(eye, to: dumpFolder.appendingPathComponent("edge-engine-eye.png"))
        }

        func measure(_ variant: Variant, against referenceReadings: [EdgeReading]?, referencePicture: Picture?) async throws -> (VariantResult, [EdgeReading], Picture) {
            try await stage.apply(variant)
            let black = try await camera.picture(background: 0)
            let white = try await camera.picture(background: 1)
            let shown = composite(black: black, white: white)
            let readings = segments.map { read(shown, along: $0) }
            XCTAssertTrue(readings.allSatisfy { $0.columns.count > 20 }, "\(variant.name): every stretch was read")
            let integral = Self.pooled(readings, \.integrals)
            let crossing = Self.pooled(readings, \.crossings)
            // The rim's colour over the face along the middle cube's edge.
            var rim: Float = 0
            var rimPixels = 0
            let m = Self.magnification
            for column in Int((middle.from.column + Self.endMargin * m).rounded(.up)) ... Int((middle.to.column - Self.endMargin * m).rounded(.down)) {
                let predicted = middle.row(atColumn: Float(column) + 0.5)
                for row in Int((predicted - 2 * m).rounded(.down)) ... Int((predicted + 1 * m).rounded(.up)) {
                    let alpha = shown.alpha(column, row)
                    guard alpha >= 0.1, alpha <= 0.9 else { continue }
                    rim += shown.luminance(column, row) / faceLuminance
                    rimPixels += 1
                }
            }
            rim /= Float(max(rimPixels, 1))
            // Against the reference: the edge's move and the opaque pixels over the room.
            var bias: Float = 0
            var biasCount = 0
            var halo: Float = 0
            var haloColumns = 0
            if let referenceReadings, let referencePicture {
                for (reading, referenceReading) in zip(readings, referenceReadings) where reading.columns == referenceReading.columns {
                    for (a, b) in zip(reading.integrals, referenceReading.integrals) {
                        bias += a - b
                        biasCount += 1
                    }
                }
                for segment in segments {
                    for column in Int((segment.from.column + Self.endMargin * m).rounded(.up)) ... Int((segment.to.column - Self.endMargin * m).rounded(.down)) {
                        let predicted = segment.row(atColumn: Float(column) + 0.5)
                        var opaqueOverRoom = 0
                        for row in Int((predicted - Self.windowAbove * m).rounded(.down)) ... Int((predicted + Self.windowBelow * m).rounded(.up)) where shown.alpha(column, row) >= 0.95 && referencePicture.alpha(column, row) < 0.5 {
                            opaqueOverRoom += 1
                        }
                        halo += Float(opaqueOverRoom) / m
                        haloColumns += 1
                    }
                }
            }
            let result = VariantResult(
                name: variant.name,
                integralRMS: integral.rms, integralPeakToPeak: integral.peakToPeak,
                crossingRMS: crossing.rms, crossingPeakToPeak: crossing.peakToPeak,
                rimOverFace: rim, rimPixels: rimPixels,
                bias: biasCount > 0 ? bias / Float(biasCount) : 0,
                haloWidth: haloColumns > 0 ? halo / Float(haloColumns) : 0
            )
            if let dumpFolder {
                let slug = variant.name.map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "-" }.reduce(into: "") { $0.append($1) }
                try writePNG(black, to: dumpFolder.appendingPathComponent("edge-\(slug).png"))
            }
            return (result, readings, shown)
        }

        let (referenceResult, referenceReadings, referencePicture) = try await measure(reference, against: nil, referencePicture: nil)
        let referenceFit = Self.lineFit(referenceReadings[middleIndex].columns, referenceReadings[middleIndex].integrals)
        print("XR presenter edge: RealityKit's picture of the reference puts the middle cube's far edge at row \(Self.format(referenceFit.middle * Self.magnification, 1)) of the picture (predicted \(Self.format(middle.row(atColumn: (middle.from.column + middle.to.column) / 2), 1))), slope \(Self.format(referenceFit.slope, 4))")
        XCTAssertEqual(referenceFit.middle * Self.magnification, middle.row(atColumn: (middle.from.column + middle.to.column) / 2), accuracy: Self.magnification, "RealityKit's camera frames the eye as the texture does (a texel of tolerance)")
        XCTAssertEqual(referenceFit.slope, Self.rollSlope, accuracy: 0.004, "the edge crosses the picture's rows at the roll's slope")

        var results: [VariantResult] = [referenceResult]
        for variant in variants {
            let (result, _, _) = try await measure(variant, against: referenceReadings, referencePicture: referencePicture)
            results.append(result)
        }

        func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(width - text.count, 0))
            return left ? text + fill : fill + text
        }
        func row(_ name: String, _ cells: [String]) -> String {
            "  " + pad(name, 52, left: true) + cells.map { pad($0, 9) }.joined()
        }
        // The table.
        print("XR presenter edge straightness: the top faces' far edges, \(segments.count) stretches, the eye \(Int(Self.eyeAboveTopMetres * 1000)) mm above the tops, slope \(Self.rollSlope), \(Int(Self.magnification)) picture pixels per texel")
        print(row("variant", ["int rms", "p-p", "x rms", "p-p", "rim/face", "n", "bias", "halo"]))
        print(row("texture: coverage", [Self.format(textureCoverage.rms), Self.format(textureCoverage.peakToPeak, 2), Self.format(textureCrossing.rms), Self.format(textureCrossing.peakToPeak, 2)]))
        print(row("texture: hard edge at 0.9", [Self.format(textureHard.rms), Self.format(textureHard.peakToPeak, 2)]))
        for result in results {
            print(row(result.name, [Self.format(result.integralRMS), Self.format(result.integralPeakToPeak, 2), Self.format(result.crossingRMS), Self.format(result.crossingPeakToPeak, 2), Self.format(result.rimOverFace), "\(result.rimPixels)", Self.format(result.bias, 3), Self.format(result.haloWidth, 2)]))
        }
        try await stage.apply(variants[0])

        // The verdict. Through the shipped core cut and the band at coverage the edge is as
        // straight as the texture's coverage itself: the quarter steps of 4x MSAA, not the
        // one-texel staircase the cut alone shows. Every lower cut and every heavier band
        // weight draws more of the cube over the room (a halo of lost passthrough) and is no
        // straighter: the blend is what filters the staircase, and the cut's only job is to
        // keep the fully covered texels opaque and depth-writing.
        func result(_ name: String) throws -> VariantResult {
            try XCTUnwrap(results.first { $0.name == name }, name)
        }
        let shipped = try result("cut 0.9, band at coverage (shipped)")
        let noBand = try result("cut 0.9, no band")
        XCTAssertLessThan(shipped.integralRMS, 0.1, "through the shipped cut and band the edge is straight to the coverage's quantisation")
        XCTAssertLessThan(shipped.integralRMS, textureHard.rms / 2, "the shipped chain shows the coverage's edge, not the texture's staircase")
        XCTAssertEqual(shipped.integralRMS, referenceResult.integralRMS, accuracy: 0.01, "the band's cells blend every partly covered texel the whole grid's band blends")
        XCTAssertEqual(shipped.bias, 0, accuracy: 0.05, "the shipped edge lies where the coverage puts it")
        XCTAssertEqual(shipped.haloWidth, 0, accuracy: 0.02, "the shipped chain draws nothing opaque over the room")
        XCTAssertEqual(shipped.rimOverFace, textureRim, accuracy: 0.05, "the rim's colour behind its opacity is the face's, as in the texture")
        XCTAssertGreaterThan(noBand.integralRMS, 0.15, "the cut alone, without the band, shows the staircase")
        for other in results where other.name != shipped.name {
            XCTAssertGreaterThanOrEqual(other.integralRMS, shipped.integralRMS - 0.005, "\(other.name) is no straighter than the shipped configuration")
        }
        for name in ["cut 0.25, no band", "cut 0.1, no band", "cut 0.9, band at full weight"] {
            let variant = try result(name)
            XCTAssertLessThan(variant.bias, -0.3, "\(name) grows the cube over the room")
            XCTAssertGreaterThan(variant.haloWidth, 0.2, "\(name) draws opaque pixels where the coverage shows mostly room")
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
