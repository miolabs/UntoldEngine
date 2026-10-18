//
//  XRPresenterMaterial.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RealityKit
import UntoldEngine

private final class XRPresenterMaterialSentinel {}

/// The material each eye's grid is shown with: the hand-written MaterialX graph
/// `Resources/XRPresenter.usda`, whose Camera Index Switch keeps the grid for its own eye and
/// discards it for the other (a mono view shows the left eye's), an Unlit Surface with the
/// post-process tone map off, and an opacity of the frame's alpha under a threshold of 0.9,
/// so that what the engine left transparent shows the passthrough and only a silhouette's fully
/// covered texels are opaque: the partly covered ones are the edge band's to blend.
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
public enum XRPresenterMaterial {
    public static let primPath = "/Root/XRPresenterMaterial"
    public static let resourceName = "XRPresenter"
    /// The edge band's graph: the same without the opacity threshold, blended (`XRPresenterEdge.usda`).
    public static let edgePrimPath = "/Root/XRPresenterEdgeMaterial"
    public static let edgeResourceName = "XRPresenterEdge"
    public static let resourceExtension = "usda"
    /// The SwiftPM resource bundle of this target.
    public static let bundleName = "UntoldEngine_UntoldEngineXRRealityKit.bundle"
    public static let colorTextureParameter = "colorTexture"
    public static let eyeParameter = "eye"

    public enum LoadError: Swift.Error, CustomStringConvertible {
        case resourceMissing

        public var description: String {
            "\(XRPresenterMaterial.resourceName).\(XRPresenterMaterial.resourceExtension) is neither in \(XRPresenterMaterial.bundleName) nor in the main bundle"
        }
    }

    /// Where the graph is: the target's resource bundle next to the running code (found without
    /// the crash risk of `Bundle.module`), else the main bundle.
    public static func resourceURL(_ name: String = resourceName) -> URL? {
        Bundle.safeModuleResourceBundle(named: bundleName, anchor: XRPresenterMaterialSentinel.self)?
            .url(forResource: name, withExtension: resourceExtension)
            ?? Bundle.main.url(forResource: name, withExtension: resourceExtension)
    }

    /// The graph as a material, drawn on both faces (the grid's winding is as seen from the eye,
    /// but a tear may fold a triangle).
    public static func load() async throws -> ShaderGraphMaterial {
        try await load(resource: resourceName, prim: primPath)
    }

    /// The edge band's graph as a material.
    public static func loadEdge() async throws -> ShaderGraphMaterial {
        try await load(resource: edgeResourceName, prim: edgePrimPath)
    }

    private static func load(resource: String, prim: String) async throws -> ShaderGraphMaterial {
        guard let url = resourceURL(resource) else { throw LoadError.resourceMissing }
        var material = try await ShaderGraphMaterial(named: prim, from: url)
        material.faceCulling = .none
        return material
    }

    /// Sets the material's parameters: `eye` 0 is the left eye, 1 the right (the graph counts
    /// them 1 and 2, the Camera Index Switch's values).
    public static func configure(_ material: inout ShaderGraphMaterial, eye: Int, texture: TextureResource) throws {
        try material.setParameter(name: colorTextureParameter, value: .textureResource(texture))
        try material.setParameter(name: eyeParameter, value: .int(Int32(eye + 1)))
    }

    /// An unlit material without the eye switch, for when the graph cannot be loaded: both grids
    /// show in both eyes then, which doubles the picture but keeps the presenter running.
    public static func fallback(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(texture: texture)
        material.blending = .transparent(opacity: .init(texture: .init(texture)))
        material.opacityThreshold = 0.5
        material.faceCulling = .none
        return material
    }
}
