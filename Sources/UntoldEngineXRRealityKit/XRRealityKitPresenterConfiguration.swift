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
    /// Vertices per row, and rows, of each eye's grid.
    public var gridColumns = 256
    public var gridRows = 240
    /// Tangents of the half angles of each eye's frustum: left, right, up, down, all positive. A
    /// few degrees wider than the headset's view, so that a head turn between the frame's pose
    /// and its display still finds pixels at the edges.
    public var frustumTangents = SIMD4<Float>(1.30, 1.30, 1.15, 1.30)
    /// The distance between the eyes, metres. RealityKit tells the presenter nothing of the
    /// eyes' places, so they sit a nominal half distance to each side of the device.
    public var interpupillaryDistance: Float = 0.063
    /// Seconds the frame is posed ahead of the moment its ticket is taken: an estimate of when
    /// RealityKit shows it (two refresh periods at 90 Hz to start; stage 3 makes it adaptive).
    public var leadSeconds: TimeInterval = 2.0 / 90.0
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
    /// The radius of the sphere around the user that takes the gaze for pinches, metres.
    public var inputTargetRadius: Float = 50

    public init() {}

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
        transform.columns.3 = SIMD4<Float>(x, 0, 0, 1)
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
