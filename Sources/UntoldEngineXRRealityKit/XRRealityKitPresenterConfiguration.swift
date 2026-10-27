//
//  XRRealityKitPresenterConfiguration.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd

/// How the RealityKit presenter renders and shows the engine's frame: the size of each eye's
/// textures and the scale they are rendered at, the grids each eye is shown on, the eyes'
/// frustum and where they sit on the device, the lead the frame is posed ahead of its ticket,
/// how many refreshes the engine has for a frame, and the depth rules of the grids.
///
/// The eyes: RealityKit renders the grids from the device's TRACKED eyes and tells the
/// presenter nothing of where they are, so the engine renders from a nominal pair, the
/// interpupillary distance apart at the ARKit device anchor plus a view offset, unless the
/// app measures the tracked eyes and sets `eyeTransforms`. The headset showed why
/// (2026-10-27): the tracked eyes sat 24.7 mm below the anchor, and a grid cell drawn at a
/// wrong depth (a cube's top seen edge-on, a sphere's limb) seen from an eye that is not the
/// engine's shows the texture displaced by that difference times the depth error, the kinks
/// at rest and the shimmer with the gaze along every silhouette, which the measured eyes
/// dialled in took almost to a native RealityKit cube's.
public struct XRRealityKitPresenterConfiguration: Sendable, Equatable {
    /// Pixels per eye: the headset's per-eye drawable size by default (the plan's D5). What
    /// the eyes are rendered at is this times `renderScale` (`renderedTextureSize`).
    public var textureSize = SIMD2<Int>(1920, 1824)
    /// How many times `textureSize` each eye is rendered at, along each axis: 1 by default,
    /// the drawable size; 1.5 renders 2880 × 2736 per eye, 2.25 times the pixels. What it
    /// buys is texels per degree: RealityKit shows the eye's texture through its bilinear
    /// sampler at the display's resolution (some 34 pixels per degree), and the uniform
    /// 1920-pixel frame gives 12.9 texels per degree at the centre of view (17.6 through the
    /// rate map), so each texel is shown 2.6 display pixels wide and the engine's own one-texel
    /// steps along edges (MSAA's quarter steps, the staircase of a shallow edge) are magnified
    /// with it; at 1.5 the texture gives 19.4 (26.4 through the map), under a display pixel
    /// per texel step at the centre. The price is the engine's GPU frame, which grows with the
    /// pixels (the whole frame, not only the shading), affordable with the pipeline two
    /// refreshes deep. Through the rate map `textureSize` × the scale is the physical pixel
    /// budget, and the map's screen grows with it, so the centre of view gains the same
    /// factor. The grids keep their vertex counts: a uniform grid is `gridColumns` ×
    /// `gridRows` whatever the scale (its cell grows with the texels), and a foveated grid's
    /// cell is `foveatedCellTexels` scaled with it, snapped to the map's tile (see there).
    /// Clamped to `renderScaleRange`; 1 exactly leaves every size as it was.
    public var renderScale: Float = 1
    /// Vertices per row, and rows, of each eye's grid (uniform; a foveated grid is the map's).
    public var gridColumns = 256
    public var gridRows = 240
    /// Whether each eye is drawn through the presenter's own rasterization rate map, fixed and
    /// head-centred (RealityKit gives no gaze). `textureSize` is then the budget of PHYSICAL
    /// pixels per eye, which the map never exceeds; the eye's screen is larger by the profile,
    /// so the centre of view is denser than a uniform frame of the same pixel count; and the
    /// grid is made from the physical size in cells of `foveatedCellTexels` (`gridColumns` and
    /// `gridRows` are not used). None by default, until the headset has judged it against the
    /// uniform frame.
    public var foveation: XRPresenterFoveationProfile = .none
    /// The side of a grid cell in physical texels when foveated, at a render scale of 1. The
    /// map's mapping of texels to the screen changes slope at its tile boundaries
    /// (`physicalGranularity`, 32 on Apple GPUs), so a cell that divides the tile puts a vertex
    /// on every boundary and the grid interpolates the map exactly within each cell. The cell
    /// in force is this times `renderScale`, snapped to the divisor of the tile nearest to it
    /// in ratio (so the grid's vertices stay about as many as at scale 1, rather than growing
    /// with the texels: at 1.5 a cell of 8 becomes 12, which the 32-texel tile has no divisor
    /// for, and snaps to 16, the grid 181 × 172 for the default budget against 241 × 229 at
    /// scale 1; 4 would snap to 8 and keep the denser grid). A value that divides the tile is
    /// taken as it is.
    public var foveatedCellTexels = 8
    /// Tangents of the half angles of each eye's frustum: left, right, up, down, all positive. A
    /// few degrees wider than the headset's view, so that a head turn between the frame's pose
    /// and its display still finds pixels at the edges.
    public var frustumTangents = SIMD4<Float>(1.30, 1.30, 1.15, 1.30)
    /// The distance between the eyes, metres: the nominal pair's, a half to each side of the
    /// device anchor, unless `eyeTransforms` is set, when it reads as the distance between the
    /// two measured eyes (for a settings line). Setting it sets the nominal pair's, which comes
    /// back when `eyeTransforms` is cleared.
    public var interpupillaryDistance: Float {
        get {
            guard let eyes = measuredEyes else { return nominalInterpupillaryDistance }
            return simd_length(Self.translation(of: eyes.1) - Self.translation(of: eyes.0))
        }
        set { nominalInterpupillaryDistance = newValue }
    }

