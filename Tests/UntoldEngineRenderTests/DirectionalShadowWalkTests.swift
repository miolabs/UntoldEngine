//
//  DirectionalShadowWalkTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
@testable import UntoldEngine
import XCTest

/// The shadow pass walks the scene once a frame for the directional light: the cascades
/// are fitted to what the walk finds, and each cascade draws the casters that reach it.
/// These tests pin that the walk fits the cascades as the shadow system does on its own,
/// and who is a caster.
@MainActor
final class DirectionalShadowWalkTests: BaseRenderSetup {
    private var savedPixels: Float = 1

    override func setUp() async throws {
        try await super.setUp()
        savedPixels = SmallObjectCulling.minimumPixels
        setRendering(.smallObjectCulling(pixels: 1))
    }

    override func tearDown() async throws {
        SmallObjectCulling.minimumPixels = savedPixels
        setSceneChannel(.ghostGeometry, .renderMode(.normal))
        destroyAllEntities()
        try await super.tearDown()
    }

    override func initializeAssets() {
        let camera = createEntity()
        createGameCamera(entityId: camera)
        CameraSystem.shared.activeCamera = camera
        cameraLookAt(entityId: camera, eye: simd_float3(0, 6, 16), target: .zero, up: simd_float3(0, 1, 0))

        let sun = createEntity()
        createDirLight(entityId: sun)
        setSunElevationAzimuth(entityId: sun, elevation: 50, azimuth: 30)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCube(at position: simd_float3, scale: simd_float3 = simd_float3(repeating: 1)) -> EntityID {
        let entity = createEntity()
        setEntityMeshDirect(entityId: entity, meshes: BasicPrimitives.createCube(extent: 1.0), assetName: "Cube")
        scaleTo(entityId: entity, scale: scale)
        translateTo(entityId: entity, position: position)
        return entity
    }

    private func makeGround() -> EntityID {
        makeCube(at: simd_float3(0, -1.2, 0), scale: simd_float3(40, 0.2, 40))
    }

    /// Draws enough frames for the culling result of the scene to come back and be used.
    private func drawFrames() {
        for _ in 0 ..< 6 {
            renderer.draw(in: renderer.metalView)
            renderInfo.lastCommandBuffer?.waitUntilCompleted()
        }
    }

    /// The casters drawn into the cascades of the last frame, counted once per cascade
    /// they were drawn into.
    private var castersDrawn: Int {
        RenderPasses.lastShadowInstancedDrawCounts.instances
    }

    // MARK: - The fit

    func testThePassFitsTheCascadesAsTheShadowSystemDoesOnItsOwn() {
        _ = makeGround()
        for index in 0 ..< 6 {
            makeCube(at: simd_float3(Float(index % 3) * 4 - 4, 0.4, Float(index / 3) * -4 + 2), scale: simd_float3(0.8, 3, 0.8))
        }
        // What shapes the fit without casting, or casts without being drawn large:
        // a roof that casts no shadow, a speck under a pixel, a hidden entity.
        let roof = makeCube(at: simd_float3(0, 12, 0), scale: simd_float3(10, 0.2, 10))
        scene.get(component: RenderComponent.self, for: roof)?.castsShadow = false
        makeCube(at: simd_float3(2, 1, 4), scale: simd_float3(repeating: 0.005))
        let hidden = makeCube(at: simd_float3(-6, 20, 0), scale: simd_float3(4, 4, 4))
        setEntitySceneChannels(entityId: hidden, channels: .ghostGeometry)
        setSceneChannel(.ghostGeometry, .renderMode(.hidden))

        drawFrames()
        XCTAssertTrue(shadowSystem.isActive)
        XCTAssertGreaterThan(castersDrawn, 0, "the posts cast")
        let matricesFromThePass = shadowSystem.cascadeLightSpaceMatrices
        let depthSpansFromThePass = shadowSystem.cascadeDepthSpans

        // The shadow system, walking the scene by itself.
        shadowSystem.updateCascades()

        XCTAssertEqual(shadowSystem.cascadeLightSpaceMatrices, matricesFromThePass)
        XCTAssertEqual(shadowSystem.cascadeDepthSpans, depthSpansFromThePass)
    }

    func testWhatDoesNotCastStillShapesTheCascades() throws {
        _ = makeGround()
        makeCube(at: simd_float3(0, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        drawFrames()
        let depthSpans = shadowSystem.cascadeDepthSpans
        let casters = castersDrawn
        XCTAssertGreaterThan(casters, 0)

        // A roof far above that casts no shadow: the cascades reach up to it, as they did
        // before the pass found its casters in the same walk, and nothing more is drawn.
        // It is wide enough to be over the first cascade from wherever the light looks.
        let roof = makeCube(at: simd_float3(0, 60, 0), scale: simd_float3(300, 0.2, 300))
        try XCTUnwrap(scene.get(component: RenderComponent.self, for: roof)).castsShadow = false
        drawFrames()

        XCTAssertGreaterThan(shadowSystem.cascadeDepthSpans[0], depthSpans[0] + 20)
        XCTAssertEqual(castersDrawn, casters)
    }

    // MARK: - The casters

    func testACasterMadeAfterAFrameCastsInTheNextOne() throws {
        _ = makeGround()
        drawFrames()
        let casters = castersDrawn

        // No invalidation of the candidate cache: the walk reads the scene as it is.
        let post = makeCube(at: simd_float3(0, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        drawFrames()
        XCTAssertGreaterThan(castersDrawn, casters, "the new cube casts")
        let castersWithThePost = castersDrawn

        // And it stops as soon as it is told not to cast.
        try XCTUnwrap(scene.get(component: RenderComponent.self, for: post)).castsShadow = false
        drawFrames()
        XCTAssertEqual(castersDrawn, casters)

        try XCTUnwrap(scene.get(component: RenderComponent.self, for: post)).castsShadow = true
        drawFrames()
        XCTAssertEqual(castersDrawn, castersWithThePost)
    }

    func testACasterOutOfReachOfTheCascadesIsNotDrawn() {
        _ = makeGround()
        makeCube(at: simd_float3(0, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        drawFrames()
        let casters = castersDrawn

        // Far past the shadow distance from anything the cascades cover.
        makeCube(at: simd_float3(0, 0.4, -400), scale: simd_float3(4, 4, 4))
        // Hidden: not a caster either.
        let hidden = makeCube(at: simd_float3(3, 0.4, 0), scale: simd_float3(0.8, 3, 0.8))
        setEntitySceneChannels(entityId: hidden, channels: .ghostGeometry)
        setSceneChannel(.ghostGeometry, .renderMode(.hidden))
        drawFrames()

        XCTAssertGreaterThan(casters, 0)
        XCTAssertEqual(castersDrawn, casters)
    }
}
