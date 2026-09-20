//
//  EngineStatsFormatter.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum EngineStatsFormatStyle {
    case compact
    case expanded
}

public func formatEngineStats(_ snapshot: EngineStatsSnapshot, style: EngineStatsFormatStyle = .expanded) -> String {
    switch style {
    case .compact:
        return compactEngineStatsString(snapshot)
    case .expanded:
        return expandedEngineStatsString(snapshot)
    }
}

public func formatEngineStatsCompact(_ snapshot: EngineStatsSnapshot) -> String {
    formatEngineStats(snapshot, style: .compact)
}

public func formatEngineStatsOverlay(_ snapshot: EngineStatsSnapshot) -> String {
    formatEngineStats(snapshot, style: .expanded)
}

private func compactEngineStatsString(_ snapshot: EngineStatsSnapshot) -> String {
    "frame=\(snapshot.frameIndex) " +
        "cpuFPS=\(formatFPS(frameMs: snapshot.timing.smoothedFrameMs)) " +
        "gpuFPS=\(formatFPS(frameMs: snapshot.timing.gpuFrameCadenceMs)) " +
        "cpuMs=\(formatMs(snapshot.timing.smoothedFrameMs)) " +
        "gpuExecMs=\(formatMs(snapshot.timing.gpuExecutionMs)) " +
        "updateMs=\(formatMs(snapshot.timing.updateMs)) " +
        "renderMs=\(formatMs(snapshot.timing.renderTotalMs)) " +
        "cullMs=\(formatMs(snapshot.timing.cullingMs)) " +
        "drawCalls=\(snapshot.render.drawCallsTotal) " +
        "triangles=\(snapshot.render.trianglesTotal) " +
        "visible=\(snapshot.render.visibleInstances)"
}

