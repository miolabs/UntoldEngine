//
//  RenderInitializer.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 15/9/25.
//

import UntoldEngine

public func initEditorRenderPipelines()
{
    initRenderPipelines()
    
    // Gizmo Pipeline
    if let gizmoPipe = createPipeline(
        vertexShader: "vertexGizmoShader",
        fragmentShader: "fragmentGizmoShader",
        vertexDescriptor: createGizmoVertexDescriptor(),
        colorFormats: [renderInfo.colorPixelFormat],
        depthFormat: renderInfo.depthPixelFormat,
        name: "Gizmo Pipeline"
    ) {
        gizmoPipeline = gizmoPipe
    }
    
    if let debugPipe = createPipeline(
        vertexShader: "vertexDebugShader",
        fragmentShader: "fragmentDebugShader",
        vertexDescriptor: createDebugVertexDescriptor(),
        colorFormats: [.bgra8Unorm_srgb],
        depthFormat: renderInfo.depthPixelFormat,
        depthCompareFunction: .less,
        depthEnabled: false,
        name: "Debug Pipeline"
    ) {
        debuggerPipeline = debugPipe
    }

}
