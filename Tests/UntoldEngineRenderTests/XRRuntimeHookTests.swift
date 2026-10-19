//
//  XRRuntimeHookTests.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
    import Foundation
    @testable import UntoldEngineXR
    import XCTest

    /// The runtime's hooks that a presenter fills in and the runtime calls from its own threads:
    /// their types must keep the closures a presenter forms free of the actor of the context
    /// that forms them.
    final class XRRuntimeHookTests: XCTestCase {
        /// The presenter-state hook is called off the main actor (the session event monitor's
        /// task, the frame loop's thread), so its type must be `@Sendable`: a closure formed in a
        /// `@MainActor` context, such as the Compositor source's init, would otherwise inherit
        /// the actor and trap at its first call, as it did on the headset (2026-10-19). The
        /// annotation here is the guard: the test stops compiling if the hook's type loses it.
        func test_presenterStateHook_isSendable_andAnswersOffTheMainActor() async {
            let runtime = XRRuntime()
            let hook: @Sendable () -> String = runtime.presenterStateDescription
            let answer = await Task.detached { hook() }.value
            XCTAssertEqual(answer, "nil")
        }
    }
#endif
