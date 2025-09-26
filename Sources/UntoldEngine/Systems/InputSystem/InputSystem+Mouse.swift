//
//  InputSystem+Mouse.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

#if os(macOS)
import AppKit
#endif
import simd

extension InputSystem
{
    #if !os(macOS)
    public func registerMouseEvents() { }
    public func unregisterMouseEvents() { }
    #else
    public func registerMouseEvents() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.leftMouseDown(event)
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.leftMouseDragged(simd_float2(Float(event.deltaX), Float(event.deltaY)))
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.leftMouseUp(event)
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleMouseScroll(event)
            return event
        }
    }
    
    // TODO: Implement this!
    public func unregisterMouseEvents() { }
    
    public func leftMouseDown(_ event: NSEvent) {
        mouseActive = true
        switch event.buttonNumber {
        case 0 : keyState.leftMousePressed = true
        case 1 : keyState.rightMousePressed = true
        default: break
        }
        
        delegate?.didUpdateKeyState( keyState )
    }

    public func leftMouseUp(_ event: NSEvent) {
        mouseActive = false
        switch event.buttonNumber {
        case 0 : keyState.leftMousePressed = false
        case 1 : keyState.rightMousePressed = false
        default: break
        }
        
        delegate?.didUpdateKeyState( keyState )
    }

    public func handleMouseScroll(_ event: NSEvent) {
        var deltaX: Double = event.scrollingDeltaX
        var deltaY: Double = event.scrollingDeltaY

        if abs(deltaX) < abs(deltaY) {
            deltaX = 0.0
        } else {
            deltaY = 0.0
            deltaX = -1.0 * deltaX
        }

        if abs(deltaX) <= 1.0 {
            deltaX = 0.0
        }

        if abs(deltaY) <= 1.0 {
            deltaY = 0.0
        }

        scrollDelta = 0.01 * simd_float2(Float(deltaX), Float(deltaY))

        if deltaX != 0.0 || deltaY != 0.0 {
            //            if shiftKey{
            //                delta=0.01*simd_float3(0.0,Float(deltaY),0.0)
            //                camera.moveCameraAlongAxis(uDelta: delta)
            //            }

            // camera.moveCameraAlongAxis(uDelta: delta)
        }
        
        delegate?.didUpdateKeyState( keyState )
    }
    
    public func leftMouseDragged(_ delta: simd_float2) {
        mouseDeltaX = delta.x
        mouseDeltaY = delta.y

        if abs(mouseDeltaX) < abs(mouseDeltaY) {
            mouseDeltaX = 0.0
        } else {
            mouseDeltaY = 0.0
            // mouseDeltaX = -1.0 * mouseDeltaX
        }

        if abs(mouseDeltaX) <= 1.0 {
            mouseDeltaX = 0.0
        }

        if abs(mouseDeltaY) <= 1.0 {
            mouseDeltaY = 0.0
        }

        lastMouseX = mouseX
        lastMouseY = mouseY

        mouseX += mouseDeltaX
        mouseY += mouseDeltaY

        mouseActive = ( mouseDeltaX != 0.0 || mouseDeltaY != 0.0 )
        
        if mouseActive {
            delegate?.didUpdateKeyState( keyState )
        }
    }
    #endif
}
