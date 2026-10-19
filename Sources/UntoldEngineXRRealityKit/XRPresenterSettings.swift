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
/// band, the frame's lead (fixed or measured) and the pipeline's depth. The presenter starts
/// from its configuration's values; each ticket carries the values in force when it was posted,
/// so the engine's thread reads a frame's settings from its ticket and never from the
/// presenter. What needs the grids or textures made again (their sizes, the second set of the
/// deeper pipeline) stays in the configuration.
public struct XRPresenterSettings: Sendable, Equatable {
    /// See `XRRealityKitPresenterConfiguration.skirtTexels`.
    public var skirtTexels: Float
    /// See `XRRealityKitPresenterConfiguration.tearThresholdMetres`.
    public var tearThresholdMetres: Float
    /// See `XRRealityKitPresenterConfiguration.tears`.
    public var tears: Bool
    /// See `XRRealityKitPresenterConfiguration.adaptiveDiagonal`. Turned off while running, the
    /// next frame writes the fixed split back once.
    public var adaptiveDiagonal: Bool
    /// See `XRRealityKitPresenterConfiguration.edgeBlending`. Only when the band's material
    /// loaded (`XRRealityKitPresenter.hasEdgeBand`), so never under the blended core, which
    /// has no band (`XRRealityKitPresenterConfiguration.silhouette`).
    public var edgeBlending: Bool
    /// See `XRRealityKitPresenterConfiguration.leadSeconds`: the fixed lead.
    public var leadSeconds: TimeInterval
    /// See `XRRealityKitPresenterConfiguration.adaptiveLead`.
    public var adaptiveLead: Bool
    /// See `XRRealityKitPresenterConfiguration.displayLatencySeconds`.
    public var displayLatencySeconds: TimeInterval
    /// See `XRRealityKitPresenterConfiguration.pipelineDepth`: 1 or 2, up to the sets of
    /// textures and grids the presenter was made with (`XRRealityKitPresenter.presentationSets`);
    /// asked beyond them, the presenter uses what it has. Each ticket carries the depth in
    /// force, and the engine's thread poses the frame a refresh further ahead for each refresh
    /// past the first.
    public var pipelineDepth: Int

    public init(configuration: XRRealityKitPresenterConfiguration = .init()) {
        skirtTexels = configuration.skirtTexels
        tearThresholdMetres = configuration.tearThresholdMetres
        tears = configuration.tears
        adaptiveDiagonal = configuration.adaptiveDiagonal
        edgeBlending = configuration.edgeBlending
        leadSeconds = configuration.leadSeconds
        adaptiveLead = configuration.adaptiveLead
        displayLatencySeconds = configuration.displayLatencySeconds
        pipelineDepth = configuration.pipelineDepth
    }
}
