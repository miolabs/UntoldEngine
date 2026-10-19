//
//  XRPresenterSettings.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The presenter's settings a game may change while it runs: the grids' depth rules, the edge
/// band and the frame's lead (fixed or measured). The presenter starts from its configuration's values; each ticket
/// carries the values in force when it was posted, so the engine's thread reads a frame's
/// settings from its ticket and never from the presenter. What needs the grids or textures made
/// again (their sizes) stays in the configuration.
public struct XRPresenterSettings: Sendable, Equatable {
    /// See `XRRealityKitPresenterConfiguration.skirtTexels`.
    public var skirtTexels: Float
    /// See `XRRealityKitPresenterConfiguration.tearThresholdMetres`.
    public var tearThresholdMetres: Float
    /// See `XRRealityKitPresenterConfiguration.adaptiveDiagonal`. Turned off while running, the
    /// next frame writes the fixed split back once.
    public var adaptiveDiagonal: Bool
    /// See `XRRealityKitPresenterConfiguration.edgeBlending`. Only when the band's material
    /// loaded (`XRRealityKitPresenter.hasEdgeBand`).
    public var edgeBlending: Bool
    /// See `XRRealityKitPresenterConfiguration.leadSeconds`: the fixed lead.
    public var leadSeconds: TimeInterval
    /// See `XRRealityKitPresenterConfiguration.adaptiveLead`.
    public var adaptiveLead: Bool
    /// See `XRRealityKitPresenterConfiguration.displayLatencySeconds`.
    public var displayLatencySeconds: TimeInterval

    public init(configuration: XRRealityKitPresenterConfiguration = .init()) {
        skirtTexels = configuration.skirtTexels
        tearThresholdMetres = configuration.tearThresholdMetres
        adaptiveDiagonal = configuration.adaptiveDiagonal
        edgeBlending = configuration.edgeBlending
        leadSeconds = configuration.leadSeconds
        adaptiveLead = configuration.adaptiveLead
        displayLatencySeconds = configuration.displayLatencySeconds
    }
}
