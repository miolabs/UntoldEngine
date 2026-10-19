//
//  XRPresenterFoveation.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import simd
import UntoldEngine

/// The presenter's own rasterization rate map: one for both eyes and every frame, made once
/// with the presenter. RealityKit gives no gaze, so the map is fixed and head-centred; what it
/// buys is density where the eye mostly looks. A uniform frame spends its pixels evenly over
/// the frustum's TANGENT plane, which is sparsest at the centre of view (12.9 texels per degree
/// for 1920 pixels over 2.6 of tangent, against a display of some 34); drawn through the map
/// with the equi-angular profile, the same number of physical pixels are spread evenly in
/// ANGLE, so the centre gains a third and the periphery, where RealityKit's resampling of the
/// texture matters least, gives it up. The engine's GPU cost is unchanged: the textures are
/// the map's physical size, which never exceeds the configuration's `textureSize`.
///
/// How the eye is drawn: the engine's scene passes attach the map and set their viewport to the
/// map's screen (`XREye.foveation`, which the frame loop hands the renderer as
/// `renderInfo.xrFoveation`); the passes after them, and the final one into the eye's
/// texture, copy physical pixels one to one. The grid is then uniform in PHYSICAL texels, a
/// vertex every `cellTexels`, and the unprojection kernel finds each texel's ray through the
/// map's decoder (`rasterization_rate_map_decoder`), so the grid is dense where the texture
/// is. The cell divides the map's tile (`physicalGranularity`), at whose boundaries the map's
/// mapping of texels to the screen changes slope, so the grid interpolates that mapping
/// exactly within each cell and the texture is shown where the engine drew it.
///
/// Metal rounds rates UP toward quality and pads to its tiles, so a screen scaled by the
/// profile's ideal ratio would come out with more physical pixels than the budget; the screen
/// is scaled down, axis by axis, until the physical size fits.
///
/// Under a render scale (`XRRealityKitPresenterConfiguration.renderScale`) the budget is the
/// scaled texture size, so the screen grows with it and the centre of view gains the same
/// factor; the grid's cell scales with it too, snapped to a divisor of the tile, so that the
/// grid keeps about its vertex count instead of growing with the texels.
public final class XRPresenterFoveation: @unchecked Sendable, CustomStringConvertible {
    public let profile: XRPresenterFoveationProfile
    /// The map, its viewport (the whole screen) and its parameters: what each eye carries into
    /// the frame loop, which attaches the map to the scene passes.
    public let frame: XRFoveationFrame
    /// The map's screen in pixels: the space the eyes' viewports and clip space live in.
    public let screenSize: SIMD2<Int>
    /// The size of the textures drawn through the map: the pixel budget, or less.
    public let physicalSize: SIMD2<Int>
    /// The pixel budget the map was fitted to (the configuration's `renderedTextureSize`:
    /// its `textureSize` times its render scale).
    public let budget: SIMD2<Int>
    /// The map's tile in physical pixels, at whose boundaries its rate changes.
    public let granularity: SIMD2<Int>
    /// The grid's cell in physical texels: divides the granularity.
    public let cellTexels: Int
    /// The rate samples per axis the map was made from.
    public let sampleCount: Int

    public var rateMap: MTLRasterizationRateMap { frame.rateMap }

    public var rateMapData: XRRasterizationRateMapData { frame.rateMapData }

    /// The screen over the budget, per axis: how much denser the centre of view is drawn than
    /// the uniform frame of the same pixel count (the rate there is 1).
    public var screenScale: SIMD2<Float> {
        SIMD2<Float>(Float(screenSize.x) / Float(budget.x), Float(screenSize.y) / Float(budget.y))
    }

    /// Texels per degree at the centre of view, horizontally: the centre is drawn at the
    /// screen's density (a texel there is a screen pixel), so the screen's width over the
    /// frustum's width in tangent, as texels per radian. 17.6 for the default budget on an
    /// Apple GPU, against 12.9 uniform.
    public func centreTexelsPerDegree(tangents: SIMD4<Float>) -> Float {
        XRRealityKitPresenterConfiguration.centreTexelsPerDegree(width: screenSize.x, tangents: tangents)
    }

