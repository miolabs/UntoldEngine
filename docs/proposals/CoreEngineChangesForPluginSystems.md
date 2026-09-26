# Core Engine Changes for Plugin Systems

**Status:** Proposal — no code yet
**Scope:** UntoldEngine core only. Jolt, particles, fluids and vegetation themselves live in external plugin packages; this document covers only what the core engine must provide so those plugins can exist.
**Baseline:** `develop` branch as of 2026-07-29.

---

## 1. Purpose

The *Engine Systems Implementation Plan* (physics / particles / fluids / vegetation) assumes a set of engine facilities that do not exist yet. This proposal enumerates the core-engine changes required to unblock those systems, ordered so that every change is justified by a concrete plugin need, and constrained by the project owner's direction on physics:

> Integrate Jolt as an **optional physics backend/plugin**, not a replacement. First add a **clean physics interface inside Untold Engine**, keep the **existing lightweight physics as the default backend**, and adopt Jolt **incrementally** — a small prototype first, then collision events, mesh colliders and character controllers once the foundation is stable — validated on macOS, iOS and visionOS **without breaking existing projects**.

Everything below follows from three rules:

1. **The core gains interfaces, not dependencies.** No Jolt code, no C++ shim, no xcframework enters the engine package. `Package.swift` keeps `dependencies: []`.
2. **Default behaviour is unchanged.** An app that never installs a plugin compiles and behaves exactly as today.
3. **Plugins stop reaching around the engine.** Every workaround the existing Arcade plugins had to invent (documented in §3) becomes a supported API.

---

## 2. Where the engine stands today

A short, factual inventory — the gaps here drive the change list.

### 2.1 Physics
`Systems/PhysicsSystem.swift` is a set of free functions: per-entity force/moment accumulators (`KineticComponent`), RK4 integration over `PhysicsComponents`, hard-coded gravity `(0, -9.8, 0)`, writes directly into `LocalTransformComponent`. It runs inside a fixed-timestep accumulator loop in `UntoldRenderer.runFrame` (`Renderer/UntoldEngine.swift:604`, `fixedStep = 1/60`, clamped to 5 substeps), game mode only.

**There is no collision detection of any kind** — no collider component, no broadphase, no contacts, no triggers, no constraints, no physics raycast, no sleeping, no character controller. `USCBuilder.onCollision(tag:)` exists in the scripting layer but nothing ever fires it. There is no interpolation of render transforms between fixed steps.

### 2.2 Plugin API
The render-extension system (`Renderer/RenderExtensions.swift`, `RenderExtensionPlugins.swift`) is genuinely self-contained for rendering: shader library / render / compute pipeline / resource / argument-buffer registries, per-frame `buildGraph`, staged passes, ownership validation with atomic install/rollback. CoolWater, CoolCloth and CoolSaber all live on it.

But it is **render-only**. There is:

- no per-frame CPU update hook on `RenderExtension` — no `update(dt:)`, and `RenderPassContext` carries neither delta-time nor a frame index;
- no fixed-step (simulation) hook for plugins — `registerCustomSystem` (`ECS/Scenes.swift:351`) runs inside the physics loop but is game-mode-only, has no ordering control and no unregister;
- no teardown callback on `RenderExtension`;
- no "once per frame" guarantee — in XR, `buildGraph` and passes run per eye, and every plugin must hand-write `guard context.currentEye == 0` dedup;
- no way for plugin passes to declare dependencies on named passes (the `dependencies:` overload of `addPass` is `internal`);
- a closed `RenderStage` enum whose earliest stage is `afterOpaqueLighting` — nothing before shadows/G-buffer, no pre-simulation stage.

### 2.3 Frame loop & threading
Single-threaded frame loop; no job system, no task graph, no frame/temp allocator. The render graph is rebuilt, topologically sorted and resource-planned **every frame** (twice per frame in stereo XR) with no caching.

### 2.4 GPU-driven rendering
No `MTLIndirectCommandBuffer` usage anywhere. GPU frustum/HZB culling exists (`Systems/CullingSystem.swift`) but the compacted visible list is read back and draws are CPU-encoded. This blocks the particles and vegetation designs (both are built on indirect draws).

