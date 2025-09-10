//
//  SceneBuilder.swift
//  UntoldEngine
//
//  Created by Javier Segura Perez on 6/9/25.
//

@resultBuilder
public struct SceneBuilder
{
    public static func buildBlock() -> [any Node] { [] }
    
    // Single node
    public static func buildBlock(_ component: any Node) -> [any Node] { [component] }

    // Multiple nodes
    public static func buildBlock(_ components: any Node...) -> [any Node] { components }
    
    // Support conditionals (if/else)
    public static func buildEither(first component : [any Node]) -> [any Node] { component }
    public static func buildEither(second component: [any Node]) -> [any Node] { component }

    // Support optionals (if let)
    public static func buildOptional(_ component: [any Node]?) -> [any Node] { component ?? [] }

    // Support loops
    public static func buildArray(_ components: [[any Node]]) -> [any Node] { components.flatMap { $0 } }
}
