//
//  BenchScenes.swift
//  PerfBench
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import SwiftUI
import UntoldEngine

/// How the runner moves the camera on platforms where the camera is not the user's head.
public struct BenchCameraOrbit: Sendable {
    public var center: simd_float3
    public var radius: Float
    public var height: Float
    /// Seconds for one full orbit.
    public var period: Float

    public init(center: simd_float3, radius: Float, height: Float, period: Float = 12.0) {
        self.center = center
        self.radius = radius
        self.height = height
        self.period = period
    }

    public func eye(at seconds: Float) -> simd_float3 {
        let angle = 2.0 * Float.pi * seconds / period
        return center + simd_float3(radius * cos(angle), height, radius * sin(angle))
    }
}

/// One benchmark scene. `build` creates every entity relative to `origin`; the runner destroys
/// them afterwards, so `teardown` only has to undo global settings the scene changed.
@MainActor
public protocol BenchScene {
    var id: String { get }
    var title: String { get }
    var notes: String { get }
    /// Camera orbit for macOS and iOS. On visionOS the head is the camera and the orbit is ignored.
    var orbit: BenchCameraOrbit { get }
    func build(origin: simd_float3)
    func teardown()
}

public extension BenchScene {
    func teardown() {}
}

public enum BenchScenes {
    @MainActor public static let all: [BenchScene] = [
        PrimitivesScene(id: "primitives-1k", gridSize: 32, spacing: 1.0, batched: false, pointLights: 4),
        PrimitivesScene(id: "primitives-10k", gridSize: 100, spacing: 1.0, batched: true, pointLights: 4),
        PrimitivesScene(id: "lights-64", gridSize: 32, spacing: 1.0, batched: true, pointLights: 64),
        PostFXScene(),
        AnimationScene(),
        StadiumScene(),
        GaussianScene(),
    ]

    @MainActor public static func scenes(withIDs ids: [String]) -> [BenchScene] {
        ids.compactMap { id in all.first { $0.id == id } }
    }
}

// MARK: - Shared helpers

@MainActor
enum BenchSceneBuilder {
    static func makeCamera(eye: simd_float3, target: simd_float3) {
        let camera = createEntity()
        setEntityName(entityId: camera, name: "Bench Camera")
        createGameCamera(entityId: camera)
        cameraLookAt(entityId: camera, eye: eye, target: target, up: simd_float3(0, 1, 0))
        setCamera(.active(camera))
    }

