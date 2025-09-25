
//
//  Components.swift
//  ECSinSwift
//
//  Created by Harold Serrano on 1/14/24.
//

import Foundation
import Metal
import MetalKit
import simd

public class LocalTransformComponent: Component {
    public var position: simd_float3 = .zero
    public var rotation: simd_quatf = .init()
    public var scale: simd_float3 = .one

    public var space: simd_float4x4 = .identity

    public var boundingBox: (min: simd_float3, max: simd_float3) = (min: simd_float3(-1.0, -1.0, -1.0), max: simd_float3(1.0, 1.0, 1.0))

    public var flipCoord: Bool = false

    public var rotationX: Float = 0
    public var rotationY: Float = 0
    public var rotationZ: Float = 0

    public required init() {}
}

public class WorldTransformComponent: Component {
    public var space: simd_float4x4 = .identity

    public required init() {}
}

public class RenderComponent: Component {
    public var mesh: [Mesh]
    public var assetURL: URL = .init(fileURLWithPath: "")
    public var assetName: String = ""

    public required init() {
        mesh = []
    }

    func cleanUp() {
        for index in 0 ..< mesh.count {
            mesh[index].cleanUp()
        }

        mesh.removeAll()
    }

    deinit {
        cleanUp()
    }
}

public class PhysicsComponents: Component {
    public var mass: Float = 1.0
    public var centerOfMass: simd_float3 = .zero
    public var velocity: simd_float3 = .zero
    public var angularVelocity: simd_float3 = .zero
    public var acceleration: simd_float3 = .zero
    public var angularAcceleration: simd_float3 = .zero
    public var inertiaTensorType: InertiaTensorType = .spherical
    public var momentOfInertiaTensor: simd_float3x3 = .init(diagonal: simd_float3(1.0, 1.0, 1.0))
    public var inverseMomentOfInertiaTensor: simd_float3x3 = .init(diagonal: simd_float3(1.0, 1.0, 1.0))
    public var linearDragCoefficients: simd_float2 = .zero
    public var angularDragCoefficients: simd_float2 = .zero
    public var pause: Bool = false
    public var inertiaTensorComputed: Bool = false

    public required init() {}
}

public class KineticComponent: Component {
    var forces: [simd_float3] = []
    var moments: [simd_float3] = []

    var gravityScale: Float = 0.0

    public required init() {}

    public func addForce(_ force: simd_float3) {
        forces.append(force)
    }

    public func clearForces() {
        forces.removeAll()
    }

    public func addMoment(_ moment: simd_float3) {
        moments.append(moment)
    }

    public func clearMoments() {
        moments.removeAll()
    }
}

public class SkeletonComponent: Component {
    var skeleton: Skeleton!

    public required init() {}

    func cleanUp() {
        skeleton = nil
    }
}

public class AnimationComponent: Component {
    var animationClips: [String: AnimationClip] = [:]
    var currentAnimation: AnimationClip?
    public var animationsFilenames: [URL] = []
    var pause: Bool = false
    var currentTime: Float = 0.0
    public required init() {}

    func cleanUp() {
        animationClips.removeAll()
        currentAnimation?.cleanUp()
        currentAnimation = nil
    }

    func getAllAnimationClips() -> [String] {
        Array(animationClips.keys)
    }

    func removeAnimationClip(animationClip: String) {
        animationClips.removeValue(forKey: animationClip)
    }
}

public enum LightType: String, CaseIterable {
    case directional
    case point
    case area
    case spotlight
}

public class LightTexture {
    public var directional: MTLTexture?
    public var point: MTLTexture?
    public var spot: MTLTexture?
    public var area: MTLTexture?
}

public class LightComponent: Component {
    public var texture: LightTexture = .init()
    public var lightType: LightType?
    
    public var color: simd_float3 = .one
    public var intensity: Float = 1.0

    public required init() {}
}

public class DirectionalLightComponent: Component {
    public required init() {}
}

public class PointLightComponent: Component {
    public var attenuation: simd_float4 = .init(1.0, 0.7, 1.8, 0.0) // (constant, linear, quadratic)->x,y,z
    public var radius: Float = 1.0
    public var falloff: Float = 0.5

    public required init() {}
}

public class SpotLightComponent: Component {
    public var attenuation: simd_float4 = .init(1.0, 0.7, 1.8, 0.0)
    public var radius: Float = 1.0
    public var innerCone: Float = 5.0
    public var outerCone: Float = 10.0
    public var direction: simd_float3 = .init(0, -1, 0)
    public var falloff: Float = 0.5
    public var coneAngle: Float = 30.0

    public required init() {}
}

public class AreaLightComponent: Component {
    public var bounds: simd_float2 = .init(1.0, 1.0)
    public var forward: simd_float3 = .zero
    public var right: simd_float3 = .zero
    public var up: simd_float3 = .zero
    public var twoSided: Bool = false

    public required init() {}
}

public class ScenegraphComponent: Component {
    var parent: EntityID = .invalid
    var level: Int = 0 // level 0 means no parent
    var children: [EntityID] = []

    public required init() {}
}

open class CameraComponent: Component {

    public var viewSpace = simd_float4x4.init(1.0)
    public var xAxis: simd_float3 = .init(0.0, 0.0, 0.0)
    public var yAxis: simd_float3 = .init(0.0, 0.0, 0.0)
    public var zAxis: simd_float3 = .init(0.0, 0.0, 0.0)

    // quaternion
    public var rotation: simd_quatf = .init()
    public var localOrientation: simd_float3 = .init(0.0, 0.0, 0.0)
    public var localPosition: simd_float3 = .init(0.0, 0.0, 0.0)
    public var orbitTarget: simd_float3 = .init(0.0, 0.0, 0.0)

    public var eye: simd_float3 = .zero
    public var up: simd_float3 = .zero
    public var target: simd_float3 = .zero

    public required init() {}
}

// TODO: Review if this components should be in the editor package
public class SceneCameraComponent: Component {
    public required init() {}
}

public class GizmoComponent: Component {
    public required init() {}
}
