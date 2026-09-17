# Multi-Platform CLI Usage

The `untoldengine` CLI tool supports creating multi-platform game projects that target macOS, iOS, and visionOS simultaneously.

## Quick Start

Create a multi-platform project in one command:

```bash
mkdir MyGame && cd MyGame
untoldengine create MyGame --platform multi --team-id YOUR_TEAM_ID
```

This creates a single Xcode project with four app targets: macOS, iOS, iOS with ARKit, and visionOS.

## Command Options

### Basic Multi-Platform Project

```bash
untoldengine create <project-name> --platform multi
```

**Required for iOS/visionOS builds:**
```bash
untoldengine create MyGame --platform multi --team-id ABCD1234EF
```

The `--team-id` is your Apple Developer Team ID, required for code signing iOS and visionOS apps.

### Custom Deployment Targets

Specify deployment versions for each platform:

```bash
untoldengine create MyGame \
  --platform multi \
  --macos-version 14 \
  --ios-version 17 \
  --visionos-version 2 \
  --team-id YOUR_TEAM_ID
```

**Available versions:**
- macOS: `13`, `14`, `15` (default: `15`)
- iOS: `16`, `17`, `18` (default: `17`)
- visionOS: `1`, `2` (default: `2`)

### Full Options

```bash
untoldengine create MyGame \
  --platform multi \
  --bundle-id com.mycompany.mygame \
  --output ~/Projects \
  --macos-version 14 \
  --ios-version 17 \
  --visionos-version 2 \
  --team-id YOUR_TEAM_ID \
  --optimization speed \
  --debug
```

**All options:**
- `--platform multi` - Create multi-platform project
- `--bundle-id` - Bundle identifier (default: auto-generated)
- `--output` - Output directory (default: current directory)
- `--macos-version` - macOS deployment target
- `--ios-version` - iOS deployment target
- `--visionos-version` - visionOS deployment target
- `--team-id` - Apple Developer Team ID
- `--optimization` - Optimization level: `none`, `speed`, `size` (default: `none`)
- `--debug` / `--no-debug` - Include debug info (default: `true`)

## Output

The CLI will display a configuration summary:

```
🎮 UntoldEngine Project Creator
Creating project: MyGame

📋 Configuration:
   Project Name:    MyGame
   Bundle ID:       com.example.mygame
   Platform:        Multi-Platform
     - macOS:       15.0
     - iOS:         17.0
     - visionOS:    2.0
   Project Dir:     /path/to/MyGame
   GameData Path:   /path/to/MyGame/Sources/MyGame/GameData
   Optimization:    -Onone
   Debug Info:      Yes
   Team ID:         ABCD1234EF

🔨 Starting build process...

✅ Settings validated
📁 Created project directory
📋 Copied template project
📦 Bundled 0 assets
⚙️ Configured Xcode project
✅ Build complete in 2.15s

✅ Project created at: /path/to/MyGame
ℹ️  Bundled 0 assets

📁 Add your game assets to: /path/to/MyGame/Sources/MyGame/GameData

Open project in Xcode? [Y/n]: 
```

## Using the Generated Project

### Open in Xcode

```bash
open MyGame/MyGame.xcodeproj
```

### Select Platform

The project has one target per platform, and Xcode shows one scheme for each. Use the scheme selector at the top to choose a scheme, then a run destination for it:

| Scheme | Run destination |
|---|---|
| **MyGame macOS** | My Mac |
| **MyGame iOS** | iPhone/iPad device or simulator |
| **MyGame iOS AR** | iPhone/iPad device (ARKit does not run in the simulator) |
| **MyGame visionOS** | Apple Vision Pro device or simulator |

The schemes are named after your project: `<project-name> macOS`, `<project-name> iOS`, `<project-name> iOS AR` and `<project-name> visionOS`.

### Build and Run

Press `Cmd+R` or click the Play button to build and run the selected scheme.

## Comparison: Single vs Multi-Platform

### Single Platform (Separate Projects)

```bash
# Create three separate projects
untoldengine create MyGame --platform macos
untoldengine create MyGame --platform ios
untoldengine create MyGame --platform visionos
```

**Result:** 3 separate Xcode projects to maintain

### Multi-Platform (One Project)

```bash
# Create one unified project
untoldengine create MyGame --platform multi --team-id YOUR_TEAM_ID
```

**Result:** 1 Xcode project that targets all platforms

## Project Structure

