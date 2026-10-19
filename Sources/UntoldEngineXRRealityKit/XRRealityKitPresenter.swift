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
///
/// With the pipeline two refreshes deep (`XRRealityKitPresenterConfiguration.pipelineDepth`),
/// the textures, grids, band and entities above are made twice, as two sets the tickets
/// alternate between by update; the replace calls of a ticket go on a presentation buffer of
/// their own, which the presenter commits at the update after the engine committed the
/// frame's buffer (ordered behind it on the engine's queue, so RealityKit takes the frame
/// only once it is drawn); and at each update the set shown is the one whose ticket of two
/// updates ago has its presentation completed, the other hidden: a frame posted at an update
/// shows at the render two updates on, whether its drawing took one refresh or nearly two,
/// and a frame later than that is held back (the set shown keeps showing) and skipped. The
/// engine's thread poses each frame a refresh further ahead for it (`XRPresenterLead`).
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@MainActor
public final class XRRealityKitPresenter {
    public let configuration: XRRealityKitPresenterConfiguration
    public let device: MTLDevice
    /// The entity to add to the `RealityView`: the grids are its children.
    public let root = Entity()
    public let statistics = XRPresenterStatistics()
    public let mailbox = XRTicketMailbox()
    /// The engine's depth per eye (`depth32Float`, reverse Z), the presenter's own: drawn into
    /// with the eye, read by the unprojection kernel after it. One pair, shared by the sets:
    /// the tickets' command buffers run in order on one queue.
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
    /// The unprojection's scratch per eye (each vertex's nearest depth between its dispatches,
    /// the depth's block maxima, the scan list), kept across frames: the tickets' command
    /// buffers run in order on one queue.
    public let unprojectScratch: [XRGridUnprojectScratch]
    /// Each eye's entries of the unprojection: one float4 per vertex, the chosen texel's depth,
    /// the texel and the rim flag.
    public var nearestDepthBuffers: [MTLBuffer] { unprojectScratch.map(\.nearestDepths) }
    /// Whether the grids show through the shader graph (each eye its own grid) or the fallback
    /// material (both grids in both eyes).
    public private(set) var usesShaderGraphMaterial = false

    /// The settings in force for the next frame: the configuration's to start with, changed
    /// while running as a game likes; each ticket carries a copy.
    public var settings: XRPresenterSettings

    /// One set of what RealityKit shows: the eyes' textures, the grids and their entities, the
    /// edge band's meshes and entities. One set with the pipeline one refresh deep; two,
    /// alternated between tickets, two refreshes deep.
    struct PresentationSet {
        let colorTextures: [LowLevelTexture]
        let meshes: [LowLevelMesh]
        let gridEntities: [ModelEntity]
        let bandMeshes: [LowLevelMesh]
        let edgeEntities: [ModelEntity]
    }

    /// The latest ticket of a set: at which update it was posted and the buffer on whose
    /// completion RealityKit shows it, for choosing the set to show.
    private struct SetContent {
        var update: UInt64 = 0
        var presentation: MTLCommandBuffer?
    }

    /// A ticket's replace calls two refreshes deep, waiting to be committed at the update after
    /// the frame's own buffer was.
    private struct DeferredPresentation {
        let frame: MTLCommandBuffer
        let presentation: MTLCommandBuffer
    }

    let sets: [PresentationSet]
    /// How many sets of textures and grids the presenter was made with: 1, or 2 for the
    /// pipeline two refreshes deep (`XRRealityKitPresenterConfiguration.pipelineDepth`).
    public var presentationSets: Int {
        sets.count
    }

    /// The first set's grids, one per eye.
    var meshes: [LowLevelMesh] {
        sets[0].meshes
    }

    /// The first set's edge band meshes, one per eye, when its graph loaded.
    var bandMeshes: [LowLevelMesh] {
        sets[0].bandMeshes
    }

