//
//  UntoldView.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 6/9/25.
//

import SwiftUI
import MetalKit

public struct UntoldView: View {
    @State private var metalView: MTKView
    private var renderer: UntoldRenderer?
    private var content:[Node] = []
    
    public init(metalView: MTKView = MTKView(), config:UntoldViewConfig = .editor, @SceneBuilder _ content: @escaping () -> [any Node]) {
        self.metalView = metalView
        guard let renderer = UntoldRenderer.create(metalView: metalView) else { return }
        renderer.initResources()
        self.renderer = renderer
        config.applyConfiguration()

        self.content = content()
    }
    
    public var body: some View {
        MetalViewRepresentable(metalView: $metalView)
    }
}

#if os(macOS)
typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalViewRepresentable: ViewRepresentable {
  @Binding var metalView: MTKView

#if os(macOS)
  func makeNSView(context: Context) -> some NSView {
    metalView
  }
  func updateNSView(_ uiView: NSViewType, context: Context) {
    updateMetalView()
  }
#elseif os(iOS)
  func makeUIView(context: Context) -> MTKView {
    metalView
  }

  func updateUIView(_ uiView: MTKView, context: Context) {
    updateMetalView()
  }
#endif

  func updateMetalView() {
      
  }
}
