//
//  XRPresenterPipelineDepthTests.swift
//  UntoldEngine
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
@testable import UntoldEngine
import UntoldEngineXR
@testable import UntoldEngineXRRealityKit
import XCTest

// MARK: - The refresh, the lead and the late count

/// The pipeline two refreshes deep, without a presenter: the refresh period measured from the
/// updates, the lead one refresh longer, the late count against the refreshes planned.
final class XRPresenterPipelineDepthTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        var now: TimeInterval

        init(_ now: TimeInterval) {
            self.now = now
        }
    }

    func test_theRefresh_isTheIntervalBetweenUpdates_averaged_withStallsLeftOut() {
        var refresh = XRPresenterRefresh()
        XCTAssertEqual(refresh.seconds, 0, "nothing until two updates")
        refresh.noteUpdate(at: 100)
        XCTAssertEqual(refresh.seconds, 0)
        refresh.noteUpdate(at: 100.010)
        XCTAssertEqual(refresh.seconds, 0.010, accuracy: 1e-9, "the first interval is taken as it is")
        for update in 2 ... 40 {
            refresh.noteUpdate(at: 100 + Double(update) * 0.010)
        }
        XCTAssertEqual(refresh.seconds, 0.010, accuracy: 1e-9, "100 updates a second: a 10 ms refresh")

        // The display goes to 90 Hz (50 Hz lighting): followed within a few updates.
        var now = 100.4
        for _ in 0 ..< 40 {
            now += 1.0 / 90
            refresh.noteUpdate(at: now)
        }
        XCTAssertEqual(refresh.seconds, 1.0 / 90, accuracy: 1e-4, "90 updates a second: 11.1 ms")

        // A stall (the space opening) is not a refresh and is left out; the next interval is
        // measured from its end. A doubled update neither.
        now += 0.5
        refresh.noteUpdate(at: now)
        XCTAssertEqual(refresh.seconds, 1.0 / 90, accuracy: 1e-4)
        now += 1.0 / 90
        refresh.noteUpdate(at: now)
        XCTAssertEqual(refresh.seconds, 1.0 / 90, accuracy: 1e-4)
        now += 0.001
        refresh.noteUpdate(at: now)
        XCTAssertEqual(refresh.seconds, 1.0 / 90, accuracy: 1e-4)
        XCTAssertEqual(refresh.lastUpdate, now)
    }

    func test_theLead_gainsOneMeasuredRefresh_twoRefreshesDeep_fixedOrAdaptive() {
        var settings = XRPresenterSettings()
        settings.leadSeconds = 0.0222
        settings.displayLatencySeconds = 0.016
        XCTAssertEqual(settings.pipelineDepth, 1, "one refresh deep by default")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0.010, frameSecondsAverage: nil), 0.0232, accuracy: 1e-12, "one deep, the refresh changes nothing")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, frameSecondsAverage: nil), 0.0232, accuracy: 1e-12, "and the lead is what it was")

        settings.pipelineDepth = 2
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0.010, frameSecondsAverage: nil), 0.0332, accuracy: 1e-12, "two deep: the fixed lead plus the 10 ms refresh")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 1.0 / 90, frameSecondsAverage: nil), 0.0232 + 1.0 / 90, accuracy: 1e-12, "plus the 11.1 ms refresh at 90 Hz: measured, never assumed")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0, frameSecondsAverage: nil), 0.0232, accuracy: 1e-12, "a refresh not yet measured adds nothing")

        settings.adaptiveLead = true
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0.010, frameSecondsAverage: 0.0064), 0.001 + 0.0064 + 0.016 + 0.010, accuracy: 1e-12, "the adaptive lead plus the refresh")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0.010, frameSecondsAverage: 0.2), XRPresenterLead.maximumSeconds + 0.010, accuracy: 1e-12, "the clamp holds the measured part; the plan's refresh rides on top")
        XCTAssertEqual(XRPresenterLead.seconds(settings: settings, ageSeconds: 0.001, refreshSeconds: 0.010, frameSecondsAverage: nil), 0.0332, accuracy: 1e-12, "before a frame completed, the fixed lead plus the refresh")

        var configuration = XRRealityKitPresenterConfiguration()
        XCTAssertEqual(configuration.pipelineDepth, 1)
        configuration.pipelineDepth = 2
        XCTAssertEqual(XRPresenterSettings(configuration: configuration).pipelineDepth, 2, "the configuration's depth reaches the settings")
    }

    func test_theLateCount_isAgainstTheRefreshesPlanned() {
        let clock = TestClock(1000)
        let statistics = XRPresenterStatistics(clock: { clock.now })
        for _ in 0 ..< 100 {
            statistics.noteUpdate()
        }
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.003, wait: 0.001, gpu: 0.005)) // 9.0 ms, on time one deep
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.0031, wait: 0.0092, gpu: 0.0043), plannedRefreshes: 1) // 16.6 ms, late one deep
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.004, wait: 0.0001, gpu: 0.0125), plannedRefreshes: 2) // 16.6 ms, on time two deep
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.004, wait: 0.0001, gpu: 0.020), plannedRefreshes: 2) // 24.1 ms, late even two deep
        clock.now += 1
        let two = statistics.snapshot()
        XCTAssertEqual(two.refreshMs, 10, accuracy: 1e-9)
        XCTAssertEqual(two.lateFrames, 2, "each frame against its own plan")
        XCTAssertEqual(two.plannedRefreshes, 2, "the deepest plan of the span")
        XCTAssertTrue(two.description.contains("2 late (plan 2 refreshes);"), two.description)

        // One deep, the line reads as it did.
        statistics.noteUpdate()
        statistics.noteFrameCompleted(XRPresenterFrameStages(cpu: 0.02))
        clock.now += 0.01
        let one = statistics.snapshot()
        XCTAssertEqual(one.plannedRefreshes, 1)
        XCTAssertEqual(one.lateFrames, 1)
        XCTAssertTrue(one.description.contains("1 late;"), one.description)
        XCTAssertFalse(one.description.contains("plan"), one.description)
        XCTAssertEqual(one.plannedRefreshesDescription, "")
    }
}

