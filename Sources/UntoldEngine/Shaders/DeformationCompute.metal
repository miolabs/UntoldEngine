//
//  DeformationCompute.metal
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <metal_stdlib>
#include "../../CShaderTypes/ShaderTypes.h"
using namespace metal;

// Linear blend skinning in compute. Writes deformed position/normal/tangent
// streams consumed by the render passes with skinning disabled, so every pass
// (G-buffer, shadows, transparency, wireframe) sees identical geometry.
//
// Normals use the cofactor matrix (equivalent to inverse-transpose up to a
// uniform factor removed by normalization), which stays correct under
// non-uniform joint scale — unlike the legacy vertex-shader path.
kernel void deformSkinLBS(
    const device simd_float4 *inPositions [[buffer(deformationPassInPositionIndex)]],
    const device simd_float4 *inNormals [[buffer(deformationPassInNormalIndex)]],
    const device simd_float4 *inTangents [[buffer(deformationPassInTangentIndex)]],
    const device ushort4 *jointIndices [[buffer(deformationPassJointIdIndex)]],
    const device simd_float4 *jointWeights [[buffer(deformationPassJointWeightsIndex)]],
    const device simd_float4x4 *jointMatrices [[buffer(deformationPassJointTransformIndex)]],
    device simd_float4 *outPositions [[buffer(deformationPassOutPositionIndex)]],
    device simd_float4 *outNormals [[buffer(deformationPassOutNormalIndex)]],
    device simd_float4 *outTangents [[buffer(deformationPassOutTangentIndex)]],
    constant DeformationPassParams &params [[buffer(deformationPassParamsIndex)]],
    uint vid [[thread_position_in_grid]])
{
    if (vid >= params.vertexCount) {
        return;
    }

    simd_float4 position = inPositions[vid];
    simd_float4 normal = inNormals[vid];
    simd_float4 tangent = inTangents[vid];

    ushort4 joints = jointIndices[vid];
    simd_float4 weights = jointWeights[vid];
    float weightSum = weights.x + weights.y + weights.z + weights.w;

    if (weightSum <= 0.0001f) {
        outPositions[vid] = position;
        outNormals[vid] = normal;
        outTangents[vid] = tangent;
        return;
    }

    simd_float4x4 skinMatrix =
        weights.x * jointMatrices[joints.x] +
        weights.y * jointMatrices[joints.y] +
        weights.z * jointMatrices[joints.z] +
        weights.w * jointMatrices[joints.w];

    float3x3 skinRotation = float3x3(
        skinMatrix.columns[0].xyz,
        skinMatrix.columns[1].xyz,
        skinMatrix.columns[2].xyz
    );
    float3x3 cofactor = float3x3(
        cross(skinRotation[1], skinRotation[2]),
        cross(skinRotation[2], skinRotation[0]),
        cross(skinRotation[0], skinRotation[1])
    );

    float3 skinnedNormal = cofactor * normal.xyz;
    float normalLength = length(skinnedNormal);
    if (normalLength > 0.0f) {
        skinnedNormal /= normalLength;
    }

    float3 skinnedTangent = skinRotation * tangent.xyz;
    float tangentLength = length(skinnedTangent);
    if (tangentLength > 0.0f) {
        skinnedTangent /= tangentLength;
    }

    outPositions[vid] = simd_float4(
        (skinMatrix * simd_float4(position.xyz, 1.0f)).xyz, position.w
    );
    outNormals[vid] = simd_float4(skinnedNormal, normal.w);
    outTangents[vid] = simd_float4(skinnedTangent, tangent.w);
}
