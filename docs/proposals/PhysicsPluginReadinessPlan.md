# Physics Plugin Readiness — Phase 1 Implementation Plan

**Status:** Draft for review — no code yet
**Supersedes for phase 1:** narrows *Core Engine Changes for Plugin Systems* (discussion #1116) per the maintainer's scope decision
**Baseline:** `develop` branch as of 2026-07-30

---

## 1. Scope decision

From the maintainer's review of the full proposal:

> I'm open to approving this direction, but I want to narrow the initial scope. For now, I'd like us to focus on making the engine plugin-ready specifically for the Physics System and the future Jolt plugin. […] I'd like to hold off on the broader render graph and ECS changes for now.

Phase 1 therefore commits to exactly five constraints:

1. Existing projects keep compiling and behaving the same.
2. The current physics system stays the default.
3. Only the plugin-facing seams needed for an optional Jolt backend are added.
4. No Jolt, native binaries, or C++ enters the core engine package (`Package.swift` keeps `dependencies: []`).
5. Render-graph (C3) and ECS (C4) changes are **out of scope** — separate review path owned by the maintainer.

### In / out at a glance (numbering from the full proposal)

| In phase 1 | Deferred |
|---|---|
| C1.1 `PhysicsBackend` protocol + registry | C2 render-extension lifecycle hooks (not needed for the Jolt prototype — see §3.7) |
| C1.2 `ColliderComponent`, `RigidBodyComponent` (2 components; fits the existing 64-slot mask, ~29 free) | C3 render graph: caching, stages, ICBs, named deps |
| C1.4 buffered contact/trigger events + USC `OnCollision` wiring | C4 ECS: mask widening, lifecycle broadcasts, octree decoupling |
| C1.5 raycast facade (minimum query surface) | C1.3 render interpolation (opt-in, phase 2 — the seam is laid, the feature isn't shipped) |
| C1.6 default backend wrap, zero behaviour change | `CharacterControllerComponent`, mesh colliders/cooking (C6), job system (C7) |
| C8 docs: backend-author guide, license policy note | C5.2 streaming/LOD real-dt fix (unrelated latent bug — offered as its own tiny PR, maintainer's call) |

---

## 2. Design summary

The full rationale lives in the original proposal; this section restates only what phase 1 builds, with the narrowing decisions called out.

### 2.1 `PhysicsBackend` protocol

```swift
public protocol PhysicsBackend: AnyObject {
    var id: String { get }
    var capabilities: PhysicsCapabilities { get }        // .collisions, .triggers, .raycast, …

    func configure(_ config: PhysicsWorldConfiguration)  // gravity, layer matrix, m/kg/s units
    func didAddBody(entity: EntityID, descriptor: PhysicsBodyDescriptor)
    func didRemoveBody(entity: EntityID)
    func step(deltaTime: Float)                           // per fixed substep, frame thread
    func drainEvents(into sink: PhysicsEventSink)         // after step, frame thread
    func writeKinematicTargets(_ batch: PhysicsBodyWriteBatch)
    func readTransforms(into batch: PhysicsTransformReadBatch)  // bulk, contiguous — never per-body calls
    func raycast(_ ray: PhysicsRay, filter: PhysicsQueryFilter) -> PhysicsRayHit?
}
```

Contract points (unchanged from the full proposal, they define the ABI-ish boundary the Jolt shim is built against):

- **Threading:** `step` and `drainEvents` are called on the frame thread; backends may parallelize internally (Jolt brings its own `JobSystemThreadPool`). Callbacks from backend worker threads never reach the engine — backends buffer internally into fixed-capacity arrays with an overflow counter.
- **Bulk transfer:** transform read-back and kinematic writes are batch-only, one contiguous buffer per direction per step.
- **Units:** metres/kg/seconds, Y-up, quaternion orientation — matches both the current system and Jolt defaults.
- **Capabilities:** calls gated on an absent capability are defined no-ops that log once.

### 2.2 Registration

`PhysicsBackendRegistry.shared.install(_:)` / `uninstall(id:)`, mirroring `RenderExtensionPluginRegistry` semantics: install before `UntoldRenderer.create(...)`, atomic with rollback, single active external backend. Installing nothing means today's behaviour, exactly.

### 2.3 Coexistence rule (was decision D3 — now fixed)

**The built-in integrator always runs for legacy entities.** An installed external backend owns *only* entities carrying the new `RigidBodyComponent`; entities with the legacy `PhysicsComponents`/`KineticComponent` pair keep using the built-in RK4 path regardless of what is installed. Both can coexist in one scene. This is the cleanest no-breakage story and removes the "what happens to old content under Jolt" question entirely.

Concretely, the fixed-step loop in `runFrame` (`Renderer/UntoldEngine.swift:604`) changes from calling `updatePhysicsSystem(fixedStep)` to calling a small internal `PhysicsCoordinator.step(fixedStep)` that:

1. runs the built-in integrator over legacy entities (same code path as today);
2. if an external backend is installed: flushes body add/remove diffs, writes kinematic targets, calls `backend.step`, reads transforms back into `LocalTransformComponent` (marking dirty, feeding the octree as today), and drains events.

### 2.4 New components — no ECS changes needed

- **`ColliderComponent`** — shape (`.sphere/.box/.capsule/.cylinder/.convexHull(meshRef)` — triangle mesh/heightfield deferred with cooking), local offset, friction, restitution, `isTrigger`.
- **`RigidBodyComponent`** — motion type (static/kinematic/dynamic), mass or density, 32-bit layer + mask, gravity scale, initial velocities.

Two new component types fit comfortably in the existing 64-slot mask (~29 free), so **C4 stays untouched**. Body lifecycle without ECS event changes:

- **Creation:** the coordinator diffs the `RigidBodyComponent` query result against the backend's known-body set once per step (cheap at prototype scale; flagged for optimization *later, on the C4 review path*, not now).
- **Destruction:** the existing `ComponentRegistry.register(componentType:handlerId:priority:cleanup:)` mechanism — already the engine's supported per-component teardown — notifies the coordinator, which calls `didRemoveBody`. Zero core change.

### 2.5 Events

`PhysicsEventSink` receives `contactBegan/Persisted/Ended`, `triggerEntered/Exited`, `bodyActivated/Deactivated` during `drainEvents`, post-step, frame thread. Delivery to users:

- subscription API in the existing `FrameEvents` style (`PhysicsEvents.onContact(...) -> EventSubscription`);
- `USCSystem` gets its never-fired `OnCollision` wired to `contactBegan` — first user-visible payoff, near-zero cost.

Fixed-capacity per-frame buffers; overflow surfaced as a counter, never an allocation mid-step. The default backend reports no collision capability, so this path is dormant until an external backend is installed.

### 2.6 Queries — raycast only

Phase 1 ships a single facade: `PhysicsQuery.raycast(_:filter:)`, routed to the active backend when it reports `.raycast`, else a documented best-effort fallback via the existing `OctreeSystem` ray query. Shapecast/overlap are protocol-sketched but not exposed until phase 2. No changes to `ScenePickingSystem`.

### 2.7 Why no render-extension hook changes (C2) are needed

The Jolt prototype never renders. Collider debug visualization, when it comes, can use the *existing* render-extension API exactly as CoolWater does today (a debug line pass doesn't need the missing dt-in-context; it reads coordinator state). So phase 1 touches nothing in `RenderExtensions.swift` / `GraphBuilder.swift`, keeping the whole surface the maintainer wants to review personally out of the diff.

---

## 3. Engine touch list

The point of this section is to show how small the core diff is.

**New files** (new `Sources/UntoldEngine/Physics/` directory):

| File | Contents |
|---|---|
| `PhysicsBackend.swift` | protocol, `PhysicsCapabilities`, `PhysicsWorldConfiguration`, descriptor/batch/event/query value types |
| `PhysicsBackendRegistry.swift` | install/uninstall, validation, rollback |
| `PhysicsCoordinator.swift` | body-set diffing, step orchestration, transform sync, event dispatch |
| `UntoldDefaultPhysicsBackend.swift` | wraps the existing free functions; reports `capabilities = []` |

**Edited files:**

| File | Change |
|---|---|
| `ECS/Components.swift` | add `ColliderComponent`, `RigidBodyComponent` |
| `Systems/RegistrationSystem.swift` | cleanup-handler registrations for the two new components (same pattern as the existing 30 handlers) |
| `Renderer/UntoldEngine.swift` | fixed-step loop calls `PhysicsCoordinator.step` instead of `updatePhysicsSystem` (~5 lines) |
| `Systems/PhysicsSystem.swift` | no behavioural edits; gravity constant reads from `PhysicsWorldConfiguration` (default `(0,-9.8,0)`); public API (`applyForce`, …) unchanged |
| `Scripting/USCSystem` path | fire `OnCollision` from the event sink |
| `docs/Extensions/` | "Creating a Physics Backend Plugin" guide + license-policy note (MIT/BSD/Zlib/Apache-2.0; no LGPL/GPL) |

Not touched: `RenderExtensions.swift`, `RenderExtensionPlugins.swift`, `GraphBuilder.swift`, `Entity.swift`, `ComponentPool.swift`, `Scenes.swift`, asset formats, `Package.swift` dependencies.

---

## 4. PR plan

Four small PRs, strictly stacked (they build on each other), each individually gated on "existing demos and tests behave identically".

| PR | Branch | Contents | Gate |
|---|---|---|---|
| **A** | `feature/physics_backend_interface` | Protocol + value types + registry + the two components. Nothing calls any of it yet. | Compiles everywhere; registry unit tests (install/rollback/double-install); zero runtime change by construction |
| **B** | `feature/physics_backend_default` | `PhysicsCoordinator` + default backend wrap + `runFrame` seam + configurable gravity | Before/after replay test: recorded scene produces bit-identical transforms vs. current `updatePhysicsSystem`; all demos unchanged |
| **C** | `feature/physics_events` | Event sink, buffers, `PhysicsEvents` subscriptions, USC `OnCollision` wiring | Dormant with no external backend (proven by test using a mock backend); mock-backend contact test fires USC event |
| **D** | `feature/physics_raycast_facade` | `PhysicsQuery.raycast` + octree fallback | Fallback parity test vs. direct octree query; mock-backend routing test |

A **mock backend** (test target only) stands in for Jolt throughout — it lets every seam be exercised in CI without any native dependency, and it doubles as the reference implementation for the backend-author guide.

The Jolt plugin repo work (xcframework build spike, C shim, sphere-on-plane) can start **as soon as PR A merges** — it only needs the protocol to compile against; PRs B–D land while the build spike proceeds in parallel.

---

## 5. Acceptance criteria for phase 1 as a whole

1. An app that installs nothing: identical behaviour, verified by the replay test and demo suite (macOS, iOS, visionOS).
2. Existing Arcade plugins (CoolWater/CoolCloth/CoolSaber) compile and run unchanged.
3. The mock backend demonstrates: body add/remove lifecycle, kinematic write + transform read-back, contact/trigger events reaching both `PhysicsEvents` subscribers and a USC `onCollision` script, raycast routing.
4. Core package still has zero external dependencies and zero C++.
5. Documentation exists for a third party to write a backend without reading engine source.

Phase 2 (after the Jolt prototype proves the seams, and on the maintainer's timetable): render interpolation (C1.3, opt-in), shapecast/overlap, mesh colliders + cooked-shape convention (C6), `CharacterControllerComponent`. C3/C4 remain on the maintainer's separate review path and phase 2 will consume whatever lands there rather than proposing its own versions.

---

## 6. Decisions to lock before PR A

Reduced from the original six — the rest either resolved themselves in the narrowing (D3 → §2.3) or belong to the Jolt repo, not the core.

| # | Decision | Recommendation |
|---|---|---|
| D4 | Collision layer width in `RigidBodyComponent` | 32-bit layer + 32-bit mask (as in the full proposal) |
| D5 | Where the Jolt plugin repo lives | Maintainer's call; affects only the docs' links |
| D7 *(new)* | Should `PhysicsWorldConfiguration` be settable per scene or global? | Global for phase 1 (matches current single-world reality); per-scene is additive later |

D1 (double precision) and D2 (determinism) are Jolt-build flags — they move to the plugin repo's first decision log and don't block any core PR.
