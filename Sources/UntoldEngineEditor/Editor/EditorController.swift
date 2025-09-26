//
//  EditorController.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 24/9/25.
//

import Foundation
import UntoldEngine

public class EditorComponentsState: ObservableObject {
    public static let shared = EditorComponentsState()

    @Published public var components: [EntityID: [ObjectIdentifier: ComponentOption_Editor]] = [:]

    func clear() {
        components.removeAll()
    }
}

public class EditorAssetBasePath: ObservableObject {
    public static let shared = EditorAssetBasePath()

    @Published public var basePath: URL? = LoadingSystem.shared.assetBasePath
}

class EditorController: SelectionDelegate, ObservableObject
{
    let selectionManager: SelectionManager
    var isEnabled: Bool = false
    @Published var activeMode: TransformManipulationMode = .none
    @Published var activeAxis: TransformAxis = .none

    init(selectionManager: SelectionManager) {
        self.selectionManager = selectionManager
        isEnabled = true        
    }

    func refreshInspector() {
        DispatchQueue.main.async {
            self.selectionManager.objectWillChange.send()
        }
    }
        
    func didSelectEntity(_ entityId: EntityID) {
        DispatchQueue.main.async {
            self.selectionManager.selectEntity(entityId: entityId)
        }
    }

    func resetActiveAxis() {
        activeAxis = .none
    }

}
