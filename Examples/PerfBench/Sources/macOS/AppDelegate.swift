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

    /// The display the bench runs on: one whose maximum refresh rate is the requested one, else
    /// the fastest connected display. Not `NSScreen.main`, which is the screen with keyboard
    /// focus and so depends on where the terminal that launched the bench happens to be.
    private static func benchScreen(requestedHz: Int?) -> NSScreen? {
        let screens = NSScreen.screens
        if let requestedHz {
            if let match = screens.first(where: { $0.maximumFramesPerSecond == requestedHz }) {
                return match
            }
            let rates = screens.map { String($0.maximumFramesPerSecond) }.joined(separator: ", ")
            print("PERFBENCH_WARNING no connected display runs at \(requestedHz) Hz (connected: \(rates) Hz); using the fastest one")
        }
        return screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let config = BenchConfig.fromEnvironment()
        let screen = Self.benchScreen(requestedHz: config.refreshHz)
        var render = BenchRenderSettings(platform: "macOS")
        render.viewportWidth = Int(Constants.drawableSize.width)
        render.viewportHeight = Int(Constants.drawableSize.height)
        render.layout = "single"
        render.vsync = true
        render.displayRefreshHz = Double(screen?.maximumFramesPerSecond ?? 60)
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

        // The drawable keeps its fixed pixel size. The window shows it one drawable pixel per
        // device pixel, so the window server presents it without rescaling, and is scaled down
        // further only if the chosen display is smaller than that, so it never hangs over onto a
        // neighbouring display that refreshes at another rate.
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let backingScale = max(1.0, screen?.backingScaleFactor ?? 1.0)
        var contentSize = CGSize(
            width: Constants.drawableSize.width / backingScale,
            height: Constants.drawableSize.height / backingScale
        )
        if let screen {
            let visible = screen.visibleFrame
            let framed = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize), styleMask: styleMask)
            let chromeHeight = framed.height - contentSize.height
            let fit = min(1.0, visible.width / contentSize.width, (visible.height - chromeHeight) / contentSize.height)
            contentSize = CGSize(width: floor(contentSize.width * fit), height: floor(contentSize.height * fit))
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Untold PerfBench"
        // Windowed presentation hands drawables back at the display rate whatever the layer's
        // sync setting, so run at the display's maximum refresh and derive the budget from it.
        var viewOptions = UntoldViewOptions.default
        viewOptions.preferredFramesPerSecond = Int(render.displayRefreshHz)
        window.contentView = NSHostingView(rootView: BenchView(renderer: renderer, runner: runner, viewOptions: viewOptions))
        if let screen {
            // Centre the window on the chosen display; the display it sits on paces its frames.
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
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
