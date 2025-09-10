//
//  UntoldConfig.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 7/9/25.
//

public struct UntoldViewConfig
{
    enum Mode {
        case game
        case editor
    }
    
    var mode: Mode = .editor
    var preferredFPS: Int = 30
    
    func applyConfiguration()
    {
        switch mode {
        case .game: gameMode = true
        case .editor: gameMode = false
        }
    }
}

extension UntoldViewConfig {
    public static var `default`: UntoldViewConfig {
        return .init( mode: .game )
    }
    public static var editor: UntoldViewConfig {
        return .init( mode: .editor )
    }

}
