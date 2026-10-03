//
//  EngineStatsRecorder.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum EngineStatsRecordingInterval: Sendable {
    /// One line per published frame. Large files, exact hitch positions.
    case perFrame
    /// One line per second (the last snapshot of each second). The summary still covers every frame.
    case perSecond
}

public enum EngineStatsRecordingError: Error {
    /// Engine stats are not compiled into this build (`ENGINE_STATS_ENABLED`), so there is nothing to record.
    case statsNotCompiledIn
    case cannotCreateFile(URL)
}

/// Whole-run numbers written as the last line of a recording and returned by `stopEngineStatsRecording()`.
public struct EngineStatsRecordingSummary: Codable, Equatable, Sendable {
    public var frames: Int = 0
    public var durationSeconds: Double = 0.0
    public var frameBudgetMs: Double = 0.0
    public var meanFrameMs: Double = 0.0
    public var p50FrameMs: Double = 0.0
    public var p95FrameMs: Double = 0.0
    public var p99FrameMs: Double = 0.0
    public var worstFrameMs: Double = 0.0
    public var framesOverBudget: Int = 0
    public var meanGPUExecutionMs: Double = 0.0
    /// Fastest GPU frame of the run. Clock drift on a lightly loaded GPU only inflates frames,
    /// so the minimum is the number to compare across runs; the mean tracks the clock state.
    public var minGPUExecutionMs: Double = 0.0
    /// Compositor deadline misses and samples over the run (visionOS), zero elsewhere.
    public var missedDeadlines: Int = 0
    public var deadlineSamples: Int = 0
    /// Mean GPU time per pass label over the frames in which the pass appeared.
    public var gpuPassMeanMs: [String: Double] = [:]
    /// Minimum GPU time per pass label. GPU clocks drift on a lightly loaded device, which only
    /// ever inflates a pass; the minimum is the robust number to compare across runs.
    public var gpuPassMinMs: [String: Double] = [:]
    /// Mean of the per-frame CPU timing fields (`EngineTimingStats` and the compositor phases),
    /// keyed by field name: what a CPU-side optimization changes.
    public var timingMeanMs: [String: Double] = [:]
    public var worstThermalState: Int = 0
    public var peakGPUAllocatedBytes: Int = 0

    public init() {}
}

/// Writes engine stats snapshots to a JSON Lines file off the render thread.
///
/// Each line is `{"type":"frame","frame":{...EngineStatsSnapshot...}}`; the last line written by
/// `stop()` is `{"type":"summary","summary":{...EngineStatsRecordingSummary...}}`. Use
/// `startEngineStatsRecording(to:interval:)` and `stopEngineStatsRecording()` rather than this
/// type directly; the monitor feeds it every published snapshot.
public final class EngineStatsRecorder: @unchecked Sendable {
    private struct Line: Codable {
        var type: String
        var frame: EngineStatsSnapshot?
        var summary: EngineStatsRecordingSummary?
    }

    public let url: URL
    public let interval: EngineStatsRecordingInterval

    private let queue = DispatchQueue(label: "com.untoldengine.profiling.recorder", qos: .utility)
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var isStopped = false

    // Accumulated on the queue
    private var frameTimes: [Double] = []
    private var gpuExecutionSum = 0.0
    private var gpuExecutionSamples = 0
    private var gpuExecutionMin = Double.greatestFiniteMagnitude
    private var gpuPassSums: [String: (sum: Double, samples: Int)] = [:]
    private var gpuPassMins: [String: Double] = [:]
    private var timingSums: [String: Double] = [:]
    private var timingSamples = 0
    private var firstTimestamp: Double?
    private var lastTimestamp: Double = 0.0
    private var lastWrittenSecond: Double = -1.0
    private var lastSnapshot: EngineStatsSnapshot?
    private var summary = EngineStatsRecordingSummary()

