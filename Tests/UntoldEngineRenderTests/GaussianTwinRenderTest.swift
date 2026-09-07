//
//  GaussianTwinRenderTest.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Metal
import simd
@testable import UntoldEngine
import XCTest

/// The mesh-to-splat twin swap on screen: the swapped mesh draws no colour but still hides
/// splats behind its shrunk depth shell, the cross-fade dithers the mesh out, and a `.untold`
/// scene's `gaussianAsset` record drives the whole loop through `GaussianTwinSystem`.
@MainActor
final class GaussianTwinRenderTest: BaseRenderSetup {
    private var temporaryFiles: [URL] = []

    override func tearDown() async throws {
        GaussianTwinSystem.shared.splatRenderingAvailableOverride = nil
        GaussianDebugOptions.shared.disableTwinShell = false
        GaussianDebugOptions.shared.disableHZBOcclusionCull = false
        LoadingSystem.shared.resourceURLFn = getResourceURL
        destroyAllEntities()
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        try await super.tearDown()
    }

    override func initializeAssets() {}

    // MARK: - Scene helpers

    private func testPLYURL() throws -> URL {
        try XCTUnwrap(LoadingSystem.shared.resourceURL(forResource: "test_gaussians", withExtension: "ply", subResource: nil))
    }

    @discardableResult
    private func createTestCamera(eye: simd_float3, target: simd_float3) -> EntityID {
        let cameraEntity = createEntity()
        if let cameraComponent = scene.assign(to: cameraEntity, component: CameraComponent.self) {
            CameraSystem.shared.activeCamera = cameraEntity
            cameraComponent.viewSpace = matrix_identity_float4x4
            cameraComponent.localPosition = .zero
        }
        cameraLookAt(entityId: cameraEntity, eye: eye, target: target, up: simd_float3(0, 1, 0))
        return cameraEntity
    }

    /// Twin settings that keep the live system (ticked by every draw) from moving a state the
    /// test forced: the fade lasts practically forever, and the swap distance is set per state
    /// by `forceTwin` so the system agrees with it.
    private static let pinnedOptions = GaussianTwinOptions(swapDistanceMeters: 1, hysteresisMeters: 0, crossFadeDuration: 1e6)

    /// A cube whose near face covers the whole frame (see GaussianRenderingTest's occlusion
    /// tests), linked to the test splat as its twin. The splat cloud sits at the cube's
    /// origin, i.e. inside the cube behind its near face. The material is emissive so the lit
    /// colour does not depend on the test IBL bake (as in EmissiveLightPassTest).
    private func makeTwinCube(at position: simd_float3, extent: Float = 8.0, options: GaussianTwinOptions = pinnedOptions) throws -> EntityID {
        let entity = createEntity()
        var meshes = BasicPrimitives.createCube(extent: extent)
        let emissiveMaterial = Material(
            runtimeMaterial: RuntimeMaterialSource(
                baseColorFactor: simd_float4(0, 0, 0, 1),
                emissiveFactor: simd_float3(0.8, 0.6, 0.4),
                metallicFactor: 0.0,
                roughnessFactor: 1.0
            ),
            device: renderInfo.device
        )
        for meshIndex in meshes.indices {
            for submeshIndex in meshes[meshIndex].submeshes.indices {
                meshes[meshIndex].submeshes[submeshIndex].material = emissiveMaterial
            }
        }
        if let renderComponent = scene.assign(to: entity, component: RenderComponent.self) {
            renderComponent.mesh = meshes
            renderComponent.assetURL = URL(fileURLWithPath: "/dev/null/twin.untold")
        }
        if let local = scene.get(component: LocalTransformComponent.self, for: entity) {
            local.position = position
            local.boundingBox = Mesh.computeMeshBoundingBox(for: meshes)
        }
        if let world = scene.get(component: WorldTransformComponent.self, for: entity) {
            var space = matrix_identity_float4x4
            space.columns.3 = simd_float4(position, 1.0)
            world.space = space
        }
        try setEntityGaussianTwin(entityId: entity, payloadURL: testPLYURL(), options: options)
        setVisibleEntities()
        return entity
    }

