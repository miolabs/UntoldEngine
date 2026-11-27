# A SharePlay plugin for Untold games — Proposal

Status: proposal, written 2026-10-28 against the checkouts of that day: the engine fork `develop` (main `UntoldEngine` folder), CoolSaber on `feature/saber_spatial_sync` (worktree `UntoldArcade-saber`, with its uncommitted spatial-sync work), the RealityKit presenter spike (`UntoldArcade/Spikes/RealityKitPresenter`) and Oche `main` (`~/Projects/Games/Oche`, build 1.0 (1) on TestFlight). D1 and D2 were decided on 2026-10-28 (its own repository, created under `miolabs` first and moved to `untoldengine` when finished; the name `UntoldSharePlay`); D3–D9 open. Stage 1 is built, see section 6. It is the "Session" and "Transport" rows of the roadmap issue untoldengine/UntoldEngine#1243 (multiplayer: sessions, replication and transports); the replication rows stay there for later. Related: #1371 stage 4 (SharePlay on the RealityKit presenter), which should consume this plugin instead of copying CoolSaber a third time.

Question: three places have now written the same SharePlay code, and every new game would write it again. What goes into a plugin that a game adds as one dependency, what stays in the game, and how do CoolSaber, Oche and the presenter example move onto it?

## TL;DR