    /// The grid for the physical size: a vertex every `cellTexels` along each axis, the last on
    /// the last texel.
    public var grid: XRPresenterGrid {
        XRPresenterGrid(
            columns: Self.vertexCount(over: physicalSize.x, cell: cellTexels),
            rows: Self.vertexCount(over: physicalSize.y, cell: cellTexels)
        )
    }

    public var description: String {
        let scale = screenScale
        return "\(profile.rawValue) rate map, screen \(screenSize.x)×\(screenSize.y), textures \(physicalSize.x)×\(physicalSize.y) (budget \(budget.x)×\(budget.y)), \(sampleCount) samples per axis, granularity \(granularity.x)×\(granularity.y), cells of \(cellTexels) texels, grid \(grid.columns)×\(grid.rows), centre \(String(format: "%.2f×%.2f", scale.x, scale.y)) denser"
    }

    init(profile: XRPresenterFoveationProfile, frame: XRFoveationFrame, budget: SIMD2<Int>, granularity: SIMD2<Int>, cellTexels: Int, sampleCount: Int) {
        self.profile = profile
        self.frame = frame
        self.budget = budget
        self.granularity = granularity
        self.cellTexels = cellTexels
        self.sampleCount = sampleCount
        let screen = frame.rateMap.screenSize
        let physical = frame.rateMap.physicalSize(layer: 0)
        screenSize = SIMD2<Int>(screen.width, screen.height)
        physicalSize = SIMD2<Int>(physical.width, physical.height)
    }

    /// Vertices along an axis of `texels` in cells of `cell`: one per cell boundary, and one on
    /// the last texel when the cells do not divide the texels.
    static func vertexCount(over texels: Int, cell: Int) -> Int {
        (texels + cell - 1) / cell + 1
    }

    /// The rates of `profile` along one axis, `samples` of them from the frustum's edge at
    /// tangent `-negative` to its edge at `+positive`, each at the centre of its span of the
    /// screen (the screen is linear in the tangent). The equi-angular profile is 1 / (1 + x²):
    /// 1 at the centre of view, 0.37 at a tangent of 1.3.
    public static func rates(of profile: XRPresenterFoveationProfile, from negative: Float, to positive: Float, samples: Int) -> [Float] {
        (0 ..< samples).map { sample in
            let x = -negative + (Float(sample) + 0.5) / Float(samples) * (negative + positive)
            switch profile {
            case .none: return 1
            case .equiAngular: return 1 / (1 + x * x)
            }
        }
    }

    /// The grid's cell in physical texels for `configuration` on a map whose tile is
    /// `granularity`: `foveatedCellTexels` times the render scale, rounded, taken as it is when
    /// it divides the tile along both axes, else the divisor of the tile nearest to it in ratio
    /// (2 at least: the granularity's divisors are a short list, powers of two on Apple GPUs).
    /// Nil when the tile has no divisor of 2 or more.
    public static func cellTexels(for configuration: XRRealityKitPresenterConfiguration, granularity: SIMD2<Int>) -> Int? {
        guard granularity.x > 0, granularity.y > 0 else { return nil }
        let preferred = max(1, Int((Float(max(1, configuration.foveatedCellTexels)) * configuration.clampedRenderScale).rounded()))
        if preferred >= 2, granularity.x % preferred == 0, granularity.y % preferred == 0 { return preferred }
        let divisors = (2 ... max(2, min(granularity.x, granularity.y))).filter { granularity.x % $0 == 0 && granularity.y % $0 == 0 }
        return divisors.min { a, b in
            let ratioA = abs(log(Float(a)) - log(Float(preferred)))
            let ratioB = abs(log(Float(b)) - log(Float(preferred)))
            return ratioA == ratioB ? a > b : ratioA < ratioB
        }
    }