private func expandedEngineStatsString(_ snapshot: EngineStatsSnapshot) -> String {
    let cpuBound = snapshot.timing.gpuFrameCadenceMs <= 0
        || snapshot.timing.smoothedFrameMs >= snapshot.timing.gpuFrameCadenceMs * 0.9
    let bottleneck = cpuBound ? "CPU-bound" : "GPU-bound"
    let meshMB = formatMB(snapshot.memory.meshMemoryBytes)
    let meshBudgetMB = formatMB(snapshot.memory.geometryBudgetBytes)
    let texMB = formatMB(snapshot.memory.textureMemoryBytes)
    let texBudgetMB = formatMB(snapshot.memory.textureBudgetBytes)
    let memPct = String(format: "%.0f%%", snapshot.memory.utilizationPercent * 100)
    let pressure = snapshot.memory.isUnderPressure ? " PRESSURE" : ""
    let compositorLine = compositorStatsLine(snapshot)
    let gpuPassLine = gpuPassStatsLine(snapshot)
    return """
    Frame \(snapshot.frameIndex) | CPU \(formatMs(snapshot.timing.smoothedFrameMs))ms (\(formatFPS(frameMs: snapshot.timing.smoothedFrameMs)) fps, smoothed)  GPU \(formatMs(snapshot.timing.gpuExecutionMs))ms exec / \(formatFPS(frameMs: snapshot.timing.gpuFrameCadenceMs)) fps cadence  [\(bottleneck)]
    Timing: frame \(formatMs(snapshot.timing.frameTotalMs))ms (raw CPU) | update \(formatMs(snapshot.timing.updateMs))ms | render \(formatMs(snapshot.timing.renderTotalMs))ms | cull \(formatMs(snapshot.timing.cullingMs))ms | stream \(formatMs(snapshot.timing.streamingRegionMs + snapshot.timing.geometryStreamingMs))ms | batchTick \(formatMs(snapshot.timing.batchingTickMs))ms | batchRebuild \(formatMs(snapshot.timing.batchingRebuildMs))ms
    Systems: scenegraph \(formatMs(snapshot.timing.scenegraphMs))ms | extensions \(formatMs(snapshot.timing.extensionsUpdateMs))ms | lod \(formatMs(snapshot.timing.lodMs))ms | animation \(formatMs(snapshot.timing.animationMs))ms | scripting \(formatMs(snapshot.timing.scriptingMs))ms | physics \(formatMs(snapshot.timing.physicsMs))ms (\(snapshot.timing.physicsStepCount) steps) | custom \(formatMs(snapshot.timing.customSystemsMs))ms | game \(formatMs(snapshot.timing.gameUpdateMs))ms | semWait \(formatMs(snapshot.timing.semaphoreWaitMs))ms
    Render: draws \(snapshot.render.drawCallsTotal) (opaque \(snapshot.render.drawCallsOpaque), transparent \(snapshot.render.drawCallsTransparent), shadow \(snapshot.render.drawCallsShadow), batched \(snapshot.render.drawCallsBatched)) | triangles \(snapshot.render.trianglesTotal) | visible \(snapshot.render.visibleInstances)
    Culling: frustum \(snapshot.culling.frustumPassed)/\(snapshot.culling.frustumTested) failed \(snapshot.culling.frustumFailed) | occlusion \(snapshot.culling.occlusionPassed)/\(snapshot.culling.occlusionTested) failed \(snapshot.culling.occlusionFailed) | usedHZB \(snapshot.culling.usedHZB) validHZB \(snapshot.culling.hzbIsValid)
    Streaming: loaded \(snapshot.streaming.loadedStreamingEntities) loading \(snapshot.streaming.loadingStreamingEntities) unloaded \(snapshot.streaming.unloadedStreamingEntities) | active \(snapshot.streaming.activeLoads) | nearby \(snapshot.streaming.nearbyEntitiesQueried) candidates \(snapshot.streaming.loadCandidates) slots \(snapshot.streaming.availableLoadSlots) | backlog \(snapshot.streaming.pendingLoadBacklog) | pendingUploads \(snapshot.streaming.pendingUploadCount) | gateMs \(formatMs(snapshot.streaming.blockedByGateMs))
    Streaming: tick=\(snapshot.streaming.updateTriggered) workMs \(formatMs(snapshot.streaming.updateWorkMs)) | evictions \(snapshot.streaming.evictionsPerformed) | avgLoadMs \(formatMs(snapshot.streaming.averageAsyncLoadMs)) | applyMs \(formatMs(snapshot.streaming.lastApplyLoadedMeshMs)) | tileSwapWarn \(snapshot.streaming.tileSwapWarnings) | repGap \(snapshot.streaming.tileRepresentationGapWarnings) | lod0VisWarn \(snapshot.streaming.lod0VisibilityWarnings) covered \(snapshot.streaming.lod0VisibilityWarningsWithFallback) open \(snapshot.streaming.lod0VisibilityWarningsNoFallback) | hierGateSkip \(snapshot.streaming.tilesSkippedByHierarchyGate)
    TileReps: resident full/lod/hlod \(snapshot.streaming.residentFullTileRepresentations)/\(snapshot.streaming.residentLODRepresentations)/\(snapshot.streaming.residentHLODRepresentations) | visible full/lod/hlod \(snapshot.streaming.visibleFullTileRepresentations)/\(snapshot.streaming.visibleLODRepresentations)/\(snapshot.streaming.visibleHLODRepresentations) | overlap visible full+lod/full+hlod/lod+hlod \(snapshot.streaming.fullAndLODVisibleOverlapTiles)/\(snapshot.streaming.fullAndHLODVisibleOverlapTiles)/\(snapshot.streaming.lodAndHLODVisibleOverlapTiles) residentFull+fallback \(snapshot.streaming.fullAndFallbackResidentOverlapTiles) | fades \(snapshot.streaming.activeTileRepresentationFades) waiting \(snapshot.streaming.waitingTileRepresentationFades)
    TileRenderCost: visible full/lod/hlod \(snapshot.render.tileFullVisibleInstances)/\(snapshot.render.tileLODVisibleInstances)/\(snapshot.render.tileHLODVisibleInstances) | draws full/lod/hlod \(snapshot.render.tileFullDrawsEstimate)/\(snapshot.render.tileLODDrawsEstimate)/\(snapshot.render.tileHLODDrawsEstimate) | tris full/lod/hlod \(snapshot.render.tileFullTrianglesEstimate)/\(snapshot.render.tileLODTrianglesEstimate)/\(snapshot.render.tileHLODTrianglesEstimate)
    Batching: groups \(snapshot.batching.batchGroupCount) | batchedMeshes \(snapshot.batching.batchedMeshCount) | dirty \(snapshot.batching.dirtyCellsBeforePrune)→\(snapshot.batching.dirtyCellsAfterPrune) | defWork \(snapshot.batching.deferredByWorkBudget) skipComplex \(snapshot.batching.skippedByComplexityGuard) | dispatched \(snapshot.batching.dispatchedBuilds)→\(snapshot.batching.lastRebuildOutputBatchCount) groups | rebuilds/s \(snapshot.batching.rebuildsThisSecond) | rebuildMs \(formatMs(snapshot.batching.lastRebuildCostMs))
    Memory: mesh \(meshMB)/\(meshBudgetMB)mb | tex \(texMB)/\(texBudgetMB)mb | total \(memPct) | entities \(snapshot.memory.trackedEntityCount)\(pressure)\(compositorLine)\(gpuPassLine)
    """
}

