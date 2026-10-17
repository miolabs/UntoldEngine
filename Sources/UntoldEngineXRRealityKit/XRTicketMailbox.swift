//
//  XRTicketMailbox.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Metal

/// One frame the presenter asks the engine for: the command buffer RealityKit's replace calls
/// were made on, the Metal textures and grid buffers they handed back for it, and when it was
/// posted. The command buffer must be committed exactly once, by whoever holds the ticket
/// last: the loop after the frame's drawing, or the mailbox when it closes on a pending one.
public struct XRPresenterTicket: @unchecked Sendable {
    public let serial: UInt64
    public let commandBuffer: MTLCommandBuffer
    /// One per eye, left first: the textures to draw the frame into.
    public let colorTextures: [MTLTexture]
    /// One per eye, left first: the grids' vertex buffers for this frame.
    public let gridBuffers: [MTLBuffer]
    /// `CACurrentMediaTime()` when the ticket was posted.
    public let postedAt: TimeInterval

    public init(serial: UInt64, commandBuffer: MTLCommandBuffer, colorTextures: [MTLTexture], gridBuffers: [MTLBuffer], postedAt: TimeInterval) {
        self.serial = serial
        self.commandBuffer = commandBuffer
        self.colorTextures = colorTextures
        self.gridBuffers = gridBuffers
        self.postedAt = postedAt
    }
}

/// The main thread posts one ticket per RealityKit frame; the engine's thread takes it. One
/// slot, never a queue: a ticket's command buffer must be committed once the replace calls ran
/// on it, so while the engine has not taken the previous ticket the main thread posts nothing
/// for its frame (a drop the presenter counts) rather than replacing it.
public final class XRTicketMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: XRPresenterTicket?
    private var closed = false

    public init() {}

    /// Whether a ticket waits to be taken.
    public var hasPending: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pending != nil
    }

    public var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    /// Posts when the slot is free and the mailbox open; false otherwise, and the caller commits
    /// the ticket's command buffer itself.
    public func post(_ ticket: XRPresenterTicket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard pending == nil, !closed else { return false }
        pending = ticket
        condition.signal()
        return true
    }

    /// Blocks until a ticket is posted; nil once the mailbox is closed.
    public func take() -> XRPresenterTicket? {
        condition.lock()
        defer { condition.unlock() }
        while pending == nil, !closed {
            condition.wait()
        }
        let ticket = pending
        pending = nil
        return ticket
    }

    /// Ends the exchange: `take` returns nil from now on and `post` false; a pending ticket's
    /// command buffer is committed empty, so that RealityKit's bookkeeping of its replace calls
    /// completes.
    public func close() {
        condition.lock()
        closed = true
        let leftover = pending
        pending = nil
        condition.broadcast()
        condition.unlock()
        leftover?.commandBuffer.commit()
    }
}
