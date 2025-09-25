//
//  LoadingSystem.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 14/9/25.
//
import Foundation
import UntoldEngine

public func playSceneAt(url: URL) {
    if let scene = loadGameScene(from: url) {
        destroyAllEntities()
        deserializeScene(sceneData: scene)
    }
}
