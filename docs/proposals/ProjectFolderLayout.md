# Project folder layout

Status: proposal, 2026-10-10. Not started. Touches the engine (BuildSystem, CLI, exporter, docs) and the editor.

## 1. Goal

A game project made with Untold Engine Studio has four folders at its root. Each has one owner, one kind of content and one reader. Compiled output lives where Xcode and SwiftPM put it (`DerivedData`, `.build/`); the project tree holds no build folder.

| Folder | Holds | Written by | Read by |
|---|---|---|---|
| `Resources/` | What the tools work from: `.blend`, `.usd`, PSDs, high-poly meshes, reference images, validation reports. Anything that produces an asset but is not one. Never bundled. | Artists and designers | Blender, the exporter, the editor's cook |
| `GameData/` | What the engine reads, the same folder as today with the same name and the same category subfolders, moved from `Sources/<Project>/` to the root. The editor's asset root; bundled into the app as it is. | The editor (imports, cooks, saves) | The editor, the app |
| `Docs/` | What is written about the game: design, implementation notes, decisions. | Everyone | People |
| `Sources/` | The game's code: the app target and the code components package. | Developers | Xcode |

Everything is tracked except the generated Xcode project and the usual build folders. The app is built from the four folders.

Why: the folder a project gets today mixes the artist's sources, the engine's assets and generated files in one tree three levels inside the code, surrounds them with ten empty category folders, and ships the sources inside the app. Section 2 has the measurements.

## 2. Today

### 2.1 What is created

The engine's BuildSystem creates the project (the CLI's `untoldengine create` and the editor's Create Project both call `BuildSystem.build`, `Sources/UntoldEngine/BuildSystem/BuildSystem.swift:328-363`). For a single platform:

```
<Project>/
├── Package.swift                      macOS only (BuildTemplates.swift:1800)
├── README.md
├── project.yml                        BuildSystem.swift:507-509
├── <Project>.xcodeproj/               xcodegen (BuildSystem.swift:518-526)
└── Sources/
    ├── <Project>/
    │   ├── AppDelegate.swift, GameViewController.swift, Base.lproj/   (not visionOS)
    │   ├── <Project>App.swift                                          (visionOS)
    │   ├── GameScene.swift, GameSceneUtils.swift, Info.plist
    │   └── GameData/
    │       └── Scenes/ Scripts/ Models/ StreamModels/ Animations/ Gaussians/ Textures/ Shaders/ LUT/
    └── <Project>Plugins/Spinner.swift   (code components, when the editor knows its engine)
```

- `project.yml` compiles `Sources` minus `<Project>/GameData` and adds `GameData` as a folder resource (`XcodeGenProjectSpec.swift:157-165`). The SwiftPM variant uses `.process("GameData")` (`BuildTemplates.swift:56-58`).
- The multi-platform variant adds four folders at the root, `<Project> macOS/`, `<Project> iOS/`, `<Project> iOS AR/`, `<Project> visionOS/` (`BuildTemplates.swift:1931-1960`).
- The editor opens any folder with a `project.yml` or `<Name>.xcodeproj`, creates `Sources/<Name>/GameData` when it is missing and then ten category folders, and points the asset root at GameData (`UntoldEditor/Sources/UntoldEditor/Editor/Window/EditorView+Project.swift:38-80`). It adds `Materials/` and `HDR/` to the nine the engine made.
- At runtime the generated `GameScene` looks up a bundle folder named `GameData` (`BuildTemplates.swift:212-225`). The engine itself never builds a `GameData` path: the asset root is whatever `assetBasePath` says, and lookups under it use the category names (`Systems/LoadingSystem.swift:17-29, 59-170`).

### 2.2 What it looks like in a real project

ZombiStation Ground Zero (visionOS, one model pack of 375 models, created and filled by the editor):

| Fact | Measure |
|---|---|
| Category folders under GameData | 11, of which 10 are empty |
| The source `.blend`, imported by the editor into `GameData/Models/<Pack>/` | 96 MB |
| The pack's folder (payloads, textures, HDR, the source) | 307 MB |
| Of that, shipped in the app bundle although the engine never reads it | the 96 MB `.blend` |

The `.blend` ships because `project.yml` bundles the whole GameData folder, and the editor's import copies a source into `GameData/<Category>/<Stem>/` (`AssetBrowserView+Import.swift:143-158, 260`), where its cook then writes beside it (`RuntimeExportLocation.swift:28-35`). The pack's manifest already names its source, as a bare file name: `"sourceAsset": "EDIFICIO_COMPLETO_BLOCKING.blend"` (`scripts/untoldexplorer.py:7682`; the engine reads it into `UntoldPackData.sourceAsset`, `Systems/RegistrationSystem.swift:2462`, and nothing uses it).

