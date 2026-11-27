// Scratch, not part of the engine: the two findings of the headset check, measured on the Mac.
import simd
@testable import UntoldEngine
import XCTest

final class ZZHeadsetFindings: BaseRenderSetup {
    override func initializeAssets() {}
    private func waitForGPU() { renderInfo.lastCommandBuffer?.waitUntilCompleted() }
    private func draw(_ n: Int) { for _ in 0 ..< n { renderer.draw(in: renderer.metalView); waitForGPU() } }
    private func save(_ name: String, in dir: URL) {
        if let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
            saveResultToDisk(image, named: name, in: dir)
        }
    }

    func testFindings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pack = env["BIM_PACK"], let out = env["BIM_OUT"] else { throw XCTSkip("BIM_PACK/BIM_OUT not set") }
        let outputDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        LoadingSystem.shared.resourceURLFn = getResourceURL
        applyIBL = false; renderEnvironment = false; ambientIntensity = 0.6
        let rootId = createEntity()
        let loaded = expectation(description: "pack")
        setEntityMeshAsync(entityId: rootId, filename: pack, withExtension: "untoldpack") { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3600)
        traverseSceneGraph()
        let all = scene.getAllEntities()
        let lodEntities = all.filter { hasComponent(entityId: $0, componentType: LODComponent.self) }
        let camera = createEntity(); createGameCamera(entityId: camera); CameraSystem.shared.activeCamera = camera
        far = 2000
        func sunShadows(_ on: Bool) {
            for light in scene.getAllEntities() where hasComponent(entityId: light, componentType: DirectionalLightComponent.self) {
                setLight(entityId: light, .directional(.castsShadow(on)))
            }
        }

        // 1. A parked car: its parts at each forced level, from a few metres, with and without the sun's shadows.
        let placements = all.filter { getEntityName(entityId: $0).lowercased().contains("aparcado") && !hasComponent(entityId: $0, componentType: RenderComponent.self) }
        print("CARS placements named aparcado: \(placements.count): \(placements.prefix(5).map { getEntityName(entityId: $0) })")
        if let car = placements.first {
            var parts: [EntityID] = []
            var queue = [car]
            while let e = queue.popLast() {
                if hasComponent(entityId: e, componentType: RenderComponent.self) { parts.append(e) }
                queue.append(contentsOf: getEntityChildren(parentId: e))
            }
            var lower = simd_float3(repeating: .greatestFiniteMagnitude), upper = -lower
            for p in parts {
                guard let local = scene.get(component: LocalTransformComponent.self, for: p), let world = scene.get(component: WorldTransformComponent.self, for: p) else { continue }
                let (a, b) = worldAABB_MinMax(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
                lower = simd_min(lower, a); upper = simd_max(upper, b)
            }
            let center = (lower + upper) * 0.5, radius = simd_length(upper - lower) * 0.5
            let lods = parts.compactMap { scene.get(component: LODComponent.self, for: $0) }
            print("CARS car=\(getEntityName(entityId: car)) parts=\(parts.count) withLOD=\(lods.count) levels=\(lods.first?.lodLevels.count ?? 0) radius=\(radius)")
            for (label, distanceFactor) in [("near", Float(1.6)), ("far", Float(6))] {
                let eye = center + simd_normalize(simd_float3(0.2, 0.35, 1)) * radius * distanceFactor
                cameraLookAt(entityId: camera, eye: eye, target: center, up: simd_float3(0, 1, 0))
                for level in 0 ..< max(1, lods.first?.lodLevels.count ?? 1) {
                    for lod in lods { lod.forcedLOD = level }
                    LODSystem.shared.reset()
                    sunShadows(true); draw(10)
                    let stats = RenderStatsCollector.shared.snapshot()
                    print("CARS view=\(label) level=\(level) triangles=\(stats.trianglesTotal) draws=\(stats.drawCallsTotal)")
                    save("car_\(label)_lod\(level)", in: outputDir)
                    if level == 0 || level == (lods.first?.lodLevels.count ?? 1) - 1 {
                        sunShadows(false); draw(10)
                        save("car_\(label)_lod\(level)_noshadow", in: outputDir)
                        sunShadows(true)
                    }
                }
            }
            for lod in lods { lod.forcedLOD = nil }
        }

        // 2. The occlusion test while the camera moves: forward, sideways, backward and up in the
        // tree views, a step per frame; the count right after the last step (the cull with the
        // final camera against the previous frame's pyramid) against the settled count there.
        for lod in lodEntities { scene.get(component: LODComponent.self, for: lod)?.forcedLOD = nil }
        let views: [(String, simd_float3, simd_float3)] = [
            ("grove", simd_float3(116.6, 6, 6.2), simd_float3(86.6, 1.5, -23.8)),
            ("tree15m", simd_float3(97.6, 1.7, 155.3), simd_float3(84.6, 2.0, 147.8)),
            ("walk", simd_float3(40, 1.7, 60), simd_float3(86, 2, -24)),
        ]
        let skipCars = env["BIM_SKIP_CARS"] != nil
        for (name, eye0, target0) in views {
            let forward = simd_normalize(target0 - eye0)
            let side = simd_normalize(simd_cross(forward, simd_float3(0, 1, 0)))
            for (motion, dir) in [("forward", forward), ("sideways", side), ("backward", -forward), ("up", simd_float3(0, 1, 0))] {
                for step in [Float(0.1), 0.3, 1.0] {
                    var eye = eye0
                    cameraLookAt(entityId: camera, eye: eye, target: eye + forward * 100, up: simd_float3(0, 1, 0))
                    LODSystem.shared.reset()
                    draw(10)
                    let before = visibleEntityIds.count
                    for _ in 0 ..< 20 {
                        eye += dir * step
                        cameraLookAt(entityId: camera, eye: eye, target: eye + forward * 100, up: simd_float3(0, 1, 0))
                        draw(1)
                    }
                    let moving = visibleEntityIds.count
                    if step == 1.0 { save("hzb_\(name)_\(motion)_moving", in: outputDir) }
                    draw(10)
                    let settled = visibleEntityIds.count
                    if step == 1.0 { save("hzb_\(name)_\(motion)_settled", in: outputDir) }
                    print("HZBSTEP view=\(name) motion=\(motion) step=\(step) m/frame: visible at the start=\(before) right after the last step=\(moving) settled there=\(settled) lost=\(settled - moving)")
                }
            }
        }
        _ = skipCars
    }
}
