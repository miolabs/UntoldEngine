//
//  ShadowSoftnessBeforeSystemTests.swift
//  UntoldEngineTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import UntoldEngine
import XCTest

/// A shadow softness set before the shadow system exists (before the renderer, or between two
/// sessions) is kept and given to the system when it is created, instead of crashing.
@MainActor
final class ShadowSoftnessBeforeSystemTests: XCTestCase {
    private var previousSystem: ShadowSystem?

    override func setUp() {
        previousSystem = shadowSystem
        shadowSystem = nil
        shadowSoftnessBeforeSystem = nil
    }

    override func tearDown() {
        shadowSystem = previousSystem
        shadowSoftnessBeforeSystem = nil
    }

    func testASettingBeforeTheSystemIsKeptAndGivenToItAtItsCreation() {
        let wanted = ShadowSoftnessSettings(filterTaps: 4, xrFilterTaps: 4)
        setShadowSoftness(wanted)
        var reference = ShadowSystem()
        reference.setSoftness(wanted)
        XCTAssertEqual(getShadowSoftness(), reference.softnessSettings)

        shadowSystem = ShadowSystem()
        applyShadowSoftnessSetBeforeSystem()
        XCTAssertEqual(shadowSystem.softnessSettings, reference.softnessSettings)
        XCTAssertNil(shadowSoftnessBeforeSystem)

        // With the system there, a setting goes to it directly.
        let later = ShadowSoftnessSettings(filterTaps: 16, xrFilterTaps: 16)
        setShadowSoftness(later)
        var laterReference = ShadowSystem()
        laterReference.setSoftness(later)
        XCTAssertEqual(getShadowSoftness(), laterReference.softnessSettings)
        XCTAssertNil(shadowSoftnessBeforeSystem)
    }

    func testWithoutAnySettingTheDefaultIsReported() {
        XCTAssertEqual(getShadowSoftness(), ShadowSystem().softnessSettings)
    }

    func testASystemCreatedWithNothingKeptKeepsItsDefault() {
        shadowSystem = ShadowSystem()
        applyShadowSoftnessSetBeforeSystem()
        XCTAssertEqual(shadowSystem.softnessSettings, ShadowSystem().softnessSettings)
    }
}
