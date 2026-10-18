//
//  XRRealityKitPresenter.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal
import QuartzCore
import RealityKit
import simd
import UntoldEngine

/// The engine's frame shown by RealityKit: two `LowLevelTexture`s the engine draws the eyes
/// into, two `LowLevelMesh` grids a kernel places from the eyes' depth, the two entities that
/// show them (one per eye, at identity, with the eye-switching material), and the exchange with
/// the engine's thread. Once per RealityKit frame, on the main thread, `update()` makes a
/// command buffer, asks RealityKit for the frame's textures and grid buffers with its replace
/// calls, and posts them as a ticket; `RealityKitFrameSource` turns each ticket into a frame
/// for the engine's loop, which draws the eyes, unprojects the grids and commits the ticket's
/// command buffer, on whose completion RealityKit shows the new content.
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@MainActor
public final class XRRealityKitPresenter {
    public let configuration: XRRealityKitPresenterConfiguration
    public let device: MTLDevice
    /// The entity to add to the `RealityView`: the two grids are its children.
    public let root = Entity()
    public let statistics = XRPresenterStatistics()
    public let mailbox = XRTicketMailbox()
    /// The engine's depth per eye (`depth32Float`, reverse Z), the presenter's own: drawn into
    /// with the eye, read by the unprojection kernel after it.
    public let depthTextures: [MTLTexture]
    public let grid: XRPresenterGrid
    public let unproject: XRGridUnprojectPass
    /// The unprojection's scratch per eye (each vertex's nearest depth, between its two
    /// dispatches), kept across frames: the tickets' command buffers run in order on one queue.
    public let nearestDepthBuffers: [MTLBuffer]
    /// Whether the grids show through the shader graph (each eye its own grid) or the fallback
    /// material (both grids in both eyes).
    public private(set) var usesShaderGraphMaterial = false

    private let colorTextures: [LowLevelTexture]
    private let meshes: [LowLevelMesh]
    private let gridEntities: [ModelEntity]
    /// The edge band's entities, one per eye, when the configuration asks for it and its graph loaded.
    private let edgeEntities: [ModelEntity]
    /// Whether the edge band is drawn.
    public private(set) var drawsEdgeBand = false
    private var commandQueue: MTLCommandQueue?
    private var serial: UInt64 = 0
    private var lastReportTime = CACurrentMediaTime()
    /// The last ticket posted, for the tests.
    private(set) var lastTicket: XRPresenterTicket?

    /// Seconds between the presenter's log lines of its numbers; 0 for none.
    public var reportInterval: TimeInterval = 5

