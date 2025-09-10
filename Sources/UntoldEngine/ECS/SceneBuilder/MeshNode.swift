//
//  ModelNode.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 6/9/25.
//

import Foundation
import SwiftUI
import simd

public struct MeshNode: Node
{
    public let entity: EntityID
    public var subNodes: [Node] = []

    public init (resource: String) {
        self.init(resource: resource) { }
    }
    
    public init (resource: String, @SceneBuilder content: @escaping () -> [any Node]) {
        let entity = createEntity()
        setEntityMesh(entityId: entity, filename: resource.filename, withExtension: resource.extensionName)
        registerTransformComponent(entityId: entity)
        registerSceneGraphComponent(entityId: entity)
        
        self.entity = entity
        
        subNodes = content()
        for n in subNodes {
            setParent(childId: n.entity, parentId: entity)
        }
    }
    
    public func materialData( roughness: Float = 0, metallic:Float = 0, emissive:(Float, Float, Float) = (0,0,0), baseColor:(Float, Float, Float, Float) = (0,0,0,0), baseColorResource:String? = nil) -> Self {
        
        updateMaterialColor(entityId: entity, color: colorFromSimd(simd_float4(baseColor.0, baseColor.1, baseColor.2, baseColor.3)))
        updateMaterialRoughness(entityId: entity, roughness: roughness)
        updateMaterialMetallic(entityId: entity, metallic: metallic)
        updateMaterialEmmisive(entityId: entity, emmissive: simd_float3(emissive.0, emissive.1, emissive.2))

        if let baseColorURL = baseColorResource != nil ? getResourceURL(forResource: baseColorResource!.filename, withExtension: baseColorResource!.extensionName) : nil {
            updateMaterialTexture(entityId: entity, textureType: .baseColor, path: baseColorURL)
        }

//        if let roughnessURL = materialData.roughnessURL {
//            updateMaterialTexture(entityId: entity, textureType: .roughness, path: roughnessURL)
//        }
//
//        if let metallicURL = materialData.metallicURL {
//            updateMaterialTexture(entityId: entity, textureType: .metallic, path: metallicURL)
//        }
//
//        if let normalURL = materialData.normalURL {
//            updateMaterialTexture(entityId: entity, textureType: .normal, path: normalURL)
//        }

        return self
    }
}
