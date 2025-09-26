//
//  InputSystem+Keyboard.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

#if os(macOS)
import AppKit
#endif

public struct KeyState
{
    public var wPressed = false, aPressed = false, sPressed = false, dPressed = false
    public var qPressed = false, ePressed = false, rPressed = false, lPressed = false, pPressed = false
    public var xPressed = false, yPressed = false, zPressed = false
    public var onePressed = false, twoPressed = false
    public var spacePressed = false, shiftPressed = false, ctrlPressed = false, altPressed = false
    public var leftMousePressed = false, rightMousePressed = false, middleMousePressed = false
    
}

extension InputSystem
{
    public var kVK_ANSI_W: UInt16 { 13 }
    public var kVK_ANSI_A: UInt16 { 0 }
    public var kVK_ANSI_S: UInt16 { 1 }
    public var kVK_ANSI_D: UInt16 { 2 }
    
    public var kVK_ANSI_R: UInt16 { 15 }
    public var kVK_ANSI_P: UInt16 { 35 }
    public var kVK_ANSI_L: UInt16 { 37 }
    public var kVK_ANSI_Q: UInt16 { 12 }
    public var kVK_ANSI_E: UInt16 { 14 }
    
    public var kVK_ANSI_1: UInt16 { 18 }
    public var kVK_ANSI_2: UInt16 { 19 }
    
    public var kVK_ANSI_G: UInt16 { 5 }
    public var kVK_ANSI_X: UInt16 { 7 }
    public var kVK_ANSI_Y: UInt16 { 16 }
    public var kVK_ANSI_Z: UInt16 { 6 }
    public var kVK_ANSI_Space: UInt16 { 49 }
    
    #if !os(macOS)
    public func registerKeyboardEvents() { }
    public func unregisterKeyboardEvents() { }
    #else
    public func registerKeyboardEvents() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.shouldHandleKey(event) == true {
                self?.keyPressed(event.keyCode)
                return nil // Mark event as handled
            }
            return event // Pass event to the system
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if self?.shouldHandleKey(event) == true {
                self?.keyReleased(event.keyCode)
                return nil // Mark event as handled
            }
            return event
        }
    }
    
    // TODO: implement this
    public func unregisterKeyboardEvents() { }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Shift key
        if event.modifierFlags.contains(.shift) {
            keyState.shiftPressed = true
        } else {
            keyState.shiftPressed = false
        }                

        // Control key
        if event.modifierFlags.contains(.control) {
            keyState.ctrlPressed = true
        } else {
            keyState.ctrlPressed = false
        }
    }
    
    private func shouldHandleKey(_: NSEvent) -> Bool {
        if let firstResponder = NSApp.keyWindow?.firstResponder {
            if firstResponder is NSTextView {
                return false // allow normal text input
            }
        }

        return true // handle the key event
    }
    
    func keyPressed(_ keyCode: UInt16) {
        switch keyCode {
        case kVK_ANSI_A: keyState.aPressed   = true
        case kVK_ANSI_W: keyState.wPressed   = true
        case kVK_ANSI_D: keyState.dPressed   = true
        case kVK_ANSI_S: keyState.sPressed   = true
        case kVK_ANSI_Q: keyState.qPressed   = true
        case kVK_ANSI_E: keyState.ePressed   = true
        case kVK_ANSI_P: keyState.pPressed   = true
        case kVK_ANSI_X: keyState.xPressed   = true
        case kVK_ANSI_Y: keyState.yPressed   = true
        case kVK_ANSI_Z: keyState.zPressed   = true
        case kVK_ANSI_1: keyState.onePressed = true
        case kVK_ANSI_2: keyState.twoPressed = true
        case kVK_ANSI_Space: keyState.spacePressed = true
        //case kVK_ANSI_G: print("G pressed")
        default: break
        }
        
        delegate?.didUpdateKeyState( )
    }
    
    func keyReleased(_ keyCode: UInt16) {
        switch keyCode {
        case kVK_ANSI_A: keyState.aPressed   = false
        case kVK_ANSI_W: keyState.wPressed   = false
        case kVK_ANSI_D: keyState.dPressed   = false
        case kVK_ANSI_S: keyState.sPressed   = false
        case kVK_ANSI_Q: keyState.qPressed   = false
        case kVK_ANSI_E: keyState.ePressed   = false
        case kVK_ANSI_P: keyState.pPressed   = false
        case kVK_ANSI_X: keyState.xPressed   = false
        case kVK_ANSI_Y: keyState.yPressed   = false
        case kVK_ANSI_Z: keyState.zPressed   = false
        case kVK_ANSI_1: keyState.onePressed = false
        case kVK_ANSI_2: keyState.twoPressed = false
        case kVK_ANSI_Space: keyState.spacePressed = false
        //case kVK_ANSI_G: print("G released")
        default: break
        }
        
        delegate?.didUpdateKeyState( )
    }
    
    #endif
}