There is no `.gitignore`, so nothing tells a developer that the Xcode project, `.build/` and the bundled copies are generated. Harold's own sample ships `project.yml` without an `.xcodeproj` (`Examples/CodeComponents/SampleProject/`), and the editor opens such a folder since upstream `3de9f54`.

### 2.3 What the code and the docs say about the layout

- The category list exists five times: engine creation (`BuildSystem.swift:733, 991`), editor open (`EditorView+Project.swift:69`), the asset browser's categories, the asset pack browser, and `docs/API/UsingAssetPaths.md:12-21` (which omits `LUT`). The chain `Sources/<Project>/GameData` is repeated four times in the engine (`BuildSystem.swift:275-278, 296-299, 442-445, 461-464`) and twice in the editor (`EditorView+Project.swift:53-55`, `CreateProjectView.swift:258-260`); the project root is found by walking three levels up from it (`Components/ComponentProject.swift:134-137`). No `ProjectLayout` type exists in either repo.
- The generated README documents `main.swift`, `GameRuntime.swift` and `.json` scenes, none of which exist (`BuildTemplates.swift:1484-1498`). `MULTI_PLATFORM_USAGE.md:154-177` puts the platform files where the code does not. `GameData` appears on 123 lines of 20 files under `docs/`; nearly all of them stay true under this proposal, since the folder keeps its name.
- The CLI's `untoldengine update --asset-path <folder>` deletes and rebuilds the nine GameData folders from a separate asset folder (`BuildSystem.swift:989-1006`, `Tools/UntoldEngineCLI/Sources/UntoldEngineCLI/UpdateCommand.swift`), folding `Materials/` and `HDR/*.hdr` into `Textures/` (`BuildSystem.swift:875-895`) and copying the engine's metallibs into `Shaders/` (`:951-986`). `create` points that asset path at the new project's own empty GameData (`CreateCommand.swift:98-104`). `assets install` finds a `GameData` folder up to three levels down (`CLIHelpers.swift:313-337`).
- Issue untoldengine/UntoldEditor#152 (Harold, 2026-10-06) calls the source-beside-pack convention intentional, so that a re-cook finds its source, and fixed the clutter in the browser only (#154 hides a folder that shares a stem with a sibling pack). Section 4 keeps that property.

## 3. The proposed layout

```
<Project>/
├── .gitignore                 <Project>.xcodeproj/, .build/, DerivedData/, xcuserdata/, .DS_Store, *.blend1
├── README.md                  describes these folders
├── project.yml
├── UntoldEditor.json          optional, as today (plugins folder, plugin packages)
├── <Project>.xcodeproj/       generated from project.yml; ignored
├── Docs/
├── GameData/                  the editor's asset root (assetBasePath); bundled as it is
│   ├── Models/                Tower.untoldpack + Tower/ (payload .untold files, Textures/, HDR/)
│   ├── StreamModels/
│   ├── Animations/
│   ├── Gaussians/
│   ├── Materials/
│   ├── HDR/
│   ├── LUT/
│   ├── Scenes/                .untoldscene
│   └── Scripts/               .uscript
├── Resources/
│   └── Models/Tower/Tower.blend     where the editor's import puts a source; artists are free below Resources/
└── Sources/
    ├── <Project>/             App.swift or AppDelegate + GameViewController, GameScene.swift, Info.plist, Base.lproj/
    └── <Project>Plugins/      code components (optional)
```

ZombiStation after conversion: `Resources/Models/EDIFICIO_COMPLETO_BLOCKING/EDIFICIO_COMPLETO_BLOCKING.blend` (96 MB, tracked, never bundled); `GameData/Models/EDIFICIO_COMPLETO_BLOCKING.untoldpack` with `GameData/Models/EDIFICIO_COMPLETO_BLOCKING/` (payloads, `Textures/`, `HDR/`); `GameData/Scenes/` once a scene is saved; no other category folder on disk. The app bundle is the same as today minus the `.blend`.

The multi-platform variant keeps its per-platform app folders but under `Sources/` (`Sources/<Project> macOS/` and so on), so the root stays at the four folders.

## 4. Rules

