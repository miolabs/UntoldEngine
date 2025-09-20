// swift-tools-version: 5.10
import PackageDescription

#if os(macOS)
var products:[Product] = [
    .library( name: "UntoldEngine", targets: ["UntoldEngine"] ),
    .executable( name: "DemoGame", targets: ["DemoGame"] ),
    .executable( name: "StarterGame", targets: ["StarterGame"] ),
    .executable( name: "SwiftUIDemo", targets: ["SwiftUIDemo"] ),
    .executable( name: "UntoldEngineEditor", targets: ["UntoldEngineEditor"] ),
]

var targets:[Target] = [
    // Library target with the engine code
    .target(
        name: "CShaderTypes",
        path: "Sources/CShaderTypes",
        publicHeadersPath: ".",
        cSettings: [
            .headerSearchPath("."),
        ]
    ),
    .target(
        name: "UntoldEngine",
        dependencies: ["CShaderTypes"],
        path: "Sources/UntoldEngine",
        exclude: ["Shaders"],
        resources: [
            // Include all Metal files and other resources
            .copy("UntoldEngineKernels/UntoldEngineKernels.metallib"),
            .process("UntoldEngineKernels/UntoldEngineKernels.air"),
            .process("UntoldEngineKernels/UntoldEngineKernels.metal"),
            .process("Resources/Models"),
            .process("Resources/HDR"),
            .process("Resources/ReferenceImages"),
            .process("Resources/textures"),
        ],
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    // Executable target for the demo game
    .executableTarget(
        name: "DemoGame",
        dependencies: ["UntoldEngine"],
        path: "Sources/DemoGame",
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    // Executable target for the starter template
    .executableTarget(
        name: "StarterGame",
        dependencies: ["UntoldEngine"],
        path: "Sources/StarterGame",
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    .executableTarget(
        name: "SwiftUIDemo",
        dependencies: ["UntoldEngine"],
        path: "Sources/SwiftUIDemo",
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    .executableTarget(
        name: "UntoldEngineEditor",
        dependencies: ["UntoldEngine"],
        path: "Sources/UntoldEngineEditor"
    ),
    // Test target for unit tests
    .testTarget(
        name: "UntoldEngineTests",
        dependencies: ["UntoldEngine"],
        path: "Tests/UntoldEngineTests"
    ),
    // Render-specific test target
    .testTarget(
        name: "UntoldEngineRenderTests",
        dependencies: ["UntoldEngine"],
        path: "Tests/UntoldEngineRenderTests"
    )

]
#else
var products:[Product] = [
    .library( name: "UntoldEngine", targets: ["UntoldEngine"] ),
    .executable( name: "SwiftUIDemo", targets: ["SwiftUIDemo"] ),
]

var targets:[Target] = [
    // Library target with the engine code
    .target(
        name: "CShaderTypes",
        path: "Sources/CShaderTypes",
        publicHeadersPath: ".",
        cSettings: [
            .headerSearchPath("."),
        ]
    ),
    .target(
        name: "UntoldEngine",
        dependencies: ["CShaderTypes"],
        path: "Sources/UntoldEngine",
        exclude: ["Shaders"],
        resources: [
            // Include all Metal files and other resources
            .copy("UntoldEngineKernels/UntoldEngineKernels.metallib"),
            .process("UntoldEngineKernels/UntoldEngineKernels.air"),
            .process("UntoldEngineKernels/UntoldEngineKernels.metal"),
            .process("Resources/Models"),
            .process("Resources/HDR"),
            .process("Resources/ReferenceImages"),
            .process("Resources/textures"),
        ],
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    .executableTarget(
        name: "SwiftUIDemo",
        dependencies: ["UntoldEngine"],
        path: "Sources/SwiftUIDemo",
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
            .linkedFramework("Cocoa", .when(platforms: [.macOS])),
            .linkedFramework("UIKit", .when(platforms: [.iOS]))
        ]
    ),
    .executableTarget(
        name: "UntoldEngineEditor",
        dependencies: ["UntoldEngine"],
        path: "Sources/UntoldEngineEditor"
    ),
]
#endif


let package = Package(
    name: "UntoldEngine",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        // .visionOS(.v1),
    ],
    products: [
        // Library product for the engine
        .library(
            name: "UntoldEngine",
            targets: ["UntoldEngine"]
        ),
        // Executable for the demo game
        .executable(
            name: "DemoGame",
            targets: ["DemoGame"]
        ),
        // Executable for the starter template
        .executable(
            name: "StarterGame",
            targets: ["StarterGame"]
        ),
        .executable(
            name: "SwiftUIDemo",
            targets: ["SwiftUIDemo"]
        ),
    ],
    targets: [
        .target(
            name: "CShaderTypes",
            path: "Sources/CShaderTypes",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "UntoldEngine",
            dependencies: ["CShaderTypes"],
            path: "Sources/UntoldEngine",
            exclude: ["Shaders"],

            // 📦 Ship prebuilt metallibs for each platform; pick at runtime.
            resources: [
                .copy("UntoldEngineKernels/UntoldEngineKernels.metallib"),         // macOS
                .copy("UntoldEngineKernels/UntoldEngineKernels-ios.metallib"),     // iOS (device)
                .copy("UntoldEngineKernels/UntoldEngineKernels-iossim.metallib"),  // iOS (simulator)
                .copy("UntoldEngineKernels/UntoldEngineKernels-tvos.metallib"),    // tvOS (device)
                .copy("UntoldEngineKernels/UntoldEngineKernels-tvossim.metallib"), // tvOS (simulator)
                .copy("UntoldEngineKernels/UntoldEngineKernels-xros.metallib"),    // visionOS (device)
                .copy("UntoldEngineKernels/UntoldEngineKernels-xrossim.metallib"), // visionOS (simulator)
                .process("Resources/Models"),
                .process("Resources/HDR"),
                .process("Resources/ReferenceImages"),
                .process("Resources/textures"),
            ],

            linkerSettings: [
                // Common
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS, .iOS/*, .visionOS*/])),

                // macOS UI stack
                .linkedFramework("AppKit", .when(platforms: [.macOS])),

                // iOS UI stack (only if some targets import UIKit)
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),

        // These executables are macOS-only
        .executableTarget(
            name: "DemoGame",
            dependencies: ["UntoldEngine"],
            path: "Sources/DemoGame",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "StarterGame",
            dependencies: ["UntoldEngine"],
            path: "Sources/StarterGame",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "SwiftUIDemo",
            dependencies: ["UntoldEngine"],
            path: "Sources/SwiftUIDemo",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS]))
            ]
        ),
        // Test target for unit tests
        .testTarget(
            name: "UntoldEngineTests",
            dependencies: ["UntoldEngine"],
            path: "Tests/UntoldEngineTests"
        ),
        // Render-specific test target
        .testTarget(
            name: "UntoldEngineRenderTests",
            dependencies: ["UntoldEngine"],
            path: "Tests/UntoldEngineRenderTests"
        ),
    ]
)

