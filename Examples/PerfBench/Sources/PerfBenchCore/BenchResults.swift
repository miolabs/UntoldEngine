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
    /// Anti-aliasing mode the scenes ran with (the post-FX scene always uses SMAA).
    public var antiAliasing: String = "fxaa"
    /// Whether the visionOS frame pacer may start the submission phase ahead of the compositor's
    /// optimal input time. Always false off visionOS.
    public var xrFramePacing: Bool = false
    /// Whether the engine was compiled with `ENGINE_LOCK_DIAGNOSTICS`. Such a build counts and
    /// times every engine lock, so its frame and CPU times are not comparable with a normal one.
    public var lockDiagnostics: Bool = false

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
    /// Fraction of the recorded frames during which the app was the active (frontmost) app; an
    /// app that is not frontmost may be scheduled at a lower priority. 1 on platforms where the
    /// question does not arise.
    public var activeFraction: Double = 1.0
    /// CPU cores' worth of work done by every other process on the machine while the scene was
    /// recorded (macOS; 0 where it is not measured). Above about one core, frame pacing and the
    /// small CPU times of the light scenes are no longer the benchmark's own.
    public var otherProcessLoadCores: Double = 0.0
}

/// CPU time used by the whole machine and by this process up to now, to tell how busy the machine
/// was with other work while a scene was recorded.
public struct MachineLoadSample: Sendable {
    public var wallSeconds: Double
    public var hostBusySeconds: Double
    public var selfCPUSeconds: Double

    public static func now() -> MachineLoadSample? {
        #if os(macOS)
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            // User, system and nice ticks of every CPU; index 2 is idle.
            let busyTicks = Double(info.cpu_ticks.0) + Double(info.cpu_ticks.1) + Double(info.cpu_ticks.3)
            let ticksPerSecond = Double(max(1, sysconf(_SC_CLK_TCK)))
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let selfSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return MachineLoadSample(
                wallSeconds: ProcessInfo.processInfo.systemUptime,
                hostBusySeconds: busyTicks / ticksPerSecond,
                selfCPUSeconds: selfSeconds
            )
        #else
            return nil
        #endif
    }

    /// CPU cores' worth of work done by other processes between an earlier sample and this one.
    public func otherProcessLoadCores(since earlier: MachineLoadSample) -> Double {
        let wall = wallSeconds - earlier.wallSeconds
        guard wall > 0 else { return 0.0 }
        let host = hostBusySeconds - earlier.hostBusySeconds
        let own = selfCPUSeconds - earlier.selfCPUSeconds
        return max(0.0, (host - own) / wall)
    }
}

public extension BenchSceneResult {
    /// Below this fraction of active frames the report says the app was not frontmost.
    static let activeFractionRequired = 0.98
    /// From this load by other processes on, the report says the machine was busy.
    static let busyMachineCores = 1.0
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
            let lockCalls = s.lockCallsPerFrame.values.reduce(0.0, +)
            let locks = s.lockCallsPerFrame.isEmpty
                ? ""
                : String(
                    format: " | locks %.0f/frame, contended %d, wait %.2f ms",
                    lockCalls, s.lockContended.values.reduce(0, +), s.lockWaitMs.values.reduce(0.0, +)
                )
            var inactive = scene.activeFraction < BenchSceneResult.activeFractionRequired
                ? String(format: " | app not active for %.0f%% of the scene", (1.0 - scene.activeFraction) * 100)
                : ""
            if scene.otherProcessLoadCores >= BenchSceneResult.busyMachineCores {
                inactive += String(format: " | MACHINE BUSY: other processes used %.1f cores", scene.otherProcessLoadCores)
            }
            lines.append(String(
                format: "  %@: frames %d | mean %.2f p95 %.2f p99 %.2f worst %.2f ms | over budget %d | gpu %.2f ms%@ | thermal %d%@%@",
                scene.id, s.frames, s.meanFrameMs, s.p95FrameMs, s.p99FrameMs, s.worstFrameMs,
                s.framesOverBudget, s.meanGPUExecutionMs, miss, s.worstThermalState, locks, inactive
            ))
        }
        return lines.joined(separator: "\n")
    }
}
