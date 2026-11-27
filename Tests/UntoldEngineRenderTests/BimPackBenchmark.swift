// Scratch benchmark, not part of the engine: loads a .untoldpack and reports what a
// frame costs from a few viewpoints, with the LOD chain and with every entity forced
// to its full meshes.
import simd
@testable import UntoldEngine
import XCTest

final class BimPackBenchmark: BaseRenderSetup {
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

        // Experiment: the engine's static batching for the parts that have no LOD chain
        // ("unchained"), or for everything ("all").
        if let batch = env["BIM_BATCH"], batch != "none" {
            let batchStart = CFAbsoluteTimeGetCurrent()
            let memoryBefore = device.currentAllocatedSize
            var marked = 0
            for entity in renderEntities where batch == "all" || !hasComponent(entityId: entity, componentType: LODComponent.self) {
                setEntityStaticBatch(entityId: entity)
                marked += 1
            }
            if let cell = env["BIM_BATCH_CELL"].flatMap(Float.init) {
                setBatching(.cellSize(cell))
            }
            setBatching(.enabled(true))
            generateBatches()
            let batchSeconds = CFAbsoluteTimeGetCurrent() - batchStart
            let batchMB = Double(device.currentAllocatedSize - memoryBefore) / 1_048_576
            let batching = EngineStatsMonitor.shared.snapshot().batching
            print("BIMBENCH batch mode=\(batch) marked=\(marked) seconds=\(String(format: "%.1f", batchSeconds)) gpuMB=\(String(format: "%.0f", batchMB)) groups=\(batching.batchGroupCount) batchedMeshes=\(batching.batchedMeshCount)")
        }

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
        let ground = lower.y
        let viewpoints: [(String, simd_float3, simd_float3)] = [
            ("overview", center + simd_float3(span * 0.55, span * 0.45, span * 0.55), center),
            ("corner", simd_float3(lower.x, ground + 12, lower.z) + simd_float3(-10, 0, -10), center),
            ("street", center + simd_float3(span * 0.25, 0, 0) * simd_float3(1, 0, 1) + simd_float3(0, ground - center.y + 1.7, 0), center + simd_float3(-span * 0.25, ground - center.y + 3, span * 0.1)),
            ("inside", simd_float3(center.x, ground + 1.7, center.z), simd_float3(center.x + span * 0.3, ground + 4, center.z + span * 0.3)),
        ]

        var views = viewpoints
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
        print("BIMBENCH smallObjectCullingPixels=\(getSmallObjectCullingPixels())")
        let modes = (env["BIM_MODES"] ?? "lod,full").split(separator: ",").map(String.init)
        let tag = env["BIM_TAG"] ?? ""
        for (name, eye, target) in views {
            for mode in modes {
                for entity in lodEntities {
                    scene.get(component: LODComponent.self, for: entity)?.forcedLOD = mode == "full" ? 0 : nil
                }
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
                var levels = [Int](repeating: 0, count: 5)
                for entity in lodEntities {
                    if let lod = scene.get(component: LODComponent.self, for: entity) {
                        levels[min(lod.currentLOD, 4)] += 1
                    }
                }
                let timing = EngineStatsMonitor.shared.snapshot().timing
                print("BIMTIME \(tag) view=\(name) mode=\(mode) update=\(String(format: "%.1f", timing.updateMs)) renderTotal=\(String(format: "%.1f", timing.renderTotalMs)) renderPrep=\(String(format: "%.1f", timing.renderPrepMs)) encode=\(String(format: "%.1f", timing.encodeMs)) submit=\(String(format: "%.1f", timing.submitMs)) culling=\(String(format: "%.1f", timing.cullingMs)) geomStreaming=\(String(format: "%.1f", timing.geometryStreamingMs)) streamingRegion=\(String(format: "%.1f", timing.streamingRegionMs)) batching=\(String(format: "%.1f", timing.batchingTickMs)) gpu=\(String(format: "%.1f", timing.gpuExecutionMs)) frameTotal=\(String(format: "%.1f", timing.frameTotalMs))")
                if mode == "lod" {
                    // What small-object culling would leave: visible entities by the height
                    // in pixels of their bounding sphere.
                    let tanHalf = tan(degreesToRadians(degrees: fov) * 0.5)
                    let viewHeight = renderInfo.viewPort.y
                    var buckets = [Int](repeating: 0, count: 6)   // <1, <2, <4, <8, <16, >=16 px
                    var drawsKept = [Int](repeating: 0, count: 6)
                    for entity in visibleEntityIds {
                        guard let local = scene.get(component: LocalTransformComponent.self, for: entity),
                              let world = scene.get(component: WorldTransformComponent.self, for: entity),
                              let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                        let center = simd_make_float3(world.space * simd_float4((local.boundingBox.min + local.boundingBox.max) * 0.5, 1))
                        let scale = max(simd_length(simd_make_float3(world.space.columns.0)), simd_length(simd_make_float3(world.space.columns.1)), simd_length(simd_make_float3(world.space.columns.2)))
                        let radius = simd_length(local.boundingBox.max - local.boundingBox.min) * 0.5 * scale
                        let distance = max(simd_distance(center, eye), 0.001)
                        let pixels = radius / (distance * tanHalf) * viewHeight
                        let bucket = pixels < 1 ? 0 : pixels < 2 ? 1 : pixels < 4 ? 2 : pixels < 8 ? 3 : pixels < 16 ? 4 : 5
                        buckets[bucket] += 1
                        drawsKept[bucket] += render.mesh.reduce(0) { $0 + $1.submeshes.count }
                    }
                    print("BIMSIZE \(tag) view=\(name) entities by pixel height [<1,<2,<4,<8,<16,>=16]=\(buckets) draws=\(drawsKept)")
                }
                if mode == "lod", let spin = env["BIM_SPIN"], spin.hasPrefix(name), let secondsToSpin = Double(spin.split(separator: ":").last ?? "") {
                    print("BIMSPIN start pid=\(ProcessInfo.processInfo.processIdentifier)")
                    fflush(stdout)
                    if let marker = env["BIM_MARKER"] {
                        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: marker, atomically: true, encoding: .utf8)
                    }
                    let until = CFAbsoluteTimeGetCurrent() + secondsToSpin
                    while CFAbsoluteTimeGetCurrent() < until {
                        renderer.draw(in: renderer.metalView)
                        waitForGPU()
                    }
                    print("BIMSPIN end")
                }
                print("BIMBENCH \(tag) view=\(name) mode=\(mode) frameMs=\(String(format: "%.1f", frameMs[frameMs.count / 2])) cpuMs=\(String(format: "%.1f", cpuMs[cpuMs.count / 2])) triangles=\(stats.trianglesTotal) draws=\(stats.drawCallsTotal) shadowDraws=\(stats.drawCallsShadow) visible=\(visibleEntityIds.count) levels=\(levels)")
                if let outputDir, let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
                    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                    saveResultToDisk(image, named: "\(tag)\(name)_\(mode)", in: outputDir)
                }
            }
        }
    }
}
