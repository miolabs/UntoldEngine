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
    public let entityID: EntityID
    public var subNodes: [Node] = []

    public init(entityID: EntityID? = nil) {
        self.entityID = entityID ?? createEntity()
    }
    
    public init (entityID: EntityID? = nil, resource: String) {
        self.init(entityID: entityID, resource: resource) { }
    }
    
    public init (entityID: EntityID? = nil, resource: String, @SceneBuilder content: @escaping () -> [any Node]) {
        self.init(entityID: entityID)
        
        setEntityMesh(entityId: self.entityID, filename: resource.filename, withExtension: resource.extensionName)
        registerTransformComponent(entityId: self.entityID)
        registerSceneGraphComponent(entityId: self.entityID)
        
        subNodes = content()
        for n in subNodes {
            setParent(childId: n.entityID, parentId: self.entityID)
        }
    }
    
    public func materialData( roughness: Float = 0, metallic:Float = 0, emissive:(Float, Float, Float) = (0,0,0), baseColor:(Float, Float, Float, Float) = (0,0,0,0), baseColorResource:String? = nil) -> Self {
        
        updateMaterialColor(entityId: entityID, color: colorFromSimd(simd_float4(baseColor.0, baseColor.1, baseColor.2, baseColor.3)))
        updateMaterialRoughness(entityId: entityID, roughness: roughness)
        updateMaterialMetallic(entityId: entityID, metallic: metallic)
        updateMaterialEmmisive(entityId: entityID, emmissive: simd_float3(emissive.0, emissive.1, emissive.2))

        if let baseColorURL = baseColorResource != nil ? getResourceURL(forResource: baseColorResource!.filename, withExtension: baseColorResource!.extensionName) : nil {
            updateMaterialTexture(entityId: entityID, textureType: .baseColor, path: baseColorURL)
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