    /// Loads the twin's payload synchronously and puts the swap in `state`, the way the system
    /// would after its fade.
    private func loadPayloadAndForce(entity: EntityID, state: GaussianTwinState, progress: Float) async throws {
        let twin = try XCTUnwrap(scene.get(component: GaussianTwinComponent.self, for: entity))
        if !twin.payloadResident {
            let url = try XCTUnwrap(twin.payloadURL)
            let loaded = await loadGaussianTwinPayload(url: url)
            let result = try XCTUnwrap(loaded)
            withWorldMutationGate {
                applyGaussianTwinPayload(result, to: entity, twin: twin)
            }
        }
        forceTwin(entity: entity, state: state, progress: progress)
    }

    private func forceTwin(entity: EntityID, state: GaussianTwinState, progress: Float) {
        guard let twin = scene.get(component: GaussianTwinComponent.self, for: entity) else { return }
        // The camera is 5 m from the cube: a zero swap distance keeps the system wanting the
        // swap (crossFading/swapped hold), 1 m keeps it not wanting it (reverting/armed hold).
        twin.options.swapDistanceMeters = (state == .crossFading || state == .swapped) ? 0 : 1
        twin.state = state
        twin.fadeProgress = progress
        scene.get(component: GaussianComponent.self, for: entity)?.opacityScale = gaussianTwinSplatOpacity(state: state, progress: progress)
    }

    // MARK: - Readback

    private struct FrameReadback {
        /// Highest alpha anywhere in the splat target: is the splat visible somewhere.
        var splatMaxAlpha: Float
        /// Pixels of the lit opaque colour that differ from the empty-scene background.
        var litCoverage: Int
    }

