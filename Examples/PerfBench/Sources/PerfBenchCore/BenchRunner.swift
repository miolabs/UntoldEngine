//
//  BenchRunner.swift
//  PerfBench
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Combine
import Foundation
import QuartzCore
import simd
import UntoldEngine

/// Drives the scenes one after another from the engine's update callback:
/// build → warm up → record → tear down, then writes `summary.json` and reports.
@MainActor
public final class BenchRunner: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case building(Int)
        case warmup(Int)
        case recording(Int)
        case tearingDown(Int)
        case finished
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var statusText: String = "Ready"
    @Published public private(set) var report: String = ""

    public let config: BenchConfig
    public var render: BenchRenderSettings
    /// Where scenes are built. Zero on macOS and iOS; a point in front of the user on visionOS.
    public var sceneOrigin: simd_float3 = .zero
    /// Whether the runner moves the camera along each scene's orbit (off on visionOS).
    public var drivesCamera = true
    public var onFinished: ((BenchRunSummary) -> Void)?

    private let scenes: [BenchScene]
    private var summary: BenchRunSummary
    private var phaseDeadline: Double = 0.0
    private var sceneStart: Double = 0.0
    private var cameraEntity: EntityID?

    public init(config: BenchConfig, render: BenchRenderSettings) {
        self.config = config
        self.render = render
        scenes = BenchScenes.scenes(withIDs: config.sceneIDs)
        summary = BenchRunSummary(runID: config.runID, label: config.label, device: .current(), render: render)
    }

    public var isRunning: Bool {
        switch phase {
        case .idle, .finished: return false
        default: return true
        }
    }

    /// Starts the run. Safe to call once; later calls are ignored.
    public func start() {
        guard phase == .idle else { return }
        guard !scenes.isEmpty else {
            statusText = "No scenes match \(config.sceneIDs)"
            phase = .finished
            return
        }
        try? FileManager.default.createDirectory(at: config.runDirectory, withIntermediateDirectories: true)
        setEngine(.metrics(.enabled))
        GPUPassTimer.shared.isEnabled = true
        setEngineStatsLogging(enabled: false)
        if render.displayRefreshHz > 0 {
            // Display-paced frames sit right at the refresh interval, so "over budget" means a
            // refresh was skipped: more than one and a half intervals.
            EngineStatsMonitor.shared.frameBudgetMs = 1.5 * 1000.0 / render.displayRefreshHz
        }
        gameMode = true
        phase = .building(0)
    }

    /// Call from the engine's game update callback every frame.
    public func update(deltaTime _: Float) {
        let now = CACurrentMediaTime()
        switch phase {
        case .idle, .finished:
            return

        case let .building(index):
            let scene = scenes[index]
            statusText = "Building \(scene.id)"
            setSceneReady(false)
            scene.build(origin: sceneOrigin)
            cameraEntity = CameraSystem.shared.activeCamera
            setSceneReady(true)
            EngineStatsMonitor.shared.reset()
            GPUPassTimer.shared.reset()
            sceneStart = now
            phaseDeadline = now + config.warmupSeconds
            phase = .warmup(index)

        case let .warmup(index):
            driveCamera(scenes[index], elapsed: now - sceneStart)
            statusText = String(format: "%@: warming up %.0fs", scenes[index].id, phaseDeadline - now)
            if now >= phaseDeadline {
                EngineStatsMonitor.shared.reset()
                GPUPassTimer.shared.reset()
                let file = config.runDirectory.appendingPathComponent("\(scenes[index].id).jsonl")
                do {
                    try startEngineStatsRecording(to: file, interval: config.perFrame ? .perFrame : .perSecond)
                } catch {
                    statusText = "Recording failed: \(error)"
                }
                phaseDeadline = now + config.measureSeconds
                phase = .recording(index)
            }

        case let .recording(index):
            driveCamera(scenes[index], elapsed: now - sceneStart)
            statusText = String(format: "%@: recording %.0fs", scenes[index].id, phaseDeadline - now)
            if now >= phaseDeadline {
                finishScene(index)
                phaseDeadline = now + 0.75
                phase = .tearingDown(index)
            }

        case let .tearingDown(index):
            if now >= phaseDeadline {
                let next = index + 1
                if next < scenes.count {
                    phase = .building(next)
                } else {
                    finishRun()
                }
            }
        }
    }

    // MARK: - Internals

    private func driveCamera(_ scene: BenchScene, elapsed: Double) {
        guard drivesCamera, let cameraEntity else { return }
        let orbit = scene.orbit
        let eye = sceneOrigin + orbit.eye(at: Float(elapsed))
        cameraLookAt(entityId: cameraEntity, eye: eye, target: sceneOrigin + orbit.center, up: simd_float3(0, 1, 0))
    }

    private func finishScene(_ index: Int) {
        let scene = scenes[index]
        let recording = stopEngineStatsRecording() ?? EngineStatsRecordingSummary()
        let snapshot = getEngineStatsSnapshot()
        if render.viewportWidth == 0 {
            render.viewportWidth = snapshot.compositor.viewTextureWidth
            render.viewportHeight = snapshot.compositor.viewTextureHeight
            render.viewCount = max(1, snapshot.compositor.viewCount)
            summary.render = render
        }
        summary.scenes.append(BenchSceneResult(
            id: scene.id,
            title: scene.title,
            notes: scene.notes,
            file: "\(scene.id).jsonl",
            warmupSeconds: config.warmupSeconds,
            measureSeconds: config.measureSeconds,
            summary: recording,
            lastSnapshot: snapshot
        ))
        scene.teardown()
        cameraEntity = nil
        setSceneReady(false)
        destroyAllEntities()
        // Frames keep rendering while destroys finalize; give the engine a camera so it does not
        // log a missing active camera every frame until the next scene builds its own.
        let placeholder = createEntity()
        setEntityName(entityId: placeholder, name: "Bench Idle Camera")
        createGameCamera(entityId: placeholder)
        cameraLookAt(entityId: placeholder, eye: simd_float3(0, 2, 6), target: .zero, up: simd_float3(0, 1, 0))
        setCamera(.active(placeholder))
    }

    private func finishRun() {
        summary.finishedAt = ISO8601DateFormatter().string(from: Date())
        do {
            let data = try summary.write(to: config.runDirectory)
            report = summary.consoleReport
            print(report)
            // One line the driver script can pick out of the console stream.
            if let json = String(data: data, encoding: .utf8) {
                print("PERFBENCH_SUMMARY_JSON " + json.replacingOccurrences(of: "\n", with: " "))
            }
            print("PERFBENCH_DONE \(config.runDirectory.path)")
        } catch {
            report = "Failed to write summary: \(error)"
            print(report)
            print("PERFBENCH_FAILED")
        }
        fflush(stdout)
        statusText = "Done"
        phase = .finished
        onFinished?(summary)
    }
}
