//
//  SceneView.swift
//
//
//  Created by Harold Serrano on 2/19/25.
//

import MetalKit
import SwiftUI

public protocol SceneViewRenderProtocol : NSObjectProtocol
{
    func resourcesDidLoad() -> Void
}


#if os(macOS)
typealias ViewRepresentable = NSViewRepresentable
#else
typealias ViewRepresentable = UIViewRepresentable
#endif


public struct SceneView: ViewRepresentable {
    private var mtkView: MTKView
    private var renderer: UntoldRenderer?
    
    public init() {
        self.renderer = UntoldRenderer.create()
        self.mtkView = self.renderer!.metalView
        self.renderer?.initResources()
    }
    
#if os(macOS)
    public func makeNSView(context _: Context) -> MTKView {
        mtkView
    }

    public func updateNSView(_: MTKView, context _: Context) {}
#else
    public func makeUIView(context _: Context) -> MTKView {
        mtkView
    }

    public func updateUIView(_: MTKView, context _: Context) {}
#endif
    
    public func customSetup( block: @escaping () -> Void ) {
        block()
    }
}
