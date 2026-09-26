# Untold Editor — UI redesign handoff

Target: `UntoldEditor` (SwiftUI + AppKit, macOS). This document describes the proposed layout so an agent can implement it in Xcode. Screenshots are in `images/`. The interactive mockup is `../Untold Editor.dc.html`.

Existing files to build on (do not start from scratch):
- `Editor/EditorScheme.swift` — color tokens (reuse; add tokens listed below)
- `Editor/EditorView.swift` — root layout (3-column + bottom dock)
- `Editor/SceneHierarchyView.swift` (`EntityRow`, `HierarchyNode`)
- `Editor/TransformManipulationView.swift` (`ModeButton`, `TransformModeCluster`, `TransformManipulationToolbar`)
- `Editor/InspectorView.swift` (+ `*EditorView` component editors), `ComponentEditorForm.swift`
- `Editor/AssetBrowserView.swift`, `Editor/LogConsoleView.swift`, `Editor/TasksPanelView.swift`
- `Editor/EngineStatsView.swift` (`EngineStatsOverlayView`)
- `Editor/EditorMenuCommands.swift` + `main.swift` (native menu)
- `Editor/SelectionManager.swift`, `Editor/EditorUndoManager.swift`

---

## 1. Screens

| # | Image | State |
|---|-------|-------|
| 1 | `images/01-empty-scene.png` | Nothing selected. Inspector shows empty state. Dock = Assets (list view). |
| 2 | `images/02-entity-selected.png` | `Entity_7` selected. Transform gizmo (arrows + rotation rings). Inspector shows components. Dock = Timeline. |
| 3 | `images/03-asset-browser.png` | Dock = Assets in grid/thumbnail view, `bike.usdz` highlighted. |
| 4 | `images/04-console-errors.png` | Dock = Console with 2 errors, 3 warnings; filter chips. |
| 5 | `images/05-edit-mode.png` | Interaction mode = **Edit**. Vertical mesh-tool strip on the left of the viewport, wireframe + vertex overlay. |
| 6 | `images/06-animate-mode-menu.png` | Interaction mode = **Animate**, mode dropdown open. Dock = Timeline. |

Window in mockups: 1440 × 861 pt. All panels resizable; widths below are defaults.

---

## 2. Global layout (top → bottom)

```
┌ macOS menu bar (native)  Untold Editor · File · Edit · Scene · Entity · Component · Assets · View · Window · Help
├ Title bar + main toolbar (48 pt)
├ Body grid: Hierarchy 250 | Center flexible | Inspector 320   (height flexible)
│   Center = Scene tabs (34) → Viewport tool header (36) → Viewport (flex) → Bottom dock (250, resizable)
└ Status bar (24 pt)
```

### 2.1 Main toolbar (48 pt, bg `#30323D`, bottom hairline black 40%)
Left → right:
1. Traffic lights (native).
2. Project chip: 16×12 orange rounded rect + **Project name** (13 pt semibold) + `· Untold Engine v0.20` (secondary).
3. **Undo / Redo / History ▾** grouped pill (bg black 25%, radius 7, inner buttons 28×26 radius 5). Redo disabled = `#5F616C`. History opens a popover listing the undo stack (`EditorUndoManager`).
4. **Play ▶ / Pause ❙❙ / Step ▶❙** grouped pill, centered horizontally in the toolbar. Active state: orange fill `editorAccent`, inverse text. (Move the play button out of the Scene Graph header.)
5. **Build target dropdown** `[device icon] macOS ▾` — `Menu` with macOS, iOS, iPadOS, visionOS, tvOS. Selecting visionOS enables the volume-bounds overlay in the viewport (see §2.4). Right-aligned.
6. **Search everywhere** field, 200 pt wide, placeholder `⌕ Search everywhere`, trailing `⌘K` hint. Global search across entities, assets, components, menu commands.

### 2.2 Hierarchy panel (250 pt)
- Header 34 pt: `Hierarchy` bold · `+` (add entity menu) · `⋯` (panel menu).
- Filter field 26 pt, radius 6, bg black 28%.
- Tree root row: `▾ [orange rect] Untold Scene` (semibold).
- Entity rows 28 pt, radius 6, 6 pt horizontal margin: caret (8 pt wide) · type icon (12×12 stroke, camera/light/mesh) · name · **visibility eye** `◉` · **lock** `🔒`. Hidden entity: eye `#5F616C`. Selected row: bg `editorAccent @ 22%`, text `#FFD9AD`, semibold.
- Groups (e.g. `Rig_Lights`) have caret and 16 pt indent; leaves 30 pt.
- Footer 11 pt secondary: `5 entities · 1 selected`.