    private func pixels(of texture: MTLTexture) -> [Float16] {
        precondition(texture.pixelFormat == .rgba16Float, "Test assumes rgba16Float targets")
        let width = texture.width
        let height = texture.height
        var data = [Float16](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return data
    }

    private var backgroundLit: [Float16]?

    /// Draws one frame and blocks until its command buffer completed, so the shared targets can
    /// be read back on the spot (no run-loop wait, which an async test could not service). The
    /// visible list is re-seeded first: the GPU cull of the previous frame is temporal (its HZB
    /// holds a full-frame cube's own near face), so the tests pin the list to every mesh entity
    /// the way the single-frame occlusion tests do.
    private func drawFrameAndWait() {
        setVisibleEntities()
        renderer.draw(in: renderer.metalView)
        renderInfo.lastCommandBuffer?.waitUntilCompleted()
    }

    private func render() throws -> FrameReadback {
        drawFrameAndWait()
        let splatTarget = try XCTUnwrap(renderInfo.gaussianRenderPassDescriptor.colorAttachments[0].texture)
        let lit = try XCTUnwrap(textureResources.deferredColorMap)

        let splat = pixels(of: splatTarget)
        var best: Float = 0
        var index = 3
        while index < splat.count {
            best = max(best, Float(splat[index]))
            index += 4
        }

        let litPixels = pixels(of: lit)
        let background = backgroundLit ?? [Float16](repeating: 0, count: litPixels.count)
        var covered = 0
        var pixel = 0
        while pixel < litPixels.count {
            let differs = (0 ..< 3).contains { abs(Float(litPixels[pixel + $0]) - Float(background[pixel + $0])) > 1e-3 }
            if differs {
                covered += 1
            }
            pixel += 4
        }
        return FrameReadback(splatMaxAlpha: best, litCoverage: covered)
    }

    /// Renders the camera alone and keeps its lit colour as the "nothing drawn" reference.
    private func captureBackground() throws {
        drawFrameAndWait()
        backgroundLit = try pixels(of: XCTUnwrap(textureResources.deferredColorMap))
    }

    // MARK: - Tests

    /// Swapped: the mesh draws no colour, yet its shrunk shell still hides the splat cloud that
    /// sits inside it. Turning the shell off (debug switch) is the control: the cloud shows.
    /// The splat cull's temporal HZB pre-cull is off so only the depth snapshot the splat pass
    /// tests against — the shell's depth — decides.
    func testSwappedTwinDrawsNoColourButItsShellStillOccludes() async throws {
        GaussianDebugOptions.shared.disableHZBOcclusionCull = true
        let eye = simd_float3(0, 3, 7)
        let target = simd_float3(0, 0, 0)
        createTestCamera(eye: eye, target: target)
        try captureBackground()

        let nearPoint = eye + 0.657 * (target - eye)
        let entity = try makeTwinCube(at: nearPoint)

        let armed = try render()
        XCTAssertGreaterThan(armed.litCoverage, 1000, "Sanity: the armed twin's mesh fills the frame")
        XCTAssertLessThan(armed.splatMaxAlpha, 0.05, "Nothing is loaded while armed")

        try await loadPayloadAndForce(entity: entity, state: .swapped, progress: 1)
        let swapped = try render()
        XCTAssertLessThan(swapped.litCoverage, armed.litCoverage / 50, "A swapped twin draws no colour (got \(swapped.litCoverage) of \(armed.litCoverage))")
        XCTAssertLessThan(swapped.splatMaxAlpha, 0.05, "The shell hides the cloud inside the mesh, got \(swapped.splatMaxAlpha)")

        GaussianDebugOptions.shared.disableTwinShell = true
        let noShell = try render()
        XCTAssertGreaterThan(noShell.splatMaxAlpha, 0.05, "Without the shell nothing writes the mesh's depth and the cloud shows")
        GaussianDebugOptions.shared.disableTwinShell = false
    }

    /// Mid cross-fade the mesh is screen-door dithered: about half its pixels are gone.
    func testCrossFadeDithersHalfTheMeshAtHalfProgress() async throws {
        let eye = simd_float3(0, 3, 7)
        let target = simd_float3(0, 0, 0)
        createTestCamera(eye: eye, target: target)
        try captureBackground()

        let nearPoint = eye + 0.657 * (target - eye)
        let entity = try makeTwinCube(at: nearPoint)
        let armed = try render()
        XCTAssertGreaterThan(armed.litCoverage, 1000)

        try await loadPayloadAndForce(entity: entity, state: .crossFading, progress: 0.5)
        let fading = try render()
        let ratio = Float(fading.litCoverage) / Float(armed.litCoverage)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.12, "Mode-2 dither at threshold 0.5 keeps about half the pixels, kept \(ratio)")

        forceTwin(entity: entity, state: .reverting, progress: 0.5)
        let reverting = try render()
        let revertRatio = Float(reverting.litCoverage) / Float(armed.litCoverage)
        XCTAssertEqual(revertRatio, 0.5, accuracy: 0.12, "Mode-1 dither at threshold 0.5 keeps the other half, kept \(revertRatio)")

        forceTwin(entity: entity, state: .armed, progress: 0)
        let back = try render()
        XCTAssertGreaterThan(back.litCoverage, armed.litCoverage * 9 / 10, "Armed again: the full mesh is back")
    }

    /// Where splats cannot be drawn (the iOS simulator creates no splat pipelines) a twin never
    /// leaves `armed`, so the mesh keeps its colour instead of turning into a depth-only hole.
    func testSwapHoldsArmedWhereSplatsCannotBeDrawn() throws {
        createTestCamera(eye: simd_float3(0, 3, 7), target: .zero)
        let entity = try makeTwinCube(at: .zero, options: GaussianTwinOptions(swapDistanceMeters: 0))
        let twin = try XCTUnwrap(scene.get(component: GaussianTwinComponent.self, for: entity))

        GaussianTwinSystem.shared.splatRenderingAvailableOverride = false
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .armed, "No splat pipelines: the mesh keeps showing")
        XCTAssertNil(twin.loadTask, "Nothing is loaded either")