    init(url: URL, interval: EngineStatsRecordingInterval) throws {
        self.url = url
        self.interval = interval
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            throw EngineStatsRecordingError.cannotCreateFile(url)
        }
        self.handle = handle
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    }

    /// Called by the monitor with each published snapshot; returns immediately.
    func enqueue(_ snapshot: EngineStatsSnapshot) {
        queue.async { [self] in
            guard !isStopped else { return }
            accumulate(snapshot)
            switch interval {
            case .perFrame:
                write(Line(type: "frame", frame: snapshot, summary: nil))
            case .perSecond:
                let second = snapshot.timestampSeconds.rounded(.down)
                if second != lastWrittenSecond {
                    lastWrittenSecond = second
                    write(Line(type: "frame", frame: snapshot, summary: nil))
                }
            }
        }
    }

    /// Writes the summary line, closes the file and returns the summary. Idempotent.
    @discardableResult
    public func stop() -> EngineStatsRecordingSummary {
        queue.sync { [self] in
            guard !isStopped else { return summary }
            isStopped = true
            summary = makeSummary()
            write(Line(type: "summary", frame: nil, summary: summary))
            try? handle.close()
            return summary
        }
    }

    // MARK: - Queue-only helpers

    private func accumulate(_ snapshot: EngineStatsSnapshot) {
        frameTimes.append(snapshot.timing.frameTotalMs)
        if snapshot.timing.gpuExecutionMs > 0 {
            gpuExecutionSum += snapshot.timing.gpuExecutionMs
            gpuExecutionSamples += 1
            gpuExecutionMin = min(gpuExecutionMin, snapshot.timing.gpuExecutionMs)
        }
        for pass in snapshot.gpuPasses.passes {
            let entry = gpuPassSums[pass.label] ?? (0.0, 0)
            gpuPassSums[pass.label] = (entry.sum + pass.ms, entry.samples + 1)
            gpuPassMins[pass.label] = min(gpuPassMins[pass.label] ?? .greatestFiniteMagnitude, pass.ms)
        }
        let t = snapshot.timing
        let c = snapshot.compositor
        let fields: [(String, Double)] = [
            ("updateMs", t.updateMs), ("renderTotalMs", t.renderTotalMs), ("renderPrepMs", t.renderPrepMs),
            ("encodeMs", t.encodeMs), ("submitMs", t.submitMs), ("cullingMs", t.cullingMs),
            ("streamingRegionMs", t.streamingRegionMs), ("geometryStreamingMs", t.geometryStreamingMs),
            ("batchingTickMs", t.batchingTickMs), ("semaphoreWaitMs", t.semaphoreWaitMs),
            ("scenegraphMs", t.scenegraphMs), ("extensionsUpdateMs", t.extensionsUpdateMs), ("lodMs", t.lodMs),
            ("animationMs", t.animationMs), ("scriptingMs", t.scriptingMs), ("physicsMs", t.physicsMs),
            ("customSystemsMs", t.customSystemsMs), ("gameUpdateMs", t.gameUpdateMs),
            ("compositorUpdateMs", c.updateMs), ("compositorInputSlackMs", c.inputSlackMs),
            ("compositorSubmissionMs", c.submissionMs), ("compositorDeadlineMarginMs", c.deadlineMarginMs),
        ]
        for (name, value) in fields {
            timingSums[name, default: 0.0] += value
        }
        timingSamples += 1
        if snapshot.timestampSeconds > 0 {
            if firstTimestamp == nil {
                firstTimestamp = snapshot.timestampSeconds
            }
            lastTimestamp = snapshot.timestampSeconds
        }
        lastSnapshot = snapshot
    }

    private func makeSummary() -> EngineStatsRecordingSummary {
        var result = EngineStatsRecordingSummary()
        result.frames = frameTimes.count
        if let first = firstTimestamp {
            result.durationSeconds = max(0.0, lastTimestamp - first)
        }
        if !frameTimes.isEmpty {
            let sorted = frameTimes.sorted()
            result.meanFrameMs = frameTimes.reduce(0.0, +) / Double(frameTimes.count)
            result.p50FrameMs = sorted[Int(Double(sorted.count - 1) * 0.50)]
            result.p95FrameMs = sorted[Int(Double(sorted.count - 1) * 0.95)]
            result.p99FrameMs = sorted[Int(Double(sorted.count - 1) * 0.99)]
            result.worstFrameMs = sorted[sorted.count - 1]
        }
        if let last = lastSnapshot {
            result.frameBudgetMs = last.hitches.frameBudgetMs
            result.framesOverBudget = frameTimes.filter { $0 > last.hitches.frameBudgetMs }.count
            result.missedDeadlines = last.compositor.missedDeadlineCount
            result.deadlineSamples = last.compositor.deadlineSampleCount
        }
        if gpuExecutionSamples > 0 {
            result.meanGPUExecutionMs = gpuExecutionSum / Double(gpuExecutionSamples)
            result.minGPUExecutionMs = gpuExecutionMin
        }
        for (label, entry) in gpuPassSums where entry.samples > 0 {
            result.gpuPassMeanMs[label] = entry.sum / Double(entry.samples)
        }
        result.gpuPassMinMs = gpuPassMins
        if timingSamples > 0 {
            for (name, sum) in timingSums {
                result.timingMeanMs[name] = sum / Double(timingSamples)
            }
        }
        result.worstThermalState = lastSnapshotMaxThermal
        result.peakGPUAllocatedBytes = peakGPUAllocated
        return result
    }

    private var lastSnapshotMaxThermal = 0
    private var peakGPUAllocated = 0

    private func write(_ line: Line) {
        if let frame = line.frame {
            lastSnapshotMaxThermal = max(lastSnapshotMaxThermal, frame.memory.thermalState)
            peakGPUAllocated = max(peakGPUAllocated, frame.memory.gpuAllocatedBytes)
        }
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        handle.write(data)
    }
}

/// Starts writing every published engine stats snapshot to `url` as JSON Lines. Replaces an
/// active recording (which is stopped and summarised first). Throws when engine stats are not
/// compiled in or the file cannot be created.
public func startEngineStatsRecording(to url: URL, interval: EngineStatsRecordingInterval = .perSecond) throws {
    #if ENGINE_STATS_ENABLED
        let recorder = try EngineStatsRecorder(url: url, interval: interval)
        EngineStatsMonitor.shared.attachRecorder(recorder)?.stop()
    #else
        _ = url
        _ = interval
        throw EngineStatsRecordingError.statsNotCompiledIn
    #endif
}

/// Stops the active recording, writes its summary line and returns the summary; nil when nothing was recording.
@discardableResult
public func stopEngineStatsRecording() -> EngineStatsRecordingSummary? {
    EngineStatsMonitor.shared.attachRecorder(nil)?.stop()
}
