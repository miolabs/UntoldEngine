//
//  InputSystem+GameController.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

import Foundation
import GameController

public struct GamePadState
{
    public var aPressed = false
    public var bPressed = false
    public var leftThumbStickActive = false
}

extension InputSystem
{
    public func registerGameControllerEvents() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect, object: nil)

        NotificationCenter.default.addObserver(self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect, object: nil)

        GCController.startWirelessControllerDiscovery { /* done */ }
    }
    
    public func unregisterGameControllerEvents() {
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidDisconnect, object: nil)
    }
    

    @objc private func controllerDidConnect(_ note: Notification) {
        guard let controller = note.object as? GCController, let gamepad = controller.extendedGamepad else { return }
        currentGamepad = gamepad
        configureGamepadHandlers(gamepad)
    }

    @objc private func controllerDidDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        if currentGamepad === controller.extendedGamepad { currentGamepad = nil }
    }

    private func configureGamepadHandlers(_ gamepad: GCExtendedGamepad) {
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in self?.gamePadState.aPressed = pressed }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in self?.gamePadState.bPressed = pressed }
        // add thumbstick/trigger mapping as needed…
    }
}