/// One line with the heaviest GPU passes of the last resolved frame, prefixed with a newline.
/// Empty when the GPU pass timer is off.
private func gpuPassStatsLine(_ snapshot: EngineStatsSnapshot) -> String {
    let g = snapshot.gpuPasses
    guard !g.passes.isEmpty else { return "" }
    let shown = g.passes.sorted { $0.ms > $1.ms }.prefix(12)
    let entries = shown.map { pass -> String in
        let repeats = pass.count > 1 ? "x\(pass.count)" : ""
        return "\(pass.label)\(repeats) \(formatMs(pass.ms))"
    }.joined(separator: " | ")
    let skipped = g.passesSkipped > 0 ? " skipped \(g.passesSkipped)" : ""
    return "\nGPU passes (\(g.passes.count), sum \(formatMs(g.totalMs))ms\(skipped)): \(entries)"
}

/// One line of Compositor Services frame accounting, prefixed with a newline so it can be appended
/// to the expanded block. Empty when the frame was not rendered through Compositor Services.
private func compositorStatsLine(_ snapshot: EngineStatsSnapshot) -> String {
    let c = snapshot.compositor
    guard c.viewCount > 0 else { return "" }
    let missRate = String(format: "%.2f%%", c.missedDeadlineRate * 100)
    let missed = c.missedDeadline ? " MISSED" : ""
    return "\nCompositor: views \(c.viewCount) @ \(c.viewTextureWidth)x\(c.viewTextureHeight) | update \(formatMs(c.updateMs))ms | inputSlack \(formatMs(c.inputSlackMs))ms | submit \(formatMs(c.submissionMs))ms | semWait \(formatMs(snapshot.timing.semaphoreWaitMs))ms | deadlineMargin \(formatMs(c.deadlineMarginMs))ms\(missed) | presentMargin \(formatMs(c.presentationMarginMs))ms | missed \(c.missedDeadlineCount)/\(c.deadlineSampleCount) (\(missRate)) | noAnchor \(c.missingAnchorCount)"
}

private func formatMB(_ bytes: Int) -> String {
    String(format: "%.0f", Double(bytes) / (1024 * 1024))
}

private func formatMs(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func formatFPS(frameMs: Double) -> String {
    guard frameMs > 0 else { return "0.0" }
    return String(format: "%.1f", 1000.0 / frameMs)
}
