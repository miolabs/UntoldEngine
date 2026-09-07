//
//  GaussianTwinSystem.swift
//  UntoldEngine
//
//  Swaps a mesh for its captured Gaussian-splat twin up close (proposal §4.5): loads the
//  payload onto the mesh entity, cross-fades the two, and hands the mesh's depth to a
//  shrunk occluder shell while the splat is shown. Shadows, physics and picking keep using
//  the mesh throughout — nothing here touches RenderComponent.isVisible.
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// One tick of the swap's state machine, kept free of scene access so it can be tested on
/// its own. `wantsSwap` is the distance decision for the current state (see
/// `gaussianTwinWantsSwap`), `payloadResident` whether the splat is on the GPU.
struct GaussianTwinStep: Equatable {
    var state: GaussianTwinState
    var progress: Float
}

func gaussianTwinStep(
    state: GaussianTwinState,
    progress: Float,
    wantsSwap: Bool,
    payloadResident: Bool,
    loadFailed: Bool,
    deltaTime: Float,
    duration: Float
) -> GaussianTwinStep {
    let increment = max(0, deltaTime) / max(duration, 0.001)
    switch state {
    case .armed:
        guard wantsSwap, !loadFailed else { return GaussianTwinStep(state: .armed, progress: 0) }
        return GaussianTwinStep(state: payloadResident ? .crossFading : .loading, progress: 0)
    case .loading:
        if loadFailed {
            return GaussianTwinStep(state: .armed, progress: 0)
        }
        guard payloadResident else {
            return GaussianTwinStep(state: .loading, progress: 0)
        }
        return GaussianTwinStep(state: wantsSwap ? .crossFading : .armed, progress: 0)
    case .crossFading:
        guard wantsSwap else { return GaussianTwinStep(state: .reverting, progress: 1 - progress) }
        let next = progress + increment
        return next >= 1 ? GaussianTwinStep(state: .swapped, progress: 1) : GaussianTwinStep(state: .crossFading, progress: next)
    case .swapped:
        return wantsSwap ? GaussianTwinStep(state: .swapped, progress: 1) : GaussianTwinStep(state: .reverting, progress: 0)
    case .reverting:
        guard !wantsSwap else { return GaussianTwinStep(state: .crossFading, progress: 1 - progress) }
        let next = progress + increment
        return next >= 1 ? GaussianTwinStep(state: .armed, progress: 0) : GaussianTwinStep(state: .reverting, progress: next)
    }
}

/// Whether the camera is close enough for the splat to stand in for the mesh. Once the swap
/// is under way (loading, fading in or swapped) the threshold grows by the hysteresis so a
/// camera resting on it does not flip the object back and forth. A zero swap distance means
/// the splat is always preferred.
func gaussianTwinWantsSwap(distance: Float, options: GaussianTwinOptions, state: GaussianTwinState) -> Bool {
    guard options.swapDistanceMeters > 0 else { return true }
    switch state {
    case .armed, .reverting:
        return distance <= options.swapDistanceMeters
    case .loading, .crossFading, .swapped:
        return distance <= options.swapDistanceMeters + max(0, options.hysteresisMeters)
    }
}

/// The splat's opacity weight for a twin state and fade progress: hidden while the mesh
/// is shown, ramping through the cross-fades, full once swapped.
func gaussianTwinSplatOpacity(state: GaussianTwinState, progress: Float) -> Float {
    switch state {
    case .armed, .loading: return 0
    case .crossFading: return simd_clamp(progress, 0, 1)
    case .swapped: return 1
    case .reverting: return 1 - simd_clamp(progress, 0, 1)
    }
}

public final class GaussianTwinSystem: @unchecked Sendable {
    public static let shared = GaussianTwinSystem()

    /// Longest frame the fade integrates, so a hitch does not jump it to the end.
    private let maxDeltaTime: Float = 0.1

    private init() {}

