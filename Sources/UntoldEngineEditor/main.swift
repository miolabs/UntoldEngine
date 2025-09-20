//
//  main.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 14/9/25.
//

import AppKit
import SwiftUI
import MetalKit
import UntoldEngine

// AppDelegate: Boiler plate code -- Handles everything – Renderer, Metal setup, and GameScene initialization
class AppDelegate: NSObject, NSApplicationDelegate, UntoldRendererDelegate {
        
    var window: NSWindow!
    var renderer: UntoldRenderer!

    func applicationDidFinishLaunching(_: Notification) {
        print("Launching Untold Engine Editor v0.2")

        // Step 1. Create and configure the window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Untold Engine Editor v0.2"
        window.center()

        // Step 2. Initialize the renderer and connect metal content
        guard let renderer = UntoldRenderer.create( updateRenderingSystemCallback: updateEditorRenderingSystem ) else {
            print("Failed to initialize the renderer.")
            return
        }
        
        renderer.delegate = self
        window.contentView = renderer.metalView

        self.renderer = renderer

        renderer.initResources()

        // Step 3. Create the game scene and connect callbacks
//        gameScene = GameScene()
//        renderer.setupCallbacks(
//            gameUpdate: { [weak self] deltaTime in self?.gameScene.update(deltaTime: deltaTime) },
//            handleInput: { [weak self] in self?.gameScene.handleInput() }
//        )

        if enableEditor {
            if #available(macOS 13.0, *) {
                let hostingView = NSHostingView(rootView: EditorView(mtkView: renderer.metalView))
                window.contentView = hostingView
            } else {
                // Fallback on earlier versions
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
    
    func willDraw(in view: MTKView) {
        if hotReload {
            // updateRayKernelPipeline()
            updateShadersAndPipeline()

            hotReload = false
        }
    }
    
    func didDraw(in view: MTKView) { }

    func resourcesDidLoad() {
        loadLightDebugMeshes()
    }
}

// Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

app.run()
