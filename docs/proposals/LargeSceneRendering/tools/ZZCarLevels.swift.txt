// Scratch, not part of the engine: every parked car of the BIM site at a forced level.
import simd
@testable import UntoldEngine
import XCTest

final class ZZCarLevels: BaseRenderSetup {
    override func initializeAssets() {}
    private func waitForGPU() { renderInfo.lastCommandBuffer?.waitUntilCompleted() }
    private func draw(_ n: Int) { for _ in 0 ..< n { renderer.draw(in: renderer.metalView); waitForGPU() } }
    private func save(_ name: String, in dir: URL) {
        if let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
            saveResultToDisk(image, named: name, in: dir)
        }
    }

    func testLevels() async throws {
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
        let camera = createEntity(); createGameCamera(entityId: camera); CameraSystem.shared.activeCamera = camera
        far = 2000

        // The LOD components of every parked car's parts.
        var carLods: [LODComponent] = []
        var carCenters: [simd_float3] = []
        for placement in all where getEntityName(entityId: placement).lowercased().contains("aparcado") && !hasComponent(entityId: placement, componentType: RenderComponent.self) {
            var queue = [placement]
            var lower = simd_float3(repeating: .greatestFiniteMagnitude), upper = -lower
            while let e = queue.popLast() {
                if let lod = scene.get(component: LODComponent.self, for: e) { carLods.append(lod) }
                if let local = scene.get(component: LocalTransformComponent.self, for: e), let world = scene.get(component: WorldTransformComponent.self, for: e), hasComponent(entityId: e, componentType: RenderComponent.self) {
                    let (a, b) = worldAABB_MinMax(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
                    lower = simd_min(lower, a); upper = simd_max(upper, b)
                }
                queue.append(contentsOf: getEntityChildren(parentId: e))
            }
            if lower.x < upper.x { carCenters.append((lower + upper) * 0.5) }
        }
        print("CARLEVELS cars=\(carCenters.count) lodComponents=\(carLods.count)")
        // The same view as before: car 01 from the front-left, the row of white cars behind it.
        guard let first = carCenters.first else { return }
        let eye = first + simd_normalize(simd_float3(0.2, 0.35, 1)) * 2.65 * 1.6
        cameraLookAt(entityId: camera, eye: eye, target: first, up: simd_float3(0, 1, 0))
        // And a view down the row from above, so that several cars are at a middle distance.
        let views: [(String, simd_float3, simd_float3)] = [
            ("row", eye, first),
            ("above", first + simd_float3(6, 5, 14), first + simd_float3(-10, 0, -20)),
        ]
        for (name, eye, target) in views {
            cameraLookAt(entityId: camera, eye: eye, target: target, up: simd_float3(0, 1, 0))
            for level in [0, 1, 2, 3] {
                for lod in carLods { lod.forcedLOD = level }
                LODSystem.shared.reset()
                draw(10)
                print("CARLEVELS view=\(name) level=\(level) triangles=\(RenderStatsCollector.shared.snapshot().trianglesTotal)")
                save("cars_\(name)_lod\(level)", in: outputDir)
            }
        }
        for lod in carLods { lod.forcedLOD = nil }
    }
}