### 2.3 Scene tabs (34 pt, bg `#242630`)
- Active tab: bg `#2A2C35`, radius 6 6 0 0, hairline border, `Untold Scene ×`.
- Inactive tab: text secondary; unsaved dot 6 pt orange (`Level_02 ●`).
- `+` new scene. Backed by `ProjectSceneCatalog`.

### 2.4 Viewport tool header (36 pt, bg `#2E3039`)
Left group:
1. **Interaction mode dropdown** (min-width 112, radius 6, bg black 28%): colored 8 pt dot + `Object Mode ▾`. Menu items (with ✓ on current, subtitle, shortcut right-aligned mono):
   - Object Mode — Select & place entities — `⇥1`
   - Edit Mode — Mesh editing: vertices, edges, faces — `⇥2`
   - Animate Mode — Keyframes & timeline — `⇥3`
   - Paint Mode — Textures, weights & UVs — `⇥4`
   Dot colors: object `#E6E7EC`, edit `#F39C3D`, animate `#4F8DE0`, paint `#B53F7A`.
2. Vertical divider 1×20 white 10%.
3. **Transform cluster** (reuse `TransformModeCluster`): Select ⬚ `Q` · Move ✣ `W` · Rotate ↻ `E` · Scale ⤢ `R`. Buttons 28×24 radius 4; active = orange fill, inverse glyph.
4. **World / Local** segmented (24 pt, active bg `#3F414D`).
5. **Snap dropdown**: `⊞ Snap 0.5m ▾` (orange icon when snapping enabled). Popover: grid step (0.1 / 0.25 / 0.5 / 1 m), rotation step (5° / 15° / 45° / 90°), scale step (0.1 / 0.25), toggle per type.

Right group (`Spacer` before):
6. **Shading dropdown**: sphere swatch + `Lit ▾`. Options: Lit, Unlit, Wireframe, Normals, Overdraw, Lighting only.
7. **Projection dropdown**: `Perspective ▾` — Perspective, Orthographic, Top, Front, Right, Game Camera.
8. **Camera speed**: `🎥 4` — scrubbable numeric, 1–10.

### 2.5 Viewport overlays (positioned inside the Metal view container)
- **Top-left**: mode badge (11 pt semibold caps, radius 5): Object = dark scrim `rgba(20,21,28,.55)`; Edit = orange; Animate = blue; Paint = magenta. Below it the existing `EngineStatsOverlayView` (mono 11 pt, `62 fps · 4.2 ms` / `1,248 tris · 3 draw calls`), bg scrim, radius 6.
- **Top-right**: **Navigation gizmo** 84×84 circle (bg scrim 35%). Positive axes: 16 pt filled balls with letter (X `#E0574F`, Y `#8BC34A`, Z `#4F8DE0`, dark letter); negative axes: 14 pt hollow rings (35% fill + 1.5 pt stroke, same colors); axis lines 2 pt from centre. Drag = orbit, click ball = snap view to that axis, click centre = toggle perspective/ortho.
- Under the gizmo, 4 round buttons 26 pt (bg scrim 45%): Zoom ⌕ · Pan ✋ · Camera view 🎥 · Perspective/Ortho ⊞.
- **Bottom-center**: hint chips `Frame selected F` · `Orbit ⌥ drag` (11 pt, bg scrim 55%, radius 5).
- **Selection**: dashed white 1.5 pt bounding rect around the selected mesh (radius 12).
- **Transform gizmo** (Object mode + selection): arrows X red `#FF5A5A` (→), Y green `#5CE08C` (↑), Z blue `#4C8DFF` (↘ 38°), 3 pt shafts with triangle heads; plus **rotation rings** 140 pt: red `rotateY 76°`, green `rotateX 72°`, blue `rotate3d(1,1,0,60°)`, and a white 55% outer trackball ring 164 pt; white centre dot 14 pt. Rendered by the engine's `GizmoSystem` — colors above are the spec.
- **Edit mode overlays**: mesh wireframe (white 50% grid, 1.5 pt outline), vertices 6 pt white dots with 1 pt dark ring; selected vertices orange. **Mesh tool strip** at left (x 12, y 86; bg scrim 60%, radius 8, padding 4): Vertex • / Edge ╱ / Face ▰ selector (34×30, active bg `#3F414D`), divider, then tools 34×34: Extrude `E` (active orange), Inset `I`, Bevel `⌘B`, Loop Cut `⌘R`, Knife `K`, Move faces `G`, Smooth, Merge `M`. The transform gizmo is hidden in Edit mode.
- **visionOS target**: 760×480 volume rect, stroke `rgba(120,200,255,.8)`, radius 8, inner glow; label chip above `visionOS volume · 1.0 × 0.6 × 0.6 m` (bg cyan, dark text).

