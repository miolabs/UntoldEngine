//
//  LightingSystem.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 14/9/25.
//

import Foundation
import UntoldEngine
import simd


func handleLightScaleInput(projectedAmount: Float, axis: simd_float3) {
    if let pointLightComponent = scene.get(component: PointLightComponent.self, for: activeEntity) {
        pointLightComponent.radius += projectedAmount
    }

    if let spotLightComponent = scene.get(component: SpotLightComponent.self, for: activeEntity) {
        spotLightComponent.coneAngle += projectedAmount * 10.0
    }

    if scene.get(component: AreaLightComponent.self, for: activeEntity) != nil {
        let scale: simd_float3 = getScale(entityId: activeEntity)
        let newScale: simd_float3 = axis * projectedAmount + scale

        scaleTo(entityId: activeEntity, scale: newScale)
    }
}

func loadLightDebugMeshes() {
    spotLightDebugMesh = loadRawMesh(name: "spot_light_debug_mesh", filename: "spot_light_debug_mesh", withExtension: "usdc")

    pointLightDebugMesh = loadRawMesh(name: "point_light_debug_mesh", filename: "point_light_debug_mesh", withExtension: "usdc")

    areaLightDebugMesh = loadRawMesh(name: "area_light_debug_mesh", filename: "area_light_debug_mesh", withExtension: "usdc")

    dirLightDebugMesh = loadRawMesh(name: "dir_light_debug_mesh", filename: "dir_light_debug_mesh", withExtension: "usdc")
}