### 2.5 ECS
`ComponentMask` is a single `UInt64` (`MAX_COMPONENTS = 64`, `Utils/Globals.swift:25`) with ~35 component types already registered, and component IDs are assigned lazily in encounter order (not stable across runs). Per-component destruction cleanup handlers exist (`ECS/ComponentRegistry.swift`) — that part is already plugin-friendly — but there is no entity-creation event and octree deregistration is hard-coded in `Scene.destroyEntityFinalize`.

### 2.6 Spatial queries
`pickEntity` (CPU octree + GPU acceleration-structure narrow phase), `OctreeSystem` AABB queries, and analytic plane picking exist. Plugin-owned geometry is invisible to all of them — CoolCloth had to build its own brute-force picking store.

### 2.7 What existing plugins had to invent
Measured across CoolWater / CoolCloth / CoolSaber, each plugin reimplements: (a) an `NSLock`-guarded singleton to smuggle per-frame simulation state from the app's `gameUpdate` closure into encode closures; (b) per-eye deduplication; (c) its own picking; (d) lazy first-use geometry initialization detected on the render thread; (e) its own occlusion handling; (f) its own metallib platform-selection boilerplate. Every one of these is a core-engine gap.

---

## 3. Proposed changes

Changes are grouped C1–C8. Each states which plugin system needs it and the compatibility impact. API sketches are illustrative surface design, not final signatures.

---

### C1. Physics provider interface (the centerpiece)

**Needed by:** Jolt plugin (all stages), particles (collision promotion, 2.7), vegetation (static trunk colliders, 4.9), fluids (obstacle SDF coupling, 3B.3).
**Compatibility:** none — the default backend reproduces today's behaviour exactly.

#### C1.1 `PhysicsBackend` protocol

A new core protocol that owns the simulation step. The engine talks to *a* physics backend; which one is a registration decision.

```swift
public protocol PhysicsBackend: AnyObject {
    var id: String { get }
    var capabilities: PhysicsCapabilities { get }   // OptionSet: collisions, triggers,
                                                    // constraints, characterController,
                                                    // meshColliders, raycast, …

    func configure(_ config: PhysicsWorldConfiguration) // gravity, layer matrix, units
    func step(deltaTime: Float)                         // called per fixed substep
    func drainEvents(into sink: PhysicsEventSink)       // after step, sim thread

    // Body sync — bulk, never per-entity FFI
    func syncBodiesFromECS(_ batch: PhysicsBodyWriteBatch)   // kinematic targets, new/removed bodies
    func readTransforms(into buffer: PhysicsTransformReadBatch) // (position, orientation) contiguous

    // Queries (capability-gated)
    func raycast(_ ray: PhysicsRay, filter: PhysicsQueryFilter) -> PhysicsRayHit?
    func shapecast(_ cast: PhysicsShapeCast, filter: PhysicsQueryFilter) -> [PhysicsShapeHit]
    func overlap(_ volume: PhysicsOverlapVolume, filter: PhysicsQueryFilter) -> [EntityID]
}
```

Registration mirrors the render-extension pattern (single active backend, install-before-`UntoldRenderer.create`, atomic with rollback):

```swift
PhysicsBackendRegistry.shared.install(JoltPhysicsBackendPlugin())  // or nothing → default
```

Design points carried over from the implementation plan, because they belong in the *interface contract*, not in the Jolt plugin:

- **Bulk transform transfer.** `readTransforms` fills one contiguous caller-supplied buffer (`UnsafeMutableBufferPointer` semantics). The contract forbids per-body calls per frame — this keeps the FFI cost flat regardless of backend.
- **Buffered events.** `drainEvents` is defined to run *after* `step()` returns, on the simulation thread. Backends that fire callbacks from worker threads (Jolt does, during `Update()`) must buffer internally into fixed-capacity arrays with an overflow counter. The engine never receives a callback mid-step.
- **Units and conventions** are fixed in `PhysicsWorldConfiguration`: metres/kg/seconds, Y-up, quaternion orientation — matching both the current system and Jolt's defaults.
- **Capabilities, not lowest common denominator.** The default backend reports `[]` (integration only). API calls gated on an absent capability are defined no-ops that log once — so gameplay code can be written against the full interface and degrade gracefully.

#### C1.2 New authoring components

