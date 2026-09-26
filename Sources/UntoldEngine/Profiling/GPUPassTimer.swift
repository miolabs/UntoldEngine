//
//  GPUPassTimer.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal

/// GPU time of one labelled pass in the most recently resolved frame.
public struct GPUPassTiming: Codable, Equatable, Sendable {
    public let label: String
    /// GPU time from the pass's first stage start to its last stage end, in milliseconds.
    /// Passes encoded more than once per frame under the same label (one per eye) are summed.
    public let ms: Double
    /// How many encoders reported under this label.
    public let count: Int

    public init(label: String, ms: Double, count: Int) {
        self.label = label
        self.ms = ms
        self.count = count
    }
}

/// Per-pass GPU timings of the last frame whose command buffer completed.
public struct GPUPassTimingSnapshot: Codable, Equatable, Sendable {
    /// Counts frames the timer has resolved since it was enabled or reset.
    public var frameIndex: UInt64 = 0
    /// Timed passes in encode order.
    public var passes: [GPUPassTiming] = []
    /// Sum of all pass times. Passes can overlap on the GPU, so this is an upper bound on the
    /// frame's GPU time, not the command buffer duration.
    public var totalMs: Double = 0.0
    /// Passes that did not get a sample slot because the frame exceeded `GPUPassTimer.maxPassesPerFrame`.
    public var passesSkipped: Int = 0

    public init(frameIndex: UInt64 = 0, passes: [GPUPassTiming] = [], totalMs: Double = 0.0, passesSkipped: Int = 0) {
        self.frameIndex = frameIndex
        self.passes = passes
        self.totalMs = totalMs
        self.passesSkipped = passesSkipped
    }

    public func ms(for label: String) -> Double? {
        passes.first { $0.label == label }?.ms
    }
}

/// Times every labelled render, compute and blit pass of the frame command buffer on the GPU.
///
/// Uses `MTLCounterSampleBuffer` timestamps at stage boundaries, the only sampling point Apple GPUs
/// support, so each pass costs two samples and no extra GPU work. Passes attach through the
/// `MTLCommandBuffer.makeRenderCommandEncoder(descriptor:passLabel:)` family of helpers; when the
/// timer is off, or the command buffer is not the one registered with `beginFrame`, those helpers
/// behave exactly like the plain Metal calls.
///
/// Results are resolved on the command buffer's completion handler and read with `snapshot()`.
/// Enable at runtime with `isEnabled = true` or the environment variable `UNTOLD_GPU_PASS_TIMING=1`.
public final class GPUPassTimer: @unchecked Sendable {
    public static let shared = GPUPassTimer()

    /// Upper bound on timed passes per frame; two timestamp samples are reserved per pass.
    public static let maxPassesPerFrame = 128

    private struct PendingPass {
        let label: String
        let startIndex: Int
        let endIndex: Int
    }

    /// Mutated only under the timer lock while the frame is being encoded; read by the completion
    /// handler after the GPU finished, when no further mutation happens.
    private final class FrameRecord: @unchecked Sendable {
        let commandBufferID: ObjectIdentifier
        let sampleBuffer: MTLCounterSampleBuffer
        var passes: [PendingPass] = []
        var nextSampleIndex = 0
        var skipped = 0

        init(commandBufferID: ObjectIdentifier, sampleBuffer: MTLCounterSampleBuffer) {
            self.commandBufferID = commandBufferID
            self.sampleBuffer = sampleBuffer
        }
    }

    private let lock = NSLock()
    private var _isEnabled: Bool
    private var configuredDevice: ObjectIdentifier?
    private var _isSupported = false
    private var timestampCounterSet: MTLCounterSet?
    private var pool: [MTLCounterSampleBuffer] = []
    private var current: FrameRecord?
    private var latest = GPUPassTimingSnapshot()
    private var resolvedFrames: UInt64 = 0
    private var nanosecondsPerGPUTick: Double = 1.0
    private var calibration: (cpu: UInt64, gpu: UInt64)?
    private var isCalibrated = false
    /// Set once any descriptor received a sample-buffer attachment, so disabling the timer can clear it again.
    private var descriptorsTouched = false

    private init() {
        _isEnabled = ProcessInfo.processInfo.environment["UNTOLD_GPU_PASS_TIMING"] == "1"
    }

