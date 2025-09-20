//
//  UntoldEngine+Editor.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 15/9/25.
//

import UntoldEngine
import simd

extension UntoldRenderer
{
    func handleSceneInput() {
        if gameMode == true {
            return
        }

        let input = (w: inputSystem.keyState.wPressed, a: inputSystem.keyState.aPressed, s: inputSystem.keyState.sPressed, d: inputSystem.keyState.dPressed, q: inputSystem.keyState.qPressed, e: inputSystem.keyState.ePressed)

        moveCameraWithInput(entityId: findSceneCamera(), input: input, speed: 1, deltaTime: 0.1)

        guard let editorController else {
            return
        }

        if activeEntity == .invalid {
            return
        }

        if inputSystem.keyState.shiftPressed || gizmoActive {
            guard let cameraComponent = scene.get(component: CameraComponent.self, for: findSceneCamera()) else {
                handleError(.noActiveCamera)
                return
            }

            guard let localTransformComponent = scene.get(component: LocalTransformComponent.self, for: activeEntity) else {
                handleError(.noLocalTransformComponent)
                return
            }

            switch (editorController.activeMode, editorController.activeAxis) {
            // Translate
            case (.translate, .x) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(1.0, 0.0, 0.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                let translation = simd_float3(1.0, 0.0, 0.0) * projectedAmount
                translateBy(entityId: activeEntity, position: translation)
                translateBy(entityId: parentEntityIdGizmo, position: translation)
                editorController.refreshInspector()

            case (.translate, .y) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(0.0, 1.0, 0.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                let translation = simd_float3(0.0, 1.0, 0.0) * projectedAmount

                translateBy(entityId: activeEntity, position: translation)
                translateBy(entityId: parentEntityIdGizmo, position: translation)
                editorController.refreshInspector()

            case (.translate, .z) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(0.0, 0.0, 1.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                let translation = simd_float3(0.0, 0.0, 1.0) * projectedAmount

                translateBy(entityId: activeEntity, position: translation)
                translateBy(entityId: parentEntityIdGizmo, position: translation)
                editorController.refreshInspector()

            // Orientation
            case (.rotate, .x) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(1.0, 0.0, 0.0)

                let angleDelta = computeRotationAngleFromGizmo(
                    axis: axisWorldDir, // simd_float3, e.g., (0,1,0)
                    gizmoWorldPosition: getLocalPosition(entityId: activeEntity), // simd_float3
                    lastMousePos: simd_float2(inputSystem.lastMouseX, inputSystem.lastMouseY), // simd_float2 in screen coords
                    currentMousePos: simd_float2(inputSystem.mouseX, inputSystem.mouseY), // simd_float2 in screen coords
                    viewMatrix: cameraComponent.viewSpace,
                    projectionMatrix: renderInfo.perspectiveSpace,
                    viewportSize: renderInfo.viewPort,
                    sensitivity: 100.0
                )

                var axisOfRotation = getAxisRotations(entityId: activeEntity)
                axisOfRotation.x -= angleDelta * 10

                applyAxisRotations(entityId: activeEntity, axis: axisOfRotation)
                editorController.refreshInspector()

            case (.rotate, .y) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(0.0, 1.0, 0.0)

                let angleDelta = computeRotationAngleFromGizmo(
                    axis: axisWorldDir,
                    gizmoWorldPosition: getLocalPosition(entityId: activeEntity),
                    lastMousePos: simd_float2(inputSystem.lastMouseX, inputSystem.lastMouseY),
                    currentMousePos: simd_float2(inputSystem.mouseX, inputSystem.mouseY),
                    viewMatrix: cameraComponent.viewSpace,
                    projectionMatrix: renderInfo.perspectiveSpace,
                    viewportSize: renderInfo.viewPort,
                    sensitivity: 100.0
                )

                var axisOfRotation = getAxisRotations(entityId: activeEntity)
                axisOfRotation.y += angleDelta * 10

                applyAxisRotations(entityId: activeEntity, axis: axisOfRotation)

                editorController.refreshInspector()

            case (.rotate, .z) where inputSystem.mouseActive:

                let axisWorldDir = simd_float3(0.0, 0.0, 1.0)

                let angleDelta = computeRotationAngleFromGizmo(
                    axis: axisWorldDir,
                    gizmoWorldPosition: getLocalPosition(entityId: activeEntity),
                    lastMousePos: simd_float2(inputSystem.lastMouseX, inputSystem.lastMouseY),
                    currentMousePos: simd_float2(inputSystem.mouseX, inputSystem.mouseY),
                    viewMatrix: cameraComponent.viewSpace,
                    projectionMatrix: renderInfo.perspectiveSpace,
                    viewportSize: renderInfo.viewPort,
                    sensitivity: 100.0
                )

                var axisOfRotation = getAxisRotations(entityId: activeEntity)
                axisOfRotation.z += angleDelta * 10

                applyAxisRotations(entityId: activeEntity, axis: axisOfRotation)
                editorController.refreshInspector()

            // scale
            case (.scale, .x) where inputSystem.mouseActive:
                let axisWorldDir = simd_float3(1.0, 0.0, 0.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                if hasComponent(entityId: activeEntity, componentType: LightComponent.self) {
                    handleLightScaleInput(projectedAmount: projectedAmount, axis: axisWorldDir)
                } else {
                    applyWorldSpaceScaleDelta(entityId: activeEntity, worldAxis: axisWorldDir, projectedAmount: projectedAmount)
                }
                editorController.refreshInspector()

            case (.scale, .y) where inputSystem.mouseActive:
                let axisWorldDir = simd_float3(0.0, 1.0, 0.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                if hasComponent(entityId: activeEntity, componentType: LightComponent.self) {
                    handleLightScaleInput(projectedAmount: projectedAmount, axis: axisWorldDir)
                } else {
                    applyWorldSpaceScaleDelta(entityId: activeEntity, worldAxis: axisWorldDir, projectedAmount: projectedAmount)
                }
                editorController.refreshInspector()

            case (.scale, .z) where inputSystem.mouseActive:
                let axisWorldDir = simd_float3(0.0, 0.0, 1.0)

                let projectedAmount = computeAxisTranslationGizmo(axisWorldDir: axisWorldDir, gizmoWorldPosition: getLocalPosition(entityId: activeEntity), mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY), viewMatrix: cameraComponent.viewSpace, projectionMatrix: renderInfo.perspectiveSpace, viewportSize: renderInfo.viewPort)

                if hasComponent(entityId: activeEntity, componentType: LightComponent.self) {
                    handleLightScaleInput(projectedAmount: projectedAmount, axis: axisWorldDir)
                } else {
                    applyWorldSpaceScaleDelta(entityId: activeEntity, worldAxis: axisWorldDir, projectedAmount: projectedAmount)
                }
                editorController.refreshInspector()

            // light direction
            case (.lightRotate, .none) where inputSystem.mouseActive:
                let lightDirEntity = findEntity(name: "directionHandle")

                // compute the view-aligned plane translation
                let cameraForward = -cameraComponent.zAxis // Assuming forward is -Z

                let absForward = simd_abs(cameraForward)

                var axis1 = simd_float3.zero
                var axis2 = simd_float3.zero

                // Determine the plane perpendicular to the dominant axis
                if absForward.x > absForward.y, absForward.x > absForward.z {
                    // Looking down X → move in YZ plane
                    axis1 = simd_float3(0, 1, 0) // Y
                    axis2 = simd_float3(0, 0, 1) // Z
                } else if absForward.y > absForward.x, absForward.y > absForward.z {
                    // Looking down Y → move in XZ plane
                    axis1 = simd_float3(1, 0, 0) // X
                    axis2 = simd_float3(0, 0, 1) // Z
                } else {
                    // Looking down Z → move in XY plane
                    axis1 = simd_float3(1, 0, 0) // X
                    axis2 = simd_float3(0, 1, 0) // Y
                }

                let projected1 = computeAxisTranslationGizmo(
                    axisWorldDir: axis1,
                    gizmoWorldPosition: getLocalPosition(entityId: activeEntity),
                    mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY),
                    viewMatrix: cameraComponent.viewSpace,
                    projectionMatrix: renderInfo.perspectiveSpace,
                    viewportSize: renderInfo.viewPort
                )

                let projected2 = computeAxisTranslationGizmo(
                    axisWorldDir: axis2,
                    gizmoWorldPosition: getLocalPosition(entityId: activeEntity),
                    mouseDelta: simd_float2(inputSystem.mouseDeltaX, inputSystem.mouseDeltaY),
                    viewMatrix: cameraComponent.viewSpace,
                    projectionMatrix: renderInfo.perspectiveSpace,
                    viewportSize: renderInfo.viewPort
                )

                let translation = axis1 * projected1 + axis2 * projected2
                translateBy(entityId: lightDirEntity!, position: translation)

                let lightPos = getPosition(entityId: parentEntityIdGizmo)
                let gizmoPos = getPosition(entityId: lightDirEntity!)

                // z axis
                let zAxis = simd_normalize(gizmoPos - lightPos) * -1.0

                let worldUp = simd_float3(0.0, 1.0, 0.0)
                let xAxis = simd_normalize(simd_cross(worldUp, zAxis))

                // if zAxis is too aligned with worldUp, swicth to a different up vector
                var finalXAxis = xAxis
                if simd_length(xAxis) < 0.001 {
                    finalXAxis = simd_normalize(simd_cross(simd_float3(1.0, 0.0, 0.0), zAxis))
                }

                // Recompute yAxis to ensure orthogonality
                let yAxis = simd_normalize(simd_cross(zAxis, finalXAxis))

                // construct rotation matrix
                let rotationMatrix = simd_float3x3(columns: (finalXAxis, yAxis, zAxis))

                let q = transformMatrix3nToQuaternion(m: rotationMatrix)

                localTransformComponent.rotation = q

            // default
            default:
                break
            }
        }
    }
}