- CoolSaber carries about 1,200 lines of SharePlay plumbing that has nothing to do with sabers: the activity, the session controller, the two messengers, the lock-guarded mailbox between the main actor and the render thread, the system coordinator (group immersive space, spatial template, `isSpatial`, `groupImmersionStyle`), the immersive-space open/dismiss phase machine, the shared-frame bookkeeping (`immersiveSpaceDisplacement`, shared world anchors, the manual "touch the controllers" calibration, the fixed fallback for a remote opponent) and the diagnostics. The presenter spike copied the controller (185 lines). Oche's plan for its R6 milestone says "port `SaberActivity` → `DartsActivity`, `SaberSessionController` → `DartsSessionController`" and adds what CoolSaber lacks: more than two participants, a host, snapshots for late joiners, spectators. Three more hand-written copies live in other MIOLabs apps outside Untold.
- The plugin is a Swift package, `UntoldSharePlay`, built like `UntoldJoltPhysics` (its own repository, the engine's plugin authoring guidelines), with two products: `UntoldSharePlay`, which does not depend on the engine, so Oche's shipping RealityKit target can use it, and `UntoldSharePlayXR`, which bridges the engine's XR runtime (shared world anchors, the immersive-space displacement, teardown). A game keeps three things of its own: its `GroupActivity` (ten lines), its wire types (plain `Codable`), and what it does with the messages.
- Nine pieces: the session (one object, main actor, observable), typed channels of two kinds (state: unreliable, latest wins per sender, the plugin adds the sequence and the timestamp; event: reliable, in order), participants with nearby and spatial flags and an optional host election, the shared frame with one precedence rule (manual > shared anchor > system displacement > fallback stage) and the conversions a game calls per frame, the immersive-space coordinator (CoolSaber's phase machine, including "cycle the space on join"), the XR bridge, a status view for the control window, diagnostics, and a transport seam with a loopback transport so the logic is tested on the Mac without a headset. Every lesson the three copies learned (section 1.6) becomes plugin behaviour and a test.
- Five stages, about two and a half weeks of plugin work plus headset sessions: the core (Mac only), the space and the frame, CoolSaber on the plugin (the gate: the same duel, nearby and over FaceTime, with a fifth of the code), Oche R6 on the core (its own session), the `untoldengine create --shareplay` template and the docs. The presenter plan's stage 4 then reuses it unchanged.

## 1. What exists (2026-10-28)

### 1.1 CoolSaber: the proof, two players, peer to peer

`UntoldArcade/CoolSaber/Examples/CoolSaberVisionOS/CoolSaberVisionOS/visionOS/` on `feature/saber_spatial_sync` (`214093b`, plus uncommitted work of +790/−31 lines over 7 files, the session "Cool Saber spatial sync issue"):

| File | Lines | What is SharePlay plumbing in it |
|---|---|---|
| `SaberActivity.swift` | 20 | The `GroupActivity`: identifier, title, `.generic`. |
| `SaberSessionController.swift` | 517 | `SaberDuelMailbox` (313 lines): the lock-guarded bridge between the main-actor session and the render thread, holding the outgoing packet and events, the latest remote packet with arrival time and stale-drop by sequence, the session/spatial/nearby/present flags, the manual frame-sync solution with heading and nudge, the opponent's shared anchor, the alignment precedence. `SaberSessionController` (204 lines): `sessions()` observer, `activate()`, `join()`, an unreliable messenger for poses and a reliable one for events created before the join, a 45 Hz outgoing pump, `$state` and `$activeParticipants` subscriptions (opponent present, `isNearbyWithLocalParticipant`), the system coordinator (`supportsGroupImmersiveSpace`, `.conversational`, `localParticipantStates` → `isSpatial`, `groupImmersionStyle` → `groupImmersionActive`), cleanup. |
| `CoolSaberVisionOSXRApp.swift` | 787 | The displacement storage in `SaberXRHolder`, the `SaberArena: CompositorContent` reading `immersiveSpaceDisplacement` and `onWorldRecenter` (about 100 lines), and `SaberArenaPresenter` (about 180 lines): the one place that opens and dismisses the space, a phase machine with deferred opens during teardown, one retry after an error, recovery of a space presented without a renderer, and `joinGroup`, which cycles an open space because a space opened before the join stays private (verified on device). The window's Start Duel / Leave Duel buttons, the status line and the diagnostics row. |
| `SaberXRGame.swift` | 927 | The shared world anchor (about 80 lines: place our anchor at the ARKit origin when a nearby opponent is present, observe the opponent's anchor, forget it on removal), the remote mapping and its precedence (about 60), the manual frame sync solve and its event (about 70), the settled-nudge re-send, the first-packet and 2-second frame diagnostics (about 60). |
| `Sources/CoolSaber/CoolSaberNet.swift` | 78 | The wire types with hand-rolled `sequence` and `timestamp`, a `SaberFrameTransform` codable matrix, the `frameSync` event. |
| `Sources/CoolSaber/CoolSaberMath.swift` | 30 of 149 | `yawAlignedFrame`: the rigid transform between two gravity-aligned frames from one shared point and one shared horizontal heading (the "touch the right controllers together" calibration). |
| Tests | 70 + 42 | Wire codec round trips, the solver. |

About 1,200 of those lines are the same for any game; about 250 are the duel (blades on the wire, what a clash does, where the remote blades are drawn). What CoolSaber does not have: more than two participants, a host, state catch-up for a late joiner.

### 1.2 The RealityKit presenter spike

`UntoldArcade/Spikes/RealityKitPresenter/Sources/RealityKitPresenter/SharePlay/`: `PresenterActivity.swift` (20) and `PresenterSessionController.swift` (165), written "after Apple's sample and CoolSaber's `SaberSessionController`": the same observer, `prepareForActivation` then `activate`, join, the coordinator with `.sideBySide`, `isSpatial`, `groupImmersionStyle`. No messages. The presenter plan's stage 4 (`XRRealityKitPresenter.md`) wants the group immersive-space origin applied and CoolSaber running on the presenter with `SaberSessionController` unchanged: a third copy unless the plugin exists first.

### 1.3 Oche: four players, a host, RealityKit

Oche 1.0 ships on RealityKit (`docs/REALITYKIT.md`, decision of 2026-10-20) with the engine path kept as a second target; R0–R5 are merged, build 1.0 (1) is on TestFlight since 2026-10-28, and **R6 SharePlay is "not started, needs two headsets"**. What is written: the wire types in `Packages/OcheRules/Sources/OcheRules/Sync/Messages.swift` (`ThrowEvent`, `ReleaseParams`, `StateSnapshot`, `DartPose`, `LobbyCommand`, versioned, 103 lines) and `HostAuthority.swift` (61 lines, deterministic validation and apply, the snapshot to broadcast). What the plan asks for (`IMPLEMENTATION.md` §8, `REALITYKIT.md` §4): the activity `com.miolabs.oche.match`, a session controller "with the mailbox carrying `DartPose` (unreliable, 45 Hz) and `ThrowEvent`/`StateSnapshot`/`LobbyCommand` (reliable)", `supportsGroupImmersiveSpace = true` with `.sideBySide` or a custom template with the seats at the oche, **host = the participant with the lowest `Participant.id` string, recomputed on every change, the new host rebroadcasts the latest snapshot**, late joiners request a snapshot, four players and spectators beyond, the board at a fixed pose in the shared frame defined by the host, name tags as attachments, Personas from the system. Tests planned: codec round trips, host election, out-of-turn rejection, snapshot catch-up. Everything in that list except the darts is the plugin.

### 1.4 The engine

- No networking. `Sources/UntoldEngineXR/UntoldEngineXRWorldAnchors.swift` (280 lines) is the one SharePlay-aware piece: `addWorldAnchor(originFromAnchorTransform:sharedWithNearbyParticipants:)`, `removeWorldAnchor`, `addWorldAnchorObserver` delivering `XRWorldAnchorUpdate` (id, pose, tracked, shared, own, event) across provider restarts, with the visionOS 26 initialiser behind `#available`. This is what the plugin's XR bridge uses; nothing else is needed from the engine for stages 1–3.
- The build templates (`BuildSystem/BuildTemplates.swift:1291` and `:1608`) generate the `ImmersiveSpace { CompositorLayer { ... } }` shell with an `XRHolder` and a Start Experience button; `BuildSettings.includesCodeComponents` is the precedent for a feature flag of `untoldengine create`.
- Plugins: `docs/Extensions/PluginAuthoringGuidelines.md` ("optional, isolated, boring to remove"; public engine API only; outside the core repository; reverse-DNS ids; tests for the manifest and registration; a README with a compatibility table), `UntoldJoltPhysics` as the shipped example (its own repository, products `UntoldJoltPhysics`, engine pinned to `develop`, tests through the engine protocol), `docs/API/UsingJoltPhysicsXR.md` as the engine-side getting-started page.
- The presenter work (#1371): the XR runtime now sits behind a frame-source seam (`feature/xr_frame_source`) and the RealityKit presenter target (`UntoldEngineXRRealityKit`); world anchors live in the runtime, so a bridge written against `UntoldEngineXR` works on both presenters.

### 1.5 The same in every copy

| Piece | CoolSaber | Presenter spike | Oche plan | Varies per game? |
|---|---|---|---|---|
| `GroupActivity` type | yes | yes | yes | identifier, title only |
| `sessions()` observer, `prepareForActivation`, `activate`, `join`, `leave`, cleanup | yes | yes | yes | no |
| Messengers before the join, reliable + unreliable | yes | – | yes | no |
| Outgoing pump at 45 Hz, latest-wins, stale-drop by sequence | yes | – | yes | rate only |
| Thread-safe mailbox for the render thread | yes | – | yes ("the mailbox pattern") | no |
| `$state`, `$activeParticipants`, local participant subtracted | yes | yes | yes | no |
| `isNearbyWithLocalParticipant` | yes | – | (nearby start mentioned) | no |
| System coordinator: group immersive space, template, `isSpatial`, `groupImmersionStyle` | yes | yes | yes | the template |
| Open/cycle/dismiss the space on the group signal | yes (phase machine) | yes (simplified) | yes | the space id |
| `immersiveSpaceDisplacement` into the frame | yes | – | RealityKit applies it | presenter kind |
| Shared world anchors for nearby | yes | – | – | no |
| Manual calibration + nudge + its event | yes | – | – | the two points |
| Fallback pose for a remote non-spatial participant | yes | – | – | the stage pose |
| Host election, snapshot catch-up, spectators | – | – | yes | the policy |
| Status text, Start/Leave buttons, diagnostics row | yes | yes | yes (lobby) | styling |
| Wire types | sabers | – | darts | **yes** |
| What the messages do | blades, clashes | – | rules, flight replay | **yes** |

### 1.6 Lessons the copies learned (each becomes plugin behaviour and a test)

1. Create the messengers and their receive loops before `join()`, or early messages are lost (CoolSaber).
2. Messages flow only in `.joined`; one sent right after `join()` can be dropped, so re-send readiness or the snapshot on the transition (NeoVerse).
3. `Activity.sessions()` emits only new sessions; `$state` and `$activeParticipants` must be observed per session (NeoVerse).
4. A space opened before the session joined stays private: the opponent cannot connect until it is closed and reopened (CoolSaber, on device). The join cycles an open space; a second cycle within 3 s is ignored.
5. visionOS allows one immersive-space request at a time; an open during the engine's asynchronous teardown is deferred until teardown completes; `.error` gets one retry; a space presented without a renderer is recovered by a dismiss (CoolSaber's presenter).
6. `activeParticipants` contains the local participant; subtract it. A participant leaving voids the alignment solved for them.
7. The unreliable stream arrives out of order; compare sequences with wrap-around and keep the newest; carry the sender's uptime for the age, never for alignment (CoolSaber's mailbox).
8. `immersiveSpaceDisplacement` is ARKit-from-shared: a pose in the group's frame times it lands in this device's ARKit frame; the wands and the device anchor stay in the un-displaced ARKit frame, so the sender strips its displacement and the receiver applies its own (CoolSaber's `SaberXRGame` header). CoolSaber observed the displacement as identity for nearby participants in a Metal space, which is why the shared anchor path exists.
9. Shared world anchors are for nearby participants only; a remote participant's pose has to be synchronised by the app (Apple, forum 801420). Anchors are re-created after a provider restart (the engine does this).
10. `ParticipantState.pose` (visionOS 26) is updated at key events, not per frame (research note): a diagnostic, not a tracking source.
11. `prepareForActivation()` first: `.activationDisabled` means no call and no nearby people to share with; the UI says so instead of failing in `activate()`.
12. No Persona appears over a Compositor Services space (the research note); the plugin does not change that, the presenter (#1371) does. The plugin must work on both presenters.
13. The render thread never touches actor state: lock-guarded `@unchecked Sendable` classes between the main actor and the frame, as the engine's concurrency rule says (no actors on the frame path).

## 2. Design

### 2.1 Shape

A Swift package `UntoldSharePlay` (D1, D2), following `docs/Extensions/PluginAuthoringGuidelines.md`:

```
UntoldSharePlay/
├── Package.swift                 platforms macOS 14, iOS 17, visionOS 2 (the engine's); Swift 6
├── Sources/
│   ├── UntoldSharePlay/          product 1: no engine dependency
│   │   ├── SharePlaySession.swift          the session, generic over the game's GroupActivity
│   │   ├── SharePlayChannel.swift          StateChannel / EventChannel + the envelope
│   │   ├── SharePlayParticipants.swift     participants, nearby/spatial flags, HostElection
│   │   ├── SharedFrame.swift               alignment sources, precedence, conversions, calibration
│   │   ├── ImmersiveSpaceCoordinator.swift the open/cycle/dismiss phase machine
│   │   ├── Transport/                      SharePlayTransport, GroupActivitiesTransport, LoopbackTransport
│   │   ├── SharePlayStatusView.swift       Start / Leave, state, participants, alignment (SwiftUI)
│   │   └── SharePlayDiagnostics.swift      the status strings, rates, the 2 s frame log
│   └── UntoldSharePlayXR/        product 2: depends on UntoldEngineXR (visionOS)
│       ├── SharePlaySession+XR.swift       attach(to: UntoldEngineXR): shared anchors in and out
│       └── CompositorContent+SharePlay.swift  .sharePlayFrame(session): displacement, recenter
├── Tests/
│   ├── UntoldSharePlayTests/     channels, envelope, election, frame, coordinator, session over the loopback
│   └── UntoldSharePlayXRTests/   the anchor bookkeeping against a fake anchor feed
├── Examples/SharedCube/          a visionOS app: each participant's head as a marker, Start/Leave, the status view
└── README.md                     install, register, platforms, compatibility table, the lessons
```

Ids: `com.untoldengine.shareplay` and `com.untoldengine.shareplay.<piece>`. The package depends on the engine (for product 2) the way Jolt does, pinned to `develop` of `untoldengine/UntoldEngine` (the fork while in development); SwiftPM clones it even for an app that links only product 1, which is acceptable for Oche (its engine target pulls it anyway) and stated in the README.

### 2.2 The pieces

**1. The activity stays the game's.** `GroupActivity` needs a concrete `Codable` type with a static identifier, and the identifier is what the system matches sessions on, so the plugin never ships one (D4). The template writes it:

```swift
struct DuelActivity: GroupActivity {
    static let activityIdentifier = "com.miolabs.coolsaber.duel"
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "CoolSaber Duel"
        metadata.type = .generic
        return metadata
    }
}
```

**2. `SharePlaySession<Activity>`** (main actor, `@Observable`): one object per app, created once with a configuration closure, generic over the activity like `GroupSession` is.

```swift
@MainActor let session = SharePlaySession(DuelActivity()) {
    $0.groupImmersiveSpace = true          // SystemCoordinator.Configuration.supportsGroupImmersiveSpace
    $0.spatialTemplate = .conversational   // .sideBySide, .surround, .custom(template)
    $0.stateRate = 45                      // Hz of the state pump
    $0.hostElection = .none                // .lowestParticipantID for Oche
}
session.startObserving()                   // Activity.sessions(); call once at launch
await session.start()                      // prepareForActivation + activate; .notAvailable, .cancelled, .started
session.leave(); session.end()
```

State: `.idle`, `.starting`, `.waiting`, `.joined`, with `statusMessage` (the strings CoolSaber and the spike show), `participants`, `localParticipantID`, `isSpatial`, `isHost`, `groupImmersion` (`.notRequested`, `.requested(style)`, `.ended`) and an `events` stream: `.joined`, `.participantJoined(id)`, `.participantLeft(id)`, `.hostChanged(to:)`, `.invalidated(reason)`. Inside: the session observer, the messengers created before `join()` (lesson 1), the subscriptions (lesson 3), the local participant subtracted (lesson 6), the coordinator configured once the session delivers it, the `localParticipantStates` and `remoteParticipantStates` (visionOS 26) read into the participants, `groupImmersionStyle` mirrored into `groupImmersion`.

**3. Channels.** Two kinds, typed, registered before the join (the plugin refuses a channel after it; lesson 1), each with its own `GroupSessionMessenger` and delivery mode. Both are `Sendable`, lock-guarded, callable from the render thread; the session's pump drains the outboxes on the main actor at `stateRate` (lesson 13).

```swift
let poses = session.stateChannel(BladePoses.self)   // unreliable; latest wins per sender
let events = session.eventChannel(DuelEvent.self)   // reliable; in order

poses.publish(local)                                 // render thread, per frame; superseded by the next
poses.latest(from: id)                               // Received<BladePoses>?: message, sequence, age
poses.latestAll()                                    // [ParticipantID: Received<BladePoses>]
events.send(.clash(at: p, intensity: 0.8))           // queued, sent in order; .to(.only(ids)) optional
events.drain()                                       // [Received<DuelEvent>] since the last drain
```

The state envelope adds `sequence: UInt32` and `sentUptime: Double`; the receiver drops stale packets with wrap-around compare and records the arrival uptime (lesson 7), so wire types lose their hand-rolled `sequence`/`timestamp` fields (`SaberPosePacket` becomes the two blades; `DartPose` stays as it is). An event channel re-sends what was queued before `.joined` on the transition (lesson 2). Messages stay small: a state message is a few dozen bytes; a snapshot such as Oche's `MatchState` is an event, sent rarely; anything large goes through `GroupSessionJournal` attachments, which the plugin exposes but does not wrap in stage 1.

**4. Participants and the host.** `SharePlayParticipant`: `id`, `isLocal`, `isNearby` (`isNearbyWithLocalParticipant`, visionOS 26, false before), `isSpatial` (from `remoteParticipantStates` on visionOS 26, from `localParticipantStates` for ourselves), `joinedAt` (local uptime). `HostElection` is a policy: `.none` (CoolSaber: symmetric) or `.lowestParticipantID` (Oche's rule: the lowest `Participant.id` string among the active participants, recomputed on every change; the plugin raises `.hostChanged`, the game re-broadcasts its snapshot). Who may play and who spectates is the game's (Oche: four seats, the rest spectate), expressed in its own events; the plugin only tells it who is present and who is host.

**5. `SharedFrame`.** The one object that knows how a pose crosses the wire. Two frames: *shared*, the group's immersive-space frame (what goes on the wire; identical on every spatial or nearby device), and *local*, the frame the game simulates in. On the engine path local is the ARKit world frame and the system never moves it; on a RealityView space (Oche, the presenter) scene coordinates already are the shared frame, so only ARKit-sourced poses (hands, anchors, the device) need converting. Inputs, each with its own setter and a source tag: the system displacement (from the `CompositorContent` environment, through the XR bridge, or identity on a RealityView space), the shared world anchors of nearby participants (from the XR bridge: an anchor another participant placed at their origin is, in our frame, local-from-theirs), the manual solution (`CoolSaberMath.yawAlignedFrame` moved in: one shared point and one horizontal heading from each side, plus the nudge along the heading, re-sent when the sliders settle, and the receiver's inverse; carried on an internal reliable channel of the plugin), and a fallback stage pose for a remote participant with no alignment at all (CoolSaber's "2 m ahead, facing us"; the game sets the pose). Precedence per remote participant, CoolSaber's: manual > shared anchor > system displacement > fallback, with `alignment(of: id)` reporting which one is in force and a summary string for the diagnostics. The per-frame API:

```swift
session.frame.toShared(localPose)                       // before publishing
session.frame.toLocal(pose, from: participant)          // after receiving (the participant's precedence applied)
session.frame.toShared(point:), .toLocal(direction:, from:)
session.frame.sharedFromARKit                            // RealityView spaces: hands and anchors into the scene
session.frame.calibrate(localPoint:localHeading:remotePoint:remoteHeading:with: participant)   // the Sync button
session.frame.nudge = SIMD2(side, forward)
```

A participant leaving clears their solution (lesson 6); a session ending clears everything.

**6. `ImmersiveSpaceCoordinator`.** `SaberArenaPresenter` lifted out, generic over the space id, in the core product because RealityKit apps open and dismiss too (D7): `bind(open:dismiss:)`, `open(reason:)`, `dismiss(reason:)`, `joinGroup(reason:)` (cycle an open space, lesson 4), `spaceDidStart(rendering:)`, `spaceDidTearDown()`, the deferred open during teardown, the one retry, the empty-space recovery (lesson 5), a `phase` and a label for the window. `session.drive(coordinator)` wires `groupImmersion` and the join to it, which is what CoolSaber's two `onChange` modifiers do today; a game that wants manual control does not call it.

**7. The XR bridge** (`UntoldSharePlayXR`). `session.attach(to: xr)`: places this device's shared world anchor at its ARKit origin as soon as a nearby participant is present and removes it when none is or the session ends; observes every shared anchor that is not ours and feeds it to the frame with its tracking state; reports the teardown to the coordinator through the engine's shutdown completion; `detach()` on teardown. `CompositorLayer(...).sharePlayFrame(session)`: `immersiveSpaceDisplacement` (initial and on change) and `onWorldRecenter` into the frame, with the log line CoolSaber prints. On the RealityKit presenter the same `attach` works (anchors live in the runtime) and the modifier is not needed.

**8. `SharePlayStatusView`.** The control-window row every copy has: Start (disabled with the reason when `prepareForActivation` says so), Leave, the state and participant count, nearby/spatial flags, the alignment source and summary, an optional Sync button and the two nudge sliders when the game enables calibration. Plain SwiftUI, restyled by the game or replaced.

**9. Transport seam.** `SharePlayTransport` with `GroupActivitiesTransport` (the real one) and `LoopbackTransport` (N in-process participants with configurable loss, reorder and delay on the unreliable path) so the session, the channels, the election and the frame are tested on macOS, where there is no SharePlay, and so a game can run two instances on one Mac. This seam is the "transport chosen per situation, behind one interface" of #1243; a local-network transport (and ARKit's visionOS 26 shared coordinate space for nearby alignment without SharePlay) is a later addition there, not part of this proposal.

### 2.3 Threads

The session and the coordinator are main-actor and observable (SwiftUI drives them). Channels, the frame and the diagnostics are `@unchecked Sendable` classes guarded by a lock, read and written from the render thread (the engine's rule: no actors on the frame path) or from a RealityView update on the main actor. The pump is one task on the main actor that drains the outboxes at `stateRate` and sends unreliably without awaiting failures, and the receive loops are one task per channel writing into its inbox. The XR bridge's anchor observer arrives on an arbitrary thread (the engine's contract) and writes the frame under its lock. Nothing in the plugin is called from the engine's frame callbacks except through those three classes.

### 2.4 What a new game writes

The whole SharePlay side of a game with two state messages, on the engine path:

```swift
import UntoldSharePlay
import UntoldSharePlayXR

struct ArenaActivity: GroupActivity { /* ten lines, section 2.2 */ }
struct Poses: Codable, Sendable { var head: simd_float4x4; var hands: [simd_float4x4] }
enum ArenaEvent: Codable, Sendable { case hit(at: SIMD3<Float>) }

@MainActor let session = SharePlaySession(ArenaActivity()) { $0.spatialTemplate = .surround }
let poses = session.stateChannel(Poses.self)
let events = session.eventChannel(ArenaEvent.self)
let space = ImmersiveSpaceCoordinator(id: "Arena")

// In the App: the window
SharePlayStatusView(session)
    .task { space.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace); session.drive(space); session.startObserving() }

// In the ImmersiveSpace
CompositorLayer(configuration: config) { layerRenderer in
    guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
    session.attach(to: xr)
    ...
}
.sharePlayFrame(session)

// Per frame, render thread
poses.publish(Poses(head: session.frame.toShared(headPose), hands: hands.map(session.frame.toShared)))
for (id, received) in poses.latestAll() where received.age < 0.5 {
    avatars[id].place(head: session.frame.toLocal(received.message.head, from: id))
}
for event in events.drain() { if case let .hit(p) = event.message { spark(at: session.frame.toLocal(point: p, from: event.sender)) } }
```

Entitlement `com.apple.developer.group-session` in the target; nothing in `Info.plist`. On a RealityView space (Oche): no `UntoldSharePlayXR`, no `attach`, no modifier; `toShared`/`toLocal` are identity for scene poses and `sharedFromARKit` converts hand joints.

### 2.5 What stays in the game

The activity, the wire types, the rules (Oche's `HostAuthority`, snapshots, who may throw), the content placed in the shared frame (the board at the host's pose, the fallback stage pose for a remote opponent), what a message does on screen, the avatar or blade for a remote participant, and the calibration gesture's two points (CoolSaber: the right controllers' ring fronts and headings).

### 2.6 Where the code comes from

| CoolSaber today | Plugin |
|---|---|
| `SaberActivity` | the game's (template) |
| `SaberSessionController` | `SharePlaySession`, `GroupActivitiesTransport` |
| `SaberDuelMailbox`: packets and events | `StateChannel`, `EventChannel`, the envelope |
| `SaberDuelMailbox`: flags, anchor, manual sync, nudge, precedence | `SharePlayParticipants`, `SharedFrame` |
| `SaberArenaPresenter`, the two `onChange`s | `ImmersiveSpaceCoordinator`, `session.drive` |
| `SaberArena`'s displacement publish, `SaberXRHolder`'s displacement storage | `.sharePlayFrame(session)` |
| `SaberXRGame`: shared anchor placement and observer | `session.attach(to:)` |
| `SaberXRGame`: `RemoteMapping`, `solveFrameSync`, settled nudge, frame diagnostics | `SharedFrame`, `SharePlayDiagnostics` |
| `CoolSaberNet`: `sequence`, `timestamp`, `SaberFrameTransform`, `frameSync` | the envelope, the plugin's codable matrix, the internal frame-sync channel |
| `CoolSaberMath.yawAlignedFrame` | `SharedFrame.calibrate` (the solver and its tests move) |
| The window's status, buttons, diagnostics row | `SharePlayStatusView` |
| Stays: `SaberBladeWire`, `SaberEvent` cases, `updateRemote`'s drawing, the clash feedback | CoolSaber |

Expected: CoolSaber's SharePlay side goes from about 1,200 lines to about 250.

## 3. Stages

### Stage 1 — The core, on the Mac (3 days)

The package skeleton (Package.swift, README with the compatibility table, LICENSE), `SharePlaySession` over the transport seam with both transports, the channels and the envelope, participants and `HostElection`, `SharePlayStatusView`, diagnostics. Tests on macOS through `LoopbackTransport`: envelope sequence and wrap-around, stale drop and age, latest-wins per sender, event order and the re-send on join (lesson 2), channels refused after the join (lesson 1), the local participant subtracted, host election across joins and leaves with the `.hostChanged` event, the session state machine (observer, start results, join, leave, invalidation). CoolSaber's and Oche's wire types compile against it unchanged except for the dropped `sequence`/`timestamp` fields.

Done: `swift test` green on the Mac; a two-instance loopback run on the Mac exchanging poses and events.

### Stage 2 — The space and the frame (4 days, Mac plus one headset for a smoke test)

`ImmersiveSpaceCoordinator` ported from `SaberArenaPresenter` with a test per case of lesson 5 (deferred open, retry, empty-space recovery, the 3 s join-cycle guard, dismiss while opening); `SharedFrame` with the precedence, the solver and its tests from `CoolSaberMathTests`, the nudge and its settle timer, the internal frame-sync channel; `UntoldSharePlayXR` (`attach`, the modifier) against a fake anchor feed; the `SharedCube` example app. Smoke test on one headset: the example opens its space, Start says "no one to share with" when nothing is available, the space cycles on a simulated join through the loopback.

Done: tests green; the example runs on the headset; the frame reports the right source for each synthetic input.

### Stage 3 — CoolSaber on the plugin (3 days, two headsets)

On a branch from `feature/saber_spatial_sync` once the saber session has its headset verdict on the anchor and manual paths (so the plugin encodes the behaviour that was verified, not the one in flux): replace the controller, mailbox, presenter, displacement publish, anchor code, remote mapping, frame sync and diagnostics by the plugin; keep the blades, the clash events, the drawing. The gate is the duel as it is today: nearby, aligned through the shared anchor, manual Sync and nudges as a fallback; remote over FaceTime with the fallback stage; the space cycling on join; leave and rejoin; the diagnostics row reading the same facts. Record the before/after line counts in the README.

Done: both duels verified on two headsets; the arcade PR with the counts.

### Stage 4 — Oche R6 on the core (the Oche session; about 1 day of plugin work if something is missing)

Oche's `feature/shareplay` uses product 1 only: `DartsActivity`, the four channels (`DartPose` state; `ThrowEvent`, `StateSnapshot`, `LobbyCommand` events), `.lowestParticipantID`, the host re-broadcasting on `.hostChanged`, the snapshot to a late joiner on `.participantJoined` (`.only([id])`), spectators by seat count, the board pose from the host as an event, name tags from `participants`. The plugin gains whatever Oche finds missing (a `Participants` targeting helper, a "request snapshot" convenience). Gate: `REALITYKIT.md` §5 R6 on two headsets.

Done: Oche's gate; no engine import in Oche's shipping target.

### Stage 5 — Template and docs (2 days)

`untoldengine create --shareplay` (a `BuildSettings.includesSharePlay` flag like `includesCodeComponents`): the entitlement in the XcodeGen spec, `GameActivity.swift`, the session, coordinator and status view wired into both visionOS templates (`:1291` and `:1608`), the plugin as a dependency; `docs/API/UsingSharePlay.md` in the engine (the getting-started page, after `UsingJoltPhysicsXR.md`) plus the mkdocs nav and `docs/index.md`; the plugin README with the lessons of section 1.6; the presenter spike's `PresenterSessionController` replaced by the plugin (or deleted with the spike). The presenter plan's stage 4 then adds nothing but `attach` on its frame source.

Done: a project created with the flag builds and joins a session with the `SharedCube` example on two headsets; the docs page merged.

### Stage 6 — Editor plugin (3 days, after stage 5; asked for on 2026-10-28)

An editor plugin package in the Code Components sense (`untold-package.json` with a runtime module and an editor module, loaded by the editor's plugin loader), so a scene is laid out around where the players will stand and the session options live with the scene:

- A `SharePlayStage` entity plugin (one per scene) whose `@UntoldAttribute`s are the session options: the spatial template, whether the group immersive space is requested, the state rate, the host election, the fallback stage pose for a remote participant who is not spatial, and the seat count. Saved with the scene; the game reads them at launch (`SharePlaySession.Configuration.init(stage:)`), so a designer changes them in the Inspector without a rebuild.
- Its `editorRepresentation` draws the participants' spots: the seats of the chosen template in the stage's local space (side by side 0.6 m apart, conversational facing each other, surround on a ring, custom seats as handles the gizmo moves), numbered, with the forward direction. The plugin also offers the seats to the game as the poses to place a name tag or a stand-in avatar at.
- In the editor's play mode, the loopback transport with N simulated participants moves markers through those spots, so the pieces that react to a session (name tags, the fallback stage, the host's placement) are tried without a headset.
- An `EditorMenuPlugin` under `.tools`: "SharePlay › Simulate N participants", "Leave", and the diagnostics summary in the console.

Done: the stage entity in a scene drives a game's session configuration; the spots match the system's seating on two headsets to within the template's tolerance; the simulated participants move in the editor viewport.

### Later, out of scope (the rest of #1243)

Replication of marked entity state (transforms, animation goals, physics ownership) over the state channels, with interpolation; a local-network transport behind the seam (and ARKit's shared coordinate space for nearby alignment without SharePlay); a dedicated server; the editor's replication marks and session panel.

## 4. Decisions

- **D1 Where it lives.** A separate repository `untoldengine/UntoldSharePlay` (developed under `miolabs` first), like `UntoldJoltPhysics`, per the plugin guidelines. Alternative: an engine product `UntoldEngineSharePlay`. Recommended: the repository. Oche's RealityKit target can use the core without the engine, the plugin iterates without an engine PR per change, and #1243's replication layer later lives in the engine on top of it. **Decided 2026-10-28 (the user):** the repository, created under `miolabs` first with the changes in our own fork, moved to (or re-created under) `untoldengine` when finished.
- **D2 Name.** `UntoldSharePlay`, products `UntoldSharePlay` and `UntoldSharePlayXR`, ids `com.untoldengine.shareplay.*`, types prefixed `SharePlay` (`SharePlaySession`, `SharePlayStateChannel`) except `SharedFrame` and `ImmersiveSpaceCoordinator`. Alternatives: `UntoldGroupPlay`; `UntoldMultiplayer` is better kept for #1243's full layer. **Decided 2026-10-28:** `UntoldSharePlay`.
- **D3 No engine dependency in the core.** Yes: product 1 imports GroupActivities, SwiftUI, simd and Spatial only.
- **D4 The game declares its activity.** Yes; the plugin ships none, the template writes it.
- **D5 Host election in the plugin.** Yes, as a policy, default `.none`; Oche's lowest-id rule is the first policy. Seats and spectators stay in the game.
- **D6 The manual calibration moves in.** Yes: the solver, the nudge, the settle timer and the frame-sync message become generic; the game supplies the two points and headings.
- **D7 The space coordinator is in the core.** Yes, since RealityKit apps open and dismiss their space on the group signal too; the engine teardown report comes through the XR bridge, a RealityView app calls `spaceDidTearDown` from its `onDisappear`.
- **D8 Minimum OS.** The package minimums follow the engine (visionOS 2, iOS 17, macOS 14); the visionOS 26 API (nearby flag, remote states, `pose`, shared anchors) behind `#available`, reported as unavailable below; the system coordinator parts `#if os(visionOS)`; iOS and macOS compile for the tests and for a future Mac or iPhone participant.
- **D9 Order after stage 2.** CoolSaber (stage 3) and Oche R6 (stage 4) can run in parallel in their own sessions, since Oche needs only the core; recommended, so the shipping product is not queued behind the demo.

## 5. Risks

- **Verification needs two headsets** for everything the system does (nearby, Personas, the displacement); the loopback transport covers the logic, not the system. Stage 3's gate is the first real one.
- **CoolSaber's spatial sync is still in flux** (uncommitted, headset findings pending): the frame's precedence and the anchor path are taken from it as verified, not as written. Stage 2 builds the frame; stage 3 waits for the saber session's verdict before freezing it.
- **GroupActivities differs per platform**: no `SystemCoordinator`, no nearby flag on macOS; `#if` and `#available` guards, with the tests on the Mac exercising the transport seam, not GroupActivities.
- **Rates and sizes**: the plugin cannot raise GroupActivities' limits; it keeps state messages small, meters bytes per second per channel in the diagnostics, and sends snapshots as events.
- **SwiftPM clones the engine for product 1 users**; acceptable for Oche, documented in the README; a split into two packages is the way out if it ever matters.
- **Swift 6**: the lock-guarded classes are `@unchecked Sendable` by design (the frame path), reviewed once in stage 1.

## 6. Progress

- **2026-10-28, stage 1 built.** Repository https://github.com/miolabs/UntoldSharePlay (private until the user opens it; default branch `develop`, MIT, a `swift test` workflow), local checkout `Untold/UntoldSharePlay` on `develop` and the worktree `Untold/UntoldSharePlay-core` on `feature/shareplay_core` = PR miolabs/UntoldSharePlay#1 (open): the transport seam (`SharePlayTransport`, `SharePlayTransportSession`, `SharePlayTransportChannel`), the GroupActivities transport (sessions, two messengers made before the join, the system coordinator on visionOS with `localParticipantStates`, `remoteParticipantStates` and `groupImmersionStyle`, `isNearbyWithLocalParticipant`), the loopback transport (a hub of in-process participants with loss, reordering and delay), the wire frame (16-byte little-endian header plus the payload), `SharePlayStateChannel` and `SharePlayEventChannel` with the router, `SharePlaySession` (state, participants in join order, host election, spatial flags, group immersion, the pump, event handlers), `HostElection`, `SharePlayDiagnostics`, `SharePlayStatusView`; 26 tests on macOS through the loopback (wire frame, channels, election, the hub, two sessions joining, exchanging, electing, leaving, being invalidated, spatial reports, reordered frames dropped as stale). Compiles for the visionOS and iOS simulators. Two design calls that differ from section 2: channels may be registered at any time (the two transport messengers exist before the join, which is what lesson 1 needs; a channel is only an id the router dispatches on), and events are delivered through handlers added to the session rather than one `AsyncStream` (several listeners, no single-consumer trap). Not in stage 1, as planned: the shared frame, the coordinator, the XR bridge, the example app.

- **2026-10-28, stage 2 built** on `feature/shareplay_frame` (worktree `Untold/UntoldSharePlay-frame`, stacked on stage 1; PR miolabs/UntoldSharePlay#2, open, to `feature/shareplay_core` until #1 merges): `SharedFrame` (the system's displacement, per-participant shared anchors, the manual calibration with `yawAlignedFrame` moved in from CoolSaber, the nudge with its 0.3 s settle and re-send, the fallback stage with seats in join order, the precedence manual > shared anchor > system displacement > fallback, the conversions), `SharedAnchorTracker` behind a four-method `SharePlayWorldAnchorHost` protocol (own anchor placed when someone nearby is in the session, its id announced on the session's own frame channel, remote anchors attributed by announcement or by the single-nearby rule, removal told), `ImmersiveSpaceCoordinator` (CoolSaber's phase machine with closures for the SwiftUI actions, `tracksTeardown` for RealityView spaces), `session.drive(coordinator)`, the session's frame channel (`frameSync`, `sharedAnchor`, `sharedAnchorRemoved`), tick handlers, and `.sharePlayFrame(session)` on a `CompositorContent` (visionOS 26, where `CompositorContent` first exists); the `SharedCube` example (`Examples/SharedCube`, XcodeGen, visionOS 26: each participant's head as a cube, the Sync button and the nudge sliders in the window). 50 tests on macOS (24 new: the frame's precedence and conversions, the solver, the nudge, the tracker with a fake host, the coordinator's deferred open, retry, empty-space recovery, join cycle and session driving, two sessions calibrating over the loopback with inverse mappings, seats, anchors announced and attributed across sessions). **A finding that changes the plan:** the engine's shared world-anchor API (`UntoldEngineXRWorldAnchors.swift`, `addWorldAnchor(sharedWithNearbyParticipants:)`, the observer) exists only as uncommitted work in the main engine folder (the saber session's), not in the fork's or upstream's `develop`; so the package stays engine-free and the `UntoldSharePlayXR` product (the engine's conformance to the host protocol, about 20 lines) waits for that API to ship as an engine PR. The anchor logic itself is in the core and tested with a fake host.

- **2026-10-28, PRs #1 and #2 merged** into `develop` of miolabs/UntoldSharePlay after the user's review (develop `3dca0c4`); the main checkout `Untold/UntoldSharePlay` is on it.
- **2026-10-28, stage 5 built** on the engine branch `feature/create_shareplay` (worktree `Untold/UntoldEngine-shareplay`, from the fork's `develop` `041eec6b`; fork PR miolabs/UntoldEngine#86, open, since the plugin lives on miolabs): `untoldengine create --shareplay` adds, on the visionOS target only, the `UntoldSharePlay` package and product, the `com.apple.developer.group-session` entitlement (XcodeGen writes the file from `properties`), `<Project>Activity.swift` (identifier `<bundle id>.session`), and in the app template a `SharePlayModel` (the session with `.sideBySide` and the group immersive space, the coordinator, `session.drive`), the status row and the space's phase in the window, the Start Experience button through the coordinator (an on/off placeholder: the plain `openImmersiveSpace` stays without the flag), the engine's teardown reported (`shutdownUntoldEngineXR` then `spaceDidTearDown`, which the plain template never did), `spaceDidStart(rendering:)` on both branches, `.sharePlayFrame(session)` on the layer, a hint in `GameScene.update` and a README line; the flag raises a lower `--visionos-version` to 26 with a note (`VisionOSVersion.sharePlayMinimum`, `supportsSharePlay`), and `BuildSystem.build` refuses SharePlay without a visionOS target at 26 (`BuildError.invalidSettings`). `BuildSettings.includesSharePlay` and `sharePlayPackage` (default `EnginePackageReference.sharePlayDevelop` = miolabs develop; the upstream URL once the plugin moves). Docs: `docs/API/UsingSharePlay.md` (getting started: the flag, send and receive, who is here, the space and the group, the example), the mkdocs nav and `docs/index.md` after Jolt, the `--shareplay` row in `UsingUntoldEngineCLI.md`. Verified: 10 new tests in `BuildSystemSharePlayTests` (the spec for visionOS and multi, the package override, macOS and iOS untouched, the validation, the app, scene and README templates on and off, the activity path, a generated project on disk) plus the code-components tests still green; the CLI built from the worktree lists the flag; a project generated with it (plugin pointed at the local checkout, engine from upstream develop) builds for the visionOS simulator. The presenter spike's own controller is left as it is (a throwaway spike).

- **2026-10-28, the gate before stage 6 (the user):** the plugin is tested on the headset before the editor phase, and the repository is public so Harold can test it. Done: `miolabs/UntoldSharePlay` is PUBLIC; `Examples/SharedCube` builds for a real Vision Pro (unsigned) and for the simulator; the headset test protocol is in `Examples/SharedCube/README.md` (branch `docs/sharedcube_headset_test`, a docs PR to `develop`): A nearby in one room (join, the space cycling, the system displacement or the manual sync and its nudges, leave and rejoin), B remote over FaceTime with spatial Personas (the system frame, the cube at the Persona's head), C alone (not available, open and close twice); what to report (the `[SharePlay]` logs of both devices, the alignment lines, the cube's distance from the head before and after the sync). Known gaps for the test: no shared world anchors until the engine's API ships (`anchors: no anchor host`), no Persona inside the engine's space (the presenter plan). Stage order from here: the headset test, then stage 3 (CoolSaber, once the anchor API is in), stage 6 (the editor plugin) after the headset verdict.

- **2026-10-28/29, the headset test loop, rows A and B1 passed.** Six nearby runs and two FaceTime runs on two Vision Pros, iterated in one worktree the user builds from (`Untold/UntoldSharePlay-headset`, branch `feature/headset_test`; the PR, miolabs/UntoldSharePlay#5, opened only after the nearby pass, as the user asked). What the headsets taught, now in the plugin: (1) the first crash was a main-actor read of the session from the render thread (the example copies what the game loop needs into a lock-guarded object); (2) the space never reopened because `shutdownUntoldEngineXR`'s completion fires from a finalize pass that never runs once `runLoop` has returned, so the example (and the stage 5 template) release the engine synchronously after the loop; (3) a sync that asks both players to stand on one spot is physically wrong (two heads cannot share it): one player marks a spot and steps aside, the other stands on it and syncs, the solved alignment is installed on one side and its inverse sent to the other, the nudge sliders are that one alignment seen from both sides; (4) in a Compositor Services space the system never moves the space (`immersiveSpaceDisplacement` stays identity) and `spatial` flickers at the open, but the system coordinator's participant pose *is* delivered there: a floor-level pose (position and heading, no height), which nearby tracks the device as the person moves and over FaceTime is the seat the spatial template gave the device ((-0.70, 0, 0.92) yaw 111° and its mirror for the conversational template), reset when the group's space opens; (5) the shared world anchors did not cross on any run, and the engine's world-anchor API is still uncommitted work in the main engine folder, so in the example they are an opt-in build flag and the example builds from the fork's develop. The frame as it stands: every device publishes poses in its own local frame as they are and announces its placement in the group's frame on the frame channel (from a displacement the system applied when it moved the space, else from the system pose paired once, on the floor, with the device pose of the moment; a later head movement never moves the placement; a new pairing replaces the old only for a real change made while the head is still); the receiver composes the two placements; precedence manual > shared anchor > system placements > fallback stage; anchor alignments are handed to the other side as a sync. Results: A.3 (nearby) both cubes on the heads with no manual step (2026-10-28); B1 (FaceTime, the cube in our own render) the cube at the template's seat (2026-10-29), after one failed run where the identity displacement had locked the placement. Left: C (alone), B2 (the cube on the spatial Persona, needs the RealityKit presenter), and the user's review of PR #5. Stage 6 can start.

- **2026-10-28, the first headset runs (the user, nearby):** two findings, both the example's and the template's, not the plugin's. (1) The game read the session from the render thread through `MainActor.assumeIsolated`: an assertion on the first frame, no cube; fixed (the participant list copied into the lock-guarded controls on the main actor). (2) After the join cycled the space it never reopened: the example waited for `shutdownUntoldEngineXR`'s completion, which fires from a frame's finalize pass, and no frame runs once `runLoop()` has returned, so a game with entities never gets it (CoolSaber has no entities, which is why it never saw this; CoolBowling already releases synchronously). Fixed in the example and in the `--shareplay` template: stop, clear the spatial input, `destroyAllEntities()` without a completion, drop the references, then `spaceDidTearDown()`. Verified in the simulator with `--cycle-space` (dismiss, teardown, reopen, the engine starting twice). Testing now runs in one worktree (`UntoldSharePlay-headset`, branch `feature/headset_test`) the user builds from, with a PR only when the whole protocol passes (the user's rule). Still unverified: the participants (the Sync button stayed disabled on the first run, with no "participant joined" line before the user left, and no log from the second device yet).

- **2026-10-28, the third headset run, both devices' logs:** the session works on the headsets: the join, the cycle and reopen, both devices seeing each other as nearby, the frame-sync exchange in both directions. Two findings for the design. (1) The system reports the device as not spatial as soon as the Metal space opens, and leaves the displacement at identity for nearby participants: a Compositor Services space is never seated by the system, so nearby alignment is the manual sync until the engine's shared world anchors are in (section 2.2's precedence stands; the `systemDisplacement` source is for RealityView spaces and, perhaps, FaceTime). (2) A sync to the other player's live head pose is physically wrong (two heads cannot share a spot; the logs show offsets of a head's distance, different per tap): the frame channel now carries marks, one player marks a spot and steps aside, the other stands on it facing the same way and calibrates to the mark; the point-and-heading overload stays for CoolSaber's controllers. The user's flow preference, join everyone first and then open the space, is the plugin's default now (`drive` opens nothing on the join or on the group's request; an open space is still cycled; `opensOnRequest:` restores the automatic open). The sliders remain one alignment seen from both sides. On the headset test branch, not yet a PR.

## 7. References

- CoolSaber: `UntoldArcade/CoolSaber/Examples/CoolSaberVisionOS/CoolSaberVisionOS/visionOS/` on `feature/saber_spatial_sync` (`SaberActivity.swift`, `SaberSessionController.swift`, `CoolSaberVisionOSXRApp.swift`, `SaberXRGame.swift`), `Sources/CoolSaber/CoolSaberNet.swift`, `CoolSaberMath.swift`.
- The spike: `UntoldArcade/Spikes/RealityKitPresenter/Sources/RealityKitPresenter/SharePlay/`.
- Oche: `docs/PLAN.md` §3 and §8, `docs/IMPLEMENTATION.md` §4.8 and §8, `docs/REALITYKIT.md` §4 and §5; `Packages/OcheRules/Sources/OcheRules/Sync/`.
- Engine: `Sources/UntoldEngineXR/UntoldEngineXRWorldAnchors.swift`, `Sources/UntoldEngine/BuildSystem/BuildTemplates.swift`, `docs/Extensions/PluginAuthoringGuidelines.md`, `docs/API/UsingJoltPhysicsXR.md`, `docs/proposals/SpatialPersonasResearch.md`, `docs/proposals/XRRealityKitPresenter.md`.
- Issues: untoldengine/UntoldEngine#1243 (multiplayer), #1371 (the presenter).
- Apple: GroupActivities (`GroupSession`, `GroupSessionMessenger`, `SystemCoordinator`, `Participant.isNearbyWithLocalParticipant`, `ParticipantState.pose`, `remoteParticipantStates`, all in the XROS 27.0 SDK interface), SwiftUI `immersiveSpaceDisplacement` and `onWorldRecenter`, the `_GroupActivities_SwiftUI` overlay (`groupImmersionStyle`, `groupActivityAssociation`); the sample "Implementing SharePlay for immersive spaces in visionOS"; WWDC23 10087, WWDC25 318; forum threads 791591 and 801420.
