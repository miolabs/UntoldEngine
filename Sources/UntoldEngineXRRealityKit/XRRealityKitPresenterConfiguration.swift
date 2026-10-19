//
//  XRRealityKitPresenterConfiguration.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// How the RealityKit presenter renders and shows the engine's frame: the size of each eye's
/// textures, the grids each eye is shown on, the eyes' frustum and distance, the lead the frame
/// is posed ahead of its ticket, and the depth rules of the grids.
public struct XRRealityKitPresenterConfiguration: Sendable, Equatable {
    /// Pixels per eye: the headset's per-eye drawable size by default (the plan's D5).
    public var textureSize = SIMD2<Int>(1920, 1824)
    /// Vertices per row, and rows, of each eye's grid (uniform; a foveated grid is the map's).
    public var gridColumns = 256
    public var gridRows = 240
    /// Whether each eye is drawn through the presenter's own rasterization rate map, fixed and
    /// head-centred (RealityKit gives no gaze). `textureSize` is then the budget of PHYSICAL
    /// pixels per eye, which the map never exceeds; the eye's screen is larger by the profile,
    /// so the centre of view is denser than a uniform frame of the same pixel count; and the
    /// grid is made from the physical size in cells of `foveatedCellTexels` (`gridColumns` and
    /// `gridRows` are not used). None by default, until the headset has judged it against the
    /// uniform frame.
    public var foveation: XRPresenterFoveationProfile = .none
    /// The side of a grid cell in physical texels when foveated. The map's mapping of texels to
    /// the screen changes slope at its tile boundaries (`physicalGranularity`, 32 on Apple
    /// GPUs), so a cell that divides the tile puts a vertex on every boundary and the grid
    /// interpolates the map exactly within each cell; the presenter halves this once if it does
    /// not divide, and draws uniformly if that does not either.
    public var foveatedCellTexels = 8
    /// Tangents of the half angles of each eye's frustum: left, right, up, down, all positive. A
    /// few degrees wider than the headset's view, so that a head turn between the frame's pose
    /// and its display still finds pixels at the edges.
    public var frustumTangents = SIMD4<Float>(1.30, 1.30, 1.15, 1.30)
    /// The distance between the eyes, metres. RealityKit tells the presenter nothing of the
    /// eyes' places, so they sit a nominal half distance to each side of the device.
    public var interpupillaryDistance: Float = 0.063
    /// Seconds the frame is posed ahead of the moment its ticket is taken: an estimate of when
    /// RealityKit shows it (two refresh periods at 90 Hz), the fixed lead. With `adaptiveLead`
    /// the lead is measured instead and this is what it falls back on until a frame has
    /// completed (`XRPresenterLead`).
    public var leadSeconds: TimeInterval = 2.0 / 90.0
    /// Whether the frame's lead follows the measured latency instead of `leadSeconds`: the
    /// ticket's age at pickup, plus the engine's frame (from the pickup to the ticket's command
    /// buffer completing on the GPU, averaged over the last frames), plus
    /// `displayLatencySeconds`. Off by default until the headset has judged it against the
    /// fixed lead; both are there at run time through `XRPresenterSettings`.
    public var adaptiveLead = false
    /// Seconds from a frame's command buffer completing to its display, the part of the
    /// adaptive lead only the headset can calibrate: RealityKit noticing the replace, its own
    /// frame and the compositor's. 16 ms to start: the fixed lead (22.2 ms) less the frame's
    /// measured latency on the headset in Release (2026-10-19: age 0.03 ms, CPU 2.8 ms, GPU
    /// 3.6 ms), rounded, so that the two leads agree at those numbers. Calibrate on the
    /// headset with the adaptive lead on: a head-locked marker that lags a head turn wants a
    /// longer latency, one that leads wants a shorter.
    public var displayLatencySeconds: TimeInterval = 0.016
    /// The near plane of the eyes' projection, metres.
    public var nearPlane: Float = 0.05
    /// The far plane of the eyes' projection, metres: depth 0 under reverse Z.
    public var farPlane: Float = 1000
    /// Where grid vertices that see nothing (the sky, passthrough) are placed: a shell this far
    /// from the eye, so that those areas keep a surface for the material to discard or show.
    public var farShellMetres: Float = 100
    /// A difference in view distance between neighbouring grid vertices above this, metres, is a
    /// tear: a silhouette the grid stretches across. The vertices on its two sides are marked
    /// (far side, near side) and the material discards the triangles that span both.
    public var tearThresholdMetres: Float = 0.5
    /// How far, in texels of the eye texture, a grid vertex at an object's rim is pushed outward
    /// past the edge texel it was placed on, so that the silhouette seen is where the filtered
    /// texture's alpha crosses the material's threshold rather than the mesh boundary through
    /// rim texels (which is quantised to the texel and flips with the predicted pose); 0 for none.
    public var skirtTexels: Float = 3
    /// Whether each cell's diagonal follows the depth each frame (the fixed one unless it crosses
    /// a depth jump and the other does not), with the index buffer rewritten per frame. Off by
    /// default until the headset has judged it against the fixed split with the skirt; both are
    /// there at run time through `XRPresenterSettings`.
    public var adaptiveDiagonal = false
    /// Whether a second entity per eye draws the grid again with the blended edge-band material
    /// over the opaque core, so that a silhouette's partly covered texels blend over the room
    /// instead of being cut by the alpha test at a texel boundary. Needs coverage in the frame's
    /// alpha: the engine's MSAA modes leave it, FXAA and SMAA do not.
    public var edgeBlending = true
    /// The radius of the sphere around the user that takes the gaze for pinches, metres.
    public var inputTargetRadius: Float = 50
    /// An offset of both eyes' viewpoints on the device, metres, zero in use: a deliberate
    /// offset (a few centimetres up) makes RealityKit show the grids from a point the engine did
    /// not draw them from, so a silhouette defect that changes with it comes from a vertex at a
    /// wrong depth, and one that does not from the texture or its mapping.
    public var viewOffsetMetres = SIMD3<Float>(0, 0, 0)

