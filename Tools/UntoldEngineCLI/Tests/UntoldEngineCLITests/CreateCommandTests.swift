//
//  CreateCommandTests.swift
//  UntoldEngineCLI
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import UntoldEngine
@testable import UntoldEngineCLI
import XCTest

final class CreateCommandTests: XCTestCase {
    // MARK: - Deployment version options

    func testEveryDeploymentTargetTheEngineSupportsParses() throws {
        // The options follow the engine's `supportedCases`, so a version the engine adds is
        // accepted here without another list to update.
        for version in MacOSVersion.supportedCases {
            XCTAssertEqual(try CreateCommand.parseMacOSVersion(version.rawValue), version)
        }
        for version in IOSVersion.supportedCases {
            XCTAssertEqual(try CreateCommand.parseIOSVersion(version.rawValue), version)
        }
        for version in VisionOSVersion.supportedCases {
            XCTAssertEqual(try CreateCommand.parseVisionOSVersion(version.rawValue), version)
        }
    }

    func testAVersionParsesWithAndWithoutItsMinorPart() throws {
        // "14.0" as the engine stores it, "14" as the help documents it.
        XCTAssertEqual(try CreateCommand.parseMacOSVersion("14"), .v14)
        XCTAssertEqual(try CreateCommand.parseMacOSVersion("14.0"), .v14)
        XCTAssertEqual(try CreateCommand.parseMacOSVersion("15"), .v15)
        XCTAssertEqual(try CreateCommand.parseIOSVersion("17"), .v17)
        XCTAssertEqual(try CreateCommand.parseIOSVersion("18.0"), .v18)
        XCTAssertEqual(try CreateCommand.parseVisionOSVersion("2"), .v2)
        XCTAssertEqual(try CreateCommand.parseVisionOSVersion("26.0"), .v26)
    }

    func testDeploymentTargetsBelowTheEngineMinimumAreRejected() {
        // macOS 13, iOS 16 and visionOS 1 were accepted once; a project with them cannot compile
        // against the engine package, so they fail here with the versions that work.
        XCTAssertThrowsError(try CreateCommand.parseMacOSVersion("13")) { error in
            XCTAssertEqual((error as? CLIError)?.errorDescription, "Invalid macOS version: 13. Valid options: 14, 15")
        }
        XCTAssertThrowsError(try CreateCommand.parseMacOSVersion("13.0"))
        XCTAssertThrowsError(try CreateCommand.parseIOSVersion("16")) { error in
            XCTAssertEqual((error as? CLIError)?.errorDescription, "Invalid iOS version: 16. Valid options: 17, 18")
        }
        XCTAssertThrowsError(try CreateCommand.parseVisionOSVersion("1")) { error in
            XCTAssertEqual((error as? CLIError)?.errorDescription, "Invalid visionOS version: 1. Valid options: 2, 26")
        }
    }

    func testAnUnknownVersionIsRejectedInsteadOfFallingBackToADefault() {
        XCTAssertThrowsError(try CreateCommand.parseMacOSVersion("12"))
        XCTAssertThrowsError(try CreateCommand.parseMacOSVersion("sonoma"))
        XCTAssertThrowsError(try CreateCommand.parseMacOSVersion(""))
        XCTAssertThrowsError(try CreateCommand.parseIOSVersion("17.1"))
        XCTAssertThrowsError(try CreateCommand.parseVisionOSVersion("3"))
    }

    func testTheDefaultVersionsAreSupported() throws {
        // `untoldengine create MyGame` with no version option has to keep working.
        let command = try CreateCommand.parse(["MyGame"])
        XCTAssertNoThrow(try CreateCommand.parseMacOSVersion(command.macosVersion))
        XCTAssertNoThrow(try CreateCommand.parseIOSVersion(command.iosVersion))
        XCTAssertNoThrow(try CreateCommand.parseVisionOSVersion(command.visionosVersion))
    }

    func testHelpListsTheSupportedVersionsOnly() {
        let help = CreateCommand.helpMessage()
        XCTAssertTrue(help.contains("macOS deployment version (14, 15)"), help)
        XCTAssertTrue(help.contains("iOS deployment version (17, 18)"), help)
        XCTAssertTrue(help.contains("visionOS deployment version (2, 26)"), help)
    }
}