    /// The nominal pair's distance, metres, 63 mm by default.
    private var nominalInterpupillaryDistance: Float = 0.063
    /// Seconds the frame is posed ahead of the moment its ticket is taken: an estimate of when
    /// RealityKit shows it (two refresh periods at 90 Hz), the fixed lead. With `adaptiveLead`
    /// the lead is measured instead and this is what it falls back on until a frame has
    /// completed (`XRPresenterLead`).
    public var leadSeconds: TimeInterval = 2.0 / 90.0
    /// Whether the frame's lead follows the measured latency instead of `leadSeconds`: the
    /// ticket's age at pickup, plus the engine's frame (from the pickup to the ticket's command
    /// buffer completing on the GPU, averaged over the last frames), plus
    /// `displayLatencySeconds`. Off by default until the headset has judged it against the
    /// fixed lead; both are there at run time through `XRPresenterSettings`.
    public var adaptiveLead = false
    /// Seconds from a frame's command buffer completing to its display, the part of the
    /// adaptive lead only the headset can calibrate: RealityKit noticing the replace, its own
    /// frame and the compositor's. 16 ms to start: the fixed lead (22.2 ms) less the frame's
    /// measured latency on the headset in Release (2026-10-19: age 0.03 ms, CPU 2.8 ms, GPU
    /// 3.6 ms), rounded, so that the two leads agree at those numbers. Calibrate on the
    /// headset with the adaptive lead on: a head-locked marker that lags a head turn wants a
    /// longer latency, one that leads wants a shorter.
    public var displayLatencySeconds: TimeInterval = 0.016
    /// How many refreshes the engine has for a frame, 1 or 2. At 1 a ticket posted at a
    /// RealityKit update shows at the next render when its command buffer completed in time,
    /// else at the one after (a late frame). At 2 the ticket is planned for the render after
    /// the next: the presenter is made with a second set of textures and grids and alternates
    /// the sets between its tickets, RealityKit's replace calls go on a presentation buffer the
    /// presenter commits at the next update (after the engine committed the frame's own), and
    /// a set is shown once its ticket of two updates ago completed. A frame whose GPU span is
    /// stretched by up to a refresh then still lands on time, at the price of one refresh of
    /// lead: the frame is posed a refresh further ahead (`XRPresenterLead`). 2 by default: on
    /// the headset (2026-10-19, Release) it took the late frames of quick head turns from one
    /// to five in a hundred to none, and the swim probe's dot held still with the longer lead;
    /// 1 is the pipeline as it was, one set. The sets are made here, and
    /// `XRPresenterSettings.pipelineDepth` chooses at run time between the depths the sets allow.
    public var pipelineDepth = 2
    /// The near plane of the eyes' projection, metres.
    public var nearPlane: Float = 0.05
    /// The far plane of the eyes' projection, metres: depth 0 under reverse Z.
    public var farPlane: Float = 1000
    /// Whether the eye textures carry a full mip chain, generated on the frame's command buffer
    /// after the eyes are drawn, with the graphs' sampler filtering between levels. The device
    /// rasterizes RealityKit content at a rate that follows the gaze, coarse away from it, and
    /// samples the texture once per pixel it rasterizes: with the base level alone, a texel
    /// density above that rate aliases the silhouettes (the kinks at rest and the waves with the
    /// gaze or the head seen on the headset, 2026-10-27), while the mip chain lets the sampler
    /// filter the texture down to the rate. Off by default until the headset has judged it;
    /// fixed for the space (the textures are made with it).
    public var mipmapped = false
    /// Where grid vertices that see nothing (the sky, passthrough) are placed: a shell this far
    /// from the eye, so that those areas keep a surface for the material to discard or show.
    public var farShellMetres: Float = 100
    /// A difference in view distance between neighbouring grid vertices above this, metres, is a
    /// tear: a silhouette the grid stretches across. The vertices on its two sides are marked
    /// (far side, near side) and the material discards the triangles that span both.
    public var tearThresholdMetres: Float = 0.5
    /// Whether the tear mask is written at all. Off, every vertex's mask is zero and the grid
    /// stays one surface: the triangles stretched between an object's rim and what lies behind
    /// it are drawn, reading the texels between the two (transparent but for the rim's partly
    /// covered ones, which the material's alpha test cuts), so no cell is discarded or kept by
    /// a per-frame decision. The placement is the same either way (the threshold still picks
    /// the near side of a footprint's depth jump). The headset test for the shimmer along the
    /// cubes' edges (2026-10-20): the tear decision as the mechanism, against the rest.
    public var tears = true
    /// How far, in texels of the eye texture, a grid vertex at an object's rim is pushed outward
    /// past the edge texel it was placed on, so that the silhouette seen is where the filtered
    /// texture's alpha crosses the material's threshold rather than the mesh boundary through
    /// rim texels (which is quantised to the texel and flips with the predicted pose); 0 for none.
    public var skirtTexels: Float = 3
    /// How the grid meets a silhouette against the room (`XRPresenterSilhouetteCells`): each
    /// rim vertex on its edge texel pushed outward by the skirt, with the cells from there to
    /// the far shell stretched across the jump, as shipped (`.skirt`); or each rim vertex on
    /// the texture's alpha crossing at the surface's own depth, with no triangle from there to
    /// the shell (`.alphaCrossing`). Live through `XRPresenterSettings`; `.skirt` by default
    /// until the headset has judged the crossing against it.
    public var silhouetteCells: XRPresenterSilhouetteCells = .skirt
    /// Whether each cell's diagonal follows the depth each frame (the fixed one unless it crosses
    /// a depth jump and the other does not), with the index buffer rewritten per frame. Off by
    /// default until the headset has judged it against the fixed split with the skirt; both are
    /// there at run time through `XRPresenterSettings`.
    public var adaptiveDiagonal = false
    /// Whether a second entity per eye draws the grid again with the blended edge-band material
    /// over the opaque core, so that a silhouette's partly covered texels blend over the room
    /// instead of being cut by the alpha test at a texel boundary. Needs coverage in the frame's
    /// alpha: the engine's MSAA modes leave it, FXAA and SMAA do not. Under the `.cutAndBand`
    /// silhouette only: the blended core has no band to turn on.
    public var edgeBlending = true
    /// How a silhouette reaches the room: the whole core blended with its depth still written
    /// and no band (`.blendedCore`, the default since 2026-10-27), or the core cut by its alpha
    /// test with the edge band blended over the cells along silhouettes (`.cutAndBand`, the
    /// chain as first shipped; see the cases). Fixed when the presenter is made: the grids'
    /// materials and the band's entities are made for it. The presenter's `silhouette` says
    /// which is in force (the blended core falls back to the cut and band when its graph cannot
    /// be loaded).
    public var silhouette: XRPresenterSilhouette = .blendedCore
    /// The radius of the sphere around the user that takes the gaze for pinches, metres.
    public var inputTargetRadius: Float = 50
    /// An offset of both nominal eyes on the device, metres, in the device anchor's frame (x
    /// right, y up, z back), zero by default: where the tracked eyes sit against the anchor
    /// when an app knows it from a measurement it cannot carry whole, or a deliberate offset
    /// (a few centimetres up) that makes RealityKit show the grids from a point the engine did
    /// not draw them from, so a silhouette defect that changes with it comes from a vertex at a
    /// wrong depth. With `eyeTransforms` set it reads as the midpoint of the two measured eyes
    /// (for a settings line); setting it sets the nominal pair's, which comes back when
    /// `eyeTransforms` is cleared.
    public var viewOffsetMetres: SIMD3<Float> {
        get {
            guard let eyes = measuredEyes else { return nominalViewOffsetMetres }
            return (Self.translation(of: eyes.0) + Self.translation(of: eyes.1)) / 2
        }
        set { nominalViewOffsetMetres = newValue }
    }

