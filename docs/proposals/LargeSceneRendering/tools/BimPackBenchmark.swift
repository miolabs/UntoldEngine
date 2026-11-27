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
        // "loader": what the engine does by itself: batching is on when the pack loads,
        // so the loader marks the parts placed once and hands them to the batching system.
        let loaderBatching = env["BIM_BATCH"] == "loader"
        if loaderBatching {
            setBatching(.enabled(true))
        } else {
            setBatching(.packSinglePlacements(false))
        }
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
        if loaderBatching {
            let batchStart = CFAbsoluteTimeGetCurrent()
            let staticId = getComponentId(for: StaticBatchComponent.self)
            let marked = queryEntitiesWithComponentIds([staticId], in: scene).count
            var frames = 0
            var lastGroups = -1
            var stable = 0
            var firstStableFrame = 0
            while frames < 3000, stable < 120 {
                renderer.draw(in: renderer.metalView)
                waitForGPU()
                frames += 1
                let groups = BatchingSystem.shared.batchGroups.count
                if groups != lastGroups { firstStableFrame = frames }
                stable = groups == lastGroups ? stable + 1 : 0
                lastGroups = groups
            }
            let batchSeconds = CFAbsoluteTimeGetCurrent() - batchStart
            let groups = BatchingSystem.shared.batchGroups
            let bytes = groups.reduce(0) { total, group in
                total + (group.positionBuffer?.length ?? 0) + (group.normalBuffer?.length ?? 0) + (group.uvBuffer?.length ?? 0)
                    + (group.tangentBuffer?.length ?? 0) + (group.indexBuffer?.length ?? 0) + (group.featureEdgeIndexBuffer?.length ?? 0)
            }
            let batchedEntities = Set(groups.flatMap(\.entityIds)).count
            let cells = Set(groups.map(\.cellId)).count
            let single = groups.filter { $0.entityIds.count == 1 }.count
            // How exact the merge is: groups whose meshes do not all have the very same material values.
            var inexactGroups = 0
            var inexactEntities = 0
            var worstColourGap: Float = 0
            for group in groups {
                let key = group.material
                func rounded(_ value: Float) -> Int { Int((value * 100).rounded()) }
                var exact = Set<[UInt32]>()
                for entity in Set(group.entityIds) {
                    guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                    for mesh in render.mesh {
                        for submesh in mesh.submeshes {
                            guard let material = submesh.material else { continue }
                            let colour = material.baseColorValue
                            guard rounded(colour.x) == rounded(key.baseColorValue.x), rounded(colour.y) == rounded(key.baseColorValue.y), rounded(colour.z) == rounded(key.baseColorValue.z),
                                  rounded(material.roughnessValue) == rounded(key.roughnessValue), rounded(material.metallicValue) == rounded(key.metallicValue),
                                  material.baseColor.texture === key.baseColor.texture else { continue }
                            exact.insert([colour.x.bitPattern, colour.y.bitPattern, colour.z.bitPattern, material.roughnessValue.bitPattern, material.metallicValue.bitPattern, material.specular.bitPattern, material.ior.bitPattern])
                            worstColourGap = max(worstColourGap, simd_reduce_max(simd_abs(simd_make_float3(colour) - simd_make_float3(key.baseColorValue))))
                        }
                    }
                }
                if exact.count > 1 {
                    inexactGroups += 1
                    inexactEntities += Set(group.entityIds).count
                }
            }
            print("BIMBENCH merge groupsWithMaterialsNotBitEqual=\(inexactGroups) entitiesInThem=\(inexactEntities) worstBaseColourGap=\(worstColourGap)")
            if env["BIM_GROUP_PROBE"] != nil {
                // What the background build left out that a full build takes.
                let incremental = Set(groups.flatMap(\.entityIds))
                let diag = BatchingSystem.shared.getTickDiagnosticsSnapshot()
                let states = BatchingSystem.shared.getCellRenderStatesSnapshot()
                var byState: [String: Int] = [:]
                for (_, state) in states { byState[state.rawValue, default: 0] += 1 }
                print("BIMGROUPPROBE tick=\(diag) cellStates=\(byState)")
                let cellSize = BatchingSystem.shared.getBatchCellSize()
                func cell(of entity: EntityID) -> BatchCellID? {
                    guard let local = scene.get(component: LocalTransformComponent.self, for: entity), let world = scene.get(component: WorldTransformComponent.self, for: entity) else { return nil }
                    let (lower, upper) = worldAABB_MinMax(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
                    let center = (lower + upper) * 0.5
                    return BatchCellID(x: Int(floor(center.x / cellSize)), y: Int(floor(center.y / cellSize)), z: Int(floor(center.z / cellSize)))
                }
                generateBatches()
                let full = Set(BatchingSystem.shared.batchGroups.flatMap(\.entityIds))
                let missing = full.subtracting(incremental)
                print("BIMGROUPPROBE incremental=\(incremental.count) full=\(full.count) missing=\(missing.count) extra=\(incremental.subtracting(full).count)")
                var missingByCell: [BatchCellID: Int] = [:]
                for entity in missing { if let id = cell(of: entity) { missingByCell[id, default: 0] += 1 } }
                for (id, count) in missingByCell {
                    print("BIMGROUPPROBE cell \(id) missing=\(count) stateBefore=\(states[id]?.rawValue ?? "none")")
                }
            }
            // Nothing may fall between the two ways of drawing: every opaque submesh of a
            // batched entity has to be in a group.
            do {
                let batchedNow = Set(BatchingSystem.shared.batchGroups.flatMap(\.entityIds))
                var indicesOfEntities = 0
                var unbatchedButSkipped = 0
                for entity in batchedNow {
                    guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                    for mesh in render.mesh { for submesh in mesh.submeshes where submesh.material != nil && submesh.material?.hasTransparency == false { indicesOfEntities += submesh.indexCount } }
                    if !BatchingSystem.shared.isBatched(entityId: entity) { unbatchedButSkipped += 1 }
                }
                let indicesOfGroups = BatchingSystem.shared.batchGroups.reduce(0) { $0 + $1.indexCount }
                print("BIMBENCH coverage indicesOfBatchedEntities=\(indicesOfEntities) indicesOfGroups=\(indicesOfGroups) entitiesInGroupsButNotMarkedBatched=\(unbatchedButSkipped)")
            }
            print("BIMBENCH loader marked=\(marked) groups=\(groups.count) groupsOfOne=\(single) cells=\(cells) batchedEntities=\(batchedEntities) bufferMB=\(String(format: "%.0f", Double(bytes) / 1_048_576)) settledAtFrame=\(firstStableFrame) seconds=\(String(format: "%.1f", batchSeconds)) summary=\(BatchingSystem.shared.getRuntimeBatchingSummaryDiagnostic())")
        } else if let batch = env["BIM_BATCH"], batch != "none" {
            let batchStart = CFAbsoluteTimeGetCurrent()
            let memoryBefore = device.currentAllocatedSize
            var marked = 0
            // "single": only the parts whose meshes and materials no other entity draws
            // (instancing takes care of the rest), and that have no LOD chain.
            var uses: [Int32: Int] = [:]
            if batch == "single" {
                for entity in renderEntities {
                    guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                    uses[RenderInstanceKeyTable.shared.resolve(render), default: 0] += 1
                }
            }
            for entity in renderEntities where batch == "all" || !hasComponent(entityId: entity, componentType: LODComponent.self) {
                if batch == "single" {
                    guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                    let id = RenderInstanceKeyTable.shared.resolve(render)
                    if id < 0 || uses[id] != 1 { continue }
                }
                setEntityStaticBatch(entityId: entity)
                marked += 1
            }
            if let cell = env["BIM_BATCH_CELL"].flatMap(Float.init) {
                setBatching(.cellSize(cell))
            }
            setBatching(.enabled(true))
            if env["BIM_BATCH_INCREMENTAL"] != nil {
                // The path a loader would take at run time: announce the entities and let
                // the per-frame tick register them and build their cells under its budgets.
                let staticId = getComponentId(for: StaticBatchComponent.self)
                let renderId = getComponentId(for: RenderComponent.self)
                let announced = Set(queryEntitiesWithComponentIds([staticId, renderId], in: scene))
                BatchingSystem.shared.notifyTileEntitiesResident(announced)
                var frames = 0
                var lastGroups = -1
                var stable = 0
                while frames < 3000, stable < 120 {
                    renderer.draw(in: renderer.metalView)
                    waitForGPU()
                    frames += 1
                    let groups = BatchingSystem.shared.batchGroups.count
                    stable = groups == lastGroups ? stable + 1 : 0
                    lastGroups = groups
                }
                let summary = BatchingSystem.shared.getRuntimeBatchingSummaryDiagnostic()
                print("BIMBENCH incremental frames=\(frames) announced=\(announced.count) groups=\(BatchingSystem.shared.batchGroups.count) batchedEntities=\(BatchingSystem.shared.batchGroups.reduce(0) { $0 + $1.entityIds.count }) summary=\(summary)")
            } else {
                generateBatches()
            }
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
        if env["BIM_INSTANCING"] == "0" {
            setRendering(.instancedDraws(.disabled))
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
                if env["BIM_GROUPS"] != nil {
                    // How far instancing and state reuse could go: the visible draws by mesh and material.
                    var drawsByMesh: [ObjectIdentifier: Int] = [:]
                    var entitiesByMesh: [ObjectIdentifier: Int] = [:]
                    var drawsByMeshAndMaterial: [String: Int] = [:]
                    var drawsByMeshSubmeshAndMaterial: [String: Int] = [:]
                    var materials = Set<String>()
                    var totalDraws = 0
                    var materialRuns = 0
                    var meshRuns = 0
                    var lastMaterial: String?
                    var lastMesh: ObjectIdentifier?
                    for entity in visibleEntityIds {
                        guard let render = scene.get(component: RenderComponent.self, for: entity) else { continue }
                        for mesh in render.mesh {
                            let meshId = ObjectIdentifier(mesh.metalKitMesh)
                            entitiesByMesh[meshId, default: 0] += 1
                            if meshId != lastMesh { meshRuns += 1; lastMesh = meshId }
                            for (index, submesh) in mesh.submeshes.enumerated() {
                                guard let material = submesh.material, material.alphaMode != .blend else { continue }
                                totalDraws += 1
                                drawsByMesh[meshId, default: 0] += 1
                                func textureKey(_ texture: MTLTexture?) -> String { texture.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "-" }
                                let materialId = "\(textureKey(material.baseColor.texture))|\(textureKey(material.normal.texture))|\(textureKey(material.roughness.texture))|\(textureKey(material.metallic.texture))|\(material.baseColorValue)|\(material.roughnessValue)|\(material.metallicValue)|\(material.emissiveValue)|\(material.alphaMode.rawValue)"
                                materials.insert(materialId)
                                drawsByMeshAndMaterial["\(meshId.hashValue)-\(index)", default: 0] += 1
                                drawsByMeshSubmeshAndMaterial["\(meshId.hashValue)-\(index)-\(materialId)-\(textureKey(material.emissive.texture))-\(textureKey(material.height.texture))-\(material.alphaCutoff)-\(material.stScale)-\(mesh.localSpace == matrix_identity_float4x4)", default: 0] += 1
                                if materialId != lastMaterial { materialRuns += 1; lastMaterial = materialId }
                            }
                        }
                    }
                    let repeated = entitiesByMesh.filter { $0.value >= 2 }
                    let drawsOfRepeated = drawsByMesh.filter { (entitiesByMesh[$0.key] ?? 0) >= 2 }.reduce(0) { $0 + $1.value }
                    print("BIMGROUPS \(tag) view=\(name) draws=\(totalDraws) distinctMeshes=\(entitiesByMesh.count) meshesUsedTwiceOrMore=\(repeated.count) drawsOfThose=\(drawsOfRepeated) instancedDrawCount=\(drawsByMeshAndMaterial.count) withMaterial=\(drawsByMeshSubmeshAndMaterial.count) materials=\(materials.count) materialRuns=\(materialRuns) meshRuns=\(meshRuns)")
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
                if mode == "lod", let probe = env["BIM_SHADOW_PROBE"], probe.hasPrefix(name + ":") {
                    // Which caster makes the shadow in a region of the frame, and who draws it with batching on.
                    let box = probe.split(separator: ":")[1].split(separator: ",").compactMap { Int($0) }
                    func regionMean() -> Float {
                        for _ in 0 ..< 4 { renderer.draw(in: renderer.metalView); waitForGPU() }
                        guard let texture = textureResources.deferredColorMap else { return -1 }
                        let scaleX = Float(texture.width) / 1920, scaleY = Float(texture.height) / 1080
                        let x0 = Int(Float(box[0]) * scaleX), x1 = Int(Float(box[1]) * scaleX), y0 = Int(Float(box[2]) * scaleY), y1 = Int(Float(box[3]) * scaleY)
                        let width = x1 - x0, height = y1 - y0
                        var pixels = [Float16](repeating: 0, count: width * height * 4)
                        pixels.withUnsafeMutableBytes { bytes in
                            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(x0, y0, width, height), mipmapLevel: 0)
                        }
                        var sum: Float = 0
                        for index in stride(from: 0, to: pixels.count, by: 4) { sum += Float(pixels[index]) + Float(pixels[index + 1]) + Float(pixels[index + 2]) }
                        return sum / Float(width * height)
                    }
                    let batchedMean = regionMean()
                    let groupsBefore = BatchingSystem.shared.batchGroups
                    var groupOf: [EntityID: [Int]] = [:]
                    for (index, group) in groupsBefore.enumerated() { for entity in group.entityIds { groupOf[entity, default: []].append(index) } }
                    let wasBatched = Set(renderEntities.filter { BatchingSystem.shared.isBatched(entityId: $0) })
                    let wasAwaiting = Set(renderEntities.filter { BatchingSystem.shared.awaitsBatch(entityId: $0) })
                    setBatching(.enabled(false))
                    let unbatchedMean = regionMean()
                    print("BIMPROBE batchedMean=\(batchedMean) unbatchedMean=\(unbatchedMean) batchedEntities=\(wasBatched.count) awaiting=\(wasAwaiting.count)")
                    let casters = renderEntities.filter { scene.get(component: RenderComponent.self, for: $0)?.castsShadow == true }
                    let gap = batchedMean - unbatchedMean
                    func effect(of subset: ArraySlice<EntityID>) -> Float {
                        for entity in subset { scene.get(component: RenderComponent.self, for: entity)?.castsShadow = false }
                        let mean = regionMean()
                        for entity in subset { scene.get(component: RenderComponent.self, for: entity)?.castsShadow = true }
                        return (mean - unbatchedMean) / gap
                    }
                    var culprits: [(EntityID, Float)] = []
                    var pending: [ArraySlice<EntityID>] = [casters[...]]
                    var renders = 0
                    while let subset = pending.popLast(), renders < 200 {
                        let share = effect(of: subset)
                        renders += 1
                        if share < 0.15 { continue }
                        if subset.count == 1 { culprits.append((subset.first!, share)); continue }
                        let middle = subset.startIndex + subset.count / 2
                        pending.append(subset[subset.startIndex ..< middle])
                        pending.append(subset[middle ..< subset.endIndex])
                    }
                    for (entity, share) in culprits {
                        let local = scene.get(component: LocalTransformComponent.self, for: entity)!
                        let world = scene.get(component: WorldTransformComponent.self, for: entity)!
                        let (lower, upper) = worldAABB_MinMax(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
                        let render = scene.get(component: RenderComponent.self, for: entity)!
                        let groups = (groupOf[entity] ?? []).map { index in "group\(index)[entities=\(groupsBefore[index].entityIds.count) verts=\(groupsBefore[index].vertexCount) box=\(groupsBefore[index].boundingBox)]" }
                        print("BIMPROBE culprit \(entity) name=\(getEntityName(entityId: entity)) share=\(share) marked=\(hasComponent(entityId: entity, componentType: StaticBatchComponent.self)) wasBatched=\(wasBatched.contains(entity)) wasAwaiting=\(wasAwaiting.contains(entity)) lod=\(hasComponent(entityId: entity, componentType: LODComponent.self)) meshes=\(render.mesh.count) submeshes=\(render.mesh.map(\.submeshes.count)) materials=\(render.mesh.flatMap { $0.submeshes.map { $0.material == nil ? "nil" : "\($0.material!.alphaMode)" } }) box=\(lower)..\(upper) \(groups)")
                    }
                    print("BIMPROBE renders=\(renders) culprits=\(culprits.count)")
                }
                print("BIMINST \(tag) view=\(name) enabled=\(getInstancedDrawsEnabled()) opaque=\(RenderPasses.lastOpaqueInstancedDrawCounts) shadow=\(RenderPasses.lastShadowInstancedDrawCounts) descriptions=\(RenderInstanceKeyTable.shared.count)")
                print("BIMBENCH \(tag) view=\(name) mode=\(mode) frameMs=\(String(format: "%.1f", frameMs[frameMs.count / 2])) cpuMs=\(String(format: "%.1f", cpuMs[cpuMs.count / 2])) triangles=\(stats.trianglesTotal) draws=\(stats.drawCallsTotal) shadowDraws=\(stats.drawCallsShadow) visible=\(visibleEntityIds.count) levels=\(levels)")
                if let outputDir, let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
                    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                    saveResultToDisk(image, named: "\(tag)\(name)_\(mode)", in: outputDir)
                }
                if mode == "lod", let outputDir, env["BIM_PICTURE_PROBE"] == name {
                    // The same view four ways, to tell what batching changes in the picture
                    // through the sun's shadows from what it changes without them.
                    func save(_ suffix: String) {
                        for _ in 0 ..< 8 { renderer.draw(in: renderer.metalView); waitForGPU() }
                        if let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
                            saveResultToDisk(image, named: "\(tag)\(name)_\(suffix)", in: outputDir)
                        }
                    }
                    func sunShadows(_ on: Bool) {
                        for light in scene.getAllEntities() where hasComponent(entityId: light, componentType: DirectionalLightComponent.self) {
                            setLight(entityId: light, .directional(.castsShadow(on)))
                        }
                    }
                    save("A_loader_shadows")
                    print("BIMPROBE A shadowsActive=\(shadowSystem.isActive) shadowDraws=\(RenderStatsCollector.shared.snapshot().drawCallsShadow) depthSpans=\(shadowSystem.cascadeDepthSpans) casters=\(RenderPasses.lastShadowInstancedDrawCounts)")
                    generateBatches()
                    save("B_full_shadows")
                    sunShadows(false)
                    save("C_full_noshadows")
                    print("BIMPROBE C shadowsActive=\(shadowSystem.isActive) shadowDraws=\(RenderStatsCollector.shared.snapshot().drawCallsShadow)")
                    setBatching(.enabled(false))
                    save("D_off_noshadows")
                    sunShadows(true)
                    save("E_off_shadows")
                    print("BIMPROBE E shadowsActive=\(shadowSystem.isActive) shadowDraws=\(RenderStatsCollector.shared.snapshot().drawCallsShadow) depthSpans=\(shadowSystem.cascadeDepthSpans) casters=\(RenderPasses.lastShadowInstancedDrawCounts)")
                    print("BIMPROBE picture groups=\(BatchingSystem.shared.batchGroups.count)")
                }
            }
        }
    }
}