    /// The grids' fixed split, for writing it back when the adaptive diagonal is turned off.
    private let fixedIndices: MTLBuffer?
    /// Every cell degenerate: what the band's index buffers start from each frame, so that a
    /// frame that draws nothing (no pose, the stop path) leaves the band empty.
    private let degenerateIndices: MTLBuffer?
    /// Whether the edge band's material loaded, so that the band can be drawn.
    public private(set) var hasEdgeBand = false
    /// Whether the edge band is drawn: it is there and the settings ask for it.
    public var drawsEdgeBand: Bool { hasEdgeBand && settings.edgeBlending }
    /// Whether each set's last ticket's cells were split by the depth (the adaptive diagonal).
    private var splitByDepth: [Bool]
    /// Each set's latest ticket.
    private var contents: [SetContent]
    /// The set whose entities show; the others are hidden.
    public private(set) var shownSet = 0
    /// The presentation buffers waiting for their frames' buffers to be committed, oldest first.
    private var deferred: [DeferredPresentation] = []
    /// How many tickets' replace calls wait to be committed (two refreshes deep).
    public var pendingPresentations: Int {
        deferred.count
    }

    /// The display's refresh period measured from the updates, for the deeper pipeline's lead.
    public private(set) var refresh = XRPresenterRefresh()
    /// Updates so far: the tickets alternate sets by it, and a set is shown for the update two
    /// before.
    private var updates: UInt64 = 0
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

        unprojectScratch = try (0 ..< stereoEyeCount).map { eye in
            guard let scratch = XRGridUnprojectScratch(device: device, grid: grid, textureSize: textureSize, label: "XR presenter eye \(eye)") else {
                throw PresenterError.nearestDepthBuffer
            }
            return scratch
        }

        // The eye material once, for every set.
        var graph: ShaderGraphMaterial?
        do {
            graph = try await XRPresenterMaterial.load()
            usesShaderGraphMaterial = true
        } catch {
            Logger.logWarning(message: "XR presenter: the eye material could not be loaded (\(error)); both eyes see both grids")
        }
        // The edge band's graph once, when the eye material loaded: a set whose band cannot
        // be made has none, and the band is unavailable.
        var edgeGraph: ShaderGraphMaterial?
        if usesShaderGraphMaterial {
            do {
                edgeGraph = try await XRPresenterMaterial.loadEdge()
            } catch {
                Logger.logWarning(message: "XR presenter: the edge band's material could not be loaded (\(error)); edges are alpha-tested only")
            }
        }

        // One set, or two for the pipeline two refreshes deep: the second starts hidden, and
        // shows once a ticket drawn into it is due.
        let setCount = min(max(configuration.pipelineDepth, 1), 2)
        var sets: [PresentationSet] = []
        for set in 0 ..< setCount {
            var colorDescriptor = LowLevelTexture.Descriptor()
            colorDescriptor.textureType = .type2D
            colorDescriptor.pixelFormat = .bgra8Unorm_srgb
            colorDescriptor.width = width
            colorDescriptor.height = height
            colorDescriptor.textureUsage = [.renderTarget, .shaderRead]
            let colorTextures = try (0 ..< stereoEyeCount).map { _ in try LowLevelTexture(descriptor: colorDescriptor) }
            let textureResources = try colorTextures.map { try TextureResource(from: $0) }
            let meshes = try (0 ..< stereoEyeCount).map { _ in try grid.makeMesh(farShell: configuration.farShellMetres) }
            let prefix = set == 0 ? "Untold XR " : "Untold XR second set, "

            var materials: [any RealityKit.Material] = []
            if let graph {
                for eye in 0 ..< stereoEyeCount {
                    var material = graph
                    try XRPresenterMaterial.configure(&material, eye: eye, texture: textureResources[eye])
                    materials.append(material)
                }
            } else {
                materials = textureResources.map { XRPresenterMaterial.fallback(texture: $0) }
            }

            var entities: [ModelEntity] = []
            for eye in 0 ..< stereoEyeCount {
                let entity = try await ModelEntity(mesh: RealityKit.MeshResource(from: meshes[eye]), materials: [materials[eye]])
                entity.name = prefix + (eye == 0 ? "left eye" : "right eye")
                entity.isEnabled = set == 0
                root.addChild(entity)
                entities.append(entity)
            }

            // The edge band: the grids' vertices again on meshes of its own, whose cells the
            // kernel keeps along silhouettes alone, blended over the opaque core; made whenever
            // its graph loaded, enabled when the settings ask for it. Its meshes start with
            // every cell degenerate, so the band draws nothing before its first frame.
            var edges: [ModelEntity] = []
            var bands: [LowLevelMesh] = []
            if let edgeGraph {
                for eye in 0 ..< stereoEyeCount {
                    var material = edgeGraph
                    try XRPresenterMaterial.configure(&material, eye: eye, texture: textureResources[eye])
                    let mesh = try grid.makeMesh(farShell: configuration.farShellMetres, indices: grid.degenerateIndices())
                    let entity = try await ModelEntity(mesh: RealityKit.MeshResource(from: mesh), materials: [material])
                    entity.name = prefix + (eye == 0 ? "left eye edge" : "right eye edge")
                    entity.isEnabled = set == 0 && configuration.edgeBlending
                    bands.append(mesh)
                    edges.append(entity)
                }
                for entity in edges {
                    root.addChild(entity)
                }
            }
            sets.append(PresentationSet(colorTextures: colorTextures, meshes: meshes, gridEntities: entities, bandMeshes: bands, edgeEntities: edges))
        }
        hasEdgeBand = edgeGraph != nil
        self.sets = sets
        splitByDepth = Array(repeating: false, count: sets.count)
        contents = Array(repeating: SetContent(), count: sets.count)
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

