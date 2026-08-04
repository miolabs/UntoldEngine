//
//  DeformationComputeTests.swift
//  UntoldEngineTests
//
//  Headless parity tests for the deformation compute kernels.
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import Metal
import simd
@testable import UntoldEngine
import XCTest

final class DeformationComputeTests: XCTestCase {
    /// deformSkinLBS must reproduce CPU linear blend skinning: blended joint
    /// matrix on positions, cofactor (inverse-transpose) on normals, rotation
    /// on tangents — within float tolerance.
    func testSkinLBSMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        guard let library = try device.makeLibraryFromBundle() else {
            throw XCTSkip("Engine metallib unavailable")
        }
        guard let function = library.makeFunction(name: "deformSkinLBS") else {
            return XCTFail("deformSkinLBS missing from engine metallib — regenerate via buildkernels.sh")
        }
        let pipeline = try device.makeComputePipelineState(function: function)

        // Synthetic skinned mesh: a vertex strip influenced by four rigid joints.
        let vertexCount = 1024
        let jointCount = 4

        var jointMatrices: [simd_float4x4] = []
        for jointIndex in 0 ..< jointCount {
            let angle = Float(jointIndex) * 0.35 + 0.2
            let axis = simd_normalize(simd_float3(0.2, 1.0, Float(jointIndex) * 0.1 - 0.15))
            let rotation = simd_float4x4(simd_quatf(angle: angle, axis: axis))
            var matrix = rotation
            matrix.columns.3 = simd_float4(
                Float(jointIndex) * 0.5 - 0.75, Float(jointIndex) * -0.25, 0.3, 1.0
            )
            jointMatrices.append(matrix)
        }

        var positions: [simd_float4] = []
        var normals: [simd_float4] = []
        var tangents: [simd_float4] = []
        var jointIndices: [simd_ushort4] = []
        var jointWeights: [simd_float4] = []

