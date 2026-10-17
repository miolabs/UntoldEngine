//
//  UntoldMeshReducer.swift
//  UntoldEngineMeshCook
//
//  Simplifies a cooked `.untold` model, or every model of a `.untoldpack`, in place:
//  the model itself gets fewer triangles (where `UntoldMeshLODCooker` writes simplified
//  copies beside it). For high-poly source exported as it is, ahead of `bake-lods`.
//
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine

/// How far to simplify: a share of the triangles, or a triangle budget for the whole
/// input (a pack's budget is shared by its models in proportion to their triangles).
public enum UntoldMeshReductionTarget: Sendable, Equatable {
    case ratio(Float)
    case triangles(Int)

    func validate() throws {
        switch self {
        case let .ratio(ratio):
            guard ratio > 0, ratio < 1 else {
                throw UntoldMeshLODError.invalidOptions("the ratio \(ratio) must be above 0 and below 1")
            }
        case let .triangles(count):
            guard count > 0 else {
                throw UntoldMeshLODError.invalidOptions("the triangle budget must be above 0")
            }
        }
    }
}

/// What reducing one model did.
public struct UntoldMeshReduction: Sendable, Equatable {
    public enum SkipReason: Sendable, Equatable {
        /// Already within the budget or the ratio's reach: the file is left as it is.
        case withinTarget
        /// Skinned, morphing or animation-only models keep their full meshes.
        case deforms
        /// A mesh twin of a Gaussian splat.
        case gaussianTwin
        /// The simplifier could not reduce it by a worthwhile amount.
        case irreducible
    }

    public var url: URL
    public var triangleCount: Int
    public var reducedTriangleCount: Int
    /// The largest deviation from the model the simplifier reports, in model units.
    public var error: Float
    public var skipped: SkipReason?
}

public enum UntoldMeshReducer {
    /// Each mesh is simplified at least this far towards nothing: the shared deviation,
    /// not a per-mesh share, decides how many triangles a mesh keeps.
    static let floorRatio: Float = 0.002
    /// Steps of the search for the shared deviation.
    static let searchSteps = 18
    /// The deviation is never allowed above this share of the input's diameter: a
    /// budget it cannot meet within that is left unmet rather than the shape lost.
    static let largestDeviationShare: Float = 0.01

    /// Simplifies the model at `modelURL` towards `target` and writes it back (or to
    /// `outputURL`). See `reducePack(at:target:)` for how the triangles are spent.
    @discardableResult
    public static func reduce(modelAt modelURL: URL, writingTo outputURL: URL? = nil, target: UntoldMeshReductionTarget) throws -> UntoldMeshReduction {
        try target.validate()
        let model = try PreparedModel(url: modelURL)
        let reductions = try reduce([model], outputs: [outputURL ?? modelURL], target: target)
        return reductions[0]
    }

