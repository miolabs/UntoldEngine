//
//  BenchResults.swift
//  PerfBench
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import UntoldEngine

/// What the run was measured on. Baselines are keyed by `model`.
public struct BenchDeviceInfo: Codable, Sendable {
    public var model: String
    public var osVersion: String
    public var gpuName: String
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var thermalStateAtStart: Int
    public var isLowPowerMode: Bool

    public static func current() -> BenchDeviceInfo {
        BenchDeviceInfo(
            model: modelIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            gpuName: MTLCreateSystemDefaultDevice()?.name ?? "unknown",
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func modelIdentifier() -> String {
        #if os(macOS)
            let key = "hw.model"
        #else
            let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// Render settings the app chose, so a baseline is never compared across different ones.
public struct BenchRenderSettings: Codable, Sendable {
    public var platform: String
    public var viewportWidth: Int = 0
    public var viewportHeight: Int = 0
    public var viewCount: Int = 1
    public var layout: String = "single"
    public var foveation: Bool = false
    public var renderQuality: Double = 1.0
    public var immersion: String = "none"
    /// Whether presentation is paced by the display. True everywhere: on macOS and iOS the view
    /// presents at the display's maximum refresh rate, on visionOS the compositor paces frames.
    /// Frame time is therefore bounded below by the refresh interval; GPU time, per-pass and
    /// per-system times are the cost metrics for scenes that fit in a frame.
    public var vsync: Bool = true
    /// Refresh rate the frame budget is derived from (0 when unknown).
    public var displayRefreshHz: Double = 0.0

    public init(platform: String) {
        self.platform = platform
    }
}

public struct BenchSceneResult: Codable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    /// Recording file, relative to the run directory.
    public var file: String
    public var warmupSeconds: Double
    public var measureSeconds: Double
    public var summary: EngineStatsRecordingSummary
    /// The last published snapshot of the scene, for the compositor, hitch and pass details.
    public var lastSnapshot: EngineStatsSnapshot
}

public struct BenchRunSummary: Codable, Sendable {
    public var runID: String
    public var label: String
    public var startedAt: String
    public var finishedAt: String = ""
    public var device: BenchDeviceInfo
    public var render: BenchRenderSettings
    public var scenes: [BenchSceneResult] = []

    public init(runID: String, label: String, device: BenchDeviceInfo, render: BenchRenderSettings) {
        self.runID = runID
        self.label = label
        startedAt = ISO8601DateFormatter().string(from: Date())
        self.device = device
        self.render = render
    }

    /// Writes `summary.json` into `directory` and returns the encoded data.
    @discardableResult
    public func write(to directory: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("summary.json"))
        return data
    }

    /// One line per scene for the console.
    public var consoleReport: String {
        var lines: [String] = []
        lines.append("PerfBench \(runID) on \(device.model) (\(device.gpuName), \(device.osVersion)) \(render.platform) \(render.viewportWidth)x\(render.viewportHeight) x\(render.viewCount)")
        for scene in scenes {
            let s = scene.summary
            let miss = s.deadlineSamples > 0
                ? String(format: " deadlineMiss %.2f%%", Double(s.missedDeadlines) / Double(s.deadlineSamples) * 100)
                : ""
            lines.append(String(
                format: "  %@: frames %d | mean %.2f p95 %.2f p99 %.2f worst %.2f ms | over budget %d | gpu %.2f ms%@ | thermal %d",
                scene.id, s.frames, s.meanFrameMs, s.p95FrameMs, s.p99FrameMs, s.worstFrameMs,
                s.framesOverBudget, s.meanGPUExecutionMs, miss, s.worstThermalState
            ))
        }
        return lines.joined(separator: "\n")
    }
}
