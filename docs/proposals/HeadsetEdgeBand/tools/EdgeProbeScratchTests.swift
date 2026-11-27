//
//  EdgeProbeScratchTests.swift  (SCRATCH — not to be committed)
//
//  Renders the Simple Dungeons pack Harold recorded on the headset, on the Mac, under a matrix
//  of the PR's settings, and writes each frame as a PNG for inspection.
//

import Metal
import simd
@testable import UntoldEngine
import XCTest

@MainActor
final class EdgeProbeScratchTests: BaseRenderSetup {
    static let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-godshadow-Projects-Untold/81c84faf-430f-4224-a0f4-ee1de52b7336/scratchpad")
    static var packURL: URL { scratch.appendingPathComponent("dungeon/dungeon.untoldpack") }
    static var outDir: URL { scratch.appendingPathComponent("probe") }

    private var savedPath: RenderPath = .deferred
    private var savedMode: AntiAliasingMode = .fxaa
    private var camera: EntityID = .max
    private var sun: EntityID = .max
    private var modelCount = 0

    override func setUp() async throws {
        try await super.setUp()
        savedPath = getRenderPath()
        savedMode = antiAliasingMode
    }

    override func tearDown() async throws {
        setRendering(.renderPath(savedPath))
        antiAliasingMode = savedMode
        SSAO.setEnabled(false)
        SSAOParams.shared.intensity = 0
        renderInfo.immersionStyle = .none
        renderInfo.xrFoveation = nil
        applyXRFoveationToSceneRenderPassDescriptors()
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        guard let pack = loadUntoldPack(url: Self.packURL) else {
            XCTFail("pack manifest unreadable")
            return
        }
        let dir = Self.packURL.deletingLastPathComponent()
        for model in pack.models {
            let url = dir.appendingPathComponent(model.path)
            let entity = createEntity()
            setEntityMesh(entityId: entity, filename: url.deletingPathExtension().path, withExtension: "untold", assetName: model.displayName)
            let m = model.transform
            let position = simd_make_float3(m.columns.3)
            let c0 = simd_make_float3(m.columns.0), c1 = simd_make_float3(m.columns.1), c2 = simd_make_float3(m.columns.2)
            let scale = simd_float3(simd_length(c0), simd_length(c1), simd_length(c2))
            let rotation = simd_normalize(simd_quatf(simd_float3x3(c0 / max(scale.x, 1e-6), c1 / max(scale.y, 1e-6), c2 / max(scale.z, 1e-6))))
            translateTo(entityId: entity, position: position)
            rotateTo(entityId: entity, rotation: rotation)
            scaleTo(entityId: entity, scale: scale)
            modelCount += 1
        }
        camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        sun = createEntity()
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, pitch: -55, yaw: 30, roll: 0)
        applyIBL = true
    }

    // MARK: - helpers

    private func note(_ s: String) {
        let url = Self.outDir.appendingPathComponent("probe.txt")
        let line = s + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        print(s)
    }

    private struct Box { var min = simd_float3(repeating: .greatestFiniteMagnitude); var max = simd_float3(repeating: -.greatestFiniteMagnitude) }

    private func worldBox(of entity: EntityID) -> Box? {
        guard let local = scene.get(component: LocalTransformComponent.self, for: entity),
              let world = scene.get(component: WorldTransformComponent.self, for: entity) else { return nil }
        let (c, e) = worldAABB_CenterExtent(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
        return Box(min: c - e, max: c + e)
    }

    private func sceneBounds(where predicate: (String) -> Bool) -> (Box, Int) {
        let transformId = getComponentId(for: WorldTransformComponent.self)
        let renderId = getComponentId(for: RenderComponent.self)
        var box = Box(); var n = 0
        for e in queryEntitiesWithComponentIds([transformId, renderId], in: scene) {
            guard predicate(getEntityName(entityId: e)), let b = worldBox(of: e) else { continue }
            box.min = simd_min(box.min, b.min); box.max = simd_max(box.max, b.max); n += 1
        }
        return (box, n)
    }

    private func draw(_ count: Int) {
        for _ in 0 ..< count {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    /// A shared-memory copy of a texture (the TAA output is private storage).
    private func sharedCopy(of tex: MTLTexture) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: tex.width, height: tex.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let copy = renderInfo.device.makeTexture(descriptor: d),
              let queue = renderInfo.device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, to: copy)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return copy
    }

    private func capture(_ name: String) {
        let taa = antiAliasingMode == .taa || antiAliasingMode == .msaaTaa
        if taa, let tex = TemporalAntiAliasing.shared.resolvedTexture, let copy = sharedCopy(of: tex), let img = textureToCGImage(texture: copy) {
            saveResultToDisk(img, named: "\(name)_taaResolved", in: Self.outDir)
        }
        guard let tex = textureResources.lookTexture, let copy = sharedCopy(of: tex), let img = textureToCGImage(texture: copy) else {
            XCTFail("\(name): no look texture"); return
        }
        saveResultToDisk(img, named: name, in: Self.outDir)
    }

    private func look(from eye: simd_float3, at target: simd_float3) {
        cameraLookAt(entityId: camera, eye: eye, target: target, up: simd_float3(0, 1, 0))
    }

    private func apply(path: RenderPath, aa: AntiAliasingMode, ssao: Bool, immersion: UntoldImmersionMode = .none) {
        renderInfo.immersionStyle = immersion
        setRendering(.renderPath(path))
        antiAliasingMode = aa
        if aa == .msaa || aa == .msaaTaa { setRendering(.multisampleCount(4)) }
        SSAOParams.shared.radius = 0.5
        SSAOParams.shared.bias = 0.025
        SSAOParams.shared.intensity = ssao ? 1.0 : 0.0
        SSAO.setEnabled(ssao)
    }

    private struct Variant { let name: String; let path: RenderPath; let aa: AntiAliasingMode; let ssao: Bool; let immersion: UntoldImmersionMode }

    private func shots() -> [(String, simd_float3, simd_float3)] {
        let (all, n) = sceneBounds { _ in true }
        let (stairs, ns) = sceneBounds { $0.contains("Stairs_Spiral") }
        let (railPillars, nr) = sceneBounds { $0.contains("Railing_Stone_Pillar") }
        let (banner, nb) = sceneBounds { $0.contains("Banner_01") }
        note("PROBE models=\(modelCount) bounds all (\(n)): \(all.min) .. \(all.max)")
        note("PROBE bounds stairs (\(ns)): \(stairs.min) .. \(stairs.max)")
        note("PROBE bounds railing pillars (\(nr)): \(railPillars.min) .. \(railPillars.max)")
        note("PROBE bounds banner (\(nb)): \(banner.min) .. \(banner.max)")
        XCTAssertGreaterThan(n, 300, "the dungeon loaded")
        let stairsCenter = (stairs.min + stairs.max) * 0.5
        let topY = stairs.max.y
        let eyeA = simd_float3(stairsCenter.x + 3.5, topY + 1.4, stairsCenter.z + 1.0)
        let targetA = simd_float3(stairsCenter.x - 1.0, topY + 0.2, stairsCenter.z - 1.5)
        let railCenter = (railPillars.min + railPillars.max) * 0.5
        let eyeB = simd_float3(railCenter.x + 2.5, railPillars.min.y + 1.6, railCenter.z + 2.5)
        let targetB = simd_float3(railCenter.x, railPillars.min.y + 0.9, railCenter.z)
        return [("A", eyeA, targetA), ("B", eyeB, targetB)]
    }

    private func run(_ variants: [Variant]) {
        for (shot, eye, target) in shots() {
            look(from: eye, at: target)
            for v in variants {
                apply(path: v.path, aa: v.aa, ssao: v.ssao, immersion: v.immersion)
                draw(10)
                capture("\(shot)_\(v.name)")
                note("PROBE \(shot) \(v.name): path=\(getRenderPath()) aa=\(antiAliasingMode) samples=\(renderInfo.opaqueSampleCount) ssao=\(SSAOParams.shared.enabled) immersion=\(renderInfo.immersionStyle) draws=\(RenderStatsCollector.shared.snapshot().drawCallsTotal)")
            }
        }
    }

    // MARK: - foveation + motion emulation

    /// The headset's configuration on the Mac: the frame's textures at a rate map's physical size,
    /// a map that changes every frame (the compositor's maps follow the gaze), and a camera that
    /// moves between frames (the head), under the forward path with MSAA + TAA.
    func testFoveatedMotion() throws {
        let device = try XCTUnwrap(renderInfo.device)
        guard device.supportsRasterizationRateMap(layerCount: 1) else { throw XCTSkip("no rate maps") }
        let screenW = 1920, screenH = 1080
        func makeMap(shift: Int) -> MTLRasterizationRateMap? {
            let d = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: screenW, height: screenH, depth: 1))
            let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 8, height: 6, depth: 1))
            let h: [Float] = [0.25, 0.5, 1, 1, 1, 0.5, 0.25, 0.25]
            let v: [Float] = [0.25, 0.5, 1, 1, 0.5, 0.25]
            for i in 0 ..< 8 { layer.horizontal[i] = h[(i + shift) % 8] }
            for j in 0 ..< 6 { layer.vertical[j] = v[(j + shift) % 6] }
            d.setLayer(layer, at: 0)
            d.label = "EdgeProbe map \(shift)"
            return device.makeRasterizationRateMap(descriptor: d)
        }
        var maps: [MTLRasterizationRateMap] = []
        for shift in 0 ..< 3 { if let m = makeMap(shift: shift) { maps.append(m) } }
        let physical = maps[0].physicalSize(layer: 0)
        // Only maps of the same physical size can alternate without reallocating the frame.
        maps = maps.filter { $0.physicalSize(layer: 0).width == physical.width && $0.physicalSize(layer: 0).height == physical.height }
        note("PROBE foveation: screen \(screenW)x\(screenH), physical \(physical.width)x\(physical.height), \(maps.count) maps of that size")
        let buffers: [MTLBuffer] = try maps.map { try XCTUnwrap(device.makeBuffer(length: $0.parameterDataSizeAndAlign.size, options: .storageModeShared)) }
        let frames: [XRFoveationFrame] = try (0 ..< maps.count).map { i in
            let data = try XCTUnwrap(XRRasterizationRateMapData(rateMap: maps[i], buffer: buffers[i]))
            let viewport = MTLViewport(originX: 0, originY: 0, width: Double(screenW), height: Double(screenH), znear: 0, zfar: 1)
            return XRFoveationFrame(rateMap: maps[i], viewport: viewport, rateMapData: data)
        }

        // The frame's resources at the physical size; the projection keeps the screen's aspect.
        renderInfo.viewPort = simd_float2(Float(physical.width), Float(physical.height))
        renderer.initSizeableResources()
        let aspect = Float(screenW) / Float(screenH)
        renderInfo.perspectiveSpace = renderInfo.reverseZEnabled
            ? matrixPerspectiveRightHandReverseZ(fovyRadians: degreesToRadians(degrees: fov), aspectRatio: aspect, nearZ: near, farZ: far)
            : matrixPerspectiveRightHand(fovyRadians: degreesToRadians(degrees: fov), aspectRatio: aspect, nearZ: near, farZ: far)
        TemporalAntiAliasing.shared.projectionDidChange()

        struct FV { let name: String; let aa: AntiAliasingMode; let ssao: Bool; let alternate: Bool; let move: Bool }
        let variants = [
            FV(name: "fov_forward_msaaTaa_ssaoOff_move", aa: .msaaTaa, ssao: false, alternate: true, move: true),
            FV(name: "fov_forward_msaaTaa_ssaoOn_move", aa: .msaaTaa, ssao: true, alternate: true, move: true),
            FV(name: "fov_forward_msaaTaa_ssaoOff_static", aa: .msaaTaa, ssao: false, alternate: false, move: false),
            FV(name: "fov_forward_none_ssaoOn_static", aa: .none, ssao: true, alternate: false, move: false),
            FV(name: "fov_forward_none_ssaoOff_static", aa: .none, ssao: false, alternate: false, move: false),
            FV(name: "fov_forward_msaaTaa_ssaoOff_moveOneMap", aa: .msaaTaa, ssao: false, alternate: false, move: true),
        ]
        for (shot, eye, target) in shots() {
            for v in variants {
                apply(path: .forward, aa: v.aa, ssao: v.ssao, immersion: .mixed)
                for f in 0 ..< 16 {
                    renderInfo.xrFoveation = frames[v.alternate ? f % frames.count : 0]
                    let t = v.move ? Float(f) * 0.006 : 0
                    look(from: eye + simd_float3(t, 0.3 * t, 0), at: target + simd_float3(2.5 * t, 0, 0))
                    draw(1)
                }
                capture("\(shot)_\(v.name)")
                note("PROBE \(shot) \(v.name): path=\(getRenderPath()) aa=\(antiAliasingMode) samples=\(renderInfo.opaqueSampleCount) ssao=\(SSAOParams.shared.enabled) viewPort=\(renderInfo.viewPort) mapAttached=\(renderInfo.offscreenRenderPassDescriptor.rasterizationRateMap != nil)")
            }
        }
        renderInfo.xrFoveation = nil
    }

    // MARK: - SSAO halo close-up

    /// A railing pillar standing within half a metre of a wall, seen from close by, as in the
    /// recording's fifth second: the SSAO kernel's range check lets a sample on the pillar occlude
    /// the wall behind it, which should show as a dark band on the wall around the pillar.
    func testSSAOHaloCloseup() throws {
        let transformId = getComponentId(for: WorldTransformComponent.self)
        let renderId = getComponentId(for: RenderComponent.self)
        var pillars: [(EntityID, Box)] = []
        var walls: [(EntityID, Box)] = []
        for e in queryEntitiesWithComponentIds([transformId, renderId], in: scene) {
            let name = getEntityName(entityId: e)
            guard let b = worldBox(of: e) else { continue }
            if name.contains("Railing_Stone_Pillar") { pillars.append((e, b)) }
            if name.hasPrefix("SM_Env_"), !name.contains("Railing"), !name.contains("Floor"), !name.contains("Ceiling"), !name.contains("Stairs"), !name.contains("Door") { walls.append((e, b)) }
        }
        // The pillar with the nearest wall face behind it (gap between the boxes, in the plane).
        var best: (pillar: Box, wall: Box, gap: Float, axis: Int, sign: Float)?
        for (_, pb) in pillars {
            let pc = (pb.min + pb.max) * 0.5
            for (_, wb) in walls {
                let wc = (wb.min + wb.max) * 0.5
                guard abs(wc.y - pc.y) < 2.0 else { continue }
                for axis in [0, 2] {
                    let other = axis == 0 ? 2 : 0
                    // the wall must overlap the pillar along the other axis
                    guard wb.min[other] < pb.max[other], wb.max[other] > pb.min[other] else { continue }
                    let gapPos = wb.min[axis] - pb.max[axis]   // wall beyond the pillar's +axis side
                    let gapNeg = pb.min[axis] - wb.max[axis]   // wall beyond the pillar's -axis side
                    for (gap, sign) in [(gapPos, Float(1)), (gapNeg, Float(-1))] where gap >= 0.0 && gap < 1.5 {
                        if best == nil || gap < best!.gap { best = (pb, wb, gap, axis, sign) }
                    }
                }
            }
        }
        note("PROBE closeup search: \(pillars.count) pillars, \(walls.count) env pieces, best gap \(best.map { String($0.gap) } ?? "none")")
        guard let best else { throw XCTSkip("no railing pillar within 1.5 m of an environment piece") }
        let pc = (best.pillar.min + best.pillar.max) * 0.5
        note("PROBE closeup: pillar \(best.pillar.min)..\(best.pillar.max) wall gap \(best.gap) m along axis \(best.axis) sign \(best.sign)")
        // Stand 1.3 m from the pillar on the side away from the wall, a little above the rail, looking at it.
        var dir = simd_float3(0, 0, 0); dir[best.axis] = -best.sign
        let eye = simd_float3(pc.x, best.pillar.max.y + 0.25, pc.z) + dir * 1.3 + simd_float3(best.axis == 0 ? 0 : 0.35, 0, best.axis == 0 ? 0.35 : 0)
        let target = simd_float3(pc.x, best.pillar.max.y - 0.35, pc.z)
        look(from: eye, at: target)
        struct CV { let name: String; let path: RenderPath; let ssao: Bool; let radius: Float; let intensity: Float }
        let variants = [
            CV(name: "closeup_forward_ssaoOff", path: .forward, ssao: false, radius: 0.5, intensity: 0),
            CV(name: "closeup_forward_ssaoOn_r05_i1", path: .forward, ssao: true, radius: 0.5, intensity: 1.0),
            CV(name: "closeup_forward_ssaoOn_r10_i1", path: .forward, ssao: true, radius: 1.0, intensity: 1.0),
            CV(name: "closeup_deferred_ssaoOn_r05_i1", path: .deferred, ssao: true, radius: 0.5, intensity: 1.0),
        ]
        for v in variants {
            apply(path: v.path, aa: .none, ssao: v.ssao)
            SSAOParams.shared.radius = v.radius
            SSAOParams.shared.intensity = v.intensity
            draw(6)
            capture(v.name)
            if v.ssao, let tex = textureResources.ssaoBlurTexture, let copy = sharedCopy(of: tex), let img = textureToCGImage(texture: copy) {
                saveResultToDisk(img, named: "\(v.name)_aoTexture", in: Self.outDir)
            }
            note("PROBE \(v.name): path=\(getRenderPath()) ssao=\(SSAOParams.shared.enabled) radius=\(SSAOParams.shared.radius) intensity=\(SSAOParams.shared.intensity)")
        }
    }

    // MARK: - SSAO halo with a synthetic wall

    /// A flat wall put 0.3 m, then 1.0 m, behind a railing pillar: with SSAO on, the far surface
    /// within the kernel's radius of the pillar should carry a dark band around the pillar.
    func testSSAOHaloSynthetic() throws {
        let (pb, n) = sceneBounds { $0.contains("Railing_Stone_Pillar_10") }
        XCTAssertEqual(n, 1, "one pillar named ..Pillar_10")
        let pc = (pb.min + pb.max) * 0.5
        let wall = createEntity()
        setEntityMeshDirect(entityId: wall, meshes: BasicPrimitives.createCube(extent: 1.0), assetName: "ProbeWall")
        scaleTo(entityId: wall, scale: simd_float3(8, 5, 0.2))
        func place(gap: Float) { translateTo(entityId: wall, position: simd_float3(pc.x, pc.y + 0.8, pb.min.z - gap - 0.1)) }
        place(gap: 0.3)
        setVisibleEntities()
        let eye = simd_float3(pc.x + 0.5, pb.max.y + 0.2, pb.max.z + 1.5)
        let target = simd_float3(pc.x, pb.max.y - 0.4, pc.z)
        look(from: eye, at: target)
        note("PROBE synthetic: pillar \(pb.min)..\(pb.max), eye \(eye)")
        struct SV { let name: String; let gap: Float; let ssao: Bool; let radius: Float; let intensity: Float }
        let variants = [
            SV(name: "synth_gap03_ssaoOff", gap: 0.3, ssao: false, radius: 0.5, intensity: 0),
            SV(name: "synth_gap03_ssaoOn_r05_i1", gap: 0.3, ssao: true, radius: 0.5, intensity: 1.0),
            SV(name: "synth_gap03_ssaoOn_r10_i15", gap: 0.3, ssao: true, radius: 1.0, intensity: 1.5),
            SV(name: "synth_gap10_ssaoOn_r05_i1", gap: 1.0, ssao: true, radius: 0.5, intensity: 1.0),
            SV(name: "synth_gap10_ssaoOn_r10_i15", gap: 1.0, ssao: true, radius: 1.0, intensity: 1.5),
            SV(name: "synth_gap10_ssaoOff", gap: 1.0, ssao: false, radius: 0.5, intensity: 0),
        ]
        for v in variants {
            place(gap: v.gap)
            apply(path: .forward, aa: .none, ssao: v.ssao)
            SSAOParams.shared.radius = v.radius
            SSAOParams.shared.intensity = v.intensity
            draw(6)
            capture(v.name)
            if v.ssao, let tex = textureResources.ssaoBlurTexture, let copy = sharedCopy(of: tex), let img = textureToCGImage(texture: copy) {
                saveResultToDisk(img, named: "\(v.name)_aoTexture", in: Self.outDir)
            }
            note("PROBE \(v.name): gap=\(v.gap) ssao=\(SSAOParams.shared.enabled) radius=\(SSAOParams.shared.radius) intensity=\(SSAOParams.shared.intensity)")
        }
    }

    // MARK: - the back-face flip under a room-like light

    /// No sun, an image light that is bright above and dark below (a room's probe), the forward
    /// path: a fragment whose interpolated normal the shader turns away from the viewer is lit
    /// from below and goes dark. Then the deferred path's normal view, which shows where the
    /// G-buffer normal is turned. The capture name carries `tag` (the shader variant).
    func testFlipLighting() throws {
        let tag = ProcessInfo.processInfo.environment["PROBE_TAG"] ?? "flipOn"
        destroyEntity(entityId: sun)
        LightingSystem.shared.activeDirectionalLight = nil
        let hdr = Self.scratch.appendingPathComponent("hdr/" + (ProcessInfo.processInfo.environment["PROBE_HDR"] ?? "toplit.hdr"))
        generateHDR(hdr.lastPathComponent, from: hdr.deletingLastPathComponent())
        applyIBL = true
        ambientIntensity = 1.0
        let (pb, _) = sceneBounds { $0.contains("Railing_Stone_Pillar_10") }
        let pc = (pb.min + pb.max) * 0.5
        var views = shots()
        views.append(("C", simd_float3(pc.x + 0.5, pb.max.y + 0.2, pb.max.z + 1.5), simd_float3(pc.x, pb.max.y - 0.4, pc.z)))
        for (shot, eye, target) in views {
            look(from: eye, at: target)
            apply(path: .forward, aa: .none, ssao: false)
            draw(4)
            capture("\(shot)_\(tag)_forward_toplit")
            // The normal view: the G-buffer must be persistent for it.
            apply(path: .deferred, aa: .none, ssao: false)
            renderDebugViewMode = .normal
            renderer.initSizeableResources()
            generateHDR(hdr.lastPathComponent, from: hdr.deletingLastPathComponent())
            draw(4)
            if let tex = textureResources.normalMap, let copy = sharedCopy(of: tex), let img = textureToCGImage(texture: copy) {
                saveResultToDisk(img, named: "\(shot)_\(tag)_normals", in: Self.outDir)
            }
            renderDebugViewMode = .lit
            renderer.initSizeableResources()
            generateHDR(hdr.lastPathComponent, from: hdr.deletingLastPathComponent())
            note("PROBE \(shot) \(tag): toplit forward + normals captured")
        }
    }

    // MARK: - the probes

    func testMatrixNoTAA() throws {
        run([
            Variant(name: "deferred_none_ssaoOff", path: .deferred, aa: .none, ssao: false, immersion: .none),
            Variant(name: "deferred_none_ssaoOn", path: .deferred, aa: .none, ssao: true, immersion: .none),
            Variant(name: "forward_none_ssaoOff", path: .forward, aa: .none, ssao: false, immersion: .none),
            Variant(name: "forward_none_ssaoOn", path: .forward, aa: .none, ssao: true, immersion: .none),
            Variant(name: "forward_msaa_ssaoOn", path: .forward, aa: .msaa, ssao: true, immersion: .none),
            Variant(name: "mixed_forward_msaa_ssaoOff", path: .forward, aa: .msaa, ssao: false, immersion: .mixed),
        ])
    }

    func testMatrixTAA() throws {
        run([
            Variant(name: "forward_msaaTaa_ssaoOff", path: .forward, aa: .msaaTaa, ssao: false, immersion: .none),
            Variant(name: "forward_msaaTaa_ssaoOn", path: .forward, aa: .msaaTaa, ssao: true, immersion: .none),
            Variant(name: "forward_taa_ssaoOff", path: .forward, aa: .taa, ssao: false, immersion: .none),
            Variant(name: "mixed_forward_msaaTaa_ssaoOff", path: .forward, aa: .msaaTaa, ssao: false, immersion: .mixed),
            Variant(name: "mixed_forward_msaaTaa_ssaoOn", path: .forward, aa: .msaaTaa, ssao: true, immersion: .mixed),
        ])
    }
}