- R1 The engine never reads `Resources/`. Nothing under it is bundled. Below `Resources/` the layout is free; the editor's own imports mirror the asset categories (`Resources/<Category>/<Stem>/<Stem>.<ext>`).
- R2 `GameData/` is the asset root, with the name, the categories and the content it has today, at the project root. Everything the editor shows, imports, cooks and saves is under it. Scene references stay relative to it (`Scenes/SceneSerializer.swift:341-373`). `project.yml` bundles it as a folder reference and the app looks it up by name, both exactly as today, so the runtime does not change.
- R3 A category folder is created when the first file goes into it, not at creation. The browser keeps showing its fixed categories. (D3)
- R4 A cook reads from `Resources/` (or anywhere) and writes only into `GameData/`: the result into the category folder the user chose, the files it references into `<Stem>/` beside it, through the exporter's existing `--assets-dir`. The pack's `sourceAsset` becomes a path relative to the pack (`../../Resources/Models/Tower/Tower.blend`). (D4)
- R5 A re-cook finds its source through `sourceAsset`; for a result that carries no manifest (`.untold`, `.untoldgs`, `.untoldanim`) and for packs cooked before this change, through the mirrored path, then the legacy folder beside the result. (D4)
- R6 No build folder in the project. Compiled output stays in `DerivedData` and `.build/`. The conversions a game needs already happen at cook time into `GameData/` (ASTC textures, LOD tiers); a build step that strips or converts per target, when one is wanted, is a build phase writing into the product, never into the project. (D2)
- R7 `Sources/` holds code only: the app target and the plugins package. `Info.plist` and storyboards stay with the app target as today.
- R8 One type describes the layout, in the engine, and both repos use it: `ProjectLayout(root:)` with `gameData`, `resources`, `docs`, `sources`, `projectSpec`, `xcodeProject`, `pluginsFolder`, the category list, and `isLegacy` (then `gameData` is `Sources/<Project>/GameData`). The five lists and the six chains of section 2.3 go. (D6)

## 5. What changes, by repository

### 5.1 Engine

- `BuildSystem`: templates and the XcodeGen spec on the new tree (`project.yml` compiles `Sources` and bundles `GameData` from the root); the generated `GameScene` is untouched; `createGameDataDirectories` is not called for a new project; `.gitignore` and a correct README written at creation; `BuildSettings` gains the layout; `update` and `assets install` find the root `GameData/` through the layout; the unused `createAssetFolderStructure` (`CLIHelpers.swift:227-245`) goes. The SwiftPM template's target moves to the project root so it can bundle `GameData/` from there (D10).
- `ProjectLayout` (public, in BuildSystem) with legacy detection: `GameData/` at the root means the new layout; `Sources/<Name>/GameData` without it means the old one.
- `convert`: the migration of section 6, in the BuildSystem so the editor and the CLI share it.
- Docs: the paths in `UsingAssetPaths.md`, `CreateXcodeProjectTutorial.md`, `GettingStarted.md`, `UsingCodeComponents.md`, the CLI README, `MULTI_PLATFORM_USAGE.md` and the exporter tutorials; the name stays, so most lines change their prefix only.
- Tests: `BuildSystemTests`, `BuildSystemCodeComponentsTests` on both layouts.

### 5.2 Editor

- Open and Create through `ProjectLayout`: asset root `<root>/GameData`, project root its parent. The two chains and the three-levels-up walk go.
- Import: a source (`blend`, `usd*`, `AssetFileHelpers.swift:22`) goes to `Resources/<Category>/<Stem>/`; a runtime file goes to `GameData/<Category>/` as today. `Resources/` appears in the browser's sidebar as a second root (`AssetBrowserView+DirectoryTree.swift:25` already takes custom roots), so a source can be cooked from there and "Reveal Source Folder" is no longer needed for new projects.
- Cook: `runtimeExportLocation(for:)` maps a source under `Resources/` to `GameData/` by the mirror; a source elsewhere cooks into the category folder the user picks. The #154 hiding rule stays, it still hides the payload folder beside a pack.
- Re-cook through `sourceAsset` (R5).
- `File > Convert Project Layout…` for an existing project (section 6).
- The USC script package the editor generates (`ScriptProjectManager`, today inside `GameData/Scripts/`, bundled with its `.build/`) moves out of the asset tree so it is not bundled; where exactly is a stage 2 detail. The `.uscript` files stay in `GameData/Scripts/`.
- Tests: `ComponentProjectTests`, `EditorControllerTests`, `ScriptProjectManagerTests`, `RuntimeExportLocationTests`, a new `ProjectLayoutTests`, a conversion test on a fixture of the old layout.

### 5.3 Exporter

- `sourceAsset` written as a path relative to the output (`untoldexplorer.py:7682`); the engine's reader accepts both forms.

## 6. Compatibility and migration

- A project whose `GameData` is still under `Sources/<Name>/` is a legacy project and works exactly as today: the editor keeps that root, the CLI its paths, the docs keep one section on the old layout. Nothing is forced.
- `Convert Project Layout…` (editor) or `untoldengine convert` (CLI), both through the BuildSystem: move `Sources/<Name>/GameData` to the root; move every source file (`blend`, `usd*`) to the mirrored place under `Resources/`; rewrite each pack's `sourceAsset`; drop empty category folders; rewrite `project.yml` (and `Package.swift`); write `.gitignore` and README; regenerate the Xcode project; log every move. Dry run first; the editor shows the list before it moves anything.
- ZombiStation Ground Zero is the first conversion and the test of R5 (its pack carries a bare `sourceAsset`).
- Harold's sample project and the tutorials move to the new layout in the same PRs.

