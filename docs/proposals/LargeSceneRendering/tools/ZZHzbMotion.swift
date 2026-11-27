// Scratch, not part of the engine: the two findings of the headset check, measured on the Mac.
import simd
@testable import UntoldEngine
import XCTest

final class ZZHzbMotion: BaseRenderSetup {
    override func initializeAssets() {}
    private func waitForGPU() { renderInfo.lastCommandBuffer?.waitUntilCompleted() }
    private func draw(_ n: Int) { for _ in 0 ..< n { renderer.draw(in: renderer.metalView); waitForGPU() } }
    private func save(_ name: String, in dir: URL) {
        if let texture = textureResources.antiAliasingTexture ?? textureResources.colorMap, let image = textureToCGImage(texture: texture) {
            saveResultToDisk(image, named: name, in: dir)
        }
    }

    func testMotion() async throws {
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

        // 2. The occlusion test while the camera moves: forward, sideways, backward and up in the
        // tree views, a step per frame; the count right after the last step (the cull with the
        // final camera against the previous frame's pyramid) against the settled count there.
        // The levels are frozen, so that the candidates of the two frames compared are the same set.
        for lod in lodEntities { scene.get(component: LODComponent.self, for: lod)?.forcedLOD = 1 }
        let views: [(String, simd_float3, simd_float3)] = [
            ("grove", simd_float3(116.6, 6, 6.2), simd_float3(86.6, 1.5, -23.8)),
            ("tree15m", simd_float3(97.6, 1.7, 155.3), simd_float3(84.6, 2.0, 147.8)),
            ("walk", simd_float3(40, 1.7, 60), simd_float3(86, 2, -24)),
        ]
        for (name, eye0, target0) in views {
            let forward = simd_normalize(target0 - eye0)
            let side = simd_normalize(simd_cross(forward, simd_float3(0, 1, 0)))
            for (motion, dir) in [("forward", forward), ("sideways", side), ("backward", -forward), ("up", simd_float3(0, 1, 0))] {
                for step in [Float(0.1), 0.3, 1.0] {
                    var eye = eye0
                    cameraLookAt(entityId: camera, eye: eye, target: eye + forward * 100, up: simd_float3(0, 1, 0))
                    LODSystem.shared.reset()
                    draw(10)
                    for _ in 0 ..< 20 {
                        eye += dir * step
                        cameraLookAt(entityId: camera, eye: eye, target: eye + forward * 100, up: simd_float3(0, 1, 0))
                        draw(1)
                    }
                    // The cull of the last step's frame: the final camera against the pyramid of one step before.
                    let moving = HZBDebugMonitor.shared.stats
                    draw(10)
                    // The cull at the same place once the pyramid comes from there too.
                    let settled = HZBDebugMonitor.shared.stats
                    print("HZBSTEP view=\(name) motion=\(motion) step=\(step) m/frame: frustum=\(moving.frustumCandidateCount) moving cull kept=\(moving.visibleAfterOcclusionCount) (test ran: \(moving.usedHZBThisFrame)) settled cull kept=\(settled.visibleAfterOcclusionCount) (frustum \(settled.frustumCandidateCount)) lost=\(settled.visibleAfterOcclusionCount - moving.visibleAfterOcclusionCount) sameCandidates=\(moving.frustumCandidateCount == settled.frustumCandidateCount)")
                }
            }
        }
    }
}