    /// Splats can be drawn at all: the tile pipelines exist (the iOS simulator never creates
    /// them, and `gaussianExecution` draws nothing there). Without them a swap would hide the
    /// mesh's colour behind a depth-only shell with no splat to show, so twins stay armed.
    var splatRenderingAvailable: Bool {
        if let splatRenderingAvailableOverride {
            return splatRenderingAvailableOverride
        }
        #if targetEnvironment(simulator)
            return false
        #else
            return PipelineManager.shared.renderPipelinesByType[.gaussianTBDRDraw]?.success == true
        #endif
    }

    /// Tests set this to exercise the state machine with or without a renderer.
    var splatRenderingAvailableOverride: Bool?

    /// Advances every twin once per frame, before the batching tick and the render prep.
    public func update(deltaTime: Float) {
        let twinId = getComponentId(for: GaussianTwinComponent.self)
        let transformId = getComponentId(for: WorldTransformComponent.self)
        let entities = queryEntitiesWithComponentIds([twinId, transformId], in: scene)
        guard !entities.isEmpty, splatRenderingAvailable else { return }

        guard let camera = CameraSystem.shared.activeCamera,
              let cameraComponent = scene.get(component: CameraComponent.self, for: camera)
        else { return }
        let cameraPosition = SceneRootTransform.shared.effectiveCameraPosition(cameraComponent.localPosition)
        let clampedDeltaTime = min(max(deltaTime, 0), maxDeltaTime)

        for entityId in entities {
            guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { continue }
            let previousState = twin.state

            withWorldMutationGate {
                // Without a mesh there is nothing to swap from: an OCC stub whose geometry has
                // not streamed in yet stays armed, and a swap already under way keeps its
                // state (the splat then shows without an occluder until the mesh returns).
                let hasMesh = scene.get(component: RenderComponent.self, for: entityId)?.mesh.isEmpty == false
                let distance = entityDistanceToCamera(entityId: entityId, cameraPosition: cameraPosition)
                let wantsSwap = gaussianTwinWantsSwap(distance: distance, options: twin.options, state: twin.state)
                    && (hasMesh || twin.state != .armed)

                let step = gaussianTwinStep(
                    state: twin.state,
                    progress: twin.fadeProgress,
                    wantsSwap: wantsSwap,
                    payloadResident: twin.payloadResident,
                    loadFailed: twin.loadFailed,
                    deltaTime: clampedDeltaTime,
                    duration: twin.options.crossFadeDuration
                )
                twin.state = step.state
                twin.fadeProgress = step.progress

                if twin.state == .loading, previousState != .loading {
                    startPayloadLoad(entityId: entityId, twin: twin)
                }
                if twin.payloadResident, let gaussian = scene.get(component: GaussianComponent.self, for: entityId) {
                    gaussian.opacityScale = gaussianTwinSplatOpacity(state: twin.state, progress: twin.fadeProgress)
                }
            }

            // Leaving or returning to `.armed` changes whether the entity may be batched
            // (BatchingSystem.resolveBatchCandidate); the per-entity draw covers the frames
            // until its batch group is rebuilt.
            if twin.state != previousState, twin.state == .armed || previousState == .armed {
                BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
            }
        }
    }

    /// Reads and encodes the payload off the main thread, then applies it under the
    /// world-mutation gate. A relink or unlink bumps the twin's load generation (and cancels
    /// the task), and the apply re-checks both under the gate, so a load that finished for an
    /// earlier link never lands on the current one.
    private func startPayloadLoad(entityId: EntityID, twin: GaussianTwinComponent) {
        guard let url = twin.payloadURL else {
            handleError(.assetDataMissing, "Gaussian twin of entity \(entityId) has no payload URL")
            twin.loadFailed = true
            twin.state = .armed
            return
        }
        twin.loadTask?.cancel()
        twin.loadGeneration &+= 1
        let generation = twin.loadGeneration
        twin.loadTask = Task {
            let result = await loadGaussianTwinPayload(url: url)
            guard !Task.isCancelled else { return }
            withWorldMutationGate {
                guard !Task.isCancelled,
                      scene.exists(entityId),
                      let twin = scene.get(component: GaussianTwinComponent.self, for: entityId),
                      twin.loadGeneration == generation
                else { return }
                twin.loadTask = nil
                guard let result else {
                    twin.loadFailed = true
                    return
                }
                if !twin.payloadResident {
                    applyGaussianTwinPayload(result, to: entityId, twin: twin)
                }
            }
        }
    }
}

