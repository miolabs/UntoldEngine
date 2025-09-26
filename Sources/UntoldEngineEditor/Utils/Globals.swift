//
//  Globals.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 14/9/25.
//

import Foundation
import UntoldEngine
import simd


var visualDebug: Bool = false
public var gameMode: Bool = false
var hotReload: Bool = false

var applyIBL: Bool = true
var renderEnvironment: Bool = false
var ambientIntensity: Float = 1.0

// Editor
public var enableEditor: Bool = true

var activeEntity: EntityID = .invalid
var editorController: EditorController?

// hightlight
public let boundingBoxVertexCount = 24

// Gizmo active
var activeHitGizmoEntity: EntityID = .invalid
var parentEntityIdGizmo: EntityID = .invalid

let gizmoDesiredScreenSize: Float = 500.0 // pixels

var spawnDistance: Float = 2.0

// Visual Debugger
enum DebugSelection: Int {
    case normalOutput
    case iblOutput
}

var currentDebugSelection: DebugSelection = .normalOutput

// light debug meshes
var spotLightDebugMesh: [Mesh] = []
var pointLightDebugMesh: [Mesh] = []
var areaLightDebugMesh: [Mesh] = []
var dirLightDebugMesh: [Mesh] = []

