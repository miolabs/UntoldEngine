//
//  PerfBenchApp.swift
//  PerfBench (iOS)
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import MetalKit
import SwiftUI
import UntoldEngine

@main
struct PerfBenchApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            BenchRootView()
        }
    }
}

@MainActor
private final class BenchHost: ObservableObject {
    let renderer: UntoldRenderer?
    let runner: BenchRunner
    let config: BenchConfig

    init() {
        config = BenchConfig.fromEnvironment()
        var render = BenchRenderSettings(platform: "iOS")
        render.layout = "single"
        render.displayRefreshHz = Double(UIScreen.main.maximumFramesPerSecond)
        runner = BenchRunner(config: config, render: render)

        let view = MTKView()
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        if let device = MTLCreateSystemDefaultDevice(), let created = UntoldRenderer.createiOS(device: device, view: view) {
            renderer = created
            let scale = UIScreen.main.nativeScale
            let bounds = UIScreen.main.nativeBounds
            runner.render.viewportWidth = Int(max(bounds.width, bounds.height) / scale * scale)
            runner.render.viewportHeight = Int(min(bounds.width, bounds.height) / scale * scale)
            created.setupCallbacks(
                gameUpdate: { [runner] deltaTime in
                    runner.update(deltaTime: deltaTime)
                },
                handleInput: {}
            )
        } else {
            renderer = nil
        }

        runner.onFinished = { [config] _ in
            if config.exitWhenDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    exit(0)
                }
            }
        }
    }
}

private struct BenchRootView: View {
    @StateObject private var host = BenchHost()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let renderer = host.renderer {
                SceneView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Text("Metal is not available").padding()
            }
            BenchStatusOverlay(runner: host.runner)
        }
        .onAppear {
            if host.config.autoStart {
                host.runner.start()
            }
        }
    }
}

private struct BenchStatusOverlay: View {
    @ObservedObject var runner: BenchRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PerfBench").font(.headline)
            Text(runner.statusText).font(.caption).monospaced()
            if runner.phase == .idle {
                Button("Start") { runner.start() }
            }
            if !runner.report.isEmpty {
                Text(runner.report).font(.caption2).monospaced()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(16)
    }
}
