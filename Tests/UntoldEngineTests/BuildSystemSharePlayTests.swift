//
//  BuildSystemSharePlayTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import UntoldEngine
import XCTest

#if os(macOS)

    /// `untoldengine create --shareplay`: the UntoldSharePlay package and product, the
    /// group-session entitlement, the activity file, and the session wired into the
    /// visionOS app template; nothing on the other platforms.
    @MainActor
    final class BuildSystemSharePlayTests: XCTestCase {
        private var tempDirectory: URL!

        override func setUp() async throws {
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuildSystemSharePlayTests_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        private func settings(
            _ target: BuildTarget = .visionOS(deployment: .v26),
            sharePlay: Bool = false,
            sharePlayPackage: EnginePackageReference? = nil
        ) -> BuildSettings {
            BuildSettings(
                projectName: "MyGame",
                bundleIdentifier: "com.test.mygame",
                outputPath: tempDirectory,
                target: target,
                includesSharePlay: sharePlay,
                sharePlayPackage: sharePlayPackage
            )
        }

        /// For `BuildSystem.build`, which takes its settings off the main actor: built from
        /// Sendable values only, so the value is not tied to the test's actor.
        private nonisolated static func buildSettings(outputPath: URL, _ target: BuildTarget, sharePlay: Bool) -> BuildSettings {
            BuildSettings(
                projectName: "MyGame",
                bundleIdentifier: "com.test.mygame",
                outputPath: outputPath,
                target: target,
                includesSharePlay: sharePlay
            )
        }

        private let multi = BuildTarget.multi(macOS: .v15, iOS: .v17, visionOS: .v26)

        private func occurrences(of needle: String, in text: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }

        // MARK: - Spec generation

        func testDefaultSettingsHaveNoSharePlay() throws {
            for target in [BuildTarget.macOS(deployment: .v15), .iOS(deployment: .v17), .visionOS(deployment: .v26), multi] {
                let yaml = try XcodeGenProjectSpec.generateYAML(settings: settings(target))
                XCTAssertFalse(yaml.contains("UntoldSharePlay"), "SharePlay is opt-in")
                XCTAssertFalse(yaml.contains("group-session"))
                XCTAssertFalse(yaml.contains("entitlements:"))
            }
        }

        func testVisionOSSpecLinksThePluginAndAddsTheEntitlement() throws {
            let yaml = try XcodeGenProjectSpec.generateYAML(settings: settings(sharePlay: true))

            XCTAssertTrue(yaml.contains("""
              UntoldSharePlay:
                url: https://github.com/miolabs/UntoldSharePlay.git
                branch: develop
            """), "the plugin is a second package next to the engine")
            XCTAssertEqual(occurrences(of: "product: UntoldSharePlay", in: yaml), 1)
            XCTAssertTrue(yaml.contains("""
                  - package: UntoldEngine
                    product: UntoldEngineAR
                  - package: UntoldSharePlay
                    product: UntoldSharePlay
                entitlements:
                  path: Sources/MyGame/MyGame.entitlements
                  properties:
                    com.apple.developer.group-session: true
                settings:
            """), "one more dependency, then the entitlement XcodeGen writes for us")
        }

        func testSharePlayPackageReferenceIsWrittenIntoTheSpec() throws {
            let pinned = try XcodeGenProjectSpec.generateYAML(settings: settings(
                sharePlay: true,
                sharePlayPackage: .init(url: "https://github.com/untoldengine/UntoldSharePlay.git", requirement: .exactVersion("0.2.0"))
            ))
            XCTAssertTrue(pinned.contains("url: https://github.com/untoldengine/UntoldSharePlay.git"))
            XCTAssertTrue(pinned.contains("exactVersion: 0.2.0"))
            XCTAssertFalse(pinned.contains("miolabs/UntoldSharePlay"))
        }

        func testMultiPlatformSpecTouchesOnlyTheVisionOSTarget() throws {
            let yaml = try XcodeGenProjectSpec.generateYAML(settings: settings(multi, sharePlay: true))

            XCTAssertEqual(occurrences(of: "product: UntoldSharePlay", in: yaml), 1)
            XCTAssertEqual(occurrences(of: "com.apple.developer.group-session: true", in: yaml), 1)
            XCTAssertTrue(yaml.contains("path: MyGame visionOS/MyGame.entitlements"))
            XCTAssertTrue(yaml.contains("""
                  - package: UntoldEngine
                    product: UntoldEngineAR
                  - package: UntoldSharePlay
                    product: UntoldSharePlay
                entitlements:
                  path: MyGame visionOS/MyGame.entitlements
            """), "the visionOS target of the multi-platform document, indented like its neighbours")
        }

        func testMacOSAndIOSSpecsIgnoreTheFlag() throws {
            for target in [BuildTarget.macOS(deployment: .v15), .iOS(deployment: .v17)] {
                let yaml = try XcodeGenProjectSpec.generateYAML(settings: settings(target, sharePlay: true))
                XCTAssertFalse(yaml.contains("UntoldSharePlay"), "\(target.platformName): the plugin is visionOS-only")
            }
        }

        // MARK: - Settings validation

        func testBuildRefusesSharePlayWithoutVisionOS26() async {
            for target in [BuildTarget.macOS(deployment: .v15), .iOS(deployment: .v17), .visionOS(deployment: .v2), .multi(macOS: .v15, iOS: .v17, visionOS: .v2)] {
                do {
                    _ = try await BuildSystem.shared.build(settings: Self.buildSettings(outputPath: tempDirectory, target, sharePlay: true))
                    XCTFail("\(target.platformName) accepted SharePlay")
                } catch let BuildError.invalidSettings(message) {
                    XCTAssertTrue(message.contains("visionOS 26"), "\(target.platformName): \(message)")
                } catch {
                    XCTFail("\(target.platformName): \(error)")
                }
            }
            XCTAssertTrue(VisionOSVersion.v26.supportsSharePlay)
            XCTAssertFalse(VisionOSVersion.v2.supportsSharePlay)
        }

        // MARK: - Templates

        func testVisionOSAppTemplateGainsTheSessionOnlyWhenAsked() throws {
            let template = try XCTUnwrap(BuildTemplates.getTemplateFiles(for: .visionOS(deployment: .v26))["Sources/{{PROJECT_NAME}}/{{PROJECT_NAME}}App.swift"])

            let with = BuildTemplates.expandingCodeComponentPlaceholders(in: template, settings: settings(sharePlay: true))
            XCTAssertTrue(with.contains("import UntoldEngineXR\nimport UntoldSharePlay\n"))
            XCTAssertTrue(with.contains("let session = SharePlaySession({{PROJECT_NAME}}Activity())"))
            XCTAssertTrue(with.contains("let space = ImmersiveSpaceCoordinator(id: \"ImmersiveSpace\")"))
            XCTAssertTrue(with.contains("session.drive(space)"))
            XCTAssertTrue(with.contains("SharePlayModel.shared.space.spaceDidStart(rendering: true)"))
            XCTAssertTrue(with.contains("SharePlayModel.shared.space.spaceDidStart(rendering: false)"))
            XCTAssertTrue(with.contains("shutdownUntoldEngineXR(xr) {"))
            XCTAssertTrue(with.contains("SharePlayModel.shared.space.spaceDidTearDown()"))
            XCTAssertTrue(with.contains(".sharePlayFrame(SharePlayModel.shared.session)"))
            XCTAssertTrue(with.contains("SharePlayStatusView(SharePlayModel.shared.session)"))
            XCTAssertTrue(with.contains("SharePlayModel.shared.space.open(reason: \"button\")"), "the button goes through the coordinator")
            XCTAssertFalse(with.contains("await openImmersiveSpace(id: \"ImmersiveSpace\")"), "not around the coordinator")
            XCTAssertTrue(with.contains("space.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)"))
            XCTAssertTrue(with.contains("session.startObserving()"))
            XCTAssertTrue(with.contains("@Environment(\\.dismissImmersiveSpace) private var dismissImmersiveSpace"))
            XCTAssertFalse(with.contains("{{SHAREPLAY_"))

            let without = BuildTemplates.expandingCodeComponentPlaceholders(in: template, settings: settings())
            XCTAssertFalse(without.contains("SharePlay"))
            XCTAssertTrue(without.contains("await openImmersiveSpace(id: \"ImmersiveSpace\")"), "the plain button stays")
            XCTAssertFalse(without.contains("{{SHAREPLAY_"))
            XCTAssertTrue(without.contains("import UntoldEngineXR\n\n"), "the placeholder line is gone, not left blank")
        }

        func testGameSceneAndReadmeMentionSharePlayOnlyWhenAsked() throws {
            let files = BuildTemplates.getTemplateFiles(for: .visionOS(deployment: .v26))
            let scene = try XCTUnwrap(files["Sources/{{PROJECT_NAME}}/GameScene.swift"])
            XCTAssertTrue(BuildTemplates.expandingCodeComponentPlaceholders(in: scene, settings: settings(sharePlay: true)).contains("stateChannel("))
            XCTAssertFalse(BuildTemplates.expandingCodeComponentPlaceholders(in: scene, settings: settings()).contains("SharePlay"))

            let readme = try XCTUnwrap(files["README.md"])
            XCTAssertTrue(BuildTemplates.expandingCodeComponentPlaceholders(in: readme, settings: settings(sharePlay: true)).contains("SharePlay"))
            XCTAssertFalse(BuildTemplates.expandingCodeComponentPlaceholders(in: readme, settings: settings()).contains("SharePlay"))
        }

        func testActivityTemplateDeclaresTheGamesActivity() {
            let activity = BuildTemplates.sharePlayActivitySwift
            XCTAssertTrue(activity.contains("struct {{PROJECT_NAME}}Activity: GroupActivity"))
            XCTAssertTrue(activity.contains("static let activityIdentifier = \"{{BUNDLE_IDENTIFIER}}.session\""))
            XCTAssertEqual(BuildTemplates.sharePlayActivityPath(for: .visionOS(deployment: .v26)), "Sources/{{PROJECT_NAME}}/{{PROJECT_NAME}}Activity.swift")
            XCTAssertEqual(BuildTemplates.sharePlayActivityPath(for: multi), "{{PROJECT_NAME}} visionOS/{{PROJECT_NAME}}Activity.swift")
        }

        // MARK: - A generated project

        func testGeneratedVisionOSProjectHasTheActivityAndTheIdentifier() async throws {
            // The build runs `xcodegen generate` at the end; CI's runner has no xcodegen.
            try XCTSkipIf(BuildSystem.xcodeGenPath() == nil, "xcodegen is not installed")
            let result = try await BuildSystem.shared.build(settings: Self.buildSettings(outputPath: tempDirectory, .visionOS(deployment: .v26), sharePlay: true))
            let projectDir = result.xcodeProjectPath.deletingLastPathComponent()
            let activity = projectDir.appendingPathComponent("Sources/MyGame/MyGameActivity.swift")
            let source = try String(contentsOf: activity, encoding: .utf8)
            XCTAssertTrue(source.contains("struct MyGameActivity: GroupActivity"))
            XCTAssertTrue(source.contains("activityIdentifier = \"com.test.mygame.session\""))
            XCTAssertFalse(source.contains("{{"))

            let app = try String(contentsOf: projectDir.appendingPathComponent("Sources/MyGame/MyGameApp.swift"), encoding: .utf8)
            XCTAssertTrue(app.contains("SharePlaySession(MyGameActivity())"))
            XCTAssertFalse(app.contains("{{"))

            let spec = try String(contentsOf: projectDir.appendingPathComponent("project.yml"), encoding: .utf8)
            XCTAssertTrue(spec.contains("product: UntoldSharePlay"))
            XCTAssertTrue(spec.contains("com.apple.developer.group-session: true"))

            let plain = try await BuildSystem.shared.build(settings: Self.buildSettings(outputPath: tempDirectory, .visionOS(deployment: .v26), sharePlay: false))
            let plainDir = plain.xcodeProjectPath.deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: plainDir.appendingPathComponent("Sources/MyGame/MyGameActivity.swift").path))
        }
    }

#endif
