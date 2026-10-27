//
//  XRPresenterGrid.swift
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

/// One eye's grid: `columns × rows` vertices the unprojection kernel places in the origin's
/// space every frame, an index buffer of two triangles per cell (static, or rewritten per frame
/// when the cells' split follows the depth), one part bounded well past the far shell. The
/// vertex layout (40 bytes) is the kernel's `XRGridVertex`: a packed position, a packed uv with
/// v = 0 at the texture's top row (affine, the fallback material's), a half2 tear mask (x the far
/// side of a depth jump, y the near side), and the projective uv (u, v times the eye-space
/// depth, that depth, and a spare component the shader graph ignores: 0, or the vertex's kind
/// under the alpha-crossing silhouette cells) the shader graph divides per pixel. The edge band's mesh is a second
/// grid of the same layout and capacity whose index buffer the kernel fills per frame with the
/// cells along silhouettes alone, every other cell degenerate (`degenerateIndices`).
public struct XRPresenterGrid: Sendable, Equatable {
    public static let vertexStride = 40
    public static let positionOffset = 0
    public static let uvOffset = 12
    public static let maskOffset = 20
    public static let uvwOffset = 24

    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        precondition(columns >= 2 && rows >= 2, "a grid needs at least two columns and two rows")
        self.columns = columns
        self.rows = rows
    }

    public var vertexCount: Int { columns * rows }

    public var indexCount: Int { (columns - 1) * (rows - 1) * 6 }

    /// Two triangles per cell, counter-clockwise as seen from the eye: looking down -Z with the
    /// first row at the top of the view.
    public func indices() -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for row in 0 ..< rows - 1 {
            for column in 0 ..< columns - 1 {
                let a = UInt32(row * columns + column)
                let b = a + 1
                let c = a + UInt32(columns)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return indices
    }

    /// Every cell degenerate: six copies of the cell's first vertex, a pair of triangles the
    /// rasterizer draws nothing for. The edge band's mesh before its first frame, and what its
    /// index buffer starts from each frame.
    public func degenerateIndices() -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for row in 0 ..< rows - 1 {
            for column in 0 ..< columns - 1 {
                let a = UInt32(row * columns + column)
                indices.append(contentsOf: [a, a, a, a, a, a])
            }
        }
        return indices
    }

    /// The vertices before the first frame: a 4 × 3 m plane 2 m ahead of the origin at head
    /// height, the uv unflipped, no tears. The kernel overwrites them on the first frame.
    public func initialVertexBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: vertexCount * Self.vertexStride)
        bytes.withUnsafeMutableBytes { raw in
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let u = Float(column) / Float(columns - 1)
                    let v = Float(row) / Float(rows - 1)
                    let base = (row * columns + column) * Self.vertexStride
                    raw.storeBytes(of: (u - 0.5) * 4, toByteOffset: base, as: Float.self)
                    raw.storeBytes(of: 1.5 + (0.5 - v) * 3, toByteOffset: base + 4, as: Float.self)
                    raw.storeBytes(of: -2, toByteOffset: base + 8, as: Float.self)
                    raw.storeBytes(of: u, toByteOffset: base + Self.uvOffset, as: Float.self)
                    raw.storeBytes(of: v, toByteOffset: base + Self.uvOffset + 4, as: Float.self)
                    raw.storeBytes(of: u * 2, toByteOffset: base + Self.uvwOffset, as: Float.self)
                    raw.storeBytes(of: v * 2, toByteOffset: base + Self.uvwOffset + 4, as: Float.self)
                    raw.storeBytes(of: Float(2), toByteOffset: base + Self.uvwOffset + 8, as: Float.self)
                }
            }
        }
        return bytes
    }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
public extension XRPresenterGrid {
    /// The grid as RealityKit draws it: the vertex buffer the kernel rewrites every frame
    /// through `replace(bufferIndex:using:)`, the indices to start from (`indices()`, two
    /// triangles per cell, unless given: the edge band starts from `degenerateIndices()`) with
    /// the capacity of the whole grid, one part whose bound takes in the far shell wherever
    /// the eye is.
    @MainActor
    func makeMesh(farShell: Float, indices initialIndices: [UInt32]? = nil) throws -> LowLevelMesh {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCount
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: Self.positionOffset),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: Self.uvOffset),
            .init(semantic: .uv1, format: .half2, layoutIndex: 0, offset: Self.maskOffset),
            .init(semantic: .uv2, format: .float4, layoutIndex: 0, offset: Self.uvwOffset),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: Self.vertexStride)]
        let mesh = try LowLevelMesh(descriptor: descriptor)

        let indices = initialIndices ?? indices()
        precondition(indices.count == indexCount, "a grid's index buffer holds six indices per cell")
        mesh.replaceUnsafeMutableIndices { raw in
            indices.withUnsafeBytes { source in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(raw.count)))
            }
        }
        let vertices = initialVertexBytes()
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            vertices.withUnsafeBytes { source in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(raw.count)))
            }
        }

        // The eye may stand anywhere within the shell's reach; the bound covers the shell from
        // any such place, with a margin, so that RealityKit never culls the grid.
        let bound = farShell * 2 + 1
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: indexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(min: [-bound, -bound, -bound], max: [bound, bound, bound])
            ),
        ])
        return mesh
    }
}
