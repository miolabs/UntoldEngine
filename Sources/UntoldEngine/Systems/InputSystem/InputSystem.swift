//
//  InputSystem.swift
//  Untold Engine
//  Created by Harold Serrano on 2/21/24.
//  Copyright © 2024 Untold Engine Studios. All rights reserved.
//

import Foundation
import GameController
import simd

#if os(macOS)
public typealias AppView = NSView
#else
public typealias AppView = UIView
#endif

public enum CameraControlMode { case idle, orbiting, moving }

public protocol InputSystemDelegate : AnyObject
{
    func didUpdateKeyState()
}

public final class InputSystem
{
    // Thread-safe shared instance
    public static let shared: InputSystem = { return InputSystem() }()
 
    public weak var delegate: InputSystemDelegate? = nil
    
    public var keyState = KeyState()
    public var keyCode: UInt16?
    
    public var gamePadState = GamePadState()
    public var currentGamepad: GCExtendedGamepad?

    // Shared state
    public var currentPanGestureState: PanGestureState?
    public var currentPinchGestureState: PinchGestureState?
    public var cameraControlMode: CameraControlMode = .idle

    public var mouseX: Float = 0, mouseY: Float = 0, lastMouseX: Float = 0, lastMouseY: Float = 0
    public var mouseDeltaX: Float = 0, mouseDeltaY: Float = 0, mouseActive: Bool = false

    public var initialPanLocation: CGPoint!
    public var initialLocation: CGPoint!
    public var gestureView: AppView?
    
    public var panDelta: simd_float2 = .init(0, 0)
    public var scrollDelta: simd_float2 = .init(0, 0)

    public var pinchDelta: simd_float3 = .init(0, 0, 0)
    public var previousScale: CGFloat = 1
}