    /// Whether passes are timed. Takes effect at the next `beginFrame`.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            _isEnabled = newValue
            lock.unlock()
        }
    }

    /// Whether the device seen by the last `beginFrame` supports stage-boundary timestamp sampling.
    /// False until the first enabled frame runs.
    public var isSupported: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSupported
    }

    public func snapshot() -> GPUPassTimingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public func reset() {
        lock.lock()
        latest = GPUPassTimingSnapshot()
        resolvedFrames = 0
        lock.unlock()
    }

    // MARK: - Frame lifecycle

    /// Registers the frame command buffer. Only passes encoded into this command buffer are timed,
    /// and its completion handler resolves the samples. Call before encoding, `endFrame()` after commit.
    public func beginFrame(commandBuffer: MTLCommandBuffer) {
        lock.lock()
        guard _isEnabled else {
            current = nil
            lock.unlock()
            return
        }
        configureIfNeeded(device: commandBuffer.device)
        guard _isSupported, let sampleBuffer = pool.popLast() ?? makeSampleBuffer(device: commandBuffer.device) else {
            current = nil
            lock.unlock()
            return
        }
        calibrateIfNeeded(device: commandBuffer.device)
        let record = FrameRecord(commandBufferID: ObjectIdentifier(commandBuffer), sampleBuffer: sampleBuffer)
        current = record
        lock.unlock()

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.resolve(record)
        }
    }

    /// Ends the timed frame. Passes attached afterwards are not timed until the next `beginFrame`.
    public func endFrame() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    // MARK: - Attaching passes

    /// Attaches timestamp samples to a render pass descriptor. Clears any earlier attachment when
    /// the timer is off, so descriptors the engine reuses every frame do not keep stale sample buffers.
    public func attach(to descriptor: MTLRenderPassDescriptor, label: String, commandBuffer: MTLCommandBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let range = reserveSamples(for: label, commandBuffer: commandBuffer) else {
            if descriptorsTouched {
                descriptor.sampleBufferAttachments[0]?.sampleBuffer = nil
            }
            return
        }
        guard let attachment = descriptor.sampleBufferAttachments[0] else { return }
        attachment.sampleBuffer = range.sampleBuffer
        attachment.startOfVertexSampleIndex = range.start
        attachment.endOfVertexSampleIndex = MTLCounterDontSample
        attachment.startOfFragmentSampleIndex = MTLCounterDontSample
        attachment.endOfFragmentSampleIndex = range.end
        descriptorsTouched = true
    }

    /// Returns a compute pass descriptor with timestamp samples attached, or nil when the pass should
    /// use a plain encoder (timer off, unsupported, or a foreign command buffer).
    public func makeComputePassDescriptor(label: String, commandBuffer: MTLCommandBuffer) -> MTLComputePassDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = reserveSamples(for: label, commandBuffer: commandBuffer) else { return nil }
        let descriptor = MTLComputePassDescriptor()
        guard let attachment = descriptor.sampleBufferAttachments[0] else { return nil }
        attachment.sampleBuffer = range.sampleBuffer
        attachment.startOfEncoderSampleIndex = range.start
        attachment.endOfEncoderSampleIndex = range.end
        return descriptor
    }

    /// Returns a blit pass descriptor with timestamp samples attached, or nil (see `makeComputePassDescriptor`).
    public func makeBlitPassDescriptor(label: String, commandBuffer: MTLCommandBuffer) -> MTLBlitPassDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = reserveSamples(for: label, commandBuffer: commandBuffer) else { return nil }
        let descriptor = MTLBlitPassDescriptor()
        guard let attachment = descriptor.sampleBufferAttachments[0] else { return nil }
        attachment.sampleBuffer = range.sampleBuffer
        attachment.startOfEncoderSampleIndex = range.start
        attachment.endOfEncoderSampleIndex = range.end
        return descriptor
    }

    // MARK: - Internals (call with the lock held)

    private func reserveSamples(for label: String, commandBuffer: MTLCommandBuffer)
        -> (sampleBuffer: MTLCounterSampleBuffer, start: Int, end: Int)?
    {
        guard let record = current, record.commandBufferID == ObjectIdentifier(commandBuffer) else { return nil }
        let start = record.nextSampleIndex
        guard start + 2 <= Self.maxPassesPerFrame * 2 else {
            record.skipped += 1
            return nil
        }
        record.nextSampleIndex = start + 2
        record.passes.append(PendingPass(label: label, startIndex: start, endIndex: start + 1))
        return (record.sampleBuffer, start, start + 1)
    }

    private func configureIfNeeded(device: MTLDevice) {
        let deviceID = ObjectIdentifier(device)
        guard configuredDevice != deviceID else { return }
        configuredDevice = deviceID
        pool.removeAll()
        isCalibrated = false
        calibration = nil
        nanosecondsPerGPUTick = 1.0
        timestampCounterSet = device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
        _isSupported = device.supportsCounterSampling(.atStageBoundary) && timestampCounterSet != nil
    }

    private func makeSampleBuffer(device: MTLDevice) -> MTLCounterSampleBuffer? {
        guard let counterSet = timestampCounterSet else { return nil }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = counterSet
        descriptor.storageMode = .shared
        descriptor.sampleCount = Self.maxPassesPerFrame * 2
        descriptor.label = "GPUPassTimer samples"
        return try? device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    /// `MTLDevice.sampleTimestamps()` reports the CPU and GPU clocks in nanoseconds, and GPU
    /// timestamps tick in nanoseconds on Apple GPUs. The unit is not guaranteed by the API, so
    /// sample both clocks on two frames at least 100 ms apart and take the ratio; on Apple
    /// silicon it comes out at 1.0 and the pass times match `gpuEndTime - gpuStartTime`.
    private func calibrateIfNeeded(device: MTLDevice) {
        guard !isCalibrated else { return }
        let sample = device.sampleTimestamps()
        guard let first = calibration else {
            calibration = (sample.cpu, sample.gpu)
            return
        }
        let cpuDeltaNs = Double(sample.cpu &- first.cpu)
        guard cpuDeltaNs >= 100_000_000, sample.gpu > first.gpu else { return }
        let ratio = cpuDeltaNs / Double(sample.gpu - first.gpu)
        // Guard against a nonsensical sample (clock reset); keep the 1 ns default in that case.
        if ratio.isFinite, ratio > 0.0001, ratio < 10000 {
            nanosecondsPerGPUTick = ratio
        }
        isCalibrated = true
    }

    // MARK: - Resolve (completion handler thread)

    private func resolve(_ record: FrameRecord) {
        let sampleCount = record.nextSampleIndex
        var passes: [GPUPassTiming] = []
        var indexByLabel: [String: Int] = [:]
        var totalMs = 0.0

        lock.lock()
        let nsPerTick = nanosecondsPerGPUTick
        lock.unlock()

        if sampleCount > 0, let data = try? record.sampleBuffer.resolveCounterRange(0 ..< sampleCount) {
            let stamps: [MTLCounterResultTimestamp] = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: MTLCounterResultTimestamp.self))
            }
            for pass in record.passes where pass.endIndex < stamps.count {
                let start = stamps[pass.startIndex].timestamp
                let end = stamps[pass.endIndex].timestamp
                guard start != MTLCounterErrorValue, end != MTLCounterErrorValue, end >= start else { continue }
                let ms = Double(end - start) * nsPerTick / 1_000_000.0
                totalMs += ms
                if let index = indexByLabel[pass.label] {
                    let merged = passes[index]
                    passes[index] = GPUPassTiming(label: merged.label, ms: merged.ms + ms, count: merged.count + 1)
                } else {
                    indexByLabel[pass.label] = passes.count
                    passes.append(GPUPassTiming(label: pass.label, ms: ms, count: 1))
                }
            }
        }

        lock.lock()
        resolvedFrames &+= 1
        latest = GPUPassTimingSnapshot(
            frameIndex: resolvedFrames,
            passes: passes,
            totalMs: totalMs,
            passesSkipped: record.skipped
        )
        pool.append(record.sampleBuffer)
        lock.unlock()
    }
}