    static func makeSun(pitch: Float = -50.0, intensity: Float = 1.5) {
        let sun = createEntity()
        setEntityName(entityId: sun, name: "Bench Sun")
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, angle: pitch, axis: simd_float3(1, 0, 0))
        setLight(entityId: sun, .color(simd_float3(1.0, 0.94, 0.86)))
        setLight(entityId: sun, .intensity(intensity))
        setLight(entityId: sun, .directional(.active))
    }

    static func makePointLights(count: Int, around center: simd_float3, radius: Float, height: Float) {
        for index in 0 ..< count {
            let light = createEntity()
            setEntityName(entityId: light, name: "Bench Point \(index)")
            createPointLight(entityId: light)
            let angle = 2.0 * Float.pi * Float(index) / Float(max(1, count))
            translateTo(entityId: light, position: center + simd_float3(radius * cos(angle), height, radius * sin(angle)))
            let hue = Double(index % 12) / 12.0
            let rgb = Color(hue: hue, saturation: 0.55, brightness: 1.0)
            setLight(entityId: light, .color(Self.rgb(rgb)))
            setLight(entityId: light, .intensity(6.0))
            setLight(entityId: light, .point(.range(8.0)))
        }
    }

    static func rgb(_ color: Color) -> simd_float3 {
        #if canImport(AppKit)
            let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
            return simd_float3(Float(native.redComponent), Float(native.greenComponent), Float(native.blueComponent))
        #else
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return simd_float3(Float(r), Float(g), Float(b))
        #endif
    }

    static func makeGrid(
        origin: simd_float3,
        gridSize: Int,
        spacing: Float,
        batched: Bool,
        namePrefix: String
    ) -> [EntityID] {
        let cube = BasicPrimitives.createCube(extent: spacing * 0.35)
        let sphere = BasicPrimitives.createSphere(extent: spacing * 0.22, segments: [24, 12])
        let half = Float(gridSize) * spacing * 0.5
        var entities: [EntityID] = []
        entities.reserveCapacity(gridSize * gridSize)
        for z in 0 ..< gridSize {
            for x in 0 ..< gridSize {
                let entity = createEntity()
                setEntityName(entityId: entity, name: "\(namePrefix)_\(x)_\(z)")
                let useSphere = (x + z) % 3 == 0
                setEntityMeshDirect(
                    entityId: entity,
                    meshes: useSphere ? sphere : cube,
                    assetName: useSphere ? "bench_sphere" : "bench_cube"
                )
                let y = 0.15 * sin(Float(x) * 0.35) * cos(Float(z) * 0.35)
                translateTo(
                    entityId: entity,
                    position: origin + simd_float3(Float(x) * spacing - half, y, Float(z) * spacing - half)
                )
                let hue = Double((x * 7 + z * 3) % 16) / 16.0
                updateMaterialColor(entityId: entity, color: Color(hue: hue, saturation: 0.6, brightness: 0.85))
                updateMaterialRoughness(entityId: entity, roughness: useSphere ? 0.25 : 0.7)
                if batched {
                    setEntityStaticBatchComponent(entityId: entity)
                }
                entities.append(entity)
            }
        }
        if batched {
            setBatching(.enabled(true))
            generateBatches()
        }
        return entities
    }
}

// MARK: - Scenes

/// A grid of individual primitives: draw-call and per-entity CPU cost, shadows, a few lights.
@MainActor
final class PrimitivesScene: BenchScene {
    let id: String
    let gridSize: Int
    let spacing: Float
    let batched: Bool
    let pointLights: Int

    init(id: String, gridSize: Int, spacing: Float, batched: Bool, pointLights: Int) {
        self.id = id
        self.gridSize = gridSize
        self.spacing = spacing
        self.batched = batched
        self.pointLights = pointLights
    }

    var title: String {
        "\(gridSize * gridSize) primitives\(batched ? ", static batching" : ""), \(pointLights) point lights"
    }

    var notes: String {
        batched
            ? "Cubes and spheres merged by the static batcher; measures batched draw cost and light-loop cost."
            : "One entity and draw per primitive; measures per-entity CPU cost and encoder overhead."
    }

    var orbit: BenchCameraOrbit {
        let extent = Float(gridSize) * spacing
        return BenchCameraOrbit(center: .zero, radius: extent * 0.7, height: extent * 0.35, period: 14.0)
    }

    func build(origin: simd_float3) {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin)
        BenchSceneBuilder.makeSun()
        _ = BenchSceneBuilder.makeGrid(origin: origin, gridSize: gridSize, spacing: spacing, batched: batched, namePrefix: id)
        let extent = Float(gridSize) * spacing
        BenchSceneBuilder.makePointLights(count: pointLights, around: origin, radius: extent * 0.4, height: 2.0)
    }

    func teardown() {
        if batched {
            setBatching(.enabled(false))
        }
    }
}

/// The 1k primitive grid with SSAO, bloom, depth of field and SMAA on: the post-processing chain.
@MainActor
final class PostFXScene: BenchScene {
    let id = "postfx"
    let title = "1024 primitives with SSAO, bloom, depth of field and SMAA"
    let notes = "Same geometry as primitives-1k; the difference is the full-screen pass chain."
    let orbit = BenchCameraOrbit(center: .zero, radius: 22.0, height: 11.0, period: 14.0)