    /// The pipeline's depth in force for the next ticket: the settings', within the sets made.
    public var pipelineDepth: Int {
        min(max(settings.pipelineDepth, 1), sets.count)
    }

    /// Once per RealityKit frame, on the main thread (`SceneEvents.Update`): the presentation
    /// buffers now due, the set to show for this render, then a command buffer, the replace
    /// calls for both eyes' textures, both grids and, when it is drawn, the edge band's meshes,
    /// a ticket for the engine. None when the engine has not taken the previous ticket (a
    /// counted drop), or before `start`.
    public func update() {
        statistics.noteUpdate()
        refresh.noteUpdate(at: CACurrentMediaTime())
        updates += 1
        let depth = pipelineDepth
        var settings = settings
        settings.pipelineDepth = depth
        commitDuePresentations()
        showSet(forUpdate: updates, depth: depth)
        // The band follows its setting on every update, whether or not a ticket goes out, on
        // the set shown; a hidden set's band is hidden with it.
        for (index, set) in sets.enumerated() {
            let wanted = settings.edgeBlending && index == shownSet
            for entity in set.edgeEntities where entity.isEnabled != wanted {
                entity.isEnabled = wanted
            }
        }
        guard let commandQueue, !mailbox.isClosed else { return }
        guard !mailbox.hasPending else {
            statistics.noteTicketDropped()
            report()
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // Two refreshes deep: the replace calls on a buffer of their own, committed at the
        // update after the frame's; one deep, on the frame's own buffer, as RealityKit expects
        // the frame to show once it is drawn.
        let presentation: MTLCommandBuffer
        if depth > 1 {
            guard let deferredBuffer = commandQueue.makeCommandBuffer() else { return }
            deferredBuffer.label = "XR presenter presentation"
            presentation = deferredBuffer
        } else {
            presentation = commandBuffer
        }
        let setIndex = depth > 1 ? Int(updates % 2) : 0
        let set = sets[setIndex]

        let replaceStart = CACurrentMediaTime()
        let textures = set.colorTextures.map { $0.replace(using: presentation) }
        let buffers = set.meshes.map { $0.replace(bufferIndex: 0, using: presentation) }
        // The cells' split per frame only when it is asked for; otherwise the mesh keeps its
        // indices and the ticket carries none. RealityKit hands the index buffers out with no
        // content, so each starts from the fixed split, blitted here on the frame's buffer:
        // the kernel splits the cells over it later in that command buffer, and a frame that
        // draws nothing (no pose yet, the stop path) still completes with every cell whole.
        // Just turned off, the same blit writes the fixed split back once, so no cell stays
        // split as the depth last left it.
        var indexBuffers: [MTLBuffer] = []
        var fixedSplitInto: [MTLBuffer] = []
        if settings.adaptiveDiagonal || splitByDepth[setIndex] {
            fixedSplitInto = set.meshes.map { $0.replaceIndices(using: presentation) }
            if settings.adaptiveDiagonal { indexBuffers = fixedSplitInto }
        }
        splitByDepth[setIndex] = settings.adaptiveDiagonal
        // The edge band's buffers while it is drawn: its vertices, which the kernel fills with
        // the grids' bytes, and its indices, handed out with no content like the grids' and
        // blitted degenerate here, so that a frame that draws nothing leaves the band empty;
        // the kernel's band pass writes the cells along silhouettes over them later in the
        // frame's command buffer. Off, the band's entities are disabled and its meshes are
        // left alone.
        var bandBuffers: [MTLBuffer] = []
        var bandIndexBuffers: [MTLBuffer] = []
        if hasEdgeBand, settings.edgeBlending {
            bandBuffers = set.bandMeshes.map { $0.replace(bufferIndex: 0, using: presentation) }
            bandIndexBuffers = set.bandMeshes.map { $0.replaceIndices(using: presentation) }
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
            presentationBuffer: presentation,
            set: setIndex,
            colorTextures: textures,
            gridBuffers: buffers,
            indexBuffers: indexBuffers,
            bandBuffers: bandBuffers,
            bandIndexBuffers: bandIndexBuffers,
            postedAt: posted,
            refreshSeconds: refresh.seconds,
            settings: settings
        )
        lastTicket = ticket
        contents[setIndex] = SetContent(update: updates, presentation: presentation)
        if depth > 1 {
            deferred.append(DeferredPresentation(frame: commandBuffer, presentation: presentation))
        }
        if !mailbox.post(ticket) {
            // Closed, or raced by a frame: a replaced texture never waits on an uncommitted buffer.
            commandBuffer.commit()
        }
        report()
    }

    /// Commits the presentation buffers whose frames' buffers the engine has committed, in
    /// order, so that each is ordered behind its frame on the queue and RealityKit takes the
    /// frame drawn; a frame not yet committed keeps its presentation and the later ones waiting.
    private func commitDuePresentations() {
        while let next = deferred.first {
            guard next.frame.status != .notEnqueued else { break }
            next.presentation.commit()
            deferred.removeFirst()
        }
    }

    /// The set to show for this update's render, two refreshes deep: the one whose latest
    /// ticket was posted two updates ago and has its presentation completed, so that a frame
    /// shows at the render it was planned for; otherwise the set shown stays (a frame later
    /// than its plan, or an update that posted no ticket, holds the previous frame on screen,
    /// and the late frame is skipped when the next one is on time). One deep, the first set
    /// shows always.
    private func showSet(forUpdate update: UInt64, depth: Int) {
        var shown = shownSet
        if depth > 1 {
            if update > 2 {
                let planned = update - 2
                let candidate = Int(planned % 2)
                let content = contents[candidate]
                if content.update == planned, content.presentation?.status == .completed {
                    shown = candidate
                }
            }
        } else {
            shown = 0
        }
        guard shown != shownSet else { return }
        shownSet = shown
        for (index, set) in sets.enumerated() {
            for entity in set.gridEntities where entity.isEnabled != (index == shown) {
                entity.isEnabled = index == shown
            }
        }
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
    /// committed empty; the presentation buffers still waiting are committed as their frames'
    /// buffers are (a frame the engine is drawing commits in a moment). No ticket is posted
    /// after this.
    public func stop() {
        mailbox.close()
        commandQueue = nil
        commitRemainingPresentations()
    }

    /// The presentation buffers left after the stop, each committed once its frame's buffer is:
    /// RealityKit's bookkeeping of the replace calls wants every one of them completed.
    private func commitRemainingPresentations() {
        commitDuePresentations()
        guard !deferred.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            MainActor.assumeIsolated {
                self.commitRemainingPresentations()
            }
        }
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