Current `PhysicsComponents` / `KineticComponent` stay untouched (they are the default backend's state). New, backend-agnostic authoring components describe *intent*:

- **`ColliderComponent`** — shape descriptor: `.sphere(r)`, `.box(halfExtents)`, `.capsule(r, h)`, `.cylinder`, `.convexHull(meshRef)`, `.triangleMesh(meshRef | cookedBlobRef)`, `.heightfield(ref)`, `.compound([...])`; plus local offset, friction, restitution, `isTrigger`.
- **`RigidBodyComponent`** — motion type (`static` / `kinematic` / `dynamic`), mass (or density), collision **layer** and **mask** (engine-level `UInt32` layer bits; the backend maps them — 32 bits per the plan's "early decisions"), gravity scale, initial velocities, sleep policy.
- **`CharacterControllerComponent`** — stage 4 (see §4); capsule dims, step height, slope limit, up vector.

These are data-only and meaningful to any backend. An entity with only the legacy `PhysicsComponents`/`KineticComponent` pair behaves exactly as today under any backend (the Jolt backend would represent it as a gravity-affected body with no collider, or simply leave it to the default integrator — decision D3, §7).

The existing per-component cleanup mechanism (`ComponentRegistry.register(componentType:handlerId:priority:cleanup:)`) is already sufficient for backends to destroy native bodies on entity destruction — **no core change needed there**; the proposal just documents it as the supported path.

#### C1.3 Transform authority and interpolation

Today `updatePhysicsSystem` writes `LocalTransformComponent` directly mid-substep. That model can't support interpolation or a backend running off-thread later. Proposed split:

1. Backend simulates at fixed `dt`; engine keeps the **previous and current** fixed-step transform per dynamic body (a small ring, not per-component storage).
2. At render time the engine writes `lerp/slerp(prev, curr, accumulator/fixedStep)` into `LocalTransformComponent` and marks it dirty (feeding `OctreeSystem.markDirty` as today).
3. Kinematic bodies flow the other way: game code writes the transform; the engine batches those into `syncBodiesFromECS` before the step.
4. `SceneRootTransform` (world shift) is applied at the sync boundary in both directions, the same way `ScenePickingSystem` already inverse-transforms rays.

Interpolation is **opt-in per world config** (`interpolateRenderTransforms: Bool`, default `false`) so the default path is bit-identical to today until a project turns it on.

#### C1.4 Event model

New engine-level event types delivered through a physics event sink after each step: `contactBegan / contactPersisted / contactEnded (entityA, entityB, point, normal, impulse)`, `triggerEntered / triggerExited`, `bodyActivated / bodyDeactivated`. Delivery:

- a Swift subscription API in the style of the existing `FrameEvents` (`UntoldRenderer.onUpdate`), e.g. `PhysicsEvents.onContact(entity:) -> EventSubscription`;
- **`USCSystem` finally gets its `OnCollision` wired**: the engine forwards `contactBegan` into the already-built (but never-fired) `USCBuilder.onCollision(tag:)` path. This is the first user-visible payoff of the whole effort and costs the core almost nothing.

Fixed-capacity per-frame event buffers with an overflow counter surfaced in the profiler — never allocate mid-step.

#### C1.5 Unified spatial queries

A thin engine facade, `PhysicsQuery`, routes to the active backend when it reports the `raycast` capability, else falls back to `OctreeSystem` AABB queries (best-effort, documented as approximate). Longer term this lets `ScenePickingSystem` offer a `physicsPreferred` backend option, but **picking integration is explicitly out of scope for stage 1**.

#### C1.6 Default backend

`Systems/PhysicsSystem.swift`'s free functions get wrapped (not rewritten) as `UntoldDefaultPhysicsBackend: PhysicsBackend`. `runFrame`'s fixed-step loop calls `backend.step(fixedStep)` instead of `updatePhysicsSystem(fixedStep)`. All existing public API (`applyForce`, `setVelocity`, …) keeps working — the functions become forwarding calls that also remain valid against the legacy components. One hard-coded constant becomes configurable in passing: gravity moves into `PhysicsWorldConfiguration` (default `(0, -9.8, 0)` — behaviour unchanged).

This refactor is **the** stage-0 deliverable: zero behaviour change, proven by the existing demos and a before/after replay test.

#### C1.7 What stays out of core

The Jolt plugin package (working name `UntoldJoltPhysics`) owns: the vendored Jolt source + build script + `Jolt.xcframework`, the `extern "C"` shim (`CJoltBridge`, opaque handles, no exceptions across the boundary, POD-only header), layer-matrix upload as a data blob, `JobSystemThreadPool` (Jolt's own, per the plan — the engine job system does not block this), cooked-shape loading, and the `PhysicsBackend` conformance. The engine never links C++.

---

### C2. Engine plugin lifecycle — update hooks, teardown, frame identity

**Needed by:** every plugin. This is the single most-reinvented workaround in the existing Arcade plugins.
**Compatibility:** additive; all new protocol requirements get default no-op implementations, so existing plugins compile unchanged (API version stays 1 — note the registry's version check is exact-equality, `RenderExtensionPlugins.swift:202`, so *not* bumping it is load-bearing).

Additions to `RenderExtension` (all defaulted):

```swift
public protocol RenderExtension: AnyObject, Sendable {
    // existing requirements …

    /// Once per frame, before graph build, regardless of eye count. Variable dt.
    func update(deltaTime: Float, context: RenderExtensionUpdateContext)

    /// Inside the fixed-step simulation loop (game mode), after physics. Fixed dt.
    func fixedUpdate(deltaTime: Float, context: RenderExtensionUpdateContext)

    /// Resources registered via registerResources are now allocated / were recreated (resize).
    func resourcesDidLoad(_ access: RenderResourceAccess)

    /// About to be unregistered (explicit uninstall, or mid-frame validation rejection).
    func willUnregister()
}
```

And to `RenderPassContext` (`Systems/GraphBuilder.swift:216`): `deltaTime: Float`, `frameIndex: UInt64`, and `isPrimaryEye: Bool` (true exactly once per frame) — killing the hand-written `currentEye == 0` boilerplate and the `NSLock` singleton pattern in one move.

Two smaller items in the same area:

- **`registerCustomSystem` gets a handle-based unregister** and a documented ordering position, or is deprecated in favour of `fixedUpdate` above.
- **A metallib platform-selection helper** in `UntoldEngineShaderSupport` (the `#if os(...)` + resource-name dance every plugin currently copies from CoolWater).

---

### C3. Render graph — caching, stages, dependencies, GPU-driven draws

**Needed by:** particles (2.2 indirect args kernel, 2.4 sorting), vegetation (4.3 GPU culling → indirect draws), fluids 3A (volumetric pass placement), and frame-rate health for all of them.
**Compatibility:** additive; existing stage semantics preserved.

1. **Graph caching.** `buildGraph` + topo sort + hazard scheduling + resource planning currently run every frame (twice in XR). Introduce a structural hash / dirty flag: rebuild only when the extension set, pass set, resource declarations or viewport change. Pass *closures* re-execute every frame; the *graph* doesn't recompile. This is a pure-internal change with a large payoff once particle/vegetation plugins add 5–10 passes each.
2. **New stages.** Extend the `RenderStage` enum (closed enum stays closed — plugins still can't invent stages, which preserves ordering guarantees) with at minimum: `.frameStart` (compute-only, before shadows/G-buffer — particle spawn/update, vegetation culling, fluid advection all live here) and `.beforeShadows` (vegetation depth into cascades). Stage list order remains the single source of execution order.
3. **Named-pass dependencies for plugins.** Promote the `internal` `addPass(id:dependencies:...)` overload to public, restricted to same-owner passes plus a curated set of exported engine pass IDs (depth prepass, HZB build, scene color resolve). Cross-plugin dependencies stay disallowed (ownership validation already enforces this).
4. **Indirect command buffer support.** Add `MTLIndirectCommandBuffer` as a first-class extension resource type (`RenderExtensionBufferDescriptor` sibling), plus `dispatchThreadgroups(indirectBuffer:)` conveniences and ICB usage declarations in `RenderGraphResourceUsage` so hazard scheduling sees them. The plan's particles design (spawn → update → indirect-args, zero readback) is unimplementable without this.
5. **Depth/HZB participation (later, M5-adjacent).** An opt-in way for a plugin pass to contribute depth to the prepass/HZB so plugin geometry can occlude and be occluded — replacing CoolWater's private occlusion pass. Design sketch only for now; not required for the physics stages.

---

### C4. ECS capacity and lifecycle

**Needed by:** all four systems together will add an estimated 10–15 component types to a mask that has 64 slots with ~35 taken.
**Compatibility:** memory-layout change, no API change.

1. **Widen `ComponentMask`** from `UInt64` to a fixed 2×`UInt64` (128 components). Touches `ECS/Entity.swift`, `ComponentPool`, and every mask intersection in `queryEntities` — mechanical but must land *before* plugins start claiming slots.
2. **Stable component IDs (diagnostic).** IDs stay lazily assigned, but add a debug-mode registry dump so plugin authors can detect ID-order-dependent bugs. Full stability across runs is out of scope.
3. **Entity lifecycle observation.** Keep the existing per-component cleanup registry as the destruction path (it works). Add a lightweight `onEntityCreated` / `onEntityDestroyed` broadcast on the `FrameEvents` bus for systems that need entity-level (not component-level) bookkeeping — the Jolt backend's body table being the first consumer. Also: un-hard-code `OctreeSystem.shared.unregisterEntity` in `Scene.destroyEntityFinalize` by moving it onto the same mechanism.

---

### C5. Fixed-timestep loop adjustments

**Needed by:** physics interpolation (C1.3), consistent plugin simulation.
**Compatibility:** two bug-level fixes flagged, both opt-in or behaviour-neutral.

1. Expose the accumulator remainder (`physicsAccumulator / fixedStep`) to the render side for transform interpolation.
2. `StreamingRegionManager.update` and `LODSystem.update` are currently fed the constant `fixedStep` instead of real delta time (`Renderer/UntoldEngine.swift`) — they run on a fake 60 Hz clock. Fix to pass measured dt (flagged as a separate, tiny PR since it's a latent bug, not a feature).
3. Document the threading contract in one place: the frame loop is single-threaded but *which* thread differs (main on macOS/iOS, compositor render thread in XR — this is why the `@MainActor` assertions became lock-based no-ops in `ECS/Scenes.swift:15`). The `PhysicsBackend` contract simply says "step and drain are called from the frame thread; backends may parallelize internally" — which is exactly Jolt's model with its own thread pool, and defers an engine job system (see C7).

---

### C6. Asset format extensions

**Needed by:** cooked physics shapes (1.6), particle effect descriptors (2.8), NanoVDB bricks / flipbook atlases (3A), vegetation instance cells and impostors (4.2/4.5).
**Compatibility:** additive chunk types; file version stays 1.

1. **Plugin chunk namespace in `.untold`.** Reserve a `UntoldChunkType` range (e.g. ≥ 0x8000) for extension-owned chunks, identified by a `(pluginID, chunkKind, chunkVersion)` header inside the chunk payload. The container format (`AssetFormat/UntoldFormat.swift`) gains no new semantics — unknown chunks are already skippable by design; this just formalizes it.
2. **Cooked-blob convention.** Cooked physics shapes (`Shape::SaveBinaryState` output) are stored as plugin chunks or sidecar files keyed by `(backendID, backendVersion)` — Jolt cooked data is not forward-compatible across Jolt versions, so the key is part of the format, and the baker invalidates on mismatch.
3. **`untoldengine` CLI plugin hooks.** A `bake-ext` subcommand (or a plugin-discovery mechanism in the existing `assets`/`export` flow) that shells out to plugin-provided bakers, so shape cooking / impostor baking / atlas packing don't fork the CLI. Design detail deferred; the reserved chunk range is the only stage-1 requirement.

---

### C7. Job scheduler and temp allocator — deliberately deferred

**Needed by:** eventually everything; blocking nothing now.

Per the implementation plan's own guidance ("ship first with Jolt's `JobSystemThreadPool`, swap later — don't block the physics spike"), the engine job system (work-stealing pool, dependencies, `n-1` workers) and frame allocator are **not** prerequisites for stages 0–4. They enter the roadmap when particles/vegetation baking or multi-system CPU work demands them (M3+). The only stage-1 commitment is that the `PhysicsBackend` contract doesn't preclude it (it doesn't — step/drain threading is already specified in C5.3).

---

### C8. Native dependency and licensing policy

**Needed by:** the Jolt plugin (first), NanoVDB later.
**Compatibility:** none — policy and documentation, mostly in the plugin repos.

Since backends live outside the engine package, the xcframework machinery (vendored source, `Scripts/build-native.sh`, per-platform slices, `lipo`, SPM `binaryTarget`) lives in the plugin repo, following the plan's Phase 0.1 checklist. The **core engine's** obligations are only:

1. Document the blessed pattern (`docs/Extensions/`): `CFoo` C shim target → Swift wrapper → `PhysicsBackend` conformance; the "no exceptions across the boundary, POD-only headers, opaque handles" rules; and the metallib-style per-platform selection helper (C2).
2. `CONTRIBUTING.md` license policy for anything that might ever be upstreamed: MIT / BSD / Zlib / Apache-2.0 only; no LGPL (static-link + App Store is unsatisfiable), no GPL/AGPL. Plus `THIRD_PARTY_LICENSES.md` conventions for plugin repos.
3. Verify (once, in the prototype) that a plugin with a `binaryTarget` works when the engine is consumed both via SPM and as a framework — transitive-framework embedding is the known trap.

---

## 4. Staged rollout

Stages map to the owner's "prototype first, then collision events, mesh colliders, character controllers" sequencing. Each stage is independently shippable and gate-checked.

| Stage | Core-engine work | Plugin work (outside core) | Gate |
|---|---|---|---|
| **0 — Interface** | C1.1, C1.2, C1.6 (default backend wrap), C2 (update hooks, pass-context dt/frame/eye), C4.1 (mask widening) | — | All demos + tests behave identically with `UntoldDefaultPhysicsBackend`; existing Arcade plugins compile unchanged |
| **1 — Prototype** | C1.3 (transform sync path, interpolation off by default), C8 docs | Jolt build spike: xcframework, C shim, sphere-on-plane from Swift; dynamic + static bodies, sphere/box/capsule | Sphere falls on device (macOS first, then iOS/visionOS); binary size measured |
| **2 — Events & queries** | C1.4 (event sink, USC `OnCollision` wiring), C1.5 (query facade), C5.1 (interpolation on) | Contact buffering in shim, triggers, layers, raycast/shapecast/overlap | Trigger + contact demos; 10k-body stress; determinism replay green |
| **3 — Mesh colliders & cooking** | C6.1/C6.2 (plugin chunks, cooked-blob convention), C6.3 sketch | Convex hull / triangle mesh / heightfield; offline cooking in the plugin baker | Large mesh collider loads with no cook stall; cooked-version invalidation proven |
| **4 — Character controller** | C1.2 `CharacterControllerComponent` finalized | `CharacterVirtual` binding (not `Character`): ground detect, steps, slopes, moving platforms | Playable character demo on all three platforms |
| **5 — GPU systems enablers** | C3 (graph caching, `.frameStart`/`.beforeShadows` stages, public named dependencies, ICB), C4.3, C7 begins | Particles plugin starts (spawn/update/indirect-args) | GPU-driven sparks with zero CPU readback |

Deferred exactly as the plan says: soft bodies, vehicles, ragdolls, cloth-via-Jolt (CoolCloth's XPBD stays as-is), live fluid solvers.

---

## 5. Delivery plan — PR breakdown

The change groups were designed to be independent, so most of the work can proceed as parallel PRs. The split below is by *reviewable unit*, not one PR per change group: some groups are too large for a single PR (C1), others too small to stand alone (C5.1 folds into interpolation). Each PR gets its own `feature/<name>` branch.

### Land first, alone

Everything else rebases on these two, so they go in before any track starts.

| PR | Content | Branch (suggested) | Rationale |
|---|---|---|---|
| **PR 1** | C4.1 — widen `ComponentMask` 64 → 128 | `feature/ecs_component_mask_128` | Mechanical but touches `Entity.swift`, `ComponentPool` and every query intersection — the worst PR to rebase late, the easiest to review early. Zero behaviour change. |
| **PR 2** | C5.2 — streaming/LOD fed constant `fixedStep` instead of real dt | `feature/streaming_lod_real_dt` | Latent bug fix, standalone and tiny. Kept separate from all feature work. |

### Parallel tracks

Tracks are independent of each other and can be worked simultaneously. **Within** a track PRs are stacked (serial), because they touch the same files — parallelizing inside a track just trades PR count for rebase pain.

| Track | PRs (in order) | Depends on | Contention file(s) |
|---|---|---|---|
| **Physics** | PR 3: `PhysicsBackend` protocol + `ColliderComponent`/`RigidBodyComponent` (C1.1, C1.2) → PR 4: default backend wrap + `runFrame` loop swap (C1.6) → PR 5: event sink + USC `OnCollision` wiring (C1.4) → PR 6: transform sync + interpolation (C1.3 + C5.1) | PR 1 | `Renderer/UntoldEngine.swift` (`runFrame`) |
| **Plugin API** | PR 7: `RenderExtension` update/teardown hooks + dt/frameIndex/isPrimaryEye in `RenderPassContext` (C2) | — | `runFrame` (small), `GraphBuilder.swift` (context struct) |
| **Render graph** | PR 8: graph caching (C3.1) → PR 9: new stages + public named-pass dependencies (C3.2, C3.3) → PR 10: ICB resource support (C3.4) | — | `GraphBuilder.swift`, `RenderExtensions.swift` |
| **Assets / docs** | PR 11: plugin chunk namespace + cooked-blob convention (C6.1, C6.2) · PR 12: native-dependency pattern + license policy docs (C8) | — | none (additive) |

C1.5 (query facade) rides with PR 5 or lands as a small follow-up; C4.3 (entity lifecycle broadcast) and C6.3 (CLI bake hooks) are stage-5-adjacent follow-ups with no slot in this first wave. C7 has no PR by design.

### Merge-order notes

- `runFrame` is touched by PRs 4, 6 and 7; `GraphBuilder.swift` by PRs 7–10. Whichever track merges second rebases — cheap if the tracks stay in flight for days, painful if for weeks. Suggested tie-break: merge PR 7 early (it is small and every other plugin consumer wants it), let the physics and graph tracks rebase over it.
- The stage-0 "zero behaviour change" guarantee is verified **per PR** against the existing demos and tests, not once at the end — this split strengthens the gate: PR 4 (backend wrap) is the only PR where a regression could realistically hide, and it is isolated precisely for that reason.
- **Do not start the Jolt plugin repo until PRs 3, 4 and 7 are merged.** The prototype needs the protocol, the loop seam and the update hooks; building it against three moving branches churns for no benefit. PRs 5–6 can land while the Jolt build spike is already underway.

---

## 6. Compatibility guarantees

- **No behaviour change without opt-in.** Default backend reproduces current integration bit-for-bit (stage-0 gate). Interpolation, Jolt, new stages — all opt-in.
- **Render-extension API version stays 1.** All protocol additions carry default implementations; the registry's exact-equality version check makes this mandatory, not just polite.
- **Existing public physics API preserved.** `applyForce`, `setVelocity`, etc. keep working against the legacy components under any backend.
- **`Package.swift` keeps zero dependencies.** Jolt and its toolchain never enter the engine package.
- **Existing Arcade plugins** (CoolWater / CoolCloth / CoolSaber) compile and run unchanged at every stage; stages 0–2 progressively let them *delete* workaround code (singletons, eye guards) at their own pace.

---

## 7. Decisions to lock before stage 1 (owner input wanted)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Double-precision physics (`JPH_DOUBLE_PRECISION`) | Off — no >10 km worlds planned; hard to change later, so decide explicitly |
| D2 | Cross-platform determinism flag | Off for the prototype; revisit if replay/lockstep netcode appears (costs ~5–10%) |
| D3 | Legacy `PhysicsComponents`-only entities under the Jolt backend | Recommend: stay on the default integrator (Jolt only owns entities with `RigidBodyComponent`) — cleanest incremental story, allows both to coexist in one scene |
| D4 | Collision layer width | 32 bits (plan's own recommendation for many groups) |
| D5 | Where the Jolt plugin repo lives | Sibling of the Arcade plugins vs. `untoldengine` org — affects C8 docs only |
| D6 | Interpolation default once proven | Proposal: default off through stage 2, flip to on in stage 3 release notes |

---

## Appendix A — Change ↔ system dependency matrix

| Core change | Jolt physics | Particles | Fluids 3A | Vegetation |
|---|---|---|---|---|
| C1 physics interface | **required** | 2.7 collision promotion | 3B.3 obstacle SDF (deferred) | 4.9 trunk colliders |
| C2 update hooks / frame identity | required (sync points) | **required** | required | required |
| C3.1 graph caching | — | strongly wanted | wanted | strongly wanted |
| C3.2 new stages | — | **required** (`.frameStart`) | required (volumetric placement) | **required** (culling, shadows) |
| C3.4 ICB support | — | **required** | — | **required** |
| C4.1 component mask 128 | required (3 new components) | required | required | required |
| C5 timestep/interpolation | **required** | — | — | — |
| C6 asset chunks | stage 3 (cooked shapes) | 2.8 descriptors | 3A bricks/atlases | 4.2/4.5 impostors, cells |
| C7 job system | no (Jolt brings its own) | later | later | later |
| C8 native-dep pattern | **required** | — | NanoVDB later | — |