    /// Reduces every distinct model of the pack at `packURL` in place, towards one
    /// triangle budget for the whole pack (a model counted once however often the pack
    /// places it). The triangles are not shared out in proportion: one deviation is
    /// searched for, the same for every mesh of every model, at which the pack holds the
    /// budget, so flat or finely tessellated parts (lettering, turned and fluted wood)
    /// give up many triangles and parts whose shape needs them keep them. The deviation
    /// never exceeds 1 % of the input's diameter. Vertices two meshes of a model share
    /// stay in place and texture seams are kept. Names, entities, materials and textures
    /// are carried over unchanged. The LOD chains in the manifest go, with their files:
    /// they were made from the full models, so run `bake-lods` again afterwards.
    @discardableResult
    public static func reducePack(at packURL: URL, target: UntoldMeshReductionTarget) throws -> [UntoldMeshReduction] {
        try target.validate()
        let packDirectory = packURL.deletingLastPathComponent()
        var manifest: [String: Any]
        do {
            let data = try Data(contentsOf: packURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UntoldMeshLODError.unreadableManifest(path: packURL.path, reason: "the manifest is not a JSON object")
            }
            manifest = object
        } catch let error as UntoldMeshLODError {
            throw error
        } catch {
            throw UntoldMeshLODError.unreadableManifest(path: packURL.path, reason: String(describing: error))
        }
        guard let models = manifest["models"] as? [[String: Any]] else {
            throw UntoldMeshLODError.unreadableManifest(path: packURL.path, reason: "the manifest has no models")
        }
        var paths: [String] = []
        for model in models {
            if let path = model["path"] as? String, !paths.contains(path) {
                paths.append(path)
            }
        }
        let urls = paths.map { packDirectory.appendingPathComponent($0).standardizedFileURL }
        let prepared = try urls.map(PreparedModel.init)
        let reductions = try reduce(prepared, outputs: urls, target: target)

        if manifest[UntoldMeshLODCooker.packManifestKey] != nil {
            manifest.removeValue(forKey: UntoldMeshLODCooker.packManifestKey)
            do {
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: packURL, options: .atomic)
            } catch {
                throw UntoldMeshLODError.writeFailed(path: packURL.path, reason: String(describing: error))
            }
        }
        return reductions
    }

    // MARK: - The models

    /// A model read and unpacked for the simplifier, or the reason it is left alone.
    struct PreparedModel {
        var url: URL
        var fileData: Data
        var decoded: UntoldDecodedAsset
        var triangleCount: Int
        var meshes: [UntoldLODMesh] = []
        var parts: [UntoldLODMeshParts] = []
        var scales: [Float] = []
        var diameter: Float = 0
        var skipped: UntoldMeshReduction.SkipReason?

        init(url: URL) throws {
            self.url = url
            do {
                fileData = try Data(contentsOf: url, options: .mappedIfSafe)
                decoded = try UntoldReader().readAsset(from: fileData)
            } catch {
                throw UntoldMeshLODError.unreadableModel(path: url.path, reason: String(describing: error))
            }
            guard decoded.header.flags & UntoldFileFlags.generatedLODLevel == 0 else {
                throw UntoldMeshLODError.invalidOptions("\(url.lastPathComponent) is a LOD level, not a model")
            }
            triangleCount = decoded.meshes.reduce(0) { $0 + Int($1.indexCount) / 3 }
            if decoded.header.fileType == .animation || !decoded.skins.isEmpty || !decoded.morphTargets.isEmpty {
                skipped = .deforms
                return
            }
            if !decoded.gaussianAssets.isEmpty {
                skipped = .gaussianTwin
                return
            }
            guard triangleCount > 0 else {
                skipped = .withinTarget
                return
            }
            let (meshes, transforms, diameter) = try UntoldMeshLODCooker.unpackGeometry(of: decoded, fileData: fileData, path: url.path)
            self.meshes = meshes
            parts = meshes.map(UntoldLODMeshParts.init)
            scales = transforms.map(UntoldMeshLODCooker.largestAxisScale)
            self.diameter = diameter
        }

        /// Every mesh simplified within `deviation` (model units).
        func simplified(deviation: Float) -> [UntoldLODMeshLevel] {
            var results = [UntoldLODMeshLevel?](repeating: nil, count: meshes.count)
            results.withUnsafeMutableBufferPointer { slots in
                // Each iteration writes its own slot.
                nonisolated(unsafe) let slots = slots
                DispatchQueue.concurrentPerform(iterations: meshes.count) { index in
                    let scale = scales[index]
                    slots[index] = UntoldMeshLODSimplifier.level(
                        of: meshes[index],
                        parts: parts[index],
                        ratio: UntoldMeshReducer.floorRatio,
                        errorLimit: scale > 0 ? deviation / scale : deviation,
                        releaseSeams: false
                    )
                }
            }
            return results.compactMap { $0 }
        }
    }

    private static func reduce(_ models: [PreparedModel], outputs: [URL], target: UntoldMeshReductionTarget) throws -> [UntoldMeshReduction] {
        let active = models.indices.filter { models[$0].skipped == nil }
        let total = models.reduce(0) { $0 + $1.triangleCount }
        let reducible = active.reduce(0) { $0 + models[$1].triangleCount }
        let budget: Int = switch target {
        case let .ratio(ratio): Int((Float(total) * ratio).rounded())
        case let .triangles(count): count
        }
        // What the models that cannot be simplified hold comes off the budget first.
        let budgetForActive = budget - (total - reducible)

        var chosen: [Int: [UntoldLODMeshLevel]] = [:]
        if !active.isEmpty, reducible > budgetForActive {
            let diameter = active.map { models[$0].diameter }.max() ?? 0
            // The largest deviation tried; the smallest that brings the models within
            // the budget is searched for between nothing and it (on a log scale).
            let largest = max(diameter * largestDeviationShare, 1e-6)
            var low = largest * 1e-5
            var high = largest
            var best: (deviation: Float, levels: [Int: [UntoldLODMeshLevel]])?
            func pass(_ deviation: Float) -> (Int, [Int: [UntoldLODMeshLevel]]) {
                var levels: [Int: [UntoldLODMeshLevel]] = [:]
                var count = 0
                for index in active {
                    let simplified = models[index].simplified(deviation: deviation)
                    levels[index] = simplified
                    count += simplified.reduce(0) { $0 + $1.triangleCount }
                }
                return (count, levels)
            }
            let (atLargest, levelsAtLargest) = pass(high)
            if atLargest > budgetForActive {
                // Even 1 % of the diameter does not meet the budget: stop there.
                best = (high, levelsAtLargest)
            } else {
                best = (high, levelsAtLargest)
                for _ in 0 ..< searchSteps {
                    let middle = (low * high).squareRoot()
                    let (count, levels) = pass(middle)
                    if count <= budgetForActive {
                        high = middle
                        best = (middle, levels)
                    } else {
                        low = middle
                    }
                    if high / low < 1.05 { break }
                }
            }
            chosen = best?.levels ?? [:]
        }

        var reductions: [UntoldMeshReduction] = []
        for (index, model) in models.enumerated() {
            let output = outputs[index]
            func unchanged(_ reason: UntoldMeshReduction.SkipReason) throws -> UntoldMeshReduction {
                if output.standardizedFileURL != model.url.standardizedFileURL {
                    do {
                        try model.fileData.write(to: output, options: .atomic)
                    } catch {
                        throw UntoldMeshLODError.writeFailed(path: output.path, reason: String(describing: error))
                    }
                }
                return UntoldMeshReduction(url: output, triangleCount: model.triangleCount, reducedTriangleCount: model.triangleCount, error: 0, skipped: reason)
            }
            if let reason = model.skipped {
                reductions.append(try unchanged(reason))
                continue
            }
            guard let levels = chosen[index] else {
                reductions.append(try unchanged(.withinTarget))
                continue
            }
            let reduced = levels.reduce(0) { $0 + $1.triangleCount }
            guard levels.count == model.meshes.count,
                  Float(reduced) <= Float(model.triangleCount) * UntoldMeshLODOptions.worthwhileReduction
            else {
                reductions.append(try unchanged(.irreducible))
                continue
            }
            do {
                let file = try UntoldMeshLODWriter.levelFile(source: model.decoded, sourceData: model.fileData, levels: levels, markAsLevel: false)
                try file.write(to: output, options: .atomic)
            } catch {
                throw UntoldMeshLODError.writeFailed(path: output.path, reason: String(describing: error))
            }
            try UntoldMeshLODCooker.removeLevels(ofModelAt: output)
            reductions.append(UntoldMeshReduction(
                url: output,
                triangleCount: model.triangleCount,
                reducedTriangleCount: reduced,
                error: zip(levels, model.scales).map { $0.error * $1 }.max() ?? 0,
                skipped: nil
            ))
        }
        return reductions
    }
}
