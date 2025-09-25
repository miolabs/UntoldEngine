//
//  UntoldRendererConfig.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

import MetalKit

public struct UntoldRendererConfig
{
    var metalView: MTKView?
    var initRenderPipelineBlocks: [ (RenderPipelineType, RenderPipelineInitBlock) ]
    
//    var updateRenderingSystemCallback: UpdateRenderingSystemCallback
//    var initRenderPipelinesCallback: InitRenderPipelinesCallback
    
    public init(metalView: MTKView? = nil, initPipelineBlocks: [(RenderPipelineType, RenderPipelineInitBlock)]) {
        self.metalView = metalView
        self.initRenderPipelineBlocks = initPipelineBlocks
    }
}

extension UntoldRendererConfig {
    public static var `default`: UntoldRendererConfig {
        return UntoldRendererConfig(
            initPipelineBlocks: DefaultPipeLines()
        )
    }
}
