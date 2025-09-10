//
//  EntityNode.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 6/9/25.
//

import simd

public protocol Node {
//    associatedtype Body: Node
//    @SceneBuilder @MainActor var body: Self.Body { get }
    
    var entity: EntityID { get }
    
    func translateBy ( x: Float, y: Float, z: Float ) -> Self
    func rotateBy(angle: Float, axis: [Axis] ) -> Self
    func scaleTo(x:Float, y:Float, z:Float) -> Self
    
    // Animations
    func setAnimations ( resource:String, name:String ) -> Self
    func changeAnimation ( name:String, withPause: Bool ) -> Self
    
    // Kinetics
    func setEntityKinetics() -> Self

}

extension Node {
//    public var body: some Node { self }
    
    @inlinable
    public func translateBy ( x: Float, y: Float, z: Float ) -> Self {
        UntoldEngine.translateBy(entityId: entity, position: simd_float3(x, y, x))
        return self
    }
    
    public func rotateBy(angle: Float, axis: [Axis] ) -> Self {
        
        var x:Float = 0
        var y:Float = 0
        var z:Float = 0
        
        for a in axis {
            switch a {
            case .x: x = 1
            case .y: y = 1
            case .z: z = 1
            }
        }
        
        UntoldEngine.rotateBy(entityId: entity, angle: angle, axis: simd_float3(x, y, z))
        return self
    }
    
    public func scaleTo(x:Float = 0, y:Float = 0, z:Float = 0) -> Self {
        UntoldEngine.scaleTo(entityId: entity, scale: simd_float3( x, y, z))
        return self
    }
    
    public func setAnimations ( resource:String, name:String ) -> Self {
        setEntityAnimations(entityId: entity, filename: resource.filename, withExtension: resource.extensionName, name: "running")
        return self
    }
        
    @inlinable
    public func changeAnimation ( name:String, withPause pause: Bool = false ) -> Self {
        UntoldEngine.changeAnimation(entityId: entity, name: name, withPause: pause )
        return self
    }
    
    @inlinable
    public func setEntityKinetics() -> Self {
        UntoldEngine.setEntityKinetics(entityId: entity)
        return self
    }
}

public enum Axis {
    case x
    case y
    case z
}

extension String {
    public var filename: String {
        return String( self.split(separator: ".").first ?? "" )
    }
    
    public var extensionName: String {
        return String( self.split(separator: ".").last ?? "" )
    }
}