    public init() {}

    /// `textureSize` as floats: the uniform eye's size, or the foveated eye's pixel budget (the
    /// presenter's `textureSize` is the size its textures were made at).
    public var eyeSize: simd_float2 { simd_float2(Float(textureSize.x), Float(textureSize.y)) }

    /// The eyes' projection for the configured frustum: right-handed, reverse Z (the near plane
    /// at depth 1, the far plane at 0), asymmetric when the tangents differ.
    public var projection: simd_float4x4 {
        XRPresenterProjection.reverseZ(tangents: frustumTangents, near: nearPlane, far: farPlane)
    }

    /// Where an eye sits on the device: half the eye distance to its side (0 left, 1 right).
    public func deviceFromView(eye: Int) -> simd_float4x4 {
        let x = eye == 0 ? -interpupillaryDistance / 2 : interpupillaryDistance / 2
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x + viewOffsetMetres.x, viewOffsetMetres.y, viewOffsetMetres.z, 1)
        return transform
    }
}

public enum XRPresenterProjection {
    /// A right-handed perspective projection from the tangents of the half angles (left, right,
    /// up, down), reverse Z: the near plane maps to depth 1 and the far plane to 0, as the
    /// engine's own helpers and the compositor's drawables do.
    public static func reverseZ(tangents: SIMD4<Float>, near: Float, far: Float) -> simd_float4x4 {
        let width = tangents.x + tangents.y
        let height = tangents.z + tangents.w
        let zs = near / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>((tangents.y - tangents.x) / width, (tangents.z - tangents.w) / height, zs, -1),
            SIMD4<Float>(0, 0, zs * far, 0)
        ))
    }
}

/// The density profile of the presenter's rasterization rate map (`XRPresenterFoveation`).
public enum XRPresenterFoveationProfile: String, Sendable, Equatable, CaseIterable {
    /// No map: uniform pixels over the frustum's tangent plane, which are sparsest at the
    /// centre of view.
    case none
    /// Texels uniform in angle: the rate at a screen position whose tangent is x is 1 / (1 + x²)
    /// along each axis, the derivative of the angle in the tangent, so the texels per degree
    /// are the same at the centre and at the edges; the centre of view gains what the periphery
    /// gives up.
    case equiAngular
}