```
MyGame/
├── MyGame.xcodeproj              # Xcode project with one target per platform
├── project.yml                   # XcodeGen configuration
├── README.md
├── MyGame macOS/                 # macOS target only
│   ├── AppDelegate.swift         # NSApplicationDelegate
│   ├── GameViewController.swift  # NSViewController: Metal view and renderer setup
│   ├── Base.lproj/
│   │   └── Main.storyboard
│   └── Info.plist
├── MyGame iOS/                   # iOS target only
│   ├── AppDelegate.swift         # UIApplicationDelegate
│   ├── GameViewController.swift  # UIViewController: Metal view and renderer setup
│   ├── Base.lproj/
│   │   └── Main.storyboard
│   └── Info.plist
├── MyGame iOS AR/                # iOS AR target only
│   ├── AppDelegate.swift         # UIApplicationDelegate
│   ├── GameViewController.swift  # UIViewController: ARKit session and AR renderer
│   ├── Base.lproj/
│   │   └── Main.storyboard
│   └── Info.plist                # Adds the camera usage description and the ARKit requirement
├── MyGame visionOS/              # visionOS target only
│   ├── MyGameApp.swift           # SwiftUI App with the immersive space
│   └── Info.plist
└── Sources/
    └── MyGame/                   # Shared by all four targets
        ├── GameScene.swift       # Game setup, update loop and input
        ├── GameSceneUtils.swift  # Points the engine at the bundled GameData
        └── GameData/             # Shared game assets
            ├── Scenes/
            ├── Scripts/
            ├── Models/
            ├── StreamModels/
            ├── Animations/
            ├── Gaussians/
            ├── Textures/
            ├── Shaders/
            └── LUT/
```

**Platform-specific files** live in the four `MyGame <platform>/` folders. Each folder belongs to exactly one target and holds what differs between platforms: the app entry point, the view controller, the storyboard and `Info.plist`. The macOS, iOS and iOS AR targets each have their own `AppDelegate.swift` and `GameViewController.swift`; the visionOS target uses a SwiftUI `App` (`MyGameApp.swift`) instead and has no storyboard.

**Shared files** live in `Sources/MyGame/`. All four targets compile `GameScene.swift` and `GameSceneUtils.swift`, and each app bundles the same `GameData/` folder.

## Platform-Specific Code

Code that only one platform needs belongs in that target's folder. Those files are compiled for a single platform, so they need no conditional compilation. When you add a file in Xcode, set its target membership to match: one target for platform code, all four for shared code.

Files in `Sources/MyGame/` are compiled into every target. When shared code has to differ per platform, use conditional compilation there (`os(iOS)` is true for both the iOS and the iOS AR target):

```swift
class GameScene {
    func setupControls() {
        #if os(macOS)
        // macOS: keyboard + mouse
        setupKeyboardControls()
        #elseif os(iOS)
        // iOS: touch controls
        setupTouchControls()
        #elseif os(visionOS)
        // visionOS: spatial gestures
        setupSpatialControls()
        #endif
    }
}
```

## Finding Your Apple Developer Team ID

Your Team ID is required for iOS and visionOS code signing. Find it:

1. **Via Xcode:**
   - Open Xcode preferences
   - Go to Accounts
   - Select your Apple ID
   - Your Team ID is shown next to your team name

2. **Via Developer Portal:**
   - Visit https://developer.apple.com/account
   - Go to Membership
   - Your Team ID is listed

3. **Via Keychain:**
   ```bash
   security find-identity -v -p codesigning | grep "Developer"
   ```

## Tips

✅ **Always specify `--team-id`** for multi-platform projects (required for iOS/visionOS)  
✅ **One GameData folder** - `Sources/MyGame/GameData` is bundled into every target  
✅ **One GameScene** - `Sources/MyGame/GameScene.swift` is compiled into every target; only the files in the per-target folders differ  
✅ **Version control friendly** - one project instead of three  
✅ **Switch platforms** by picking another scheme in Xcode, without changing projects  

## Examples

### Basic Multi-Platform Game

```bash
mkdir SpaceGame && cd SpaceGame
untoldengine create SpaceGame \
  --platform multi \
  --bundle-id com.studio.spacegame \
  --team-id ABCD1234EF
```

### Production Build with Optimization

```bash
mkdir ReleaseGame && cd ReleaseGame
untoldengine create ReleaseGame \
  --platform multi \
  --bundle-id com.studio.releasegame \
  --team-id ABCD1234EF \
  --optimization speed \
  --no-debug
```

### Custom Deployment Targets

```bash
mkdir ModernGame && cd ModernGame
untoldengine create ModernGame \
  --platform multi \
  --macos-version 15 \
  --ios-version 18 \
  --visionos-version 2 \
  --team-id ABCD1234EF
```

## Troubleshooting

**Error: "Build failed: xcodegen not found"**
```bash
brew install xcodegen
```

**Error: "Invalid bundle identifier"**
- Use format: `com.company.app`
- Only alphanumeric, dots, and hyphens
- Example: `com.mystudio.mygame`

**iOS/visionOS build fails with signing error:**
- Ensure you've provided `--team-id`
- Verify your Team ID is correct
- Check your Apple Developer account is active

**Platform switch not working in Xcode:**
- Make sure you've opened the `.xcodeproj` file
- Check that all four schemes (`MyGame macOS`, `MyGame iOS`, `MyGame iOS AR`, `MyGame visionOS`) appear in the scheme selector
- Try cleaning the build folder (`Cmd+Shift+K`)

## See Also

- [Using the UntoldEngine CLI](../../docs/API/UsingUntoldEngineCLI.md)
- [UntoldEngine Documentation](https://github.com/untoldengine/UntoldEngine)
