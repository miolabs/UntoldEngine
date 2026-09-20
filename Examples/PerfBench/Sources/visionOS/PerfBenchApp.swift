//
//  PerfBenchApp.swift
//  PerfBench (visionOS)
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CompositorServices
import Foundation
import simd
import SwiftUI
import UntoldEngine
import UntoldEngineXR

/// Keeps the XR runtime and its render thread alive for the life of the app.
@MainActor
final class XRHolder {
    static let shared = XRHolder()
    var xr: UntoldEngineXR?
    var renderThread: Thread?
    /// The layer configuration the compositor was given, recorded into the run summary.
    var layout = "dedicated"
    var foveation = false
}

/// Matches the engine's current expectations: dedicated per-eye textures, no foveation.
/// The runner records these values so baselines never mix configurations.
struct PerfBenchLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities _: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

@MainActor
final class BenchHost: ObservableObject {
    static let shared = BenchHost()

    let config: BenchConfig
    let runner: BenchRunner

    private init() {
        config = BenchConfig.fromEnvironment()
        var render = BenchRenderSettings(platform: "visionOS")
        render.layout = XRHolder.shared.layout
        render.foveation = XRHolder.shared.foveation
        render.immersion = config.immersion
        render.displayRefreshHz = 90.0
        render.xrFramePacing = XRFramePacer.shared.isEnabled
        runner = BenchRunner(config: config, render: render)
        // Scenes are built three metres in front of the user, slightly below eye level.
        runner.sceneOrigin = simd_float3(0.0, -0.8, -3.0)
        runner.drivesCamera = false
        runner.onFinished = { [config] _ in
            if config.exitWhenDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    exit(0)
                }
            }
        }
    }

    var immersionStyle: ImmersionStyle {
        config.immersion == "mixed" ? .mixed : .full
    }

    var isMixedImmersion: Bool {
        config.immersion == "mixed"
    }
}

@main
struct PerfBenchApp: App {
    @State private var immersionStyle: ImmersionStyle = BenchHost.shared.immersionStyle

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 420)

        ImmersiveSpace(id: "PerfBenchSpace") {
            CompositorLayer(configuration: PerfBenchLayerConfiguration()) { layerRenderer in
                Task { @MainActor in
                    startXR(layerRenderer: layerRenderer)
                }
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }

    @MainActor
    private func startXR(layerRenderer: LayerRenderer) {
        guard XRHolder.shared.xr == nil else { return }
        guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else {
            print("PERFBENCH_FAILED xr")
            return
        }
        XRHolder.shared.xr = xr
        let host = BenchHost.shared
        let runner = host.runner
        // The XR module's UntoldImmersionMode cannot be named here (the module and its class share
        // a name), so let the parameter type pick the enum.
        xr.setImmersionMode(xrImmersionMode: host.isMixedImmersion ? .mixed : .full)
        xr.setupCallbacks(
            gameUpdate: { deltaTime in
                // Runs on the XR render thread, inside the frame's update phase, which is where the
                // engine expects scene mutations from; the runner publishes its UI state to main.
                runner.update(deltaTime: deltaTime)
            },
            handleInput: {}
        )
        let thread = Thread {
            xr.start()
            xr.runLoop()
        }
        thread.name = "XR Render Thread"
        thread.qualityOfService = .userInteractive
        XRHolder.shared.renderThread = thread
        thread.start()
        if host.config.autoStart {
            // Give the compositor a few frames before the first scene is built.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                host.runner.start()
            }
        }
    }
}

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @ObservedObject private var runner = BenchHost.shared.runner
    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Untold PerfBench").font(.extraLargeTitle).fontWeight(.bold)
            Text(runner.statusText).font(.title3).monospaced()
            if !runner.report.isEmpty {
                ScrollView {
                    Text(runner.report).font(.caption).monospaced()
                }
                .frame(maxHeight: 200)
            }
            HStack {
                Button("Open Space") { open() }.disabled(opened)
                Button("Start") { runner.start() }.disabled(!opened || runner.phase != .idle)
            }
        }
        .padding(40)
        .task {
            if BenchHost.shared.config.autoStart {
                open()
            }
        }
    }

    private func open() {
        guard !opened else { return }
        opened = true
        Task {
            await openImmersiveSpace(id: "PerfBenchSpace")
        }
    }
}
