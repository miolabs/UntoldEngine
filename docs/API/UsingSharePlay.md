# Getting Started: SharePlay in a visionOS Game

[UntoldSharePlay](https://github.com/miolabs/UntoldSharePlay) gives an engine game
the SharePlay session as one dependency: the group session from a FaceTime call
or with people nearby, typed channels for game state and events, the
participants and an optional host, the shared coordinate frame between
headsets, and the one place that opens and dismisses the immersive space. A
game keeps three things of its own: its `GroupActivity`, its wire types, and
what the messages do.

This is a getting-started page. The plugin's
[integration guide](https://github.com/miolabs/UntoldSharePlay/blob/develop/docs/GettingStarted.md)
walks through a whole game, its [recipes](https://github.com/miolabs/UntoldSharePlay/blob/develop/docs/Recipes.md)
take one task at a time, and its README holds the reference: the channels,
the shared frame's precedence, the calibration, the coordinator and the
lessons it encodes.

## 1. Create a Project With SharePlay

```bash
untoldengine create MyGame --platform visionos --shareplay
```

The flag adds, on the visionOS target only:

- the `UntoldSharePlay` package and product next to the engine;
- the `com.apple.developer.group-session` entitlement;
- `Sources/MyGame/MyGameActivity.swift`, the game's `GroupActivity` (its
  identifier is `<bundle identifier>.session`, what the system matches
  sessions on, so keep it stable);
- in `MyGameApp.swift`: a `SharePlayModel` holding the `SharePlaySession` and
  the `ImmersiveSpaceCoordinator`, the session's status row in the window, the
  Start Experience button going through the coordinator, the engine's teardown
  reported to it, and `.sharePlayFrame(session)` on the `CompositorLayer`.

SharePlay's immersive-space pieces need visionOS 26, so the flag raises a lower
`--visionos-version` and says so. With `--platform multi` the same happens on
the visionOS target; macOS and iOS are untouched.

To add SharePlay to an existing project, copy those four pieces from a freshly
generated one; the package is

```yaml
packages:
  UntoldSharePlay:
    url: https://github.com/miolabs/UntoldSharePlay.git
    branch: develop
```

## 2. Send and Receive

Wire types are plain `Codable`. A **state channel** is unreliable and the
latest message wins per sender (poses, published every frame); an **event
channel** is reliable and in order (hits, throws, snapshots). Both are usable
from the engine's render thread; the session pumps them from the main actor.

```swift
import UntoldSharePlay

struct Poses: Codable, Sendable { var head: simd_float4x4 }
enum GameEvent: Codable, Sendable { case hit(at: SIMD3<Float>) }

// Once, on the main actor (the generated SharePlayModel is the place):
let poses = SharePlayModel.shared.session.stateChannel(Poses.self)
let events = SharePlayModel.shared.session.eventChannel(GameEvent.self)

// Per frame, in GameScene.update, on the render thread:
let frame = SharePlayModel.shared.session.frame
frame.updateDevicePose(headPose) // pairs with the system's pose of this device
poses.publish(Poses(head: headPose)) // our local frame, as it is
for (participant, received) in poses.latestAll() where received.age < 0.5 {
    let local = frame.toLocal(received.message.head, from: participant)
    // place that participant's avatar at `local`
}
for event in events.drain() {
    // event.message, event.sender
}
```

Poses go on the wire in the sender's own local frame, as the engine reports
them. `frame.toLocal(_:from:)` maps a participant's wire pose into this
device's frame through whatever alignment is in force for them: the manual
calibration, their shared world anchor, the system's placements of the two
devices (from the system's pose of each, which `updateDevicePose` pairs with
the device pose), or a fallback stage in front of the player. On two headsets
nearby, or over FaceTime, the system's placements put the other player's
avatar on their head with no manual step.

## 3. Who Is Here

```swift
let session = SharePlayModel.shared.session
session.state              // .idle, .starting, .waiting, .joined
session.participants       // in join order, the local one included: isLocal, isNearby, isSpatial
session.isHost             // with a host election policy, the same answer on every device
session.addEventHandler { event in
    switch event {
    case .participantJoined(let id): /* send the newcomer a snapshot: events.send(snapshot, to: .only([id])) */ break
    case .hostChanged: /* the host re-broadcasts its state */ break
    default: break
    }
}
```

A host-authoritative game sets `$0.hostElection = .lowestParticipantID` when
it makes the session (in `SharePlayModel`), validates events as the host and
broadcasts its state; the other devices apply what the host sends.

## 4. The Space and the Group

The generated `ImmersiveSpaceCoordinator` opens the space when the system asks
for the group immersive space, cycles it on the join (a space opened before
the session joined stays private), and dismisses it when the group leaves its
space. `SharePlaySession.Configuration` chooses the spatial template
(`.sideBySide`, `.conversational`, `.surround`) and whether the group
immersive space is requested at all.

Spatial Personas are drawn by the system around a scene that RealityKit
renders, so a `CompositorLayer` game sees its remote participants only through
what it draws itself from their poses (see the research note in
`docs/proposals/SpatialPersonasResearch.md` and the RealityKit presenter plan).
Nearby participants (visionOS 26) are real people seen through passthrough.
Either way the system's pose of each device aligns the two frames; shared
world anchors add a second alignment once the engine's world-anchor API is in
the plugin.

## 5. Try It

The plugin's `Examples/SharedCube` app shows every participant's head as a
cube, with the calibration and the fine-tune sliders in its window. Two
headsets, or a headset and a FaceTime participant on another Vision Pro, are
needed for a session; the simulator has no SharePlay.

See also: [Spatial Input](UsingSpatialInput.md), [XR Immersion Modes](UsingXRImmersionMode.md).