/// Builds the GPU buffers for a twin payload — `.untoldgs` through `GaussianChunkLoader`,
/// anything else as a `.ply`. Runs off the caller's actor; `nil` on failure, which is reported
/// through `handleError` like the other Gaussian load paths.
func loadGaussianTwinPayload(url: URL) async -> GaussianLoadResult? {
    if url.pathExtension.lowercased() == "untoldgs" {
        return buildGaussianLoadResultFromUntoldGS(url: url)
    }
    do {
        return try buildGaussianLoadResultFromPLY(url: url, sourceDescription: url.lastPathComponent)
    } catch {
        handleError(.assetDataMissing, "Failed to read Gaussian twin payload \(url.lastPathComponent): \(error.localizedDescription)")
        return nil
    }
}

/// Links `entityId`'s mesh to the captured splat at `payloadURL` as its twin. Nothing is loaded
/// here: `GaussianTwinSystem` loads the payload when the camera comes within
/// `options.swapDistanceMeters` (at once when that is 0), cross-fades to it, and fades back
/// when the camera leaves. The `.untold` loader calls this for every `gaussianAsset` record
/// flagged `meshTwin`; apps can call it on any mesh entity.
public func setEntityGaussianTwin(
    entityId: EntityID,
    payloadURL: URL,
    options: GaussianTwinOptions = GaussianTwinOptions()
) {
    guard scene.exists(entityId) else {
        handleError(.entityMissing, entityId)
        return
    }
    withWorldMutationGate {
        var leftBatchableState = false
        if let existing = scene.get(component: GaussianTwinComponent.self, for: entityId) {
            existing.loadTask?.cancel()
            existing.loadTask = nil
            existing.loadGeneration &+= 1
            leftBatchableState = existing.state != .armed
            if existing.payloadResident || existing.payloadGPUBytes > 0 {
                // Drops the old payload and resets the swap to `.armed`.
                removeEntityGaussian(entityId: entityId)
            }
        } else {
            registerComponent(entityId: entityId, componentType: GaussianTwinComponent.self)
        }
        guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { return }
        twin.payloadURL = payloadURL
        twin.options = options
        twin.state = .armed
        twin.fadeProgress = 0
        twin.loadFailed = false
        twin.payloadResident = false
        twin.payloadGPUBytes = 0
        twin.payloadBoundingBox = nil
        if leftBatchableState {
            BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
        }
    }
}

/// `setEntityGaussianTwin(entityId:payloadURL:options:)` with the payload looked up through
/// `LoadingSystem` like the other asset entry points.
public func setEntityGaussianTwin(
    entityId: EntityID,
    filename: String,
    withExtension: String,
    options: GaussianTwinOptions = GaussianTwinOptions()
) {
    guard let url = LoadingSystem.shared.resourceURL(forResource: filename, withExtension: withExtension, subResource: nil) else {
        handleError(.filenameNotFound, filename)
        return
    }
    setEntityGaussianTwin(entityId: entityId, payloadURL: url, options: options)
}

/// Unlinks the twin: cancels a pending load, drops the splat it loaded and shows the mesh
/// again. Also the component's cleanup handler when the entity is destroyed.
public func removeEntityGaussianTwin(entityId: EntityID) {
    withWorldMutationGate {
        guard let twin = scene.get(component: GaussianTwinComponent.self, for: entityId) else { return }
        twin.loadTask?.cancel()
        twin.loadTask = nil
        twin.loadGeneration &+= 1
        if twin.payloadResident || twin.payloadGPUBytes > 0 {
            removeEntityGaussian(entityId: entityId)
        }
        twin.state = .armed
        twin.fadeProgress = 0
        scene.remove(component: GaussianTwinComponent.self, from: entityId)
        BatchingSystem.shared.notifyEntityMaterialChanged(entityId: entityId)
    }
}
