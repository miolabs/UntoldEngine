//
//  DefaultEntitiesTests.swift
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

/// What a scene has before the app adds anything: a camera on every path, since the headset
/// writes the head pose into it, and a sun everywhere but the headset, where the passthrough
/// room is lit by its probe and the immersive environment by its own light.
@MainActor
final class DefaultEntitiesTests: BaseRenderSetup {
    override func tearDown() async throws {
        destroyAllEntities()
        try await super.tearDown()
    }

    func testTheHeadsetGetsACameraAndNoSun() {
        destroyAllEntities()
        LightingSystem.shared.activeDirectionalLight = nil
        let made = renderer.createDefaultEntities(sun: false)
        XCTAssertNil(made.sun)
        XCTAssertEqual(CameraSystem.shared.activeCamera, made.camera)
        XCTAssertNil(LightingSystem.shared.activeDirectionalLight)
        XCTAssertEqual(getDirectionalLightParameters().intensity, 0.0, "no sun lights the scene")
    }

    func testTheOtherPathsGetASunToo() {
        destroyAllEntities()
        LightingSystem.shared.activeDirectionalLight = nil
        let made = renderer.createDefaultEntities(sun: true)
        XCTAssertEqual(CameraSystem.shared.activeCamera, made.camera)
        XCTAssertEqual(LightingSystem.shared.activeDirectionalLight, made.sun)
        XCTAssertEqual(getDirectionalLightParameters().intensity, 1.0)
    }
}