### 2.6 Bottom dock (250 pt default, resizable, bg `#2A2C35`)
Tab strip 34 pt: `Assets · Console (badge) · Timeline · Tasks` — 26 pt pills, active bg `#3F414D` semibold. Console badge: red `#E5484D` circle with unread-error count. Right side: shared filter field 200 pt (placeholder changes per tab: `Filter assets` / `Filter log` / `Filter tracks`) + `▾` panel menu.

**Assets** (extend `AssetBrowserView`): split 220 | flex. Left: folder tree (Project root ▾ / Primitives / Lights / Models ▾ / Stream Models / Animations / Scripts), rows 24 pt, active bg `#3F414D`. Right: breadcrumb `Test GS › Models` + **grid/list toggle** (24×20 buttons). Grid: 96 pt cells, 72 pt thumbnail (radius 5) + centred name 11 pt; selected cell bg orange 18% + 1 pt orange border. List: columns icon 20 | name | kind 90 | size 80 (mono) | date 70, rows 26 pt. Asset kinds & swatch colors: Model green `#3FB56A`, Material `#5CE08C`, Texture `#B5893F`, Animation `#B53F7A`, Scene orange.

**Console** (extend `LogConsoleView`): sub-bar 30 pt with filter chips `All 14` (active bg `#3F414D`) · `● 2 errors` red `#FF7B7B` · `▲ 3 warnings` yellow `#F5C451` · `ⓘ 9 info`; right: `Clear · Collapse · Pause on error`. Rows mono 11.5 pt, grid: time 70 | glyph 14 | message flex (pre-wrap) | source 220 right-aligned (`File.swift:line`, secondary). Error rows bg `rgba(229,72,77,.12)`, text `#FFB3B3`; warning text `#F0D9A0`.

**Timeline** (new; wires to `AnimationEditorView` data): split 220 | flex. Left: transport `⏮ ◀ ▶ ▶ ⏭` + mono timecode `00:01.20`; track list — entity row (`Entity_7  Idle_Spin  ◉`) then property rows indented 20 pt (`Transform › Position`, `Transform › Rotation`, `Material › Emission`), `+ Add track`. Right: ruler 30 pt, 60 pt per 0.5 s, mono 10 pt labels; vertical grid lines white 7%; track lanes 2 pt lines white 15% at 24 pt spacing; keyframes 9 pt diamonds (white, selected orange); clip bar orange 35% fill + orange border; playhead 1.5 pt orange line with triangle head.

**Tasks**: existing `TasksPanelView`.

### 2.7 Inspector (320 pt, bg `#2E3039`)
- Header 34 pt: `Inspector` bold · lock 🔒 (pin selection) · `⋯`.
- **Empty state** (nothing selected): centred 44 pt dashed square, `No entity selected`, helper text `Click an entity in the viewport or Hierarchy. Drag a model from Assets to place it.`
- **Entity header**: type icon (orange stroke square) · editable name field 26 pt (semibold) · enabled dot green. Row of two 24 pt dropdowns: `Tag  Prop ▾` · `Layer  Default ▾`.
- **Component sections** (`DisclosureGroup` with `EditorDisclosureStyle`), header 30 pt semibold, trailing controls: enabled dot `◉` green + `⋯` menu (Reset / Remove / Copy / Paste). Sections separated by hairline black 35%.
  - **Transform**: `Reset` link right; rows Position / Rotation / Scale, grid `56 | 1fr ×3`, 24 pt mono fields, each with a 2×12 colored bar (X red, Y green, Z blue). Reuse `NumericInputView`.
  - **Mesh Renderer**: `Mesh  [swatch] bike.usdz ⊙` asset picker; `Cast shadows` toggle (orange).
  - **Material** `M_Bike_Green` · `Open ↗` (opens full material editor). 64 pt sphere preview; sliders Metallic / Roughness / Emission / Opacity (4 pt track, orange fill, mono value right); `Base color` swatch with hex.
  - **Rigid Body** collapsed.
