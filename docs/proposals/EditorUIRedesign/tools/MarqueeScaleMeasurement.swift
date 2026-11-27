// The measurement behind the numbers given for PR 147 (2026-10-05). Not part of the repo.
// Drop it into Tests/UntoldEditorTests and run:
//   swift test --disable-swift-testing --filter MarqueeScaleMeasurement            (debug)
//   swift test -c release -Xswiftc -enable-testing --disable-swift-testing --filter MarqueeScaleMeasurement
// It times one mouse-up of the rectangle (MarqueeSelection.entities with the real pass)
// on scenes of spheres placed at random in a cube 400 units wide around the camera.
import MetalKit
import ModelIO
import simd
@testable import UntoldEditor
@testable import UntoldEngine
import XCTest

@MainActor
final class MarqueeScaleMeasurement: XCTestCase {
    private var originalScene: UntoldEngine.Scene!
    private var window: NSWindow!
    private var renderer: UntoldRenderer!
    private let size = CGSize(width: 1200, height: 800)

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        guard let created = UntoldRenderer.create() else {
            XCTFail("no renderer")
            return
        }
        renderer = created
        window.contentView = created.metalView
        created.initResources()
        originalScene = scene
        scene = Scene()
        setIgnoreRayIntersectionWithTransparents(false)
    }

    override func tearDown() {
        scene = originalScene
        originalScene = nil
        renderer = nil
        window = nil
        super.tearDown()
    }

    private struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    private func ms(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func makeView() -> MarqueeGeometry.View {
        let camera = createEntity()
        registerComponent(entityId: camera, componentType: CameraComponent.self)
        cameraLookAt(entityId: camera, eye: .zero, target: simd_float3(0, 0, -1), up: simd_float3(0, 1, 0))
        return MarqueeGeometry.View(
            viewSpace: scene.get(component: CameraComponent.self, for: camera)?.viewSpace ?? matrix_identity_float4x4,
            perspectiveSpace: matrixPerspectiveRightHand(fovyRadians: .pi / 2, aspectRatio: Float(size.width / size.height), nearZ: 0.1, farZ: 2000),
            size: size
        )
    }

    private func run(_ label: String, count: Int, segments: [UInt32], side: Float = 400, walls: Int = 0) {
        scene = Scene()
        let view = makeView()
        let meshes = BasicPrimitives.createSphere(extent: 1, segments: segments)
        let triangles = meshes.reduce(0) { $0 + $1.submeshes.reduce(0) { $0 + $1.metalKitSubmesh.indexCount / 3 } }
        var generator = Generator(state: 42)

        for _ in 0 ..< count {
            let entity = createEntity()
            setEntityMeshDirect(entityId: entity, meshes: meshes, assetName: "S")
            translateTo(entityId: entity, position: simd_float3(
                (generator.next() - 0.5) * side, (generator.next() - 0.5) * side, (generator.next() - 0.5) * side
            ))
        }
        // Walls that fill the view, one behind the other: overdraw.
        if walls > 0 {
            let wall = BasicPrimitives.createCube(extent: 1)
            for index in 0 ..< walls {
                let entity = createEntity()
                setEntityMeshDirect(entityId: entity, meshes: wall, assetName: "W")
                let distance = Float(20 + index)
                scaleTo(entityId: entity, scale: simd_float3(distance * 4, distance * 4, 0.1))
                translateTo(entityId: entity, position: simd_float3(0, 0, -distance))
            }
        }

        let selectionManager = SelectionManager()
        func selection(_ rect: CGRect) -> String {
            var totals: [Double] = []
            var chosen = 0
            var handed = -1
            // The first run makes the pipeline; it is not counted.
            for run in 0 ..< 6 {
                handed = -1
                let time = ms {
                    chosen = MarqueeSelection.entities(inside: rect, view: view, selectionManager: selectionManager, seen: { rect, view, drawn in
                        handed = drawn.count
                        return SelectionVisibilityPass.entitiesSeen(in: rect, view: view, scale: 2, drawn: drawn)
                    }).count
                }
                if run > 0 {
                    totals.append(time)
                }
            }
            return String(format: "%8.2f ms | chosen %d | pass handed %d entities", median(totals), chosen, handed)
        }

        print(String(format: "SCALE %@: %d entities x %d tris = %.1f M tris, walls %d", label, count, triangles, Double(count * triangles) / 1_000_000, walls))
        print("SCALE   mouse-up, rectangle of 60 x 60 points : \(selection(CGRect(x: 570, y: 370, width: 60, height: 60)))")
        print("SCALE   mouse-up, the whole viewport          : \(selection(CGRect(origin: .zero, size: size)))")
    }

    func test_scale() {
        run("A", count: 375, segments: [32, 16])
        run("B", count: 5000, segments: [32, 16])
        run("C", count: 20000, segments: [32, 16])
        run("D", count: 100_000, segments: [32, 16])
        run("E heavy", count: 20000, segments: [128, 64])
        run("F overdraw", count: 375, segments: [32, 16], walls: 300)
    }
}