    /// The textures, grids, entities and materials for `configuration`; throws when RealityKit
    /// or Metal refuses one of them. The material graph failing to load is not an error: the
    /// fallback material stands in and `usesShaderGraphMaterial` says so.
    public init(device: MTLDevice, configuration: XRRealityKitPresenterConfiguration = .init()) async throws {
        self.device = device
        self.configuration = configuration
        let grid = XRPresenterGrid(columns: configuration.gridColumns, rows: configuration.gridRows)
        self.grid = grid
        unproject = try XRGridUnprojectPass(device: device)

        let width = configuration.textureSize.x
        let height = configuration.textureSize.y
        var colorDescriptor = LowLevelTexture.Descriptor()
        colorDescriptor.textureType = .type2D
        colorDescriptor.pixelFormat = .bgra8Unorm_srgb
        colorDescriptor.width = width
        colorDescriptor.height = height
        colorDescriptor.textureUsage = [.renderTarget, .shaderRead]
        let colorTextures = try (0 ..< stereoEyeCount).map { _ in try LowLevelTexture(descriptor: colorDescriptor) }
        self.colorTextures = colorTextures
        let textureResources = try colorTextures.map { try TextureResource(from: $0) }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        depthTextures = try (0 ..< stereoEyeCount).map { eye in
            guard let texture = device.makeTexture(descriptor: depthDescriptor) else { throw PresenterError.depthTexture }
            texture.label = "XR presenter depth eye \(eye)"
            return texture
        }

        nearestDepthBuffers = try (0 ..< stereoEyeCount).map { eye in
            guard let buffer = XRGridUnprojectPass.makeNearestDepthBuffer(device: device, grid: grid, label: "XR presenter nearest depth eye \(eye)") else {
                throw PresenterError.nearestDepthBuffer
            }
            return buffer
        }

        let meshes = try (0 ..< stereoEyeCount).map { _ in try grid.makeMesh(farShell: configuration.farShellMetres) }
        self.meshes = meshes

        var materials: [any RealityKit.Material] = []
        do {
            let graph = try await XRPresenterMaterial.load()
            for eye in 0 ..< stereoEyeCount {
                var material = graph
                try XRPresenterMaterial.configure(&material, eye: eye, texture: textureResources[eye])
                materials.append(material)
            }
            usesShaderGraphMaterial = true
        } catch {
            Logger.logWarning(message: "XR presenter: the eye material could not be loaded (\(error)); both eyes see both grids")
            materials = textureResources.map { XRPresenterMaterial.fallback(texture: $0) }
        }

        var entities: [ModelEntity] = []
        var meshResources: [RealityKit.MeshResource] = []
        for eye in 0 ..< stereoEyeCount {
            let meshResource = try await RealityKit.MeshResource(from: meshes[eye])
            meshResources.append(meshResource)
            let entity = ModelEntity(mesh: meshResource, materials: [materials[eye]])
            entity.name = eye == 0 ? "Untold XR left eye" : "Untold XR right eye"
            root.addChild(entity)
            entities.append(entity)
        }
        gridEntities = entities

        // The edge band: the same grids again, blended, over the opaque core.
        var edges: [ModelEntity] = []
        if configuration.edgeBlending, usesShaderGraphMaterial {
            do {
                let graph = try await XRPresenterMaterial.loadEdge()
                for eye in 0 ..< stereoEyeCount {
                    var material = graph
                    try XRPresenterMaterial.configure(&material, eye: eye, texture: textureResources[eye])
                    let entity = ModelEntity(mesh: meshResources[eye], materials: [material])
                    entity.name = eye == 0 ? "Untold XR left eye edge" : "Untold XR right eye edge"
                    root.addChild(entity)
                    edges.append(entity)
                }
                drawsEdgeBand = true
            } catch {
                Logger.logWarning(message: "XR presenter: the edge band's material could not be loaded (\(error)); edges are alpha-tested only")
            }
        }
        edgeEntities = edges
        root.name = "Untold XR presenter"
    }

    public enum PresenterError: Swift.Error, CustomStringConvertible {
        case depthTexture
        case nearestDepthBuffer

        public var description: String {
            switch self {
            case .depthTexture: return "Metal gave no depth texture for the presenter"
            case .nearestDepthBuffer: return "Metal gave no scratch buffer for the presenter's grids"
            }
        }
    }

    /// Lets `update` post tickets, with command buffers from `commandQueue`: the engine's own
    /// queue, so that the frame's drawing and RealityKit's reading of it order on one queue.
    public func start(commandQueue: MTLCommandQueue) {
        self.commandQueue = commandQueue
    }

    /// Once per RealityKit frame, on the main thread (`SceneEvents.Update`): a command buffer,
    /// the replace calls for both eyes' textures and both grids, a ticket for the engine. None
    /// when the engine has not taken the previous ticket (a counted drop), or before `start`.
    public func update() {
        statistics.noteUpdate()
        guard let commandQueue, !mailbox.isClosed else { return }
        guard !mailbox.hasPending else {
            statistics.noteTicketDropped()
            report()
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let replaceStart = CACurrentMediaTime()
        let textures = colorTextures.map { $0.replace(using: commandBuffer) }
        let buffers = meshes.map { $0.replace(bufferIndex: 0, using: commandBuffer) }
        // The cells' split per frame only when it is asked for; otherwise the mesh keeps its
        // indices and the ticket carries none.
        let indexBuffers = configuration.adaptiveDiagonal ? meshes.map { $0.replaceIndices(using: commandBuffer) } : []
        let posted = CACurrentMediaTime()
        statistics.noteTicketPosted(replaceSeconds: posted - replaceStart)

        serial += 1
        let ticket = XRPresenterTicket(
            serial: serial,
            commandBuffer: commandBuffer,
            colorTextures: textures,
            gridBuffers: buffers,
            indexBuffers: indexBuffers,
            postedAt: posted
        )
        lastTicket = ticket
        if !mailbox.post(ticket) {
            // Closed, or raced by a frame: a replaced texture never waits on an uncommitted buffer.
            commandBuffer.commit()
        }
        report()
    }

    /// Ends the exchange: the engine's loop, waiting on the mailbox, ends; a pending ticket is
    /// committed empty. No ticket is posted after this.
    public func stop() {
        mailbox.close()
        commandQueue = nil
    }

    private func report() {
        guard reportInterval > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastReportTime >= reportInterval else { return }
        lastReportTime = now
        print(statistics.snapshot().description)
    }
}