- **+ Add Component** button: 30 pt, outlined orange 60%, orange semibold text; opens searchable component list.

### 2.8 Status bar (24 pt, bg `#1F2028`, 11 pt secondary)
`● Ready` (green dot) · `62 fps` · `3 draw calls` · `5 entities` · `GPU 212 MB` (mono) … right: `Last action: Move Entity_7 (0.00, 0.85, −2.40)` · `Target: macOS · Metal` · `● Autosaved 19:31` (orange).

---

## 3. Color tokens (add to `EditorScheme.swift`)

Existing tokens keep their roles. New/adjusted values from the mockup:

```swift
static let editorWindowBackground = Color(hex: 0x2A2C35)   // body
static let editorChromeBackground = Color(hex: 0x30323D)   // toolbars
static let editorViewportHeader   = Color(hex: 0x2E3039)
static let editorTabStrip         = Color(hex: 0x242630)
static let editorBarDark          = Color(hex: 0x1F2028)   // status bar
static let editorControlFill      = Color.black.opacity(0.28) // pills, fields
static let editorControlActive    = Color(hex: 0x3F414D)   // active segment
static let editorAccent           = Color(hex: 0xF39C3D)   // orange (selection / active)
static let editorAccentSoft       = Color(hex: 0xF39C3D).opacity(0.22)
static let editorTextPrimary      = Color(hex: 0xE6E7EC)
static let editorTextSecondary    = Color(hex: 0xC8CAD2)
static let editorTextTertiary     = Color(hex: 0x8A8C97)
static let editorTextDisabled     = Color(hex: 0x5F616C)
static let editorAxisX = Color(hex: 0xFF5A5A); editorAxisY = 0x5CE08C; editorAxisZ = 0x4C8DFF
static let editorNavX = Color(hex: 0xE0574F); editorNavY = 0x8BC34A; editorNavZ = 0x4F8DE0
static let editorError = 0xFF7B7B; editorWarning = 0xF5C451; editorSuccess = 0x5CE08C
static let editorModeEdit = 0xF39C3D; editorModeAnimate = 0x4F8DE0; editorModePaint = 0xB53F7A
static let editorScrim = Color(red: 20/255, green: 21/255, blue: 28/255).opacity(0.55)
```

Typography: system font (SF Pro). Body 12 pt, panel titles 12 pt semibold, toolbar labels 12–13 pt, hints 11 pt, numeric values `ui-monospace` 11 pt. Radii: pills/fields 6–7, inner buttons 4–5, cards 8, popovers 8 with shadow `0 10 30 black 50%`.

---

## 4. Behaviour & state

- `InteractionMode` enum (`object, edit, animate, paint`) in `EditorController`; published; drives header dropdown, viewport badge, tool strip visibility, gizmo visibility (hidden in edit), and auto-selects dock tab (animate → Timeline).
- `BuildTarget` enum (`macOS, iOS, iPadOS, visionOS, tvOS`); visionOS shows the volume overlay; status bar `Target:` reflects it.
- Dock tab selection persisted in `UserDefaults`; Console tab shows unread error count badge when not active.
- Hierarchy eye/lock toggles write to entity visibility / selectability flags (`SelectionManager` respects lock).
- Snap settings persisted; shown in Snap dropdown label (`Snap 0.5m`).
- Search everywhere `⌘K`; mode shortcuts `⇥1–4`; tools `Q W E R`; frame selected `F`.
- All new menu commands routed through `EditorMenuCommands` notifications, consistent with the existing native menu.

## 5. Suggested implementation order

1. Tokens + main toolbar (play cluster, undo/redo, build target, search).
2. Viewport header: mode dropdown, snap dropdown, shading/projection dropdowns.
3. Hierarchy eye/lock columns, scene tabs.
4. Inspector: entity header, Transform axis bars, Material section, Add Component.
5. Bottom dock: tab pills, grid/list assets, console filter chips, Timeline panel.
6. Viewport overlays: mode badge, nav gizmo, Edit-mode tool strip, visionOS volume.
7. Status bar.
