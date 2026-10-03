//
//  LockScenes.swift
//  PerfBench
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import SwiftUI
import UntoldEngine

// Scenes of the `locks` session. Each one renders the same 1,024 primitives as `primitives-1k`
// and adds one kind of work against the engine's shared state: game code calling the public API
// for every entity, an asset loading while the frame renders, or a second thread reading the
// scene. In a build with ENGINE_LOCK_DIAGNOSTICS they are judged on lock calls per frame,
// contention, wait and hold time; in a normal build on frame and CPU times like any other scene.

private enum LockSceneLayout {
    static let gridSize = 32
    static let spacing: Float = 1.0
    static let orbit = BenchCameraOrbit(center: .zero, radius: 26.0, height: 12.0, period: 16.0)

    static func buildBase(origin: simd_float3, namePrefix: String) -> [EntityID] {
        BenchSceneBuilder.makeCamera(eye: origin + orbit.eye(at: 0), target: origin)
        BenchSceneBuilder.makeSun()
        return BenchSceneBuilder.makeGrid(
            origin: origin,
            gridSize: gridSize,
            spacing: spacing,
            batched: false,
            namePrefix: namePrefix
        )
    }
}

/// Game code that reads and moves every entity through the public API, every frame.
final class LockAPICallsScene: BenchScene {
    let id = "locks-api"
    let title = "1024 primitives moved through the public API every frame"
    let notes = "getLocalPosition, translateTo and rotateBy on each entity per frame; measures what the public API costs in lock calls."
    let orbit = LockSceneLayout.orbit

    private var entities: [EntityID] = []
    private var basePositions: [simd_float3] = []

    func build(origin: simd_float3) {
        entities = LockSceneLayout.buildBase(origin: origin, namePrefix: id)
        basePositions = entities.map { getLocalPosition(entityId: $0) }
    }

    func update(deltaTime: Float, elapsed: Double) {
        let time = Float(elapsed)
        for (index, entity) in entities.enumerated() {
            let base = basePositions[index]
            // A read, as game logic would do before deciding where the entity goes.
            let current = getLocalPosition(entityId: entity)
            let lift = 0.25 * sin(time * 2.0 + Float(index) * 0.21)
            translateTo(entityId: entity, position: simd_float3(current.x, base.y + lift, current.z))
            rotateBy(entityId: entity, angle: 45.0 * deltaTime, axis: simd_float3(0, 1, 0))
        }
    }

    func teardown() {
        entities = []
        basePositions = []
    }
}

/// An asset that keeps loading on the loader's threads while the frame renders.
final class LockLoadingScene: BenchScene {
    let id = "locks-loading"
    let title = "1024 primitives while an asset loads over and over"
    let notes = "redplayer.untold loaded asynchronously, destroyed and loaded again for the whole scene; measures contention between the loader and the frame."
    let orbit = LockSceneLayout.orbit

    /// Seconds a loaded asset stays in the scene before it is destroyed and the next load starts.
    private let lifetime = 0.25

    private let state = LoadState()
    private var origin: simd_float3 = .zero
    private var current: EntityID?
    private var loadedAt: Double?

    /// Written from the loader's completion (any thread), read from the update thread.
    private final class LoadState: @unchecked Sendable {
        private let lock = NSLock()
        private var finishedGeneration = 0

        func markFinished(_ generation: Int) {
            lock.lock()
            finishedGeneration = max(finishedGeneration, generation)
            lock.unlock()
        }

        func hasFinished(_ generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return finishedGeneration >= generation
        }
    }

    private var generation = 0
    private var stopping = false

    func build(origin: simd_float3) {
        self.origin = origin
        stopping = false
        _ = LockSceneLayout.buildBase(origin: origin, namePrefix: id)
        startLoad()
    }

    /// The load in flight, if any, is left to finish; no new one starts.
    func requestStop() {
        stopping = true
    }

    /// False while a load is in flight: its entity must not be destroyed under the loader.
    var isQuiescent: Bool {
        state.hasFinished(generation)
    }

    func update(deltaTime _: Float, elapsed: Double) {
        guard !stopping, let entity = current, state.hasFinished(generation) else { return }
        if loadedAt == nil {
            loadedAt = elapsed
            translateTo(entityId: entity, position: origin + simd_float3(0, 1.5, 0))
            return
        }
        if let loadedAt, elapsed - loadedAt >= lifetime {
            destroyEntity(entityId: entity)
            startLoad()
        }
    }

    func teardown() {
        current = nil
        loadedAt = nil
    }

    private func startLoad() {
        generation += 1
        loadedAt = nil
        let entity = createEntity()
        setEntityName(entityId: entity, name: "Bench Loaded \(generation)")
        current = entity
        let loadGeneration = generation
        let state = state
        // Not blocking the render loop: the point is the loader and the frame working at once.
        setEntityMeshAsync(entityId: entity, filename: "redplayer", withExtension: "untold", blockRenderLoop: false) { _ in
            state.markFinished(loadGeneration)
        }
    }
}

/// A second thread reading the scene while the frame renders, as a render thread reads what the
/// main thread updates on visionOS.
final class LockSecondThreadScene: BenchScene {
    let id = "locks-threads"
    let title = "1024 primitives while a second thread reads the scene"
    let notes = "A background thread reads every entity's transform in a loop while the frame runs; measures contention and wait on the scene's locks."
    let orbit = LockSceneLayout.orbit

    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var stopRequested = false
        private let finished = DispatchSemaphore(value: 0)
        let entities: [EntityID]

        init(entities: [EntityID]) {
            self.entities = entities
        }

        var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopRequested
        }

        func start() {
            let thread = Thread { [self] in
                var checksum: Float = 0
                while !shouldStop {
                    for entity in entities {
                        if let transform = scene.get(component: LocalTransformComponent.self, for: entity) {
                            checksum += transform.position.y
                        }
                    }
                    // One sweep per millisecond at most: a steady second reader, not a spin loop
                    // that would measure how fast a core can hammer one lock.
                    usleep(1000)
                }
                _ = checksum
                finished.signal()
            }
            thread.name = "PerfBench Scene Reader"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stopAndWait() {
            lock.lock()
            stopRequested = true
            lock.unlock()
            _ = finished.wait(timeout: .now() + 2.0)
        }
    }

    private var reader: Reader?

    func build(origin: simd_float3) {
        let entities = LockSceneLayout.buildBase(origin: origin, namePrefix: id)
        let reader = Reader(entities: entities)
        self.reader = reader
        reader.start()
    }

    /// Stops the reader before the runner destroys the entities it reads.
    func requestStop() {
        reader?.stopAndWait()
        reader = nil
    }

    func teardown() {
        requestStop()
    }
}