        var seed: UInt64 = 0x5DEF_02F4
        func nextUnitFloat() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }

        for vertexIndex in 0 ..< vertexCount {
            positions.append(simd_float4(
                nextUnitFloat() * 2 - 1, nextUnitFloat() * 2 - 1, nextUnitFloat() * 2 - 1, 1
            ))
            let normal = simd_normalize(simd_float3(
                nextUnitFloat() * 2 - 1, nextUnitFloat() * 2 - 1, nextUnitFloat() * 2 - 1
            ))
            normals.append(simd_float4(normal, 0))
            let tangent = simd_normalize(simd_cross(normal, simd_float3(0, 1, 0.2)))
            tangents.append(simd_float4(tangent, vertexIndex % 2 == 0 ? 1 : -1))

            let joint0 = UInt16(vertexIndex % jointCount)
            let joint1 = UInt16((vertexIndex + 1) % jointCount)
            jointIndices.append(simd_ushort4(joint0, joint1, 0, 0))
            let weight0 = 0.25 + 0.5 * nextUnitFloat()
            jointWeights.append(simd_float4(weight0, 1 - weight0, 0, 0))
        }
        // Exercise the zero-weight passthrough branch too.
        jointWeights[0] = simd_float4(repeating: 0)

        func makeBuffer(_ data: [some Any]) throws -> MTLBuffer {
            try data.withUnsafeBytes { bytes in
                try XCTUnwrap(device.makeBuffer(
                    bytes: bytes.baseAddress!,
                    length: bytes.count,
                    options: .storageModeShared
                ))
            }
        }

        let inPositions = try makeBuffer(positions)
        let inNormals = try makeBuffer(normals)
        let inTangents = try makeBuffer(tangents)
        let inJointIndices = try makeBuffer(jointIndices)
        let inJointWeights = try makeBuffer(jointWeights)
        let inJointMatrices = try makeBuffer(jointMatrices)
        let outLength = vertexCount * MemoryLayout<simd_float4>.stride
        let outPositions = try XCTUnwrap(device.makeBuffer(length: outLength, options: .storageModeShared))
        let outNormals = try XCTUnwrap(device.makeBuffer(length: outLength, options: .storageModeShared))
        let outTangents = try XCTUnwrap(device.makeBuffer(length: outLength, options: .storageModeShared))

        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inPositions, offset: 0, index: Int(deformationPassInPositionIndex.rawValue))
        encoder.setBuffer(inNormals, offset: 0, index: Int(deformationPassInNormalIndex.rawValue))
        encoder.setBuffer(inTangents, offset: 0, index: Int(deformationPassInTangentIndex.rawValue))
        encoder.setBuffer(inJointIndices, offset: 0, index: Int(deformationPassJointIdIndex.rawValue))
        encoder.setBuffer(inJointWeights, offset: 0, index: Int(deformationPassJointWeightsIndex.rawValue))
        encoder.setBuffer(inJointMatrices, offset: 0, index: Int(deformationPassJointTransformIndex.rawValue))
        encoder.setBuffer(outPositions, offset: 0, index: Int(deformationPassOutPositionIndex.rawValue))
        encoder.setBuffer(outNormals, offset: 0, index: Int(deformationPassOutNormalIndex.rawValue))
        encoder.setBuffer(outTangents, offset: 0, index: Int(deformationPassOutTangentIndex.rawValue))
        var params = DeformationPassParams(vertexCount: UInt32(vertexCount))
        encoder.setBytes(
            &params,
            length: MemoryLayout<DeformationPassParams>.stride,
            index: Int(deformationPassParamsIndex.rawValue)
        )
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreadgroups(
            MTLSize(width: (vertexCount + width - 1) / width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        let gpuPositions = outPositions.contents().bindMemory(to: simd_float4.self, capacity: vertexCount)
        let gpuNormals = outNormals.contents().bindMemory(to: simd_float4.self, capacity: vertexCount)
        let gpuTangents = outTangents.contents().bindMemory(to: simd_float4.self, capacity: vertexCount)

        var maxPositionError: Float = 0
        var maxNormalError: Float = 0
        var maxTangentError: Float = 0

        for vertexIndex in 0 ..< vertexCount {
            let weights = jointWeights[vertexIndex]
            let joints = jointIndices[vertexIndex]

            var expectedPosition = positions[vertexIndex]
            var expectedNormal = normals[vertexIndex]
            var expectedTangent = tangents[vertexIndex]

            let weightSum = weights.x + weights.y + weights.z + weights.w
            if weightSum > 0.0001 {
                var skinMatrix = weights.x * jointMatrices[Int(joints.x)]
                skinMatrix += weights.y * jointMatrices[Int(joints.y)]
                skinMatrix += weights.z * jointMatrices[Int(joints.z)]
                skinMatrix += weights.w * jointMatrices[Int(joints.w)]

                let rotation = simd_float3x3(
                    simd_float3(skinMatrix.columns.0.x, skinMatrix.columns.0.y, skinMatrix.columns.0.z),
                    simd_float3(skinMatrix.columns.1.x, skinMatrix.columns.1.y, skinMatrix.columns.1.z),
                    simd_float3(skinMatrix.columns.2.x, skinMatrix.columns.2.y, skinMatrix.columns.2.z)
                )
                let cofactor = simd_float3x3(
                    simd_cross(rotation.columns.1, rotation.columns.2),
                    simd_cross(rotation.columns.2, rotation.columns.0),
                    simd_cross(rotation.columns.0, rotation.columns.1)
                )

                let skinnedPosition = skinMatrix * simd_float4(
                    positions[vertexIndex].x, positions[vertexIndex].y, positions[vertexIndex].z, 1
                )
                expectedPosition = simd_float4(
                    skinnedPosition.x, skinnedPosition.y, skinnedPosition.z, positions[vertexIndex].w
                )
                expectedNormal = simd_float4(
                    simd_normalize(cofactor * simd_float3(
                        normals[vertexIndex].x, normals[vertexIndex].y, normals[vertexIndex].z
                    )),
                    normals[vertexIndex].w
                )
                expectedTangent = simd_float4(
                    simd_normalize(rotation * simd_float3(
                        tangents[vertexIndex].x, tangents[vertexIndex].y, tangents[vertexIndex].z
                    )),
                    tangents[vertexIndex].w
                )
            }

            maxPositionError = max(maxPositionError, simd_reduce_max(simd_abs(gpuPositions[vertexIndex] - expectedPosition)))
            maxNormalError = max(maxNormalError, simd_reduce_max(simd_abs(gpuNormals[vertexIndex] - expectedNormal)))
            maxTangentError = max(maxTangentError, simd_reduce_max(simd_abs(gpuTangents[vertexIndex] - expectedTangent)))
        }

        XCTAssertLessThan(maxPositionError, 1e-4, "GPU LBS positions diverge from CPU reference")
        XCTAssertLessThan(maxNormalError, 1e-4, "GPU LBS normals diverge from CPU reference")
        XCTAssertLessThan(maxTangentError, 1e-4, "GPU LBS tangents diverge from CPU reference")
    }
}
