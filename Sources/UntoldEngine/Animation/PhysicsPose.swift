//
//  PhysicsPose.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

// Physics pose: a pose handed in from outside the animation pipeline — a
// ragdoll, a physics-driven arm, a hit reaction simulated by a physics
// plugin — blended into the displayed pose per joint by a weight. The
// plugin reads the skeleton (`getSkeletonJointInfo`) once to build its
// rig, reads the displayed joint transforms (`getJointModelTransforms`)
// to drive or seed its bodies, and hands a model-space pose back
// (`setPhysicsPose`) that the next animation update blends in. Runs last,
// after foot IK, so every animated stage has had its say and the physics
// result is what lands on the skin. See docs/API/UsingPhysicsPose.md.

/// The joints of an entity's skeleton, for building a physics rig that maps
/// onto it.
public struct SkeletonJointInfo: Sendable {
    /// Skeleton joint order (parents before children).
    public let jointPaths: [String]
    /// nil for a parentless joint.
    public let parentIndices: [Int?]
    /// Model-space bind pose, one per joint.
    public let bindModelTransforms: [simd_float4x4]

    /// The engine builds these from an entity's skeleton; a game builds one
    /// only to describe a skeleton of its own (tests, offline tools).
    public init(jointPaths: [String], parentIndices: [Int?], bindModelTransforms: [simd_float4x4]) {
        self.jointPaths = jointPaths
        self.parentIndices = parentIndices
        self.bindModelTransforms = bindModelTransforms
    }
}

/// Per-entity physics pose state: the pose last handed in and the scratch
/// the blend composes it against.
struct PhysicsPoseState {
    var isActive = false
    /// Model-space target per joint, as the plugin gave it.
    var modelTransforms: [simd_float4x4] = []
    /// Blend weight per joint, 0…1.
    var weights: [Float] = []

    /// Model-space forward kinematics of the pose as blended so far, walked
    /// alongside the joints; reused across frames so the stage never
    /// allocates in steady state.
    var positions: [simd_float3] = []
    var rotations: [simd_quatf] = []

    mutating func clear() {
        isActive = false
        modelTransforms = []
        weights = []
    }
}

/// Blends the physics pose into `animationComponent.localPose`, joint by
/// joint in skeleton order, against forward kinematics of the pose as
/// modified so far — so a joint under a physics-driven parent is measured
/// relative to where physics put that parent, not where the clip did.
///
/// A weighted joint slerps its local rotation toward the physics rotation.
/// It also lerps its local translation toward the physics translation when
/// it is the top of a physics-driven subtree (no parent, or a parent at
/// weight 0); below that, joints keep their animated bone offsets, so a
/// rig whose bodies drift apart never stretches the skin. Joints at weight
/// 0 keep their animated local transform relative to their (possibly
/// physics-driven) parent.
///
/// Rest scale is ignored here, as in the IK stages: the composition is
/// rigid, and the skeleton folds the rest scale back in when it builds
/// the skin matrices.
func applyPhysicsPose(
    entityId _: EntityID,
    animationComponent: AnimationComponent,
    skeleton: Skeleton
) {
    guard animationComponent.physicsPose.isActive else { return }

    let jointCount = skeleton.jointPaths.count
    guard animationComponent.localPose.jointCount == jointCount,
          animationComponent.physicsPose.modelTransforms.count == jointCount,
          animationComponent.physicsPose.weights.count == jointCount
    else { return }

    if animationComponent.physicsPose.positions.count != jointCount {
        animationComponent.physicsPose.positions = [simd_float3](repeating: .zero, count: jointCount)
        animationComponent.physicsPose.rotations = [simd_quatf](
            repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: jointCount
        )
    }

    let parentIndices = skeleton.parentIndices
    let weights = animationComponent.physicsPose.weights
    let modelTransforms = animationComponent.physicsPose.modelTransforms

    for index in 0 ..< jointCount {
        let parentIndex = parentIndices[index]
        let parentPosition = parentIndex.map { animationComponent.physicsPose.positions[$0] } ?? .zero
        let parentRotation = parentIndex.map { animationComponent.physicsPose.rotations[$0] }
            ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        let weight = weights[index]
        if weight > 0 {
            // The physics target, taken into the parent's blended frame.
            let target = modelTransforms[index]
            let targetModelPosition = simd_float3(target.columns.3.x, target.columns.3.y, target.columns.3.z)
            let targetModelRotation = AnimationClip.localRotation(
                from: target, scale: AnimationClip.localScale(from: target)
            )
            let inverseParentRotation = parentRotation.inverse
            let targetLocalRotation = simd_normalize(inverseParentRotation * targetModelRotation)

            animationComponent.localPose.rotations[index] = simd_normalize(
                simd_slerp(animationComponent.localPose.rotations[index], targetLocalRotation, weight)
            )

            let parentIsAnimated = parentIndex.map { weights[$0] <= 0 } ?? true
            if parentIsAnimated {
                let targetLocalPosition = inverseParentRotation.act(targetModelPosition - parentPosition)
                animationComponent.localPose.translations[index] = simd_mix(
                    animationComponent.localPose.translations[index], targetLocalPosition, simd_float3(repeating: weight)
                )
            }
        }

        animationComponent.physicsPose.positions[index] = parentPosition
            + parentRotation.act(animationComponent.localPose.translations[index])
        animationComponent.physicsPose.rotations[index] = simd_normalize(
            parentRotation * animationComponent.localPose.rotations[index]
        )
    }
}