    /// The nominal pair's offset, metres, zero by default.
    private var nominalViewOffsetMetres = SIMD3<Float>(0, 0, 0)

    /// The device anchor to each eye (left, then right), as Compositor Services hands them out
    /// per view (`LayerRenderer.Drawable.views[i].transform`, which the engine's Compositor
    /// path renders from): the tracked eyes, measured by the app (`XREyeMeasurement` in
    /// `UntoldEngineXR` runs a bare compositor layer for a moment and averages them). Set, the
    /// engine renders each eye from its transform in place of the nominal pair, and
    /// `interpupillaryDistance` and `viewOffsetMetres` report the pair's distance and midpoint;
    /// nil, the default, is the nominal pair. An eye the array does not reach (fewer than two
    /// transforms) stays nominal.
    public var eyeTransforms: [simd_float4x4]?

    public init() {}

    /// The two measured eyes when both are set.
    private var measuredEyes: (simd_float4x4, simd_float4x4)? {
        guard let eyeTransforms, eyeTransforms.count >= 2 else { return nil }
        return (eyeTransforms[0], eyeTransforms[1])
    }

    private static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// The render scales accepted: 0.5 to 2 along each axis (a quarter to four times the
    /// pixels); a value outside is clamped, one that is not a number is 1.
    public static let renderScaleRange: ClosedRange<Float> = 0.5 ... 2