        GaussianTwinSystem.shared.splatRenderingAvailableOverride = true
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .loading, "With the pipelines the same tick starts the swap")
        twin.loadTask?.cancel()
    }

    /// A `.untold` scene whose entity carries a `gaussianAsset` record with the `meshTwin` flag
    /// comes up with the twin linked and its settings seeded; the system then loads, fades,
    /// swaps, reverts by distance, and the ledger and bounding box account for both.
    func testUntoldSceneLinksTheTwinAndTheSystemRunsTheSwap() async throws {
        let fixture = try makeTwinSceneFixture()
        let entity = createEntity()
        setEntityMesh(entityId: entity, filename: fixture.untoldURL.deletingPathExtension().path, withExtension: "untold")

        let twin = try XCTUnwrap(scene.get(component: GaussianTwinComponent.self, for: entity), "The meshTwin record links a twin to the mesh entity")
        XCTAssertEqual(twin.payloadURL?.standardizedFileURL, fixture.payloadURL.standardizedFileURL, "Payload resolved next to the .untold file")
        XCTAssertEqual(twin.options.occluderShrinkMeters, 0.03)
        XCTAssertEqual(twin.options.exposureOffsetEV, 0.5)
        XCTAssertEqual(twin.options.swapDistanceMeters, 12)
        XCTAssertEqual(twin.state, .armed)
        let meshBox = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entity)).boundingBox
        XCTAssertEqual(meshBox.max.x, 1, accuracy: 1e-5, "Sanity: the fixture mesh box is the unit box")
        let meshBytes = MemoryBudgetManager.shared.getMemorySize(for: entity) ?? 0
        XCTAssertGreaterThan(meshBytes, 0, "The mesh registers its own bytes")

        // Far away: nothing happens.
        let camera = createTestCamera(eye: simd_float3(0, 0, 40), target: .zero)
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .armed)
        XCTAssertNil(scene.get(component: GaussianComponent.self, for: entity))

        // Within the swap distance: the payload loads, then the fade runs to the swap.
        cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 5), target: .zero, up: simd_float3(0, 1, 0))
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .loading)
        let deadline = Date().addingTimeInterval(15)
        while !twin.payloadResident, !twin.loadFailed, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(twin.payloadResident, "The .untoldgs payload should load")
        let gaussian = try XCTUnwrap(scene.get(component: GaussianComponent.self, for: entity))
        XCTAssertEqual(gaussian.exposureOffsetEV, 0.5, "The record's exposure offset reaches the splat")
        XCTAssertEqual(gaussian.opacityScale, 0, "Resident but hidden until the fade starts")

        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .crossFading)
        for _ in 0 ..< 4 {
            GaussianTwinSystem.shared.update(deltaTime: 0.1)
        }
        XCTAssertEqual(twin.state, .swapped)
        XCTAssertEqual(gaussian.opacityScale, 1)

        // The test cloud reaches about ±1.4 in x and y, past the fixture's unit box.
        let unionBox = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entity)).boundingBox
        XCTAssertLessThan(unionBox.min.x, meshBox.min.x, "The mesh box grows to the union with the splat's box")
        XCTAssertGreaterThan(unionBox.max.x, meshBox.max.x, "The mesh box grows to the union with the splat's box")
        XCTAssertLessThanOrEqual(simd_reduce_max(unionBox.min - meshBox.min), 0, "It never shrinks")
        XCTAssertGreaterThanOrEqual(simd_reduce_min(unionBox.max - meshBox.max), 0, "It never shrinks")
        XCTAssertEqual(MemoryBudgetManager.shared.getMemorySize(for: entity) ?? 0, meshBytes, "The mesh entry is untouched by the splat")
        XCTAssertEqual(MemoryBudgetManager.shared.auxiliaryMeshBytes(for: entity), twin.payloadGPUBytes, "The splat's bytes ride beside it")
        XCTAssertGreaterThan(twin.payloadGPUBytes, 0)

        // Beyond the swap distance plus hysteresis: the reverse fade ends armed, payload kept.
        cameraLookAt(entityId: camera, eye: simd_float3(0, 0, 40), target: .zero, up: simd_float3(0, 1, 0))
        GaussianTwinSystem.shared.update(deltaTime: 0.016)
        XCTAssertEqual(twin.state, .reverting)
        for _ in 0 ..< 4 {
            GaussianTwinSystem.shared.update(deltaTime: 0.1)
        }
        XCTAssertEqual(twin.state, .armed)
        XCTAssertEqual(gaussian.opacityScale, 0)
        XCTAssertTrue(twin.payloadResident, "A revert keeps the payload so the next swap is instant")

        // Unlinking drops the splat and its bytes; the mesh's stay.
        removeEntityGaussianTwin(entityId: entity)
        XCTAssertNil(scene.get(component: GaussianComponent.self, for: entity))
        XCTAssertNil(scene.get(component: GaussianTwinComponent.self, for: entity))
        XCTAssertEqual(MemoryBudgetManager.shared.getMemorySize(for: entity) ?? 0, meshBytes)
        XCTAssertEqual(MemoryBudgetManager.shared.auxiliaryMeshBytes(for: entity), 0)
    }

    // MARK: - .untold fixture with a gaussianAsset chunk

    private struct TwinSceneFixture {
        let untoldURL: URL
        let payloadURL: URL
    }

    private func makeTwinSceneFixture() throws -> TwinSceneFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaussianTwinRenderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryFiles.append(directory)

        // The payload: the test splat cooked to .untoldgs, next to the scene file.
        var cookOptions = UntoldGSCookOptions()
        cookOptions.log2ChunkSplats = 8
        let bake = try bakeGaussianSplatProgressiveTiers(
            plyURL: testPLYURL(),
            outputBaseURL: directory.appendingPathComponent("chair.untoldgs"),
            lodFractions: [1.0],
            cookOptions: cookOptions
        )
        let payloadURL = try XCTUnwrap(bake.tiers.first?.url)

        let strings = makeStringTable(["chair", "chair_mesh", "chair_mat", "albedo.ktx2", payloadURL.lastPathComponent])
        let bounds = UntoldAABB(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let entity = UntoldEntityRecordV1(
            entityId: 0,
            nameOffset: strings.offsets["chair"]!,
            firstMeshRecordIndex: 0,
            meshRecordCount: 1,
            localBounds: bounds,
            worldBounds: bounds
        )
        let material = UntoldMaterialRecordV1(
            nameOffset: strings.offsets["chair_mat"]!,
            baseColorTextureIndex: UntoldFormat.invalidIndex
        )
        let texture = UntoldTextureRefRecordV1(
            nameOffset: strings.offsets["albedo.ktx2"]!,
            uriOffset: strings.offsets["albedo.ktx2"]!,
            textureFormat: .rgba8,
            width: 16,
            height: 16,
            mipCount: 1
        )
        let vertexWriter = UntoldBinaryWriter()
        for position in [SIMD3<Float>(-1, -1, 0), SIMD3<Float>(1, -1, 0), SIMD3<Float>(0, 1, 0)] {
            UntoldPBRStaticVertexV1(
                position: position,
                normalPacked: UntoldVertexPacking.packNormal(SIMD3<Float>(0, 0, 1)),
                tangentPacked: UntoldVertexPacking.packTangent(SIMD3<Float>(1, 0, 0), handedness: 1)
            ).encode(to: vertexWriter)
        }
        let vertexData = vertexWriter.data
        let indexWriter = UntoldBinaryWriter()
        indexWriter.writeUInt16LE(0)
        indexWriter.writeUInt16LE(1)
        indexWriter.writeUInt16LE(2)
        let indexData = indexWriter.data
        let mesh = UntoldMeshRecordV1(
            entityId: 0,
            meshNameOffset: strings.offsets["chair_mesh"]!,
            materialIndex: 0,
            indexType: .uint16,
            vertexCount: 3,
            indexCount: 3,
            vertexStrideBytes: UInt32(vertexData.count / 3),
            vertexDataOffset: 0,
            indexDataOffset: 0,
            vertexDataSizeBytes: UInt64(vertexData.count),
            indexDataSizeBytes: UInt64(indexData.count),
            estimatedGPUBytes: UInt64(vertexData.count + indexData.count),
            localBounds: bounds
        )
        let twinRecord = UntoldGaussianAssetRecordV1(
            entityId: 0,
            payloadPathOffset: strings.offsets[payloadURL.lastPathComponent]!,
            flags: UntoldGaussianAssetFlags.meshTwin,
            lodCount: 1,
            occluderShrinkMeters: 0.03,
            exposureOffsetEV: 0.5,
            swapDistanceMeters: 12
        )

        var header = UntoldFileHeaderV1(
            fileType: .tile,
            chunkCount: 0,
            meshCount: 1,
            materialCount: 1,
            textureRefCount: 1,
            entityCount: 1,
            vertexLayout: .pbrStaticV1,
            worldBounds: bounds
        )
        let payloads: [(UntoldChunkType, Data, UInt32)] = [
            (.stringTable, strings.data, 0),
            (.entityTable, encodeRecords([entity]), 1),
            (.meshTable, encodeRecords([mesh]), 1),
            (.materialTable, encodeRecords([material]), 1),
            (.textureTable, encodeRecords([texture]), 1),
            (.vertexData, vertexData, 0),
            (.indexData, indexData, 0),
            (.gaussianAssetTable, encodeRecords([twinRecord]), 1),
        ]
        header.chunkCount = UInt32(payloads.count)
        let untoldURL = directory.appendingPathComponent("chair.untold")
        let fileData = buildFileData(header: header, payloads: payloads)
        try fileData.write(to: untoldURL, options: .atomic)
        let decoded = try UntoldReader().readAsset(from: fileData)
        XCTAssertEqual(decoded.gaussianAssets.count, 1, "Fixture carries one gaussianAsset record")
        return TwinSceneFixture(untoldURL: untoldURL, payloadURL: payloadURL)
    }

    private func encodeRecords(_ records: [some UntoldBinaryEncodable]) -> Data {
        let writer = UntoldBinaryWriter()
        for record in records {
            record.encode(to: writer)
        }
        return writer.data
    }

    private func makeStringTable(_ strings: [String]) -> (data: Data, offsets: [String: UInt32]) {
        let writer = UntoldBinaryWriter()
        var offsets: [String: UInt32] = [:]
        for string in strings {
            offsets[string] = UInt32(writer.count)
            writer.writeNullTerminatedUTF8(string)
        }
        return (writer.data, offsets)
    }

    private func buildFileData(header: UntoldFileHeaderV1, payloads: [(UntoldChunkType, Data, UInt32)]) -> Data {
        let headerWriter = UntoldBinaryWriter()
        header.encode(to: headerWriter)
        let alignment = Int(UntoldFormat.fileAlignment)
        func aligned(_ value: Int) -> Int {
            let remainder = value % alignment
            return remainder == 0 ? value : value + (alignment - remainder)
        }

        var runningOffset = headerWriter.count + 40 * payloads.count
        var entries: [UntoldChunkEntryV1] = []
        for payload in payloads {
            runningOffset = aligned(runningOffset)
            entries.append(UntoldChunkEntryV1(
                chunkType: payload.0,
                fileOffset: UInt64(runningOffset),
                compressedSize: UInt64(payload.1.count),
                uncompressedSize: UInt64(payload.1.count),
                elementCount: payload.2
            ))
            runningOffset += payload.1.count
        }

        let writer = UntoldBinaryWriter()
        header.encode(to: writer)
        for entry in entries {
            entry.encode(to: writer)
        }
        for payload in payloads {
            writer.align(to: alignment)
            writer.writeData(payload.1)
        }
        return writer.data
    }
}
