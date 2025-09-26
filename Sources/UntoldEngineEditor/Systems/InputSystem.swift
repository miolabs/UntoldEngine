//
//  InputSystem.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 14/9/25.
//

import AppKit
import Cocoa
import Foundation
import GameController
import simd
import UntoldEngine

extension InputSystem
{
    public func registerMouseClickEvent( inView view: AppView) {        
        // Click gesture
        let rightClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        view.addGestureRecognizer(rightClickGesture)
        rightClickGesture.buttonMask = 0x2 // 0x1 = left, 0x2 = right, 0x4 = middle
    }
    
    @objc func handleRightClick(_ gestureRecognizer: NSClickGestureRecognizer) {
        mouseRaycast(gestureRecognizer: gestureRecognizer, in: gestureRecognizer.view!)
    }
    
    public func mouseRaycast(gestureRecognizer: NSClickGestureRecognizer, in view: NSView) {
        let currentLocation = gestureRecognizer.location(in: view)
        let (entityId, hit) = getRaycastedEntity(currentLocation: currentLocation, view: view)

        if HitGizmoToolAxis(entityId: entityId) {
            return
        }

        gizmoActive = false
        RemoveGizmo()
        editorController?.activeMode = .none
        editorController?.activeAxis = .none
        activeHitGizmoEntity = .invalid

        if hit {
            activeEntity = entityId

            (delegate as? SelectionDelegate)?.didSelectEntity(activeEntity)
            (delegate as? SelectionDelegate)?.resetActiveAxis()

        } else {
            activeEntity = .invalid
            RemoveGizmo()
        }
    }
    
    func getRaycastedEntity(currentLocation: NSPoint, view: NSView) -> (entityId: EntityID, hit: Bool) {
        var hitEntityId: EntityID = .invalid
        var hitEntity = false

        guard let cameraComponent = scene.get(component: CameraComponent.self, for: findSceneCamera()) else {
            handleError(.noActiveCamera)
            return (hitEntityId, hitEntity)
        }

        let currentCGPoint = simd_float2(Float(currentLocation.x), Float(currentLocation.y))

        let rayDirection: simd_float3 = rayDirectionInWorldSpace(uMouseLocation: currentCGPoint, uViewPortDim: simd_float2(Float(view.bounds.width), Float(view.bounds.height)), uPerspectiveSpace: renderInfo.perspectiveSpace, uViewSpace: cameraComponent.viewSpace)

        if getAllGameEntitiesWithMeshes().count == 0 {
            return (hitEntityId, hitEntity)
        }

        if let rtxCommandBuffer = renderInfo.commandQueue.makeCommandBuffer() {
            executeRayVsModelHit(rtxCommandBuffer, cameraComponent.localPosition, rayDirection)

            rtxCommandBuffer.addCompletedHandler { commandBuffer in
                if let error = commandBuffer.error {
                    // Handle error if any
                    print("Command buffer completed with error: \(error)")
                } else {
                    if let data = bufferResources.rayModelInstanceBuffer?.contents().assumingMemoryBound(to: Int32.self) {
                        let value = data.pointee

                        if value != -1 {
                            hitEntityId = accelStructResources.entityIDIndex[Int(value)]
                            hitEntity = true
                        }
                    }
                }

                cleanUpAccelStructures()
            }

            rtxCommandBuffer.commit()
            rtxCommandBuffer.waitUntilCompleted()
        }

        if hitEntity {
            return (hitEntityId, hitEntity)
        }

        return (hitEntityId, hitEntity)
    }
}

