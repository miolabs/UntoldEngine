//
//  ReduceCommand.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import UntoldEngineMeshCook

struct ReduceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reduce",
        abstract: "Simplify a cooked .untold model, or every model of a .untoldpack, in place",
        discussion: """
        For high-poly source exported as it is: the model itself gets fewer
        triangles, built with meshoptimizer like the LOD levels of `bake-lods`,
        which writes simplified copies beside the model instead. Give a share of
        the triangles (--ratio) or a budget for the whole input
        (--target-triangles, a pack's models counted together). An input already
        within the budget is left as it is, so running the command again with a
        budget changes nothing; a ratio reduces again every time.

        The budget is not shared out in proportion: the command searches for one
        deviation, the same for every mesh, at which the input holds the budget,
        so flat or finely tessellated parts (lettering, fluted turnings) give up
        many triangles and parts whose shape needs them keep them. It never goes
        above 1 % of the input's diameter; a budget that would need more is left
        unmet. Names, entities, materials and textures are kept, as are the
        borders two meshes share and the seams of textured meshes. LOD levels
        cooked from the full model are removed: run `bake-lods` afterwards.

        Examples:
          untoldengine reduce --input Models/table/table.untold --target-triangles 40000
          untoldengine reduce --input Models/cabinet/cabinet.untoldpack --ratio 0.25
          untoldengine reduce --input chair.untold --output chair_low.untold --ratio 0.1
        """
    )

    @Option(name: .long, help: "The .untold model or the .untoldpack manifest to simplify")
    var input: String

    @Option(name: .long, help: "Write the simplified model here instead of over the input (a .untold input only)")
    var output: String?

    @Option(name: .long, help: "Share of the triangles to keep, above 0 and below 1")
    var ratio: Float?

    @Option(name: .customLong("target-triangles"), help: "Triangle budget for the whole input")
    var targetTriangles: Int?

    func validate() throws {
        guard (ratio == nil) != (targetTriangles == nil) else {
            throw ValidationError("Give exactly one of --ratio or --target-triangles.")
        }
    }

    func run() throws {
        let inputURL = resolvePath(input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ReduceError.inputNotFound(inputURL.path)
        }
        let target: UntoldMeshReductionTarget = if let ratio { .ratio(ratio) } else { .triangles(targetTriangles ?? 0) }

        switch inputURL.pathExtension.lowercased() {
        case "untoldpack":
            guard output == nil else { throw ValidationError("--output is for a .untold input; a pack is reduced in place.") }
            let reductions = try UntoldMeshReducer.reducePack(at: inputURL, target: target)
            for reduction in reductions {
                Self.print(reduction)
            }
            let before = reductions.reduce(0) { $0 + $1.triangleCount }
            let after = reductions.reduce(0) { $0 + $1.reducedTriangleCount }
            printSuccess("\(inputURL.lastPathComponent): \(Self.grouped(before)) → \(Self.grouped(after)) triangles in \(reductions.count) model(s); run bake-lods to cook its LOD chains again")
        case "untold":
            let outputURL = output.map { resolvePath($0).standardizedFileURL }
            let reduction = try UntoldMeshReducer.reduce(modelAt: inputURL, writingTo: outputURL, target: target)
            Self.print(reduction)
        default:
            throw ReduceError.unsupportedInput(inputURL.pathExtension)
        }
    }

    private static func print(_ reduction: UntoldMeshReduction) {
        let name = reduction.url.lastPathComponent
        if let reason = reduction.skipped {
            printInfo("  \(name): \(grouped(reduction.triangleCount)) triangles, unchanged (\(describe(reason)))")
            return
        }
        let millimetres = String(format: "%.1f", reduction.error * 1000)
        printInfo("  \(name): \(grouped(reduction.triangleCount)) → \(grouped(reduction.reducedTriangleCount)) triangles, largest deviation \(millimetres) mm")
    }

    private static func describe(_ reason: UntoldMeshReduction.SkipReason) -> String {
        switch reason {
        case .withinTarget: "already within the target"
        case .deforms: "skinned, morphing or animation-only models keep their full meshes"
        case .gaussianTwin: "the mesh twin of a Gaussian splat"
        case .irreducible: "the simplifier could not reduce it by a worthwhile amount"
        }
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

enum ReduceError: LocalizedError, Equatable {
    case inputNotFound(String)
    case unsupportedInput(String)

    var errorDescription: String? {
        switch self {
        case let .inputNotFound(path):
            "Input not found: \(path)"
        case let .unsupportedInput(pathExtension):
            "reduce needs a .untold or .untoldpack input, not .\(pathExtension)"
        }
    }
}
