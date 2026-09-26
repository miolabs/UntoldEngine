//
//  AppDelegate.swift
//  PerfBench (macOS)
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import MetalKit
import simd
import SwiftUI
import UntoldEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        /// Fixed drawable size so runs on different displays compare; contents scale is pinned to 1.
        static let drawableSize = CGSize(width: 1920, height: 1080)
    }

    private var window: NSWindow!
    private var renderer: UntoldRenderer!
    private var runner: BenchRunner!

    func applicationDidFinishLaunching(_: Notification) {
        let config = BenchConfig.fromEnvironment()
        var render = BenchRenderSettings(platform: "macOS")
        render.viewportWidth = Int(Constants.drawableSize.width)
        render.viewportHeight = Int(Constants.drawableSize.height)
        render.layout = "single"
        render.vsync = true
        render.displayRefreshHz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        runner = BenchRunner(config: config, render: render)

        guard let renderer = UntoldRenderer.create() else {
            print("PERFBENCH_FAILED renderer")
            NSApp.terminate(nil)
            return
        }
        self.renderer = renderer
        let view = renderer.metalView
        // Fixed drawable size, the same recipe the engine's render tests use: no auto-resizing,
        // an explicit drawable size and viewport, and one resize report so the engine rebuilds
        // its viewport-sized resources on the first frame.
        view.autoResizeDrawable = false
        view.frame = NSRect(origin: .zero, size: Constants.drawableSize)
        renderer.mtkView(view, drawableSizeWillChange: Constants.drawableSize)
        view.drawableSize = Constants.drawableSize
        (view.layer as? CAMetalLayer)?.contentsScale = 1.0
        renderInfo.viewPort = simd_float2(Float(Constants.drawableSize.width), Float(Constants.drawableSize.height))

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Constants.drawableSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untold PerfBench"
        // Windowed presentation hands drawables back at the display rate whatever the layer's
        // sync setting, so run at the display's maximum refresh and derive the budget from it.
        var viewOptions = UntoldViewOptions.default
        viewOptions.preferredFramesPerSecond = Int(render.displayRefreshHz)
        window.contentView = NSHostingView(rootView: BenchView(renderer: renderer, runner: runner, viewOptions: viewOptions))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        renderer.setupCallbacks(
            gameUpdate: { [weak self] deltaTime in
                self?.runner.update(deltaTime: deltaTime)
            },
            handleInput: {}
        )

        runner.onFinished = { _ in
            if config.exitWhenDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }

        if config.autoStart {
            runner.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}

private struct BenchView: View {
    let renderer: UntoldRenderer
    @ObservedObject var runner: BenchRunner
    let viewOptions: UntoldViewOptions

    var body: some View {
        ZStack(alignment: .topLeading) {
            SceneView(renderer: renderer, options: viewOptions)
            VStack(alignment: .leading, spacing: 6) {
                Text("PerfBench").font(.headline)
                Text(runner.statusText).font(.caption).monospaced()
                if !runner.isRunning, runner.phase == .idle {
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
}
