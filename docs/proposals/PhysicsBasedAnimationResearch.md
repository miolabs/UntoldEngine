# Physics-Based Animation — Research for a Future Phase

Status: research only, no implementation. Companion to the animation system and Jolt physics integration efforts. Researched 2026-08-05.

## TL;DR

Physics-based animation is very feasible as a later phase, and cheaper than expected, because **Jolt already ships the hard parts as first-class library features**: ragdolls with motor-driven pose matching, a `SkeletonMapper` that maps between a low-detail physics skeleton and a high-detail animation skeleton, and soft bodies with animation-coupled "skinned constraints". This is literally the tech Guerrilla shipped in Horizon Forbidden West (Jolt's author wrote it there), so the paths are production-proven.

The recommended scope for a first physics-animation phase is **not** full simulated characters. It is, in order of payoff per effort:

1. **Spring/jiggle bones** (Verlet chains, outside the physics world) — trivial cost, huge perceived-life payoff.
2. **Foot IK + physics grounding** (raycasts + two-bone IK) — kills the most visible artifact (floating feet); shares infrastructure with everything below.
3. **Passive ragdolls with pose-driven "death stiffness"** — mostly authoring on top of Jolt's `Ragdoll`.
4. **Hit-reaction layering** (the Unreal "Physical Animation Component" pattern) — simulate a bone subtree with motors holding the animation pose, apply an impulse, ramp a per-bone blend weight up and back down. This is the flagship feature: it's what gives non-Euphoria AAA games their melee staggers and gunshot flinches.

Full active ragdolls (balance cheats, Gang-Beasts-style) are a medium step beyond that. RL/learned controllers (DeepMimic/AMP/PHC/DReCon) are explicitly **not** recommended as a roadmap item — no shipped commercial game is confirmed to use one, they require a GPU training farm (IsaacLab) plus a risky sim-to-Jolt transfer, and they retrain per character.

---

## 1. What Jolt gives us for free

All class references are in the Jolt repo (`github.com/jrouwe/JoltPhysics`); samples in `Samples/Tests/Rig/`.

### 1.1 Ragdoll (`Jolt/Physics/Ragdoll/Ragdoll.h`)

- `RagdollSettings`: a `Skeleton` (the *physics* skeleton) plus one `Part` per joint. Each `Part` **extends `BodyCreationSettings`** (shape, mass, motion type) and adds `mToParent`, the constraint to the parent joint's body — canonically a `SwingTwistConstraint` (twist axis along the bone, elliptic swing cone, twist min/max, and **per-joint swing/twist `MotorSettings`**).
- Setup helpers that matter: `Stabilize()` (inertia conditioning so long chains solve stably), `CalculateConstraintPriorities()` (root-first solver ordering), `DisableParentChildCollisions()`.
- The reference humanoid in `Samples/Utils/RagdollLoader.cpp` is **12 capsule bodies / 11 SwingTwist constraints** — that's the whole physics skeleton. Fingers, twist bones, facial bones never simulate.

### 1.2 The three keying modes (Jolt's own vocabulary)

| Mode | API | Behavior |
|---|---|---|
| **Hard keying** | kinematic bodies + `SetPose()` | Follows animation exactly; pushes objects, is never pushed. Cheapest interactive mode. |
| **Soft keying** | `DriveToPoseUsingKinematics(pose, dt)` | Sets body velocities so bodies reach the pose in `dt`; tracks animation almost exactly but reacts to heavy impacts. |
| **Motor driving** | `DriveToPoseUsingMotors(pose)` or `(prevPose, pose, dt)` | Activates constraint motors toward the pose's local joint rotations (the 2-pose overload also drives target velocity). This is the powered/active ragdoll. |

Motor stiffness is a built-in PD controller: `MotorSettings` with spring frequency (Hz) + damping ratio (Jolt guidance: ~20 Hz = stiff, ~2 Hz = soft; default 2 Hz/1.0) and min/max force/torque limits — lowering torque limits makes a character "weaker". `ResetWarmStart()` after teleports.

### 1.3 SkeletonMapper (`Jolt/Skeleton/SkeletonMapper.h`) — the key architectural piece

Maps both directions between the ~12-body ragdoll skeleton and the full animation skeleton:

- `MapReverse(animPoseModelSpace → ragdollPose)` — every frame, produce motor/kinematic targets from the animation.
- `Map(ragdollPoseModelSpace, animPoseLocalSpace → outAnimPoseModelSpace)` — after the physics step, write the simulated result back onto the full skeleton. Directly mapped joints copy through; **chains** (e.g. 5 HD spine vertebrae between 2 ragdoll bodies) are reoriented while keeping their local shape; **unmapped** joints (fingers, twist bones) keep their animated local transforms.
- `LockAllTranslations()` — pins bone translations to the neutral pose so constraint stretch ("bones pulling apart", constraints are never 100% rigid) never reaches the render skeleton.

`SkeletonMapperTest` demonstrates the full loop: sample HD animation → `MapReverse` → `DriveToPoseUsingMotors` → step → `Ragdoll::GetPose` → `Map` back → render.

### 1.4 Soft bodies (secondary motion for cloth/flesh)

Jolt's XPBD soft bodies have **skinned constraints** designed exactly for animation coupling: each simulated vertex is tethered to its skinned (animated) position within a `mMaxDistance` sphere plus a back-stop sphere. Call `SoftBodyMotionProperties::SkinVertices(...)` each step with the joint matrices. `SetSkinnedMaxDistanceMultiplier(→0)` progressively hard-skins the body — a ready-made LOD knob. There's also a newer Cosserat-rod path and GPU strand hair. Limits: no soft-soft collisions, rigid-only interaction.

### 1.5 Performance reference points

- Jolt's own sample runs **160 motor-driven ragdolls** (~1,920 bodies) in real time; `PerformanceTest/RagdollScene.h` is the official benchmark.
- LOD ladder available out of the box: motor-driven (near) → soft keyed → hard keyed/kinematic (mid) → single capsule, no ragdoll (far). Community guidance for real Mixamo-style rigs: collapse to 10–20 bodies, never 60.

---

## 2. Technique landscape (with verdicts)

| Technique | Difficulty | Runtime cost | Payoff | Verdict |
|---|---|---|---|---|
| Spring/jiggle bones (Verlet chains) | Low | Trivial | Very high | Do early; independent of the ragdoll stack |
| Foot IK + grounding | Low-Med | Near zero (a few raycasts) | Very high | Do early; shares infra with layering |
| Passive ragdoll + pose-driven death stiffness | Low | Very low | Baseline | First ragdoll milestone; mostly authoring |
| Hit-reaction layering (UE pattern) | Medium | Low (subtree, only during reactions) | High — "AAA feel" | **The flagship feature** |
| Full active ragdoll w/ balance cheats | Medium | Low-Med | High for stumbles / physics-comedy | If the design wants it |
| SIMBICON-style balance controllers | Medium | Low | Niche, robotic look | Reference only |
| RL controllers (DeepMimic/AMP/PHC/DReCon) | Very high | Low at inference | Highest ceiling, unproven in shipping | Not a roadmap item; scoped experiment at most |
| Euphoria-class behavior synthesis | Very high | ~1 core/char historically | Best-in-class | Unlicensable since 2017 (Rockstar-only); imitate the *effect* via layering |

Key notes per technique:

- **Passive ragdolls**: raw ragdolls look like wet noodles even for deaths. The standard fix (Jolt's "160 ragdolls" sample does this) is keeping weak motors pulling toward a death pose so corpses have stiffness.
- **Hit-reaction layering** (the highest-ROI item): character stays animation-driven; on hit → enable simulation on the hit bone's subtree, motors hold the ongoing animation pose, apply the impulse, ramp per-bone physics blend weight to ~0.5–1.0 and back to 0 over ~0.2–0.5 s with spatial falloff up the chain. Most of the work is *engine plumbing* (per-bone simulate flags, blend weights in pose composition, named strength profiles), not physics research.
- **Active ragdolls / balance**: local-space pose matching does not keep a character upright — nothing generates world-space balancing torque. Shipped indie games (Gang Beasts, Human Fall Flat) cheat with external world-space forces on pelvis/head; the honest alternatives are SIMBICON foot placement or RL, both of which look either robotic or are research-grade.
- **RL state of the art** (for reference): DeepMimic (2018, imitate one clip) → DReCon (Ubisoft 2019, RL tracks motion-matching output) → AMP (2021, adversarial style reward) → PHC/PULSE (2023-24, one policy tracks ~10k AMASS clips, 98.9%) → MaskedMimic (NVIDIA 2024). Training needs GPU-parallel sim (IsaacLab, 4096 envs); inference is a tiny MLP (cheap). Blockers for us: policies are trained against a specific simulator + character (sim-to-Jolt transfer is a real gap; retrain per rig), and designer iteration ("change the walk" = retrain) is terrible. As of 2025-26, no confirmed shipped commercial game uses a fully learned physics controller.

---

## 3. How other engines structure it (what to imitate)

Every engine converges on the same per-tick pipeline:

```
gameplay sets per-bone mode (simulate on/off, profile, blend weight)
  → animation graph evaluates pose
  → animation-space passes (foot IK, spring bones)
  → map anim pose → physics targets (Jolt: MapReverse + DriveToPoseUsingMotors)
  → physics fixed step(s)
  → read back simulated pose (Ragdoll::GetPose + SkeletonMapper::Map)
  → per-bone blend: final[i] = slerp(anim[i], phys[i], w[i])
  → skinning
```

Load-bearing design decisions, with each engine's answer:

- **Animation always owns the final bone transforms; physics is a pose *source*.** Unreal blends in the skeletal mesh component's post-physics tick; Godot 4 routes it through the `SkeletonModifier3D` stack (physics ragdoll = one modifier among IK/constraints, with a centralized per-modifier `influence` blend applied by the skeleton itself — the cleanest ownership model, and the one that fits Untold's entity/extension architecture best). Jolt deliberately takes no position: it hands you `GetPose` + `SkeletonMapper` and the engine owns blending.
- **Two mechanisms, not one** (Unreal has both, deliberately): (a) main-scene simulation blended back per-bone (Physical Animation Component + `SetAllBodiesBelowSimulatePhysics` / `SetAllBodiesBelowPhysicsBlendWeight`) for things that interact with the world, and (b) a *graph-local* lightweight sim (RigidBody anim node / AnimDynamics) whose output is just a pose — used for accessories/secondary motion, one-way collision against the world. Worth keeping both slots in mind for the Untold design.
- **Gameplay API vocabulary that shipped everywhere**: simulate-below-bone(subtree), per-bone blend weight, named strength **profiles** ("hit_reaction", "staggered", "dead" — Unreal's Physical Animation Profiles, PuppetMaster's muscle profiles), impulse-at-bone, global strength multiplier. PuppetMaster's three-axis decomposition is a good mental model: **pin weight** (world-space pull to animated position), **muscle weight** (joint motor strength), **mapping weight** (how much of the simulated result is displayed).
- **Fixed-step mismatch**: physics at fixed 60 Hz, render interpolation of body transforms; motor/kinematic targets written before each fixed step (`DriveToPoseUsingKinematics` takes the step dt explicitly).
- **Transition quality lives in two details**: seed body velocities from the last two animation frames when simulation starts (UE's "Transfer Bone Velocities"), and always *ramp* blend weights, never toggle. Get-up = pick nearest get-up clip to the settled pose (facing + prone/supine), blend out over ~0.3 s.

## 4. Common pitfalls (collected)

- **Jitter**: motors fighting limits/contacts, or stepping physics at render rate. Fix: fixed timestep + render interpolation, never drive motors toward a pose that violates joint limits.
- **Constraint explosion**: huge impulses when a drive target teleports (animation snap, motion warp). Fix: clamp motor force/torque, snap with `SetPose` + `ResetWarmStart` on large discontinuities.
- **Activation inside geometry** → first-frame explosion. Depenetrate / settle substeps.
- **Retargeting**: motor gains tuned for one character misbehave on another — scale gains with inertia, don't hardcode torques. (Jolt's frequency-based `MotorSettings` already helps here.)
- **Bone stretch** from non-rigid constraints reaching the render skeleton — solved by `SkeletonMapper::LockAllTranslations`.
- **Networking**: simulated poses are client-side cosmetic; never gameplay-authoritative.

## 5. Suggested phasing (when we get there)

1. **Phase A — animation-space physics (no ragdoll)**: spring/jiggle bone chains (Verlet, render-rate, outside Jolt's world) + foot IK grounding via Jolt raycasts. Requires only the "pose modifier stack" hook, now part of the animation system plan (`docs/Architecture/animationPoseLayer.md`, section 4).
2. **Phase B — passive ragdolls**: `RagdollSettings` authoring from a skeleton subset, SkeletonMapper setup, animation→ragdoll handoff with velocity seeding, death-pose stiffness.
3. **Phase C — hit-reaction layering**: partial-subtree simulation, per-bone blend weights in pose composition, named strength profiles, impulse-at-bone API, blend-back ramp. (The flagship.)
4. **Phase D (optional)** — full active ragdoll states (stumble/unpinned) with balance cheats; soft-body skinned-constraint cloth.
5. **Non-phase** — RL controllers: revisit only if a project specifically needs them; budget a person-year to a demo.

The only thing worth doing *during* the current animation-system work is cheap future-proofing: (a) a post-animation pose-modification pass (modifier stack à la Godot `SkeletonModifier3D`) with per-modifier blend weight, and (b) keeping the animation skeleton's model-space pose accessible per frame in a form a mapper can consume (contiguous joint matrices + parent indices). **Done 2026-08-05** — both are specified in `docs/Architecture/animationPoseLayer.md` section 4 ("Pose modifier stack", with the lazily computed model-space snapshot in `PoseModifierContext`).

## 6. Key references

- Jolt ragdolls: `Jolt/Physics/Ragdoll/Ragdoll.h`, `Jolt/Skeleton/SkeletonMapper.h`, `Jolt/Physics/Constraints/SwingTwistConstraint.h`, `MotorSettings.h`; samples `Samples/Tests/Rig/*` (esp. `PoweredRigTest`, `SkeletonMapperTest`, `RigPileTest`), `Samples/Utils/RagdollLoader.cpp`; docs https://jrouwe.github.io/JoltPhysics/ · https://github.com/jrouwe/JoltPhysics/blob/master/Docs/Samples.md
- Guerrilla GDC 2022, "Architecting Jolt Physics for 'Horizon Forbidden West'": https://www.guerrilla-games.com/read/architecting-jolt-physics-for-horizon-forbidden-west
- Unreal Physics-Driven Animation: https://dev.epicgames.com/documentation/unreal-engine/physics-driven-animation-in-unreal-engine · RigidBody node: https://dev.epicgames.com/documentation/en-us/unreal-engine/animation-blueprint-rigid-body-in-unreal-engine
- Godot 4 modifier stack: https://docs.godotengine.org/en/stable/classes/class_skeletonmodifier3d.html · https://docs.godotengine.org/en/stable/classes/class_physicalbonesimulator3d.html
- ezEngine Jolt ragdoll component (three keying modes exposed): https://ezengine.net/pages/docs/physics/jolt/ragdolls/jolt-ragdoll-component.html
- PuppetMaster (pin/muscle/mapping weight model): http://root-motion.com/puppetmasterdox/html/page3.html
- Active-ragdoll balance: https://medium.com/@jacasch/balancing-of-active-ragdolls-in-games-367f146b25fb
- Foot IK reference impl (ozz-animation): https://guillaumeblanc.github.io/ozz-animation/samples/foot_ik/
- Spring bones: Godot 4.4 `SpringBoneSimulator3D` (https://gamefromscratch.com/godot-4-4-gets-jiggle-physics/) · https://github.com/naelstrof/JigglePhysics
- RL lineage: DeepMimic https://arxiv.org/abs/1804.02717 · DReCon https://www.theorangeduck.com/media/uploads/other_stuff/DReCon.pdf · AMP https://arxiv.org/abs/2104.02180 · PHC https://github.com/ZhengyiLuo/PHC · PULSE https://github.com/ZhengyiLuo/PULSE · MaskedMimic https://dl.acm.org/doi/10.1145/3687951 · Survey https://arxiv.org/pdf/2203.04735
- SIMBICON: https://www.cs.ubc.ca/~van/papers/2007-siggraph-simbicon.pdf
- Euphoria/NaturalMotion history: https://en.wikipedia.org/wiki/Euphoria_(software)
- Jolt community ragdoll-authoring advice (Mixamo rigs, 10–20 bodies): https://github.com/jrouwe/JoltPhysics/discussions/1764 · https://github.com/jrouwe/JoltPhysics/discussions/1895
