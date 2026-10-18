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
/// show them (one per eye, at identity, with the eye-switching material), the edge band's two
/// meshes and entities (the grid's vertices again, the cells along silhouettes alone, blended
/// over the core), and the exchange with the engine's thread. Once per RealityKit frame, on the
/// main thread, `update()` makes a command buffer, asks RealityKit for the frame's textures,
/// grid buffers and band buffers with its replace calls, and posts them as a ticket;
/// `RealityKitFrameSource` turns each ticket into a frame for the engine's loop, which draws the
/// eyes, unprojects the grids and the band and commits the ticket's command buffer, on whose
/// completion RealityKit shows the new content. With a foveation
/// profile in the configuration, both eyes are drawn through the presenter's own fixed
/// rasterization rate map (`XRPresenterFoveation`): the textures are its physical size, within
/// the configured pixel budget, and the grids a vertex every cell of physical texels.
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
    /// Each eye's grid: the configuration's, or, through a rate map, the map's physical texels
    /// in cells.
    public let grid: XRPresenterGrid
    /// The rate map both eyes are drawn through, when the configuration asks for one and the
    /// device has them; nil, and the eyes are drawn uniformly.
    public let foveation: XRPresenterFoveation?
    /// The size of each eye's textures in pixels: the configuration's `textureSize`, or the rate
    /// map's physical size within it.
    public let textureSize: SIMD2<Int>
    public let unproject: XRGridUnprojectPass
    /// The unprojection's scratch per eye (each vertex's nearest depth, between its two
    /// dispatches), kept across frames: the tickets' command buffers run in order on one queue.
    public let nearestDepthBuffers: [MTLBuffer]
    /// Whether the grids show through the shader graph (each eye its own grid) or the fallback
    /// material (both grids in both eyes).
    public private(set) var usesShaderGraphMaterial = false

    /// The settings in force for the next frame: the configuration's to start with, changed
    /// while running as a game likes; each ticket carries a copy.
    public var settings: XRPresenterSettings

    private let colorTextures: [LowLevelTexture]
    let meshes: [LowLevelMesh]
    /// The grids' fixed split, for writing it back when the adaptive diagonal is turned off.
    private let fixedIndices: MTLBuffer?
    /// Every cell degenerate: what the band's index buffers start from each frame, so that a
    /// frame that draws nothing (no pose, the stop path) leaves the band empty.
    private let degenerateIndices: MTLBuffer?
    private let gridEntities: [ModelEntity]
    /// The edge band's meshes, one per eye, when its graph loaded: the grid's vertices again
    /// (the kernel writes the same bytes into them), an index buffer of the cells along
    /// silhouettes the kernel writes per frame, every other cell degenerate.
    let bandMeshes: [LowLevelMesh]
    /// The edge band's entities, one per eye, on the band's meshes, when its graph loaded;
    /// enabled by the settings.
    private let edgeEntities: [ModelEntity]
    /// Whether the edge band's material loaded, so that the band can be drawn.
    public private(set) var hasEdgeBand = false
    /// Whether the edge band is drawn: it is there and the settings ask for it.
    public var drawsEdgeBand: Bool { hasEdgeBand && settings.edgeBlending }
    /// Whether the last ticket's cells were split by the depth (the adaptive diagonal).
    private var splitByDepth = false
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
        settings = XRPresenterSettings(configuration: configuration)
        // The rate map first: the textures and the grid take their sizes from it.
        let foveation = XRPresenterFoveation.make(device: device, configuration: configuration)
        self.foveation = foveation
        let textureSize = foveation?.physicalSize ?? configuration.textureSize
        self.textureSize = textureSize
        let grid = foveation?.grid ?? XRPresenterGrid(columns: configuration.gridColumns, rows: configuration.gridRows)
        self.grid = grid
        fixedIndices = grid.indices().withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        fixedIndices?.label = "XR presenter fixed split"
        degenerateIndices = grid.degenerateIndices().withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        degenerateIndices?.label = "XR presenter empty band"
        unproject = try XRGridUnprojectPass(device: device)

        let width = textureSize.x
        let height = textureSize.y
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
        for eye in 0 ..< stereoEyeCount {
            let entity = try await ModelEntity(mesh: RealityKit.MeshResource(from: meshes[eye]), materials: [materials[eye]])
            entity.name = eye == 0 ? "Untold XR left eye" : "Untold XR right eye"
            root.addChild(entity)
            entities.append(entity)
        }
        gridEntities = entities

        // The edge band: the grids' vertices again on meshes of its own, whose cells the kernel
        // keeps along silhouettes alone, blended over the opaque core; made whenever its graph
        // loads, enabled when the settings ask for it. Its meshes start with every cell
        // degenerate, so the band draws nothing before its first frame.
        var edges: [ModelEntity] = []
        var bands: [LowLevelMesh] = []
        if usesShaderGraphMaterial {
            do {
                let graph = try await XRPresenterMaterial.loadEdge()
                for eye in 0 ..< stereoEyeCount {
                    var material = graph
                    try XRPresenterMaterial.configure(&material, eye: eye, texture: textureResources[eye])
                    let mesh = try grid.makeMesh(farShell: configuration.farShellMetres, indices: grid.degenerateIndices())
                    let entity = try await ModelEntity(mesh: RealityKit.MeshResource(from: mesh), materials: [material])
                    entity.name = eye == 0 ? "Untold XR left eye edge" : "Untold XR right eye edge"
                    entity.isEnabled = configuration.edgeBlending
                    bands.append(mesh)
                    edges.append(entity)
                }
                for entity in edges {
                    root.addChild(entity)
                }
                hasEdgeBand = true
            } catch {
                Logger.logWarning(message: "XR presenter: the edge band's material could not be loaded (\(error)); edges are alpha-tested only")
                edges = []
                bands = []
            }
        }
        edgeEntities = edges
        bandMeshes = bands
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
    /// the replace calls for both eyes' textures, both grids and, when it is drawn, the edge
    /// band's meshes, a ticket for the engine. None when the engine has not taken the previous
    /// ticket (a counted drop), or before `start`.
    public func update() {
        statistics.noteUpdate()
        let settings = settings
        // The band follows its setting on every update, whether or not a ticket goes out.
        for entity in edgeEntities where entity.isEnabled != settings.edgeBlending {
            entity.isEnabled = settings.edgeBlending
        }
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
        // indices and the ticket carries none. RealityKit hands the index buffers out with no
        // content, so each starts from the fixed split, blitted here: the kernel splits the
        // cells over it later in this command buffer, and a frame that draws nothing (no pose
        // yet, the stop path) still completes with every cell whole. Just turned off, the same
        // blit writes the fixed split back once, so no cell stays split as the depth last left it.
        var indexBuffers: [MTLBuffer] = []
        var fixedSplitInto: [MTLBuffer] = []
        if settings.adaptiveDiagonal || splitByDepth {
            fixedSplitInto = meshes.map { $0.replaceIndices(using: commandBuffer) }
            if settings.adaptiveDiagonal { indexBuffers = fixedSplitInto }
        }
        splitByDepth = settings.adaptiveDiagonal
        // The edge band's buffers while it is drawn: its vertices, which the kernel fills with
        // the grids' bytes, and its indices, handed out with no content like the grids' and
        // blitted degenerate here, so that a frame that draws nothing leaves the band empty;
        // the kernel's band pass writes the cells along silhouettes over them later in this
        // command buffer. Off, the band's entities are disabled and its meshes are left alone.
        var bandBuffers: [MTLBuffer] = []
        var bandIndexBuffers: [MTLBuffer] = []
        if hasEdgeBand, settings.edgeBlending {
            bandBuffers = bandMeshes.map { $0.replace(bufferIndex: 0, using: commandBuffer) }
            bandIndexBuffers = bandMeshes.map { $0.replaceIndices(using: commandBuffer) }
        }
        if !fixedSplitInto.isEmpty || !bandIndexBuffers.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "XR presenter index buffers' start"
            if let fixedIndices {
                for buffer in fixedSplitInto {
                    blit.copy(from: fixedIndices, sourceOffset: 0, to: buffer, destinationOffset: 0, size: min(fixedIndices.length, buffer.length))
                }
            }
            if let degenerateIndices {
                for buffer in bandIndexBuffers {
                    blit.copy(from: degenerateIndices, sourceOffset: 0, to: buffer, destinationOffset: 0, size: min(degenerateIndices.length, buffer.length))
                }
            }
            blit.endEncoding()
        }
        let posted = CACurrentMediaTime()
        statistics.noteTicketPosted(replaceSeconds: posted - replaceStart)

        serial += 1
        let ticket = XRPresenterTicket(
            serial: serial,
            commandBuffer: commandBuffer,
            colorTextures: textures,
            gridBuffers: buffers,
            indexBuffers: indexBuffers,
            bandBuffers: bandBuffers,
            bandIndexBuffers: bandIndexBuffers,
            postedAt: posted,
            settings: settings
        )
        lastTicket = ticket
        if !mailbox.post(ticket) {
            // Closed, or raced by a frame: a replaced texture never waits on an uncommitted buffer.
            commandBuffer.commit()
        }
        report()
    }

    /// Ends the exchange after one more frame, for a shutdown the engine finishes in a frame:
    /// `shutdown` is handed a completion and asked to shut the engine down (the engine defers
    /// destroying the world's entities to the start of a frame, and runs the shutdown's own
    /// completion then: the loop stopped, the active camera cleared), and the presenter posts
    /// the ticket of that frame; the exchange ends when the completion fires, or after a second
    /// if no frame comes. Stopping first would leave the destroys and the completion to the next
    /// session's first frame, which would then lose its camera and draw nothing.
    /// `then` runs on the main actor once the exchange has ended, so that whoever opens the
    /// next session can wait for it. The presenter keeps itself alive until then.
    public func stop(after shutdown: (@escaping @Sendable () -> Void) -> Void, then: (@MainActor () -> Void)? = nil) {
        let once = XRPresenterOnce()
        let finish: @Sendable () -> Void = {
            guard once.claim() else { return }
            // The completion comes on the engine's thread; the exchange ends on the main one.
            let end: @MainActor () -> Void = {
                self.stop()
                then?()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { end() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { end() } }
            }
        }
        shutdown(finish)
        postUntilFinished(once: once, finish: finish, ticketsLeft: 90)
    }

    /// A ticket per refresh until the shutdown's completion fires (`once` claimed), or until
    /// `ticketsLeft` are posted, then `finish` itself. The engine finalizes the destroys at the
    /// start of a frame only when a frame's completion asked for it, so each ticket asks first;
    /// a loop that skips a frame's update (assets loading) or drops a ticket gets the next one.
    private func postUntilFinished(once: XRPresenterOnce, finish: @escaping @Sendable () -> Void, ticketsLeft: Int) {
        guard !once.isClaimed else { return }
        guard ticketsLeft > 0 else {
            finish()
            return
        }
        needsFinalizeDestroys = true
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.011) {
            MainActor.assumeIsolated {
                self.postUntilFinished(once: once, finish: finish, ticketsLeft: ticketsLeft - 1)
            }
        }
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

/// A flag claimed once, from any thread.
private final class XRPresenterOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
