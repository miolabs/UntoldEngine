// TEMPORARY EXPERIMENT (not for commit): what a rasterization rate map costs the board's frame
// on the Mac, pass by pass, with the engine's own pass timing.
import Metal
import simd
import SwiftUI
@testable import UntoldEngine
import XCTest

@MainActor
final class BoardFoveationExperiment: BaseRenderSetup {
    private var board: EntityID!
    private var sun: EntityID!

    override func tearDown() async throws {
        renderInfo.xrFoveation = nil
        applyXRFoveationToSceneRenderPassDescriptors()
        setRendering(.gpuPassTiming(.disabled))
        setRendering(.perFragmentIndirectLighting(.enabled))
        setRendering(.perFragmentLighting(.enabled))
        setRendering(.multisampleCount(4))
        antiAliasingMode = .fxaa
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        assetBasePath = URL(fileURLWithPath: "/Users/godshadow/Projects/Untold/UntoldArcade-viewer/UntoldViewer/Viewer/Resources")
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 0.45), target: .zero, up: simd_float3(0, 1, 0))
        loadBoard(filename: "board", ext: "untold", base: "/Users/godshadow/Projects/Untold/UntoldArcade-viewer/UntoldViewer/Viewer/Resources")
        sun = createEntity()
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, pitch: -40, yaw: 20, roll: 0)
        applyIBL = true
    }

    /// The light experiments want the environment alone.
    private func removeSun() {
        if let sun { destroyEntity(entityId: sun); self.sun = nil }
        LightingSystem.shared.activeDirectionalLight = nil
    }

    private func loadBoard(filename: String, ext: String, base: String) {
        if let board { destroyEntity(entityId: board) }
        assetBasePath = URL(fileURLWithPath: base)
        board = createEntity()
        setEntityMesh(entityId: board, filename: filename, withExtension: ext)
        // Fit the camera to whatever loaded: the board's radius over the vertical field of view.
        _ = frameGPUMilliseconds()
        let local = scene.get(component: LocalTransformComponent.self, for: board)!.boundingBox
        let world = scene.get(component: WorldTransformComponent.self, for: board)!.space
        let centre4 = world * simd_float4((local.min + local.max) * 0.5, 1)
        let centre = simd_float3(centre4.x, centre4.y, centre4.z)
        let radius = simd_length(local.max - local.min) * 0.5
        let distance = max(radius * 1.8, 0.05)
        if let camera = CameraSystem.shared.activeCamera {
            if ext == "untold" {
                cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 0.45), target: .zero, up: simd_float3(0, 1, 0))
            } else {
                cameraLookAt(entityId: camera, eye: centre + simd_float3(0, 0, distance), target: centre, up: simd_float3(0, 1, 0))
            }
        }
        print(String(format: "BOARD %@: bounds %.3f %.3f %.3f .. %.3f %.3f %.3f, radius %.3f, camera at %.3f", filename, local.min.x, local.min.y, local.min.z, local.max.x, local.max.y, local.max.z, radius, distance))
    }

    private func resize(_ width: Int, _ height: Int) {
        let size = CGSize(width: width, height: height)
        renderer.metalView.drawableSize = size
        renderer.metalView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        renderer.mtkView(renderer.metalView, drawableSizeWillChange: size)
        renderer.pendingResize = true
        renderer.initSizeableResources()
        renderer.pendingResize = false
    }

    /// A rate map over a screen whose size is the physical size divided by the profile's mean
    /// rate, the same profile across and down. Returns the map and its screen size.
    private func makeRateMap(physicalWidth: Int, physicalHeight: Int, profile: [Float]) -> (MTLRasterizationRateMap, MTLSize)? {
        let mean = profile.reduce(0, +) / Float(profile.count)
        let screen = MTLSize(width: Int(Float(physicalWidth) / mean), height: Int(Float(physicalHeight) / mean), depth: 1)
        let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: profile.count, height: profile.count, depth: 0))
        for (i, rate) in profile.enumerated() {
            layer.horizontal[i] = rate
            layer.vertical[i] = rate
        }
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: screen, layer: layer)
        descriptor.label = "Experiment foveation"
        guard let map = renderInfo.device.makeRasterizationRateMap(descriptor: descriptor) else { return nil }
        return (map, screen)
    }

    private func foveate(_ profile: [Float]) {
        guard let (map, screen) = makeRateMap(physicalWidth: 1920, physicalHeight: 1080, profile: profile) else {
            XCTFail("no rate map"); return
        }
        let physical = map.physicalSize(layer: 0)
        resize(physical.width, physical.height)
        let buffer = renderInfo.device.makeBuffer(length: max(map.parameterDataSizeAndAlign.size, 64), options: .storageModeShared)!
        let data = XRRasterizationRateMapData(rateMap: map, buffer: buffer)!
        renderInfo.xrFoveation = XRFoveationFrame(
            rateMap: map,
            viewport: MTLViewport(originX: 0, originY: 0, width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1),
            rateMapData: data
        )
        applyXRFoveationToSceneRenderPassDescriptors()
        print(String(format: "FOV map: screen %d×%d, physical %d×%d", screen.width, screen.height, physical.width, physical.height))
    }

    private func unfoveate(physicalWidth: Int, physicalHeight: Int) {
        renderInfo.xrFoveation = nil
        resize(physicalWidth, physicalHeight)
        applyXRFoveationToSceneRenderPassDescriptors()
    }

    private func frameGPUMilliseconds() -> Double {
        renderer.draw(in: renderer.metalView)
        guard let cb = renderInfo.lastCommandBuffer else { return 0 }
        cb.waitUntilCompleted()
        return (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }

    private func measure(_ label: String) {
        for _ in 0 ..< 15 { _ = frameGPUMilliseconds() }
        var samples: [Double] = []
        var cpuSamples: [Double] = []
        for _ in 0 ..< 40 {
            let start = CACurrentMediaTime()
            renderer.draw(in: renderer.metalView)
            cpuSamples.append((CACurrentMediaTime() - start) * 1000)
            guard let cb = renderInfo.lastCommandBuffer else { continue }
            cb.waitUntilCompleted()
            samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        samples.sort()
        cpuSamples.sort()
        print(String(format: "CPU %@: draw() %.2f ms median (p10 %.2f, p90 %.2f), %d draws", label, cpuSamples[20], cpuSamples[4], cpuSamples[36], RenderStatsCollector.shared.snapshot().drawCallsTotal))
        let passes = GPUPassTiming.shared.averages()
        func pass(_ name: String) -> String {
            guard let p = passes.first(where: { $0.label == name }) else { return "\(name) -" }
            return p.vertexMs > 0.005 ? String(format: "%@ v%.2f f%.2f", name, p.vertexMs, p.fragmentMs) : String(format: "%@ %.2f", name, p.fragmentMs)
        }
        print(String(format: "FOV %@: frame %.2f ms (p10 %.2f, p90 %.2f) at %.0f×%.0f ×%d | %@ | %@ | %@ | %@ | %@ | draws %d plain",
                     label, samples[20], samples[4], samples[36], renderInfo.viewPort.x, renderInfo.viewPort.y, renderInfo.opaqueSampleCount,
                     pass("Forward"), pass("G-Buffer"), pass("TAA"), pass("Post"), pass("Shadows"), renderInfo.opaqueDrawsPlain))
    }

    private func profile(edge: Float) -> [Float] {
        // Full rate in the middle four quanta, falling to `edge` at the sides, 16 quanta.
        let half: [Float] = [edge, edge, edge * 1.2, edge * 1.6, edge * 2.2, edge * 3, 1, 1].map { min($0, 1) }
        return half + half.reversed()
    }

    func testBoardLODLevels() {
        loadBoard(filename: "board", ext: "untold", base: "/Users/godshadow/Projects/Untold/UntoldArcade-viewer/UntoldViewer/Viewer/Resources")
        _ = frameGPUMilliseconds()
        let lodId = getComponentId(for: LODComponent.self)
        let entities = queryEntitiesWithComponentIds([lodId], in: scene)
        print("LOD: \(entities.count) entities with LOD components")
        var byLevels: [Int: Int] = [:]
        for entityId in entities {
            guard let lod = scene.get(component: LODComponent.self, for: entityId) else { continue }
            byLevels[lod.lodLevels.count, default: 0] += 1
        }
        print("LOD: level counts \(byLevels.sorted { $0.key < $1.key })")
        for entityId in entities.prefix(6) {
            guard let lod = scene.get(component: LODComponent.self, for: entityId) else { continue }
            let levels = lod.lodLevels.enumerated().map { index, level -> String in
                let meshes = level.mesh.count
                let textured = level.mesh.flatMap(\.submeshes).filter { $0.material?.baseColor.texture != nil }.count
                let subs = level.mesh.flatMap(\.submeshes).count
                return "L\(index): \(meshes) meshes, \(textured)/\(subs) textured submeshes, screen \(level.screenPercentage ?? -1), max \(level.maxDistance)"
            }
            print("LOD entity \(entityId): shareMaterials \(lod.levelsShareMaterials), byScreen \(lod.selectsByScreenSize), current \(lod.currentLOD): \(levels.joined(separator: " | "))")
        }
    }

    func testRateMapCost() {
        setRendering(.gpuPassTiming(.enabled))
        setRendering(.tileLightStage(.disabled))
        loadBoard(filename: "board", ext: "untold", base: "/Users/godshadow/Projects/Untold/UntoldArcade-viewer/UntoldViewer/Viewer/Resources")
        antiAliasingMode = .msaaTaa
        setRendering(.multisampleCount(4))
        foveate(profile(edge: 0.125))
        measure("x4 forward slim")
        setRendering(.tileLightStage(.enabled))
    }

    // MARK: - The headset's tour on the Mac

    /// The lit pixels of a frame (alpha over a half) and their mean luminance, sampled every
    /// other row and column of the opaque pass's resolved colour.
    private func litFrameLuminance() -> (pixels: Int, luminance: Float, halves: [UInt16], width: Int, height: Int) {
        guard let texture = textureResources.deferredColorMap else { return (0, 0, [], 0, 0) }
        var halves = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var sum: Float = 0
        var count = 0
        for y in stride(from: 0, to: texture.height, by: 2) {
            for x in stride(from: 0, to: texture.width, by: 2) {
                let i = (y * texture.width + x) * 4
                let a = Float(Float16(bitPattern: halves[i + 3]))
                if a < 0.5 { continue }
                let r = Float(Float16(bitPattern: halves[i]))
                let g = Float(Float16(bitPattern: halves[i + 1]))
                let b = Float(Float16(bitPattern: halves[i + 2]))
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                count += 1
            }
        }
        return (count, count > 0 ? sum / Float(count) : 0, halves, texture.width, texture.height)
    }

    private func savePPM(_ halves: [UInt16], width: Int, height: Int, to path: String) {
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0 ..< width * height {
            for c in 0 ..< 3 {
                let v = max(0, min(1, Float(Float16(bitPattern: halves[p * 4 + c]))))
                bytes[p * 3 + c] = UInt8(powf(v, 1 / 2.2) * 255)
            }
        }
        data.append(contentsOf: bytes)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func testTourLuminance() throws {
        let out = "/private/tmp/claude-501/-Users-godshadow-Projects-Untold-UntoldEngine--claude-worktrees-laughing-heyrovsky-2b5b5c/80a6b544-fc46-42eb-ba24-778b24015f67/scratchpad/tour"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        resize(1280, 720)
        loadBoard(filename: "board", ext: "untold", base: "/Users/godshadow/Projects/Untold/UntoldArcade-viewer/UntoldViewer/Viewer/Resources")
        let camera = try XCTUnwrap(CameraSystem.shared.activeCamera)
        cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 0), target: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
        let distance: Float = 1.2
        let period = 24.0
        let fps = 30.0
        func pose(at time: Double) -> (position: simd_float3, yaw: Float) {
            let phase = time.truncatingRemainder(dividingBy: period)
            func ease(_ u: Double) -> Float { Float(0.5 - 0.5 * cos(min(max(u, 0), 1) * .pi)) }
            let approach = distance * 0.7
            var offset = simd_float3(0, 0, 0)
            var yaw: Float = 0
            switch phase {
            case ..<6: offset = simd_float3(0, 0, 1) * (approach * ease(phase / 6))
            case ..<12: offset = simd_float3(0, 0, 1) * (approach * (1 - ease((phase - 6) / 6)))
            case ..<18: offset = simd_float3(1, 0, 0) * Float(sin((phase - 12) / 6 * 2 * .pi)) * 0.6
            default: yaw = Float(sin((phase - 18) / 6 * 2 * .pi)) * (25 * .pi / 180)
            }
            return (simd_float3(0, 0, -distance) + offset, yaw)
        }
        let configs: [(label: String, mode: AntiAliasingMode, perFragment: Bool, occlusion: Bool)] = [
            ("forward msaaTaa", .msaaTaa, true, true),
            ("forward msaaTaa occlusion off", .msaaTaa, true, false),
        ]
        defer { setRendering(.occlusionCullingMaxCameraStep(0.5)) }
        for config in configs {
            antiAliasingMode = config.mode
            setRendering(.multisampleCount(4))
            setRendering(.occlusionCullingMaxCameraStep(config.occlusion ? 0.5 : 0))
            setRendering(.perFragmentLighting(config.perFragment ? .enabled : .disabled))
            setRendering(.perFragmentIndirectLighting(.enabled))
            for _ in 0 ..< 5 { _ = frameGPUMilliseconds() }
            var recent: [Float] = []
            var dark = 0
            var saved = 0
            var previous: (halves: [UInt16], width: Int, height: Int)?
            var minimum: Float = .greatestFiniteMagnitude
            var maximum: Float = 0
            let frames = Int(period * fps)
            for frame in 0 ..< frames {
                let time = Double(frame) / fps
                let p = pose(at: time)
                translateTo(entityId: board, position: p.position)
                rotateTo(entityId: board, rotation: simd_quatf(angle: p.yaw, axis: simd_float3(0, 1, 0)))
                _ = frameGPUMilliseconds()
                let lit = litFrameLuminance()
                minimum = min(minimum, lit.luminance)
                maximum = max(maximum, lit.luminance)
                let draws = renderInfo.opaqueDrawsPlain
                if recent.count >= 8 {
                    let median = recent.sorted()[recent.count / 2]
                    if median > 0, lit.luminance < 0.6 * median {
                        dark += 1
                        let hzb = getHZBDebugStats()
                        print(String(format: "DARK %@: frame %d t=%.2f luminance %.4f (median of the last %d: %.4f), %d lit pixels, %d draws, hzb valid %d used %d candidates %d visible %d occluded %d", config.label, frame, time, lit.luminance, recent.count, median, lit.pixels, draws, hzb.hzbIsValid ? 1 : 0, hzb.usedHZBThisFrame ? 1 : 0, hzb.frustumCandidateCount, hzb.visibleAfterOcclusionCount, hzb.occludedCount))
                        if saved < 3 {
                            if let previous { savePPM(previous.halves, width: previous.width, height: previous.height, to: "\(out)/\(config.label.replacingOccurrences(of: " ", with: "_"))_\(frame - 1)_before.ppm") }
                            savePPM(lit.halves, width: lit.width, height: lit.height, to: "\(out)/\(config.label.replacingOccurrences(of: " ", with: "_"))_\(frame)_dark.ppm")
                            saved += 1
                        }
                    }
                }
                recent.append(lit.luminance)
                if recent.count > 8 { recent.removeFirst() }
                previous = (lit.halves, lit.width, lit.height)
                if frame % 60 == 0 {
                    print(String(format: "TOUR %@: frame %d t=%.1f luminance %.4f, %d lit pixels, %d draws", config.label, frame, time, lit.luminance, lit.pixels, draws))
                }
            }
            print(String(format: "TOUR %@: %d dark frames of %d, luminance %.4f .. %.4f", config.label, dark, frames, minimum, maximum))
        }
    }

    // MARK: - The light: energy and orientation

    private func scratch(_ name: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/claude-501/-Users-godshadow-Projects-Untold-UntoldEngine--claude-worktrees-laughing-heyrovsky-2b5b5c/80a6b544-fc46-42eb-ba24-778b24015f67/scratchpad/\(name)")
    }

    /// A Radiance .hdr of one value everywhere (flat RGBE scanlines).
    private func writeUniformHDR(value: Float, to url: URL) throws {
        let width = 64, height = 32
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8)
        let exponent = Int(ceil(log2(value)))
        let mantissa = UInt8(min(255, max(0, Int((value / powf(2, Float(exponent))) * 256))))
        let e = UInt8(exponent + 128)
        for _ in 0 ..< width * height { data.append(contentsOf: [mantissa, mantissa, mantissa, e]) }
        try data.write(to: url)
    }

    private func litPixel(_ x: Int, _ y: Int) -> simd_float3 {
        guard let texture = textureResources.deferredColorMap else { return .zero }
        var halves = [UInt16](repeating: 0, count: 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(min(x, texture.width - 1), min(y, texture.height - 1), 1, 1), mipmapLevel: 0)
        }
        return simd_float3(Float(Float16(bitPattern: halves[0])), Float(Float16(bitPattern: halves[1])), Float(Float16(bitPattern: halves[2])))
    }

    private func makeSphere(_ name: String, at position: simd_float3, colour: Color, roughness: Float, metallic: Float) -> EntityID {
        let entity = createEntity()
        setEntityMeshDirect(entityId: entity, meshes: BasicPrimitives.createSphere(extent: 0.5), assetName: name)
        translateTo(entityId: entity, position: position)
        updateMaterialColor(entityId: entity, color: colour)
        updateMaterialRoughness(entityId: entity, roughness: roughness)
        updateMaterialMetallic(entityId: entity, metallic: metallic)
        return entity
    }

    private func drawSync() {
        renderer.draw(in: renderer.metalView)
        renderInfo.lastCommandBuffer?.waitUntilCompleted()
    }

    /// Three spheres under a uniform environment of 0.5: a white rough sphere must read the
    /// irradiance less its reflection (≈ 0.48), chrome the environment itself (0.5), a black
    /// one its 4 % reflection over 0.03 of the light (≈ 0.035).
    func testSpheresUnderUniformLight() throws {
        if let board { destroyEntity(entityId: board); self.board = nil }
        removeSun()
        resize(1280, 720)
        let camera = try XCTUnwrap(CameraSystem.shared.activeCamera)
        cameraLookAt(entityId: camera, eye: .zero, target: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
        let hdr = scratch("uniform.hdr")
        try writeUniformHDR(value: 0.5, to: hdr)
        setRendering(.environment(.asset("uniform.hdr", directory: hdr.deletingLastPathComponent())))
        setRendering(.environment(.intensity(1.0)))
        applyIBL = true
        setRendering(.perFragmentLighting(.enabled))
        setRendering(.perFragmentIndirectLighting(.enabled))
        antiAliasingMode = .none
        // Radius 0.25 at 2 m: ~9 % of the height; centres at x = ±0.6.
        let white = makeSphere("white", at: simd_float3(-0.6, 0, -2), colour: .white, roughness: 1, metallic: 0)
        let black = makeSphere("black", at: simd_float3(0, 0, -2), colour: Color(red: 0.03, green: 0.03, blue: 0.03), roughness: 1, metallic: 0)
        let chrome = makeSphere("chrome", at: simd_float3(0.6, 0, -2), colour: .white, roughness: 0.05, metallic: 1)
        _ = (white, black, chrome)
        for _ in 0 ..< 3 { drawSync() }
        let tanHalf = tanf(65 / 2 * .pi / 180)
        func pixelX(_ x: Float) -> Int { Int(640 + (x / 2 / (tanHalf * 1280 / 720)) * 640) }
        let centreY = 360
        let w = litPixel(pixelX(-0.6), centreY), b = litPixel(pixelX(0), centreY), c = litPixel(pixelX(0.6), centreY)
        let wTop = litPixel(pixelX(-0.6), centreY - 50)
        print(String(format: "SPHERES uniform 0.5: white centre %.3f %.3f %.3f (top %.3f), black centre %.3f %.3f %.3f, chrome centre %.3f %.3f %.3f; expected white ≈ 0.48, black ≈ 0.035, chrome ≈ 0.5", w.x, w.y, w.z, wTop.x, b.x, b.y, b.z, c.x, c.y, c.z))
        func texel(_ texture: MTLTexture?, _ label: String) {
            guard let texture else { print("IBL \(label): none"); return }
            var halves = [UInt16](repeating: 0, count: 4)
            halves.withUnsafeMutableBytes { bytes in
                texture.getBytes(bytes.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0)
            }
            print(String(format: "IBL %@ (%dx%d, format %d): centre %.3f %.3f %.3f", label, texture.width, texture.height, texture.pixelFormat.rawValue, Float(Float16(bitPattern: halves[0])), Float(Float16(bitPattern: halves[1])), Float(Float16(bitPattern: halves[2]))))
        }
        texel(textureResources.iblEnvironmentTexture, "source")
        texel(textureResources.irradianceMap, "irradiance")
        texel(textureResources.specularMap, "specular")
        print(String(format: "IBL ambientIntensity %.3f", ambientIntensity))
        // The loader's transfer: what a file of 1.0 and of 0.25 read back as.
        for value: Float in [1.0, 0.25] {
            let url = scratch(String(format: "uniform_%.2f.hdr", value))
            try writeUniformHDR(value: value, to: url)
            setRendering(.environment(.asset(url.lastPathComponent, directory: url.deletingLastPathComponent())))
            drawSync()
            texel(textureResources.iblEnvironmentTexture, String(format: "source for a file of %.2f", value))
        }
        setRendering(.environment(.asset("teatro_massimo_2k")))
    }

    /// A probe cube with one sun-bright texel on the face that lights what faces the camera,
    /// prefiltered as the headset's room probe is, on a white rough sphere: the shading across
    /// the sphere must be a smooth gradient. Prints a ridge measure (the mean absolute second
    /// difference along the sphere's middle row, over its range) and saves the frame.
    func testProbeSwirl() throws {
        if let board { destroyEntity(entityId: board); self.board = nil }
        removeSun()
        resize(1280, 720)
        let camera = try XCTUnwrap(CameraSystem.shared.activeCamera)
        cameraLookAt(entityId: camera, eye: .zero, target: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
        applyIBL = true
        antiAliasingMode = .none
        setRendering(.perFragmentLighting(.enabled))
        setRendering(.perFragmentIndirectLighting(.enabled))
        _ = makeSphere("white", at: simd_float3(0, 0, -2), colour: .white, roughness: 1, metallic: 0)
        let device = renderInfo.device!
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let cube = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let set = try XCTUnwrap(makeRuntimeEnvironmentLightingTextureSet(labelPrefix: "Swirl"))
        defer {
            RuntimeEnvironmentLightingStore.shared.publishXRLighting(nil)
            RuntimeEnvironmentLightingStore.shared.setMode(.staticIBL)
        }
        for face in 0 ..< 6 {
            var texels = [UInt16](repeating: 0, count: 8 * 8 * 4)
            for i in 0 ..< 64 {
                let sun = face == 4 && i == 3 * 8 + 4 // one texel of the +z face, near its centre
                let value = Float16(sun ? 40.0 : 0.05)
                texels[i * 4] = value.bitPattern; texels[i * 4 + 1] = value.bitPattern; texels[i * 4 + 2] = value.bitPattern; texels[i * 4 + 3] = Float16(1.0).bitPattern
            }
            texels.withUnsafeBytes { bytes in
                cube.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, slice: face, withBytes: bytes.baseAddress!, bytesPerRow: 8 * 8, bytesPerImage: 8 * 8 * 8)
            }
        }
        let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
        XCTAssertTrue(executeXRIBLCubePreFilterPass(commandBuffer: commandBuffer, environmentCubeTexture: cube, target: set))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        RuntimeEnvironmentLightingStore.shared.publishXRLighting(RuntimeEnvironmentLighting(irradianceMap: set.irradianceMap, specularMap: set.specularMap, brdfMap: set.brdfMap, intensityScale: 1, isValid: true))
        RuntimeEnvironmentLightingStore.shared.setMode(.realWorldEstimate)
        for _ in 0 ..< 2 { drawSync() }
        let tanHalf = tanf(65 / 2 * .pi / 180)
        let radiusPixels = Int(0.25 / 2 / tanHalf * 360)
        let r = Int(Float(radiusPixels) * 0.85)
        var row: [Float] = []
        for x in (640 - r) ... (640 + r) { row.append(litPixel(x, 360).x) }
        var second: Float = 0
        for i in 1 ..< row.count - 1 { second += abs(row[i - 1] - 2 * row[i] + row[i + 1]) }
        let range = max((row.max() ?? 0) - (row.min() ?? 0), 1e-4)
        let ridge = second / Float(row.count - 2) / range
        let frame = litFrameLuminance()
        savePPM(frame.halves, width: frame.width, height: frame.height, to: scratch("swirl.ppm").path)
        print(String(format: "SWIRL middle row: min %.4f max %.4f, ridge %.5f (second difference / range per pixel); frame saved", row.min() ?? 0, row.max() ?? 0, ridge))
    }

    /// A probe cube with one bright face at a time, prefiltered as the headset's room probe
    /// is, lighting a white rough sphere: which side of the sphere each face lights.
    func testProbeOrientation() throws {
        if let board { destroyEntity(entityId: board); self.board = nil }
        removeSun()
        resize(1280, 720)
        let camera = try XCTUnwrap(CameraSystem.shared.activeCamera)
        cameraLookAt(entityId: camera, eye: .zero, target: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
        applyIBL = true
        antiAliasingMode = .none
        setRendering(.perFragmentLighting(.enabled))
        setRendering(.perFragmentIndirectLighting(.enabled))
        _ = makeSphere("white", at: simd_float3(0, 0, -2), colour: .white, roughness: 1, metallic: 0)
        let device = renderInfo.device!
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let cube = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let set = try XCTUnwrap(makeRuntimeEnvironmentLightingTextureSet(labelPrefix: "Orientation"))
        let names = ["+x", "-x", "+y", "-y", "+z", "-z"]
        let tanHalf = tanf(65 / 2 * .pi / 180)
        let radiusPixels = Int(0.25 / 2 / tanHalf * 360) // sphere radius on screen
        let r = Int(Float(radiusPixels) * 0.75)
        defer {
            RuntimeEnvironmentLightingStore.shared.publishXRLighting(nil)
            RuntimeEnvironmentLightingStore.shared.setMode(.staticIBL)
        }
        for bright in 0 ..< 6 {
            for face in 0 ..< 6 {
                let value = Float16(face == bright ? 1.0 : 0.02)
                var texels = [UInt16](repeating: 0, count: 8 * 8 * 4)
                for i in 0 ..< 64 { texels[i * 4] = value.bitPattern; texels[i * 4 + 1] = value.bitPattern; texels[i * 4 + 2] = value.bitPattern; texels[i * 4 + 3] = Float16(1.0).bitPattern }
                texels.withUnsafeBytes { bytes in
                    cube.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, slice: face, withBytes: bytes.baseAddress!, bytesPerRow: 8 * 8, bytesPerImage: 8 * 8 * 8)
                }
            }
            let commandBuffer = try XCTUnwrap(renderInfo.commandQueue.makeCommandBuffer())
            XCTAssertTrue(executeXRIBLCubePreFilterPass(commandBuffer: commandBuffer, environmentCubeTexture: cube, target: set))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            RuntimeEnvironmentLightingStore.shared.publishXRLighting(RuntimeEnvironmentLighting(irradianceMap: set.irradianceMap, specularMap: set.specularMap, brdfMap: set.brdfMap, intensityScale: 1, isValid: true))
            RuntimeEnvironmentLightingStore.shared.setMode(.realWorldEstimate)
            for _ in 0 ..< 2 { drawSync() }
            let centre = litPixel(640, 360).x, top = litPixel(640, 360 - r).x, bottom = litPixel(640, 360 + r).x, left = litPixel(640 - r, 360).x, right = litPixel(640 + r, 360).x
            let sides = [("centre(+z)", centre), ("top(+y)", top), ("bottom(-y)", bottom), ("left(-x)", left), ("right(+x)", right)]
            let brightest = sides.max { $0.1 < $1.1 }!
            print(String(format: "ORIENTATION face %@ bright: centre %.3f top %.3f bottom %.3f left %.3f right %.3f → brightest %@", names[bright], centre, top, bottom, left, right, brightest.0))
        }
    }
}
