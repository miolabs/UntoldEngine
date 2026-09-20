//
//  BenchConfig.swift
//  PerfBench
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Run configuration, read from the environment so the driver script and `devicectl` can set it.
///
/// | Variable | Meaning | Default |
/// |---|---|---|
/// | `UNTOLD_BENCH_SCENES` | Comma-separated scene ids, or `all` | `all` |
/// | `UNTOLD_BENCH_WARMUP` | Seconds rendered before recording starts, per scene | `3` |
/// | `UNTOLD_BENCH_SECONDS` | Seconds recorded per scene | `15` |
/// | `UNTOLD_BENCH_OUTPUT` | Output directory | `<Documents>/PerfBench` |
/// | `UNTOLD_BENCH_RUN_ID` | Run folder name | timestamp |
/// | `UNTOLD_BENCH_LABEL` | Free text stored in the summary (commit, branch, note) | empty |
/// | `UNTOLD_BENCH_KEEP_OPEN` | `1` keeps the app running after the last scene | exit when done |
/// | `UNTOLD_BENCH_AUTOSTART` | `0` waits for the Start button (visionOS) | start on launch |
/// | `UNTOLD_BENCH_IMMERSION` | `full` or `mixed` (visionOS) | `full` |
/// | `UNTOLD_BENCH_PER_FRAME` | `0` records one line per second instead of per frame | per frame |
public struct BenchConfig: Sendable {
    public var sceneIDs: [String]
    public var warmupSeconds: Double
    public var measureSeconds: Double
    public var outputDirectory: URL
    public var runID: String
    public var label: String
    public var exitWhenDone: Bool
    public var autoStart: Bool
    public var immersion: String
    public var perFrame: Bool

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> BenchConfig {
        func double(_ key: String, _ fallback: Double) -> Double {
            guard let raw = environment[key], let value = Double(raw), value > 0 else { return fallback }
            return value
        }
        let scenesRaw = environment["UNTOLD_BENCH_SCENES"] ?? "all"
        let sceneIDs = scenesRaw == "all"
            ? BenchScenes.all.map(\.id)
            : scenesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let outputDirectory = environment["UNTOLD_BENCH_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? documents.appendingPathComponent("PerfBench", isDirectory: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        return BenchConfig(
            sceneIDs: sceneIDs,
            warmupSeconds: double("UNTOLD_BENCH_WARMUP", 3.0),
            measureSeconds: double("UNTOLD_BENCH_SECONDS", 15.0),
            outputDirectory: outputDirectory,
            runID: environment["UNTOLD_BENCH_RUN_ID"] ?? formatter.string(from: Date()),
            label: environment["UNTOLD_BENCH_LABEL"] ?? "",
            exitWhenDone: environment["UNTOLD_BENCH_KEEP_OPEN"] != "1",
            autoStart: environment["UNTOLD_BENCH_AUTOSTART"] != "0",
            immersion: environment["UNTOLD_BENCH_IMMERSION"] ?? "full",
            perFrame: environment["UNTOLD_BENCH_PER_FRAME"] != "0"
        )
    }

    public var runDirectory: URL {
        outputDirectory.appendingPathComponent(runID, isDirectory: true)
    }
}
