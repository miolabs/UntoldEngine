//
//  SceneView.swift
//
//
//  Created by Harold Serrano on 2/19/25.
//

import MetalKit
import SwiftUI

#if os(macOS)
typealias ViewRepresentable = NSViewRepresentable
#else
typealias ViewRepresentable = UIViewRepresentable
#endif


public struct SceneView: ViewRepresentable {
    private var mtkView: MTKView
    private var renderer: UntoldRenderer?
    
    //TODO: Maybe we should thow an error on init instead of allowing nil renderer value
    public init( renderer: UntoldRenderer? = nil) {
        self.renderer = renderer ?? UntoldRenderer.create()
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
    
    public func onInit( block: @escaping () -> Void ) -> Self {
        block()
        return self
    }
}
