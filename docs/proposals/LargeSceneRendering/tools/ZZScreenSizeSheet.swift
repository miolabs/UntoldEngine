// Scratch, not part of the engine: renders the panels of the comparison sheet for the
// pull request of LOD selection by screen size. SHEET_OUT names the folder.
import Foundation
import simd
@testable import UntoldEngine
@testable import UntoldEngineMeshCook
import XCTest

final class ZZScreenSizeSheet: BaseRenderSetup {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        LoadingSystem.shared.resourceURLFn = getResourceURL
        LODSystem.shared.reset()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZZScreenSizeSheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        LODSystem.shared.reset()
        destroyAllEntities()
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    override func initializeAssets() {}

    private func projection(fovYDegrees: Float) -> simd_float4x4 {
        matrixPerspectiveRightHandReverseZ(
            fovyRadians: degreesToRadians(degrees: fovYDegrees),
            aspectRatio: Float(windowWidth) / Float(windowHeight),
            nearZ: near, farZ: far
        )
    }

    private func draw(_ frames: Int = 8) {
        for _ in 0 ..< frames {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    func testSheet() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SHEET_OUT"] else { throw XCTSkip("SHEET_OUT not set") }
        let outputDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let asset = env["SHEET_MODEL"] ?? "stadium"

        let source = try XCTUnwrap(LoadingSystem.shared.resourceURL(forResource: asset, withExtension: "untold"))
        let destination = tempRoot.appendingPathComponent("Model/Model.untold")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let manifest: [String: Any] = ["formatVersion": 1, "sourceAsset": "Site.blend", "models": [[
            "displayName": "Model", "path": "Model/Model.untold",
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
        ]]]
        let packURL = tempRoot.appendingPathComponent("Site").appendingPathExtension("untoldpack")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: packURL)
        let report = try UntoldMeshLODCooker.cookChains(forPackAt: packURL, options: UntoldMeshLODOptions(minimumTriangles: 0))
        XCTAssertTrue(report.failures.isEmpty)

        let rootId = createEntity()
        let loaded = expectation(description: "pack")
        setEntityMeshAsync(entityId: rootId, filename: packURL.deletingPathExtension().path, withExtension: "untoldpack") { ok in
            XCTAssertTrue(ok); loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 60)
        traverseSceneGraph()

        let lodEntities = scene.getAllEntities().filter { hasComponent(entityId: $0, componentType: LODComponent.self) }
        XCTAssertFalse(lodEntities.isEmpty)
        var lower = simd_float3(repeating: .greatestFiniteMagnitude), upper = -lower
        for entity in lodEntities {
            guard let local = scene.get(component: LocalTransformComponent.self, for: entity),
                  let world = scene.get(component: WorldTransformComponent.self, for: entity) else { continue }
            let (a, b) = worldAABB_MinMax(localMin: local.boundingBox.min, localMax: local.boundingBox.max, worldMatrix: world.space)
            lower = simd_min(lower, a); upper = simd_max(upper, b)
        }
        let center = (lower + upper) * 0.5
        let radius = simd_length(upper - lower) * 0.5
        if let first = lodEntities.first, let lod = scene.get(component: LODComponent.self, for: first) {
            print("SHEET levels=\(lod.lodLevels.map { "\($0.maxDistance) @\($0.screenPercentage)" }) radius=\(radius) center=\(center)")
        }

        far = 10000
        near = 1
        let sun = createEntity()
        createDirLight(entityId: sun)
        setSunElevationAzimuth(entityId: sun, elevation: 45, azimuth: 135)
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera

        // Screen sizes a hand-made chain would have, large enough to see; the stored
        // distances are the same switches under the field of view of the load (60°), so
        // the two rules agree there and part when the field of view changes.
        let sizes: [Float] = [1, 0.6, 0.4, 0.25]
        let reach60 = 1 / tan(degreesToRadians(degrees: 60) / 2)
        for entity in lodEntities {
            guard let lod = scene.get(component: LODComponent.self, for: entity) else { continue }
            let worldRadius = entityDistanceAndRadius(entityId: entity, cameraPosition: .zero, localRadius: lod.screenSizeRadius).radius
            for index in lod.lodLevels.indices {
                lod.lodLevels[index].screenPercentage = index < sizes.count ? sizes[index] : 0
                if index + 1 < lod.lodLevels.count, index + 1 < sizes.count {
                    lod.lodLevels[index].maxDistance = worldRadius * reach60 / sizes[index + 1]
                }
            }
        }
        // The camera stands where the wide view shows the model at a fifth of the height.
        let share = Float(env["SHEET_SIZE"] ?? "") ?? 0.2
        let distance = radius * reach60 / share
        let eye = center + simd_normalize(simd_float3(0.55, 0.35, 1)) * distance
        cameraLookAt(entityId: camera, eye: eye, target: center, up: simd_float3(0, 1, 0))
        print("SHEET distance=\(distance) eye=\(eye)")

        func triangles() -> Int {
            lodEntities.reduce(0) { total, entity in
                guard let render = scene.get(component: RenderComponent.self, for: entity) else { return total }
                return total + render.mesh.reduce(0) { $0 + $1.submeshes.reduce(0) { $0 + $1.indexCount / 3 } }
            }
        }
        func levelsDrawn() -> [Int] {
            lodEntities.compactMap { scene.get(component: LODComponent.self, for: $0)?.currentLOD }
        }
        func panel(_ name: String, fov fovDegrees: Float, byScreenSize: Bool?, forced: Int?) {
            fov = fovDegrees
            renderInfo.perspectiveSpace = projection(fovYDegrees: fovDegrees)
            for entity in lodEntities {
                guard let lod = scene.get(component: LODComponent.self, for: entity) else { continue }
                if let byScreenSize { lod.selectsByScreenSize = byScreenSize }
                lod.forcedLOD = forced
            }
            LODSystem.shared.reset()
            draw(12)
            let levels = Set(levelsDrawn()).sorted()
            print("SHEET panel=\(name) fov=\(fovDegrees) levels=\(levels) triangles=\(triangles())")
            if let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
                saveResultToDisk(image, named: name, in: outputDir)
            }
        }
        for (label, fovDegrees) in [("wide", Float(60)), ("zoom", Float(20))] {
            panel("\(label)_reference", fov: fovDegrees, byScreenSize: nil, forced: 0)
            panel("\(label)_before", fov: fovDegrees, byScreenSize: false, forced: nil)
            panel("\(label)_after", fov: fovDegrees, byScreenSize: true, forced: nil)
        }
        fov = 60
        renderInfo.perspectiveSpace = projection(fovYDegrees: 60)
    }
}