## 7. Stages

| Stage | Where | Content | Size |
|---|---|---|---|
| 1 | Engine | `ProjectLayout`, templates, XcodeGen spec, `.gitignore`, README, `update` and `assets install` through the layout, `convert`, docs, tests | About a day and a half |
| 2 | Editor | Open/Create through the layout, imports to `Resources/`, cook mirror, re-cook by `sourceAsset`, Convert, the script package out of the asset tree, tests | About a day and a half |
| 3 | Engine (exporter) | `sourceAsset` as a relative path, reader accepts both | Half a day |

Stage 1 first: the editor pins the engine's develop. Stage 3 can ride with stage 1. Each stage is one PR to upstream.

## 8. Decisions

- D1 Names: `Resources`, `Docs`, `Sources`, and `GameData` kept for the asset folder. The first draft called it `Assets`; the user chose to keep `GameData` (2026-10-10) since the runtime looks the folder up by that name, the CLI and every doc page use it, and the asset browser's panel is already titled Assets whatever the folder is called; only the folder's place changes. `Resources` is also Apple's word for a bundle's files; that use stays inside `Sources/` and does not collide.
- D2 No build folder in the project. The first draft had a `GameData/` produced by the build and ignored, next to an `Assets/`; the user pointed out that it duplicates what `DerivedData` and `.build/` already are: a copy of the assets in the project tree, copied once more into the product. Nothing needs a folder between the asset tree and the bundle: the conversions a game needs are made by the cook into the asset tree (ASTC textures, LOD tiers), and what the CLI's `update` does beyond copying is two legacy foldings (Materials and HDR into `Textures/`, the engine's metallibs into `Shaders/`). Bundling the asset tree as it is also means the app sees exactly what the editor played from. When a per-target strip or conversion is wanted, it is a build phase writing into the product.
- D3 Category folders on demand. Ten empty folders is the noise this proposal starts from; Finder users lose the preview of the categories, the browser keeps it.
- D4 Re-cook by `sourceAsset`, mirror as the fallback. The manifest field exists and is unused; a relative path costs one line in the exporter and keeps Harold's #152 property with the source outside the bundled tree.
- D5 The generated Xcode project is ignored. It is regenerated by `xcodegen` and by the editor on open, and Harold's sample already ships without one. If he prefers it tracked, one line in the `.gitignore` template changes.
- D6 One `ProjectLayout` in the engine. The editor already depends on the engine's BuildSystem for creation; the layout belongs with it.
- D7 Legacy projects stay supported until Harold decides otherwise; conversion is explicit.
- D8 No staging step and no command for it. The editor plays from `GameData/` and Xcode bundles `GameData/`, as both do today.
- D9 Multi-platform app folders go under `Sources/`.
- D10 The SwiftPM variant (macOS only) declares its target at the project root with explicit `sources: ["Sources/<Project>"]` and `resources: [.copy("GameData")]`, since SwiftPM resources must sit inside the target folder; to be verified in `BuildSystemTests`. If that does not hold up, the SwiftPM variant is dropped (iOS and visionOS never had it) and the Xcode project is the one way.

## 9. What Harold may object to, and the answer

- The layout is documented and taught. The folder keeps its name, so the pages change a path prefix; stage 1 updates every one of them, and the old layout keeps working.
- Source beside pack is intentional (#152). The source keeps a deterministic place (the mirror) and the pack records it (`sourceAsset`); the browser shows `Resources/` as a root, so cooking from a source is one click, as it is today from the hidden folder.
- SwiftPM wants resources inside the target. D10.
- Projects in the wild. D7, with `convert` doing the move and logging it.
- The runtime is untouched: the app bundle has the same `GameData` folder, found the same way, minus the files that never belonged in it.

## 10. Questions for Harold

1. The on-demand category folders (D3) and the ignored Xcode project (D5).
2. Whether a project needs the engine's metallibs in a `Shaders/` folder at all. `update` copies them for old projects (`BuildSystem.swift:951-986`), the runtime falls back to the engine's own bundle (`LoadingSystem.swift:169`, `Utils/Bundle+ResourceFallback.swift:59-62`), and ZombiStation runs with an empty `Shaders/`. The `Materials/` and `HDR/` foldings of `update` (`BuildSystem.swift:875-895`) are not needed either: the scene serializer looks in `<root>/HDR/` first (`SceneSerializer.swift:1302-1305`) and the editor already plays from that tree.
3. Whether `update` keeps a role for new projects (pulling assets from an external folder into `GameData/`) or serves old ones only.