    func build(origin: simd_float3) {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin)
        BenchSceneBuilder.makeSun()
        _ = BenchSceneBuilder.makeGrid(origin: origin, gridSize: 32, spacing: 1.0, batched: false, namePrefix: id)
        BenchSceneBuilder.makePointLights(count: 4, around: origin, radius: 12.0, height: 2.0)
        setRendering(.postProcessing(.enabled))
        setRendering(.antiAliasing(.smaa))
        setPostFX(.ssao(.enabled(true)))
        setPostFX(.ssao(.quality(.balanced)))
        setPostFX(.bloomThreshold(.enabled(true)))
        setPostFX(.bloomComposite(.enabled(true)))
        setPostFX(.depthOfField(.enabled(true)))
    }

    func teardown() {
        setPostFX(.depthOfField(.enabled(false)))
        setPostFX(.bloomComposite(.enabled(false)))
        setPostFX(.bloomThreshold(.enabled(false)))
        setPostFX(.ssao(.enabled(false)))
        setRendering(.antiAliasing(.none))
    }
}

/// Sixteen skinned characters playing a clip: animation sampling, joint updates and the deformation pass.
@MainActor
final class AnimationScene: BenchScene {
    let id = "animation-16"
    let title = "16 skinned characters running"
    let notes = "redplayer.untold with the running clip; measures the animation system and GPU skinning."
    let orbit = BenchCameraOrbit(center: simd_float3(0, 1, 0), radius: 11.0, height: 3.0, period: 14.0)

    func build(origin: simd_float3) {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin + simd_float3(0, 1, 0))
        BenchSceneBuilder.makeSun()
        AnimationSystem.shared.isEnabled = true
        for index in 0 ..< 16 {
            let entity = createEntity()
            setEntityName(entityId: entity, name: "Bench Player \(index)")
            setEntityMesh(entityId: entity, filename: "redplayer", withExtension: "untold")
            setEntityAnimations(entityId: entity, filename: "running", withExtension: "untold", name: "running")
            changeAnimation(entityId: entity, name: "running")
            let x = Float(index % 4) * 2.2 - 3.3
            let z = Float(index / 4) * 2.2 - 3.3
            translateTo(entityId: entity, position: origin + simd_float3(x, 0, z))
        }
    }
}

/// A textured, multi-material asset with a ground plane: material binds and texture bandwidth.
@MainActor
final class StadiumScene: BenchScene {
    let id = "stadium"
    let title = "Stadium and grass (textured assets)"
    let notes = "stadium.untold and grass.untold from the render-test resources."
    let orbit = BenchCameraOrbit(center: .zero, radius: 60.0, height: 22.0, period: 18.0)

    func build(origin: simd_float3) {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin)
        BenchSceneBuilder.makeSun(pitch: -40.0)
        let stadium = createEntity()
        setEntityName(entityId: stadium, name: "Bench Stadium")
        setEntityMesh(entityId: stadium, filename: "stadium", withExtension: "untold")
        translateTo(entityId: stadium, position: origin)
        let grass = createEntity()
        setEntityName(entityId: grass, name: "Bench Grass")
        setEntityMesh(entityId: grass, filename: "grass", withExtension: "untold")
        translateTo(entityId: grass, position: origin)
    }
}

/// A Gaussian splat next to primitives: the splat cull, depth-key and radix-sort passes every frame.
@MainActor
final class GaussianScene: BenchScene {
    let id = "gaussian"
    let title = "Gaussian splat with primitives"
    let notes = "test_gaussians.ply (small) plus a 16x16 grid; exercises the sort pipeline, not splat count."
    let orbit = BenchCameraOrbit(center: .zero, radius: 10.0, height: 4.0, period: 14.0)

    func build(origin: simd_float3) {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin)
        BenchSceneBuilder.makeSun()
        let splat = createEntity()
        setEntityName(entityId: splat, name: "Bench Gaussian")
        setEntityGaussian(entityId: splat, filename: "test_gaussians", withExtension: "ply")
        translateTo(entityId: splat, position: origin + simd_float3(0, 1, 0))
        _ = BenchSceneBuilder.makeGrid(origin: origin, gridSize: 16, spacing: 1.0, batched: false, namePrefix: id)
    }
}