// MARK: - Encoder helpers

public extension MTLCommandBuffer {
    /// Creates a render command encoder labelled `passLabel`, timed by `GPUPassTimer` when it is
    /// enabled and this is the frame command buffer. Otherwise identical to `makeRenderCommandEncoder(descriptor:)`.
    func makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor, passLabel: String) -> MTLRenderCommandEncoder? {
        GPUPassTimer.shared.attach(to: descriptor, label: passLabel, commandBuffer: self)
        let encoder = makeRenderCommandEncoder(descriptor: descriptor)
        encoder?.label = passLabel
        return encoder
    }

    /// Creates a compute command encoder labelled `passLabel`, timed by `GPUPassTimer` when possible.
    func makeComputeCommandEncoder(passLabel: String) -> MTLComputeCommandEncoder? {
        if let descriptor = GPUPassTimer.shared.makeComputePassDescriptor(label: passLabel, commandBuffer: self),
           let encoder = makeComputeCommandEncoder(descriptor: descriptor)
        {
            encoder.label = passLabel
            return encoder
        }
        let encoder = makeComputeCommandEncoder()
        encoder?.label = passLabel
        return encoder
    }

    /// Creates a blit command encoder labelled `passLabel`, timed by `GPUPassTimer` when possible.
    func makeBlitCommandEncoder(passLabel: String) -> MTLBlitCommandEncoder? {
        if let descriptor = GPUPassTimer.shared.makeBlitPassDescriptor(label: passLabel, commandBuffer: self),
           let encoder = makeBlitCommandEncoder(descriptor: descriptor)
        {
            encoder.label = passLabel
            return encoder
        }
        let encoder = makeBlitCommandEncoder()
        encoder?.label = passLabel
        return encoder
    }
}
