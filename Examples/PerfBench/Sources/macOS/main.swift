//
//  main.swift
//  PerfBench (macOS)
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

// Line-buffer stdout so the driver script sees progress and the last lines survive a crash.
setvbuf(stdout, nil, _IOLBF, 0)

// Top-level code is not main-actor isolated in Swift 5 language mode; the app is.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
