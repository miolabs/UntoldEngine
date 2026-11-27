// Scratch, not part of the engine: what a frame of many small draws costs on the CPU.
import simd
@testable import UntoldEngine
import XCTest

final class ZZDrawCostBenchmark: BaseRenderSetup {
    override func initializeAssets() {}

    func testManyDraws() throws {
        let env = ProcessInfo.processInfo.environment
        guard let tag = env["DRAWCOST_TAG"] else { throw XCTSkip("DRAWCOST_TAG not set") }
        defer { destroyAllEntities() }
        applyIBL = false
        renderEnvironment = false
        ambientIntensity = 0.5
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        far = 1000
        cameraLookAt(entityId: camera, eye: simd_float3(0, 95, 95), target: .zero, up: simd_float3(0, 1, 0))

        let side = Int(env["DRAWCOST_SIDE"] ?? "100") ?? 100
        let cube = BasicPrimitives.createCube(extent: 0.5)
        for row in 0 ..< side {
            for column in 0 ..< side {
                let entity = createEntity()
                setEntityMeshDirect(entityId: entity, meshes: cube, assetName: "Cube")
                translateTo(entityId: entity, position: simd_float3((Float(column) - Float(side) / 2) * 1.2, 0, (Float(row) - Float(side) / 2) * 1.2))
            }
        }
        traverseSceneGraph()

        var stats = RenderDrawStats()
        for _ in 0 ..< 10 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
        var cpu: [Double] = []
        for _ in 0 ..< 40 {
            let start = CFAbsoluteTimeGetCurrent()
            renderer.draw(in: renderer.metalView)
            cpu.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
            stats = RenderStatsCollector.shared.snapshot()
        }
        cpu.sort()
        print("DRAWINST \(tag) opaque=\(RenderPasses.lastOpaqueInstancedDrawCounts) shadow=\(RenderPasses.lastShadowInstancedDrawCounts)")
        print("DRAWCOST \(tag) entities=\(side * side) visible=\(visibleEntityIds.count) draws=\(stats.drawCallsTotal) shadowDraws=\(stats.drawCallsShadow) cpuMedianMs=\(String(format: "%.2f", cpu[cpu.count / 2])) cpuMinMs=\(String(format: "%.2f", cpu[0]))")
    }
}