    /// `renderScale` within `renderScaleRange`: what the presenter applies.
    public var clampedRenderScale: Float {
        guard renderScale.isFinite else { return 1 }
        return min(max(renderScale, Self.renderScaleRange.lowerBound), Self.renderScaleRange.upperBound)
    }

    /// The size each eye is rendered at: `textureSize` times the render scale along each axis,
    /// rounded to whole pixels, at least one; `textureSize` itself at a scale of 1. The uniform
    /// eye's texture size, or the foveated eye's pixel budget (the presenter's `textureSize`
    /// is the size its textures were made at).
    public var renderedTextureSize: SIMD2<Int> {
        let scale = clampedRenderScale
        guard scale != 1 else { return textureSize }
        return SIMD2<Int>(
            max(1, Int((Float(textureSize.x) * scale).rounded())),
            max(1, Int((Float(textureSize.y) * scale).rounded()))
        )
    }

    /// `renderedTextureSize` as floats.
    public var eyeSize: simd_float2 {
        let size = renderedTextureSize
        return simd_float2(Float(size.x), Float(size.y))
    }

    /// Texels per degree at the centre of view of a uniform eye of `renderedTextureSize` through
    /// the configured frustum, horizontally: the texture's width over the frustum's width in
    /// tangent is the texels per unit tangent, which at the centre of view (where a degree is
    /// π / 180 of tangent) is the texels per radian. 12.9 for the default; what the display's
    /// pixels per degree (some 34 on the headset) compare with. Through the rate map the centre
    /// is drawn at the map's screen size instead (`XRPresenterFoveation.centreTexelsPerDegree`).
    public var centreTexelsPerDegree: Float {
        Self.centreTexelsPerDegree(width: renderedTextureSize.x, tangents: frustumTangents)
    }

