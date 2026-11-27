// Scratch benchmark, not part of the engine: loads a .untoldpack and reports what a
// frame costs from a few viewpoints. The plain form: nothing beyond what upstream
// develop has, so that the same file builds on develop and on a branch of it.
import simd
@testable import UntoldEngine
import XCTest

final class BimPlainBenchmark: BaseRenderSetup {
    override func initializeAssets() {}

    private func waitForGPU() {
        renderInfo.lastCommandBuffer?.waitUntilCompleted()
    }

    func testBimPack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pack = env["BIM_PACK"] else { throw XCTSkip("BIM_PACK not set") }
        let outputDir = env["BIM_OUT"].map { URL(fileURLWithPath: $0) }
        LoadingSystem.shared.resourceURLFn = getResourceURL
        applyIBL = false
        renderEnvironment = false
        ambientIntensity = 0.6

        let device = try XCTUnwrap(renderInfo.device)
        let before = device.currentAllocatedSize
        let rootId = createEntity()
        let start = CFAbsoluteTimeGetCurrent()
        let loaded = expectation(description: "pack")
        setEntityMeshAsync(entityId: rootId, filename: pack, withExtension: "untoldpack") { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 3600)
        let seconds = CFAbsoluteTimeGetCurrent() - start
        let gpuMB = Double(device.currentAllocatedSize - before) / 1_048_576
        let all = scene.getAllEntities()
        let renderEntities = all.filter { hasComponent(entityId: $0, componentType: RenderComponent.self) }
        let lodEntities = all.filter { hasComponent(entityId: $0, componentType: LODComponent.self) }
        print("BIMBENCH load seconds=\(String(format: "%.1f", seconds)) gpuMB=\(String(format: "%.0f", gpuMB)) entities=\(all.count) render=\(renderEntities.count) lod=\(lodEntities.count)")

        // Scene bounds from the entities' world boxes.
        var lower = simd_float3(repeating: .greatestFiniteMagnitude)
        var upper = simd_float3(repeating: -.greatestFiniteMagnitude)
        traverseSceneGraph()
        for entity in renderEntities {
            guard let local = scene.get(component: LocalTransformComponent.self, for: entity),
                  let world = scene.get(component: WorldTransformComponent.self, for: entity) else { continue }
            for corner in 0 ..< 8 {
                let point = simd_float4(
                    corner & 1 == 0 ? local.boundingBox.min.x : local.boundingBox.max.x,
                    corner & 2 == 0 ? local.boundingBox.min.y : local.boundingBox.max.y,
                    corner & 4 == 0 ? local.boundingBox.min.z : local.boundingBox.max.z, 1
                )
                let moved = simd_make_float3(world.space * point)
                lower = simd_min(lower, moved)
                upper = simd_max(upper, moved)
            }
        }
        let center = (lower + upper) * 0.5
        let extent = upper - lower
        print("BIMBENCH bounds min=\(lower) max=\(upper)")

        let sun = createEntity()
        createDirLight(entityId: sun)

        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        far = 2000

        let span = max(extent.x, extent.z)
        var views: [(String, simd_float3, simd_float3)] = [
            ("overview", center + simd_float3(span * 0.55, span * 0.45, span * 0.55), center),
        ]
        if let custom = env["BIM_VIEWS"] {
            // name=ex,ey,ez>tx,ty,tz;...
            views = custom.split(separator: ";").compactMap { entry in
                let parts = entry.split(separator: "=")
                guard parts.count == 2 else { return nil }
                let points = parts[1].split(separator: ">").map { $0.split(separator: ",").compactMap { Float($0) } }
                guard points.count == 2, points[0].count == 3, points[1].count == 3 else { return nil }
                return (String(parts[0]), simd_float3(points[0]), simd_float3(points[1]))
            }
        }
        if let pixels = env["BIM_CULL_PIXELS"].flatMap(Float.init) {
            setRendering(.smallObjectCulling(pixels: pixels))
        }
        let tag = env["BIM_TAG"] ?? ""
        for (name, eye, target) in views {
            cameraLookAt(entityId: camera, eye: eye, target: target, up: simd_float3(0, 1, 0))
            LODSystem.shared.reset()
            // Settle: LOD selection, culling history, pipelines.
            for _ in 0 ..< 6 {
                renderer.draw(in: renderer.metalView)
                waitForGPU()
            }
            var frameMs: [Double] = []
            var cpuMs: [Double] = []
            var stats = RenderDrawStats()
            for _ in 0 ..< 10 {
                let frameStart = CFAbsoluteTimeGetCurrent()
                renderer.draw(in: renderer.metalView)
                let cpuEnd = CFAbsoluteTimeGetCurrent()
                waitForGPU()
                frameMs.append((CFAbsoluteTimeGetCurrent() - frameStart) * 1000)
                cpuMs.append((cpuEnd - frameStart) * 1000)
                stats = RenderStatsCollector.shared.snapshot()
            }
            frameMs.sort()
            cpuMs.sort()
            let timing = EngineStatsMonitor.shared.snapshot().timing
            print("BIMTIME \(tag) view=\(name) update=\(String(format: "%.1f", timing.updateMs)) renderTotal=\(String(format: "%.1f", timing.renderTotalMs)) encode=\(String(format: "%.1f", timing.encodeMs)) culling=\(String(format: "%.1f", timing.cullingMs)) gpu=\(String(format: "%.1f", timing.gpuExecutionMs)) frameTotal=\(String(format: "%.1f", timing.frameTotalMs))")
            print("BIMBENCH \(tag) view=\(name) frameMs=\(String(format: "%.1f", frameMs[frameMs.count / 2])) cpuMs=\(String(format: "%.1f", cpuMs[cpuMs.count / 2])) triangles=\(stats.trianglesTotal) draws=\(stats.drawCallsTotal) shadowDraws=\(stats.drawCallsShadow) visible=\(visibleEntityIds.count)")
            if let outputDir, let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
                try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                saveResultToDisk(image, named: "\(tag)\(name)", in: outputDir)
            }
        }
    }
}