// MARK: - The presenter two refreshes deep

/// The presenter made with two sets: the tickets alternate between them, the replace calls
/// wait on a presentation buffer committed at the next update behind the frame's, a set
/// shows once its ticket of two updates ago completed and a late frame holds the set shown.
@MainActor
final class XRPresenterPipelineDepthPresenterTests: BaseRenderSetup {
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(10)
        while condition() == false {
            guard Date() < deadline else {
                throw XCTSkip("the GPU did not get there in time", file: file, line: line)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Waits for `condition` while letting the main queue run: the presenter's retries after
    /// a stop are blocks on it, which a nested run loop inside the test's own block cannot
    /// reach.
    private func waitAsync(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while condition() == false {
            guard Date() < deadline else {
                throw XCTSkip("the GPU did not get there in time", file: file, line: line)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func smallConfiguration(depth: Int) -> XRRealityKitPresenterConfiguration {
        var configuration = XRRealityKitPresenterConfiguration()
        configuration.textureSize = [64, 48]
        configuration.gridColumns = 5
        configuration.gridRows = 4
        configuration.pipelineDepth = depth
        return configuration
    }

    func test_oneRefreshDeep_theSettingsCannotAskForMoreSetsThanWereMade() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: smallConfiguration(depth: 1))
        presenter.reportInterval = 0
        XCTAssertEqual(presenter.presentationSets, 1)
        XCTAssertEqual(presenter.root.children.count, presenter.hasEdgeBand ? 4 : 2, "one set: a grid per eye and its band")
        presenter.start(commandQueue: renderInfo.commandQueue)
        presenter.settings.pipelineDepth = 2
        XCTAssertEqual(presenter.pipelineDepth, 1, "two refreshes need two sets")
        presenter.update()
        let ticket = try XCTUnwrap(presenter.mailbox.take())
        XCTAssertEqual(ticket.settings.pipelineDepth, 1, "the ticket says what is in force")
        XCTAssertEqual(ticket.set, 0)
        XCTAssertTrue(ticket.presentationBuffer === ticket.commandBuffer, "the replace calls are on the frame's own buffer")
        XCTAssertEqual(presenter.pendingPresentations, 0)
        ticket.commandBuffer.commit()
        presenter.stop()
    }

    func test_twoRefreshesDeep_theTicketsAlternateSets_andASetShowsOnceItsTicketOfTwoUpdatesAgoCompleted() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: smallConfiguration(depth: 2))
        presenter.reportInterval = 0
        XCTAssertEqual(presenter.presentationSets, 2)
        XCTAssertEqual(presenter.root.children.count, presenter.hasEdgeBand ? 8 : 4, "two sets: two grids per eye and their bands")
        XCTAssertEqual(presenter.settings.pipelineDepth, 2)
        XCTAssertEqual(presenter.pipelineDepth, 2)
        let grids = presenter.root.children.filter { !$0.name.hasSuffix("edge") }
        let bands = presenter.root.children.filter { $0.name.hasSuffix("edge") }
        XCTAssertEqual(grids.count, 4)
        func shownGrids() -> [String] {
            grids.filter(\.isEnabled).map(\.name)
        }
        func shownBands() -> [String] {
            bands.filter(\.isEnabled).map(\.name)
        }
        XCTAssertEqual(shownGrids(), ["Untold XR left eye", "Untold XR right eye"], "the first set shows, the second is hidden")
        XCTAssertEqual(presenter.shownSet, 0)
        presenter.start(commandQueue: renderInfo.commandQueue)

        func post() throws -> XRPresenterTicket {
            // No loop: the test takes the tickets itself and commits their frames' buffers.
            presenter.update()
            return try XCTUnwrap(presenter.mailbox.take())
        }
        func finish(_ ticket: XRPresenterTicket) throws {
            ticket.commandBuffer.commit()
            try waitUntil { ticket.commandBuffer.status == .completed }
        }

        // Update 1: the ticket is drawn into the second set; its replace calls are on a
        // presentation buffer of their own, which waits.
        let t1 = try post()
        XCTAssertEqual(t1.settings.pipelineDepth, 2, "the depth travels in the ticket")
        XCTAssertEqual(t1.set, 1)
        XCTAssertFalse(t1.presentationBuffer === t1.commandBuffer, "the replace calls are on a buffer of the presenter's")
        XCTAssertEqual(t1.presentationBuffer.status, .notEnqueued)
        XCTAssertEqual(presenter.pendingPresentations, 1)
        XCTAssertEqual(t1.colorTextures.count, 2)
        XCTAssertEqual(t1.gridBuffers.count, 2)

        // Update 2: the other set; the first ticket's frame is not committed, so its
        // presentation waits on, never ahead of its frame.
        let t2 = try post()
        XCTAssertEqual(t2.set, 0)
        XCTAssertEqual(t1.presentationBuffer.status, .notEnqueued, "a presentation never goes before its frame")
        XCTAssertEqual(presenter.pendingPresentations, 2)
        XCTAssertEqual(presenter.shownSet, 0)
        try finish(t1)
        try finish(t2)
        XCTAssertEqual(t1.presentationBuffer.status, .notEnqueued, "committed at an update, not on the frame's completion")

        // Update 3: both presentations go, in order, behind their frames.
        let t3 = try post()
        XCTAssertNotEqual(t1.presentationBuffer.status, .notEnqueued)
        XCTAssertNotEqual(t2.presentationBuffer.status, .notEnqueued)
        XCTAssertEqual(presenter.pendingPresentations, 1)
        XCTAssertEqual(t3.set, 1)
        try waitUntil { t1.presentationBuffer.status == .completed && t2.presentationBuffer.status == .completed }
        try finish(t3)

        // Update 4: the ticket of update 2 is due, in the first set, which shows already.
        let t4 = try post()
        XCTAssertEqual(presenter.shownSet, 0)
        XCTAssertEqual(t4.set, 0)
        try waitUntil { t3.presentationBuffer.status == .completed }
        try finish(t4)

        // Update 5: the ticket of update 3 is due and completed: the second set shows, with
        // its band, and the first is hidden.
        let t5 = try post()
        XCTAssertEqual(presenter.shownSet, 1)
        XCTAssertEqual(shownGrids(), ["Untold XR second set, left eye", "Untold XR second set, right eye"])
        if presenter.hasEdgeBand {
            XCTAssertEqual(shownBands(), ["Untold XR second set, left eye edge", "Untold XR second set, right eye edge"], "the band follows the set shown")
        }
        XCTAssertEqual(t5.set, 1)
        try waitUntil { t4.presentationBuffer.status == .completed }

        // Update 6: the ticket of update 4, completed: the first set again. The fifth ticket's
        // frame is late (never committed so far): its presentation waits.
        let t6 = try post()
        XCTAssertEqual(presenter.shownSet, 0)
        XCTAssertEqual(presenter.pendingPresentations, 2, "the fifth's and the sixth's own")
        XCTAssertEqual(t6.set, 0)
        try finish(t6)

        // Update 7: the fifth ticket is due but not completed: the set shown holds; the sixth
        // ticket's presentation waits behind the fifth's, in order.
        let t7 = try post()
        XCTAssertEqual(presenter.shownSet, 0, "a late frame holds the set shown")
        XCTAssertEqual(presenter.pendingPresentations, 3, "the presentations stay in order behind the late frame's")
        XCTAssertEqual(t6.presentationBuffer.status, .notEnqueued)
        XCTAssertEqual(t7.set, 1)
        try finish(t5)
        try finish(t7)

        // Update 8: the three presentations go; the sixth ticket is due in the first set.
        let t8 = try post()
        XCTAssertEqual(presenter.pendingPresentations, 1, "the eighth's own alone")
        XCTAssertNotEqual(t5.presentationBuffer.status, .notEnqueued)
        XCTAssertNotEqual(t6.presentationBuffer.status, .notEnqueued)
        XCTAssertEqual(presenter.shownSet, 0)
        try waitUntil { t7.presentationBuffer.status == .completed }
        try finish(t8)

        // Update 9: the seventh ticket is due and completed: the second set shows it; the late
        // fifth was never shown.
        let t9 = try post()
        XCTAssertEqual(presenter.shownSet, 1)
        XCTAssertEqual(t9.set, 1)

        // One slot still: a ticket posted while the previous waits is dropped, never queued.
        presenter.update()
        presenter.update()
        let t10 = try XCTUnwrap(presenter.mailbox.take())
        XCTAssertEqual(presenter.statistics.snapshot().ticketsDropped, 1)
        XCTAssertFalse(presenter.mailbox.hasPending)
        XCTAssertEqual(t10.set, 0)
        try finish(t9)
        try finish(t10)

        // One refresh deep at run time: the first set shows, the tickets go into it on the
        // frame's own buffer, and the presentations still waiting go as their frames do.
        presenter.settings.pipelineDepth = 1
        XCTAssertEqual(presenter.pipelineDepth, 1)
        let t11 = try post()
        XCTAssertEqual(presenter.shownSet, 0)
        XCTAssertEqual(shownGrids(), ["Untold XR left eye", "Untold XR right eye"])
        XCTAssertEqual(t11.set, 0)
        XCTAssertEqual(t11.settings.pipelineDepth, 1)
        XCTAssertTrue(t11.presentationBuffer === t11.commandBuffer)
        XCTAssertEqual(presenter.pendingPresentations, 0)
        try finish(t11)

        // Two deep again, and a stop with a presentation waiting: committed once its frame is.
        presenter.settings.pipelineDepth = 2
        let t12 = try post()
        XCTAssertFalse(t12.presentationBuffer === t12.commandBuffer)
        XCTAssertEqual(presenter.pendingPresentations, 1)
        presenter.stop()
        XCTAssertEqual(presenter.pendingPresentations, 1, "the frame is not committed yet")
        XCTAssertTrue(presenter.mailbox.isClosed)
        t12.commandBuffer.commit()
        try await waitAsync { presenter.pendingPresentations == 0 && t12.presentationBuffer.status == .completed }
    }

    /// Two refreshes deep, each frame is posed for its ticket's posting plus the lead plus one
    /// refresh as the presenter measured it from the updates.
    func test_twoRefreshesDeep_theFrameIsPosedOneMeasuredRefreshFurther() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("the presenter needs macOS 15") }
        var configuration = smallConfiguration(depth: 2)
        configuration.leadSeconds = 0.02
        let presenter = try await XRRealityKitPresenter(device: renderInfo.device, configuration: configuration)
        presenter.reportInterval = 0
        let source = RealityKitFrameSource(presenter: presenter) { _ in matrix4x4Translation(0, 0, 5) }
        presenter.start(commandQueue: renderInfo.commandQueue)

