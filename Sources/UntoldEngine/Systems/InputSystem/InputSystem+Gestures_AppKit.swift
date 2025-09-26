//
//  InputSystem+GesturesAppKit.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

#if os(macOS)
import AppKit
import simd

extension InputSystem
{
    public func registerGestureEvents( inView view: AppView ) {
        // Pinch gesture
        let pinchGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinchGesture)
        
        // Pan gesture
        let panGesture = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(panGesture)
    }
    
    // TODO: Implement this!
    public func unregisterGestureEvents( fromView view: AppView ) { }
    
    @objc func handlePinch(_ gestureRecognizer: NSMagnificationGestureRecognizer) {
        handlePinchGesture(gestureRecognizer, in: gestureRecognizer.view!)
    }

    @objc func handlePan(_ gestureRecognizer: NSPanGestureRecognizer) {
        handlePanGesture(gestureRecognizer, in: gestureRecognizer.view!)
    }
    
    public func handlePinchGesture(_ gestureRecognizer: NSMagnificationGestureRecognizer, in _: NSView) {
        let currentScale = gestureRecognizer.magnification

        if gestureRecognizer.state == .began {
            // store the initial scale
            previousScale = currentScale
            currentPinchGestureState = .began

        } else if gestureRecognizer.state == .changed {
            // determine the direction of the pinch
            let scaleDiff = currentScale - previousScale
            pinchDelta = 3.0 * simd_float3(0.0, 0.0, Float(1.0) * Float(scaleDiff))

            previousScale = currentScale

            currentPinchGestureState = .changed

        } else if gestureRecognizer.state == .ended {
            previousScale = 1.0

            currentPinchGestureState = .ended
        }
        
        delegate?.didUpdateKeyState( keyState )
    }
    
    public func handlePanGesture(_ gestureRecognizer: NSPanGestureRecognizer, in view: NSView) {
        let currentPanLocation = gestureRecognizer.translation(in: view)
//        let currentLocation = gestureRecognizer.location(in: view)

        switch gestureRecognizer.state {
        case .began:
            // Store the initial touch location and perform any initial setup
            initialPanLocation = currentPanLocation
            currentPanGestureState = .began

        case .changed:
            // Calculate the deltas from the initial touch location
            var deltaX = currentPanLocation.x - initialPanLocation.x
            var deltaY = currentPanLocation.y - initialPanLocation.y

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

            // Add your code for touch moved here
            panDelta = simd_float2(Float(deltaX), Float(deltaY))
            currentPanGestureState = .changed
            initialPanLocation = currentPanLocation
            
        case .ended, .cancelled, .failed:
            // reset
            panDelta = simd_float2(0, 0)
            initialPanLocation = nil
            currentPanGestureState = .ended
            cameraControlMode = .idle
        
        default: break
        }
        
        delegate?.didUpdateKeyState( keyState )
    }

}

#endif
