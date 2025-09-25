//
//  Camera.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 15/9/25.
//

import Foundation
import UntoldEngine

public func findSceneCamera() -> EntityID {
    for entityId in scene.getAllEntities() {
        if hasComponent(entityId: entityId, componentType: CameraComponent.self), hasComponent(entityId: entityId, componentType: SceneCameraComponent.self) {
            return entityId
        }
    }

    // if scene camera was not found, then create one

    let sceneCamera = createEntity()
    createSceneCamera(entityId: sceneCamera)
    return sceneCamera
}