    /// Texels per degree at the centre of view of `width` texels spread evenly over a frustum of
    /// `tangents` (left and right), the texels per unit tangent as texels per radian.
    public static func centreTexelsPerDegree(width: Int, tangents: SIMD4<Float>) -> Float {
        let span = tangents.x + tangents.y
        guard span > 0 else { return 0 }
        return Float(width) / span * .pi / 180
    }

    /// The eyes' projection for the configured frustum: right-handed, reverse Z (the near plane
    /// at depth 1, the far plane at 0), asymmetric when the tangents differ.
    public var projection: simd_float4x4 {
        XRPresenterProjection.reverseZ(tangents: frustumTangents, near: nearPlane, far: farPlane)
    }

    /// Where an eye sits on the device (0 left, 1 right): its measured transform when
    /// `eyeTransforms` has one for it, else the nominal pair's, half the eye distance to its
    /// side of the anchor plus the view offset, unrotated.
    public func deviceFromView(eye: Int) -> simd_float4x4 {
        if let eyeTransforms, eye >= 0, eye < eyeTransforms.count {
            return eyeTransforms[eye]
        }
        let x = eye == 0 ? -nominalInterpupillaryDistance / 2 : nominalInterpupillaryDistance / 2
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x + nominalViewOffsetMetres.x, nominalViewOffsetMetres.y, nominalViewOffsetMetres.z, 1)
        return transform
    }
}

public enum XRPresenterProjection {
    /// A right-handed perspective projection from the tangents of the half angles (left, right,
    /// up, down), reverse Z: the near plane maps to depth 1 and the far plane to 0, as the
    /// engine's own helpers and the compositor's drawables do.
    public static func reverseZ(tangents: SIMD4<Float>, near: Float, far: Float) -> simd_float4x4 {
        let width = tangents.x + tangents.y
        let height = tangents.z + tangents.w
        let zs = near / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>((tangents.y - tangents.x) / width, (tangents.z - tangents.w) / height, zs, -1),
            SIMD4<Float>(0, 0, zs * far, 0)
        ))
    }
}

/// How the RealityKit presenter draws a silhouette against the room
/// (`XRRealityKitPresenterConfiguration.silhouette`).
public enum XRPresenterSilhouette: String, Sendable, Equatable, CaseIterable {
    /// The shipped chain: each eye's grid drawn opaque through an alpha test at 0.9 (a texel
    /// shows only where its alpha is at least that), its depth written, with the edge band's
    /// blended graph drawn on meshes of its own over the cells along silhouettes and depth
    /// jumps (`edgeBlending`), so that a silhouette's partly covered texels blend over the room
    /// where the cut would step texel by texel. On the Mac the band covers the cut to the
    /// resampled texture's own floor (2026-10-19). On the headset (2026-10-27, the eyes
    /// measured) the band's choice of cells, made per cell and per frame, showed on a curved
    /// silhouette as a polygon of cells breathing with the gaze, which the blended core does
    /// not have; the cut and band stays as the option.
    case cutAndBand
    /// The experiment that answers it: each eye's grid drawn through the band's blended graph
    /// itself (`XRPresenterBlended.usda`), with no alpha test anywhere along a silhouette, the
    /// material's depth write kept on (`ShaderGraphMaterial.writesDepth`) so the grid still
    /// occludes what RealityKit draws after it and what the system composites by the layer's
    /// depth (Spatial Personas), and no band meshes made (`hasEdgeBand` is false). The whole
    /// grid goes through RealityKit's transparent pass, which shades every cell at the
    /// display's resolution once (the shipped core does too, under its alpha test); the band's
    /// second pass is gone with the band. What the device renders differently from the Mac is
    /// the suspect: the shipped cut rasterized without anti-aliasing under its foveated
    /// render, and the texel staircase marching as the texture changes every frame; the
    /// blended core removes the first and leaves the second. Its depth footprint is the
    /// shipped chain's: the far shell, the skirt's texels and the triangles stretched across
    /// a depth jump write depth at an opacity near 0 (the alpha test discarded them, a blend
    /// cannot), so a RealityKit entity standing in the sliver beside a silhouette, between
    /// the object and what lies behind it, is occluded there; the shipped band's cells blend
    /// over the same texels and write the same depth (a shader graph material writes depth
    /// unless told not to), the same 921 texels of a box behind the test's cubes hidden by
    /// either chain on the Mac. The other eye's grid is collapsed in the vertex stage and
    /// writes nothing.
    case blendedCore