        var leads: [TimeInterval] = []
        func nextFrame() throws -> (ticket: XRPresenterTicket, lead: TimeInterval) {
            // No loop: the test takes the frames itself; a frame let go commits its buffer.
            presenter.update()
            let ticket = try XCTUnwrap(presenter.lastTicket)
            let frame = try XCTUnwrap(source.nextFrame())
            let lead = frame.timing.presentationTime - ticket.postedAt
            leads.append(lead)
            return (ticket, lead)
        }

        // The first update measures nothing yet: the fixed lead past the pickup alone.
        let first = try nextFrame()
        XCTAssertEqual(first.ticket.refreshSeconds, 0)
        XCTAssertEqual(first.ticket.settings.pipelineDepth, 2)
        XCTAssertGreaterThanOrEqual(first.lead, 0.02)
        XCTAssertLessThan(first.lead, 0.03)

        // Updates ten milliseconds apart, as RealityKit's at 100 Hz: the lead gains the
        // measured refresh.
        var last = (ticket: first.ticket, lead: first.lead)
        for _ in 0 ..< 12 {
            try await Task.sleep(nanoseconds: 10_000_000)
            last = try nextFrame()
        }
        XCTAssertGreaterThanOrEqual(last.ticket.refreshSeconds, 0.009, "the refresh measured from the updates")
        XCTAssertLessThan(last.ticket.refreshSeconds, 0.025)
        XCTAssertEqual(last.ticket.refreshSeconds, presenter.refresh.seconds, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(last.lead, 0.02 + last.ticket.refreshSeconds, "the fixed lead plus the refresh, past the pickup")
        XCTAssertLessThan(last.lead, 0.03 + last.ticket.refreshSeconds)

        // One deep at run time: the refresh is still measured and carried, and adds nothing.
        presenter.settings.pipelineDepth = 1
        try await Task.sleep(nanoseconds: 10_000_000)
        let shallow = try nextFrame()
        XCTAssertEqual(shallow.ticket.settings.pipelineDepth, 1)
        XCTAssertGreaterThan(shallow.ticket.refreshSeconds, 0)
        XCTAssertGreaterThanOrEqual(shallow.lead, 0.02)
        XCTAssertLessThan(shallow.lead, 0.03)

        let numbers = presenter.statistics.snapshot()
        XCTAssertEqual(numbers.leadMsMax, try XCTUnwrap(leads.max()) * 1000, accuracy: 1e-6, "the leads in force reached the statistics")
        XCTAssertEqual(numbers.leadMsAverage, leads.reduce(0, +) / Double(leads.count) * 1000, accuracy: 1e-6)
        presenter.stop()
        try await waitAsync { presenter.pendingPresentations == 0 }
    }
}
