//
//  MetalView.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 15/9/25.
//

import SwiftUI
import MetalKit
import UntoldEngine

public struct MetalView: View {
    @State private var metalView: MTKView
    @State var playerAngle: Float = 0
    
    private var renderer: UntoldRenderer?
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var playerEntityID: EntityID = createEntity()
    
    public init() {
        self.renderer = UntoldRenderer.create()
        self.metalView = self.renderer?.metalView ?? MTKView()
        
        renderer?.initResources()
    }
    
    public var body: some View {
        MetalViewRepresentable(metalView: $metalView)
            .onReceive(timer) { _ in
                playerAngle += 0.1
                rotateBy(entityId: playerEntityID, angle: playerAngle, axis: simd_float3( 0, 0, 1))
        }
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