    /// The map for `configuration` on `device`, or nil when the configuration asks for none,
    /// the device has no rasterization rate maps, Metal refuses the map, or no cell of two
    /// texels or more divides the map's granularity: the presenter then draws uniformly, as it
    /// did before, and says so. The budget is the configuration's rendered texture size.
    public static func make(device: MTLDevice, configuration: XRRealityKitPresenterConfiguration) -> XRPresenterFoveation? {
        let profile = configuration.foveation
        guard profile != .none else { return nil }
        guard device.supportsRasterizationRateMap(layerCount: 1) else {
            Logger.logWarning(message: "XR presenter: this GPU has no rasterization rate maps; the eyes are drawn uniformly")
            return nil
        }
        let budget = configuration.renderedTextureSize
        let tangents = configuration.frustumTangents
        guard budget.x > 0, budget.y > 0, tangents.min() > 0 else { return nil }

        // The ideal screen: the budget over the profile's mean rate per axis, so that the
        // physical size would be the budget if Metal took the rates as given. It rounds them up
        // and pads to its tiles, so the screen is shrunk, axis by axis, until the physical size
        // fits; the budget itself always fits (every rate is at most 1).
        var samples = 64
        var horizontal = rates(of: profile, from: tangents.x, to: tangents.y, samples: samples)
        var vertical = rates(of: profile, from: tangents.z, to: tangents.w, samples: samples)
        var scale = SIMD2<Float>(
            1 / max(horizontal.reduce(0, +) / Float(samples), 1e-3),
            1 / max(vertical.reduce(0, +) / Float(samples), 1e-3)
        )
        var rateMap: MTLRasterizationRateMap?
        for _ in 0 ..< 48 {
            let screen = SIMD2<Int>(
                max(budget.x, Int((Float(budget.x) * scale.x).rounded())),
                max(budget.y, Int((Float(budget.y) * scale.y).rounded()))
            )
            let descriptor = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: screen.x, height: screen.y, depth: 1))
            let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: samples, height: samples, depth: 1))
            for (index, rate) in horizontal.enumerated() { layer.horizontal[index] = rate }
            for (index, rate) in vertical.enumerated() { layer.vertical[index] = rate }
            descriptor.setLayer(layer, at: 0)
            descriptor.label = "XR presenter \(profile.rawValue) rate map"
            guard let candidate = device.makeRasterizationRateMap(descriptor: descriptor) else {
                // Too many samples for this device: half as many, the same profile.
                samples /= 2
                guard samples >= 2 else { break }
                horizontal = rates(of: profile, from: tangents.x, to: tangents.y, samples: samples)
                vertical = rates(of: profile, from: tangents.z, to: tangents.w, samples: samples)
                continue
            }
            let physical = candidate.physicalSize(layer: 0)
            if physical.width <= budget.x, physical.height <= budget.y {
                rateMap = candidate
                break
            }
            if physical.width > budget.x { scale.x *= min(Float(budget.x) / Float(physical.width), 0.998) }
            if physical.height > budget.y { scale.y *= min(Float(budget.y) / Float(physical.height), 0.998) }
        }
        guard let rateMap else {
            Logger.logWarning(message: "XR presenter: Metal made no rasterization rate map within \(budget.x)×\(budget.y) pixels; the eyes are drawn uniformly")
            return nil
        }

        // The grid's cell: the configured one at the render scale, or the tile's divisor
        // nearest to it.
        let granularity = SIMD2<Int>(rateMap.physicalGranularity.width, rateMap.physicalGranularity.height)
        guard let cell = cellTexels(for: configuration, granularity: granularity) else {
            Logger.logWarning(message: "XR presenter: no grid cell of two texels or more divides the rate map's granularity \(granularity.x)×\(granularity.y); the eyes are drawn uniformly")
            return nil
        }

        // The map's parameters for the kernels, copied once: the map never changes.
        let sizeAndAlign = rateMap.parameterDataSizeAndAlign
        let align = max(1, sizeAndAlign.align)
        let length = max(16, (sizeAndAlign.size + align - 1) / align * align)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let data = XRRasterizationRateMapData(rateMap: rateMap, buffer: buffer)
        else {
            Logger.logWarning(message: "XR presenter: the rate map's parameters could not be copied; the eyes are drawn uniformly")
            return nil
        }
        buffer.label = "XR presenter rate map parameters"
        let screen = rateMap.screenSize
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1)
        let foveation = XRPresenterFoveation(
            profile: profile,
            frame: XRFoveationFrame(rateMap: rateMap, viewport: viewport, rateMapData: data),
            budget: budget,
            granularity: granularity,
            cellTexels: cell,
            sampleCount: samples
        )
        print("✓ XR presenter foveation: \(foveation)")
        return foveation
    }
}
