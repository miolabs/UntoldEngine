//
//  XRPresenterInput.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RealityKit
import simd

/// The gaze's target for pinches. A compositor layer receives every spatial event of its space;
/// a `RealityView` only those aimed at an entity that takes input, so the presenter surrounds
/// the user with one: a sphere turned inside out as a static collision mesh, with an input
/// target component and no model, that every gaze lands on when it lands on nothing else.
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
public enum XRPresenterInput {
    /// The input entity, `radius` metres around the origin.
    @MainActor
    public static func makeTargetEntity(radius: Float) async throws -> Entity {
        let sphere = invertedSphere(radius: radius, segments: 24, rings: 12)
        let shape = try await ShapeResource.generateStaticMesh(positions: sphere.positions, faceIndices: sphere.indices)
        let entity = Entity()
        entity.name = "Untold XR input target"
        entity.components.set(InputTargetComponent())
        entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
        return entity
    }

    /// A UV sphere whose triangles face inward, for a collider met from inside.
    public static func invertedSphere(radius: Float, segments: Int, rings: Int) -> (positions: [SIMD3<Float>], indices: [UInt16]) {
        var positions: [SIMD3<Float>] = []
        for ring in 0 ... rings {
            let phi = Float.pi * Float(ring) / Float(rings)
            let y = cos(phi) * radius
            let r = sin(phi) * radius
            for segment in 0 ... segments {
                let theta = 2 * Float.pi * Float(segment) / Float(segments)
                positions.append(SIMD3<Float>(r * cos(theta), y, r * sin(theta)))
            }
        }
        var indices: [UInt16] = []
        let stride = segments + 1
        for ring in 0 ..< rings {
            for segment in 0 ..< segments {
                let a = UInt16(ring * stride + segment)
                let b = a + 1
                let c = a + UInt16(stride)
                let d = c + 1
                // Clockwise from outside, so counter-clockwise from inside.
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return (positions, indices)
    }
}