    /// For a settings line.
    public var label: String {
        switch self {
        case .cutAndBand: return "cut and band"
        case .blendedCore: return "blended core"
        }
    }
}

/// How the RealityKit presenter's grid meets a silhouette against the room
/// (`XRRealityKitPresenterConfiguration.silhouetteCells`, live as
/// `XRPresenterSettings.silhouetteCells`): where a rim vertex (one whose own centre texel lies
/// off the near surface its footprint reached) is placed, and what becomes of the cells between
/// it and the far shell.
public enum XRPresenterSilhouetteCells: String, Sendable, Equatable, CaseIterable {
    /// The shipped rule: a rim vertex sits on its edge texel pushed outward by the skirt
    /// (`skirtTexels`), at that texel's depth, and the cells from there to the shell are
    /// stretched across the depth jump, marked by the tear mask for the materials to discard
    /// (or drawn, with the tears off). On a curved silhouette the headset showed those cells
    /// (2026-10-27: the example's sphere beside a RealityKit sphere, the measured eyes in
    /// force): the limb read as a polygon of cells whose segments breathed with the gaze, each
    /// cell straddling the limb carrying texels on a plane from the rim vertex to the shell,
    /// where a RealityKit sphere's limb is geometry resolved by the device's multisampling at
    /// the true depth.
    case skirt
    /// A rim vertex sits on the texture's alpha crossing: along the line from its edge texel
    /// toward its own centre, the first point where the bilinearly filtered alpha of the eye's
    /// colour (the engine's coverage) falls below one half, found to a sixteenth of a texel, at
    /// the surface's depth read at the covered texel nearest the crossing. The mesh boundary is
    /// then the silhouette itself, a chord per cell through points on the texture's edge, which
    /// the device's own multisampling resolves as it resolves a RealityKit sphere's, and the
    /// core's alpha test trims only what the filter leaves inside the chord (alpha between one
    /// half and the cut), which the band blends. No triangle joins a crossing vertex to the
    /// shell: the triangulation writes them degenerate (so the grids' index buffers are
    /// rewritten each frame, as under the adaptive diagonal), and a cell with a crossing vertex
    /// and one corner on the shell is split so that corner is alone in its triangle. A rim
    /// vertex with no crossing within reach (alpha at or above one half all the way past its
    /// centre: an internal depth jump against another opaque surface) keeps the skirt rule,
    /// with its tears. The kernel writes each vertex's kind into the projective coordinate's
    /// spare component for the triangulation and the band (zero under the skirt rule).
    case alphaCrossing

    /// For a settings line.
    public var label: String {
        switch self {
        case .skirt: return "skirt"
        case .alphaCrossing: return "alpha crossing"
        }
    }
}

/// The density profile of the presenter's rasterization rate map (`XRPresenterFoveation`).
public enum XRPresenterFoveationProfile: String, Sendable, Equatable, CaseIterable {
    /// No map: uniform pixels over the frustum's tangent plane, which are sparsest at the
    /// centre of view.
    case none
    /// Texels uniform in angle: the rate at a screen position whose tangent is x is 1 / (1 + x²)
    /// along each axis, the derivative of the angle in the tangent, so the texels per degree
    /// are the same at the centre and at the edges; the centre of view gains what the periphery
    /// gives up.
    case equiAngular
}
