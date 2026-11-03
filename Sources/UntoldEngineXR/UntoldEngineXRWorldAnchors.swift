//
//  UntoldEngineXRWorldAnchors.swift
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// World anchors for games rendering through UntoldEngineXR. The engine owns
// the ARKit WorldTrackingProvider (and recreates it on every provider run),
// so a game cannot add anchors to it directly. This file lets a game request
// anchors — including ones shared with nearby SharePlay participants, the
// system's way of giving two headsets in one room a common reference — and
// observe every anchor update the provider reports, across provider restarts.
//

#if os(visionOS)
    import Foundation
    import simd
    #if canImport(ARKit)
        import ARKit
    #endif

    /// One change to a world anchor, as reported by ARKit.
    public struct XRWorldAnchorUpdate: Sendable {
        public enum Event: Sendable {
            case added
            case updated
            case removed
        }

        /// ARKit's identifier for the anchor. A shared anchor keeps its
        /// identifier on every participant's device.
        public let id: UUID
        /// The anchor's pose in this device's ARKit world frame.
        public let originFromAnchorTransform: simd_float4x4
        public let isTracked: Bool
        /// True for anchors shared between nearby SharePlay participants —
        /// this device's own as well as the ones received from others.
        public let isSharedWithNearbyParticipants: Bool
        /// True when this device requested the anchor through `addWorldAnchor`.
        /// A shared anchor that is not ours came from another participant.
        public let isOwn: Bool
        public let event: Event
    }

    /// Lock-guarded book-keeping behind the public world-anchor API.
    final class XRWorldAnchorStore: @unchecked Sendable {
        struct Request {
            var originFromAnchorTransform: simd_float4x4
            var sharedWithNearbyParticipants: Bool
            #if canImport(ARKit)
                var anchor: WorldAnchor?
            #endif
        }

        private let lock = NSLock()
        private var requests: [UUID: Request] = [:]
        private var observers: [UUID: @Sendable (XRWorldAnchorUpdate) -> Void] = [:]
        /// Anchors already handed to the current provider instance.
        private var installed: Set<UUID> = []
        private var installedProvider: ObjectIdentifier?

        func addRequest(_ request: Request) -> UUID {
            let handle = UUID()
            lock.withLock { requests[handle] = request }
            return handle
        }

        func removeRequest(_ handle: UUID) -> Request? {
            lock.withLock { requests.removeValue(forKey: handle) }
        }

        func request(_ handle: UUID) -> Request? {
            lock.withLock { requests[handle] }
        }

        func update(_ handle: UUID, _ body: (inout Request) -> Void) {
            lock.withLock {
                guard var request = requests[handle] else { return }
                body(&request)
                requests[handle] = request
            }
        }

        var handles: [UUID] {
            lock.withLock { Array(requests.keys) }
        }

        #if canImport(ARKit)
            /// ARKit ids of the anchors this device requested.
            var ownAnchorIDs: Set<UUID> {
                lock.withLock { Set(requests.values.compactMap { $0.anchor?.id }) }
            }

            /// Marks the anchor as handed to `provider`; false if it already was.
            func markInstalled(_ anchorID: UUID, in provider: WorldTrackingProvider) -> Bool {
                lock.withLock {
                    let token = ObjectIdentifier(provider)
                    if installedProvider != token {
                        installedProvider = token
                        installed.removeAll()
                    }
                    return installed.insert(anchorID).inserted
                }
            }

            func unmarkInstalled(_ anchorID: UUID) {
                lock.withLock { _ = installed.remove(anchorID) }
            }
        #endif

        func addObserver(_ handler: @escaping @Sendable (XRWorldAnchorUpdate) -> Void) -> UUID {
            let id = UUID()
            lock.withLock { observers[id] = handler }
            return id
        }

        func removeObserver(_ id: UUID) {
            lock.withLock { _ = observers.removeValue(forKey: id) }
        }

        func notify(_ update: XRWorldAnchorUpdate) {
            let handlers = lock.withLock { Array(observers.values) }
            for handler in handlers { handler(update) }
        }
    }

    public extension UntoldEngineXR {
        /// Asks ARKit to track a world anchor at `originFromAnchorTransform`
        /// (this device's ARKit world frame). With `sharedWithNearbyParticipants`
        /// the anchor is also delivered, during a SharePlay session, to every
        /// participant in the same room, in *their* ARKit frame — so its
        /// transform on the other device maps this device's frame into theirs.
        ///
        /// The anchor is installed as soon as world tracking runs and
        /// re-installed after every provider restart, until `removeWorldAnchor`.
        /// - Returns: a handle for `removeWorldAnchor`, or nil without ARKit.
        @discardableResult
        func addWorldAnchor(
            originFromAnchorTransform: simd_float4x4 = matrix_identity_float4x4,
            sharedWithNearbyParticipants: Bool = false
        ) -> UUID? {
            #if canImport(ARKit)
                let handle = worldAnchorStore.addRequest(XRWorldAnchorStore.Request(
                    originFromAnchorTransform: originFromAnchorTransform,
                    sharedWithNearbyParticipants: sharedWithNearbyParticipants,
                    anchor: nil
                ))
                let provider = currentWorldTracking()
                if provider.state == .running {
                    Task { await self.installRequestedWorldAnchors(into: provider) }
                }
                return handle
            #else
                _ = (originFromAnchorTransform, sharedWithNearbyParticipants)
                return nil
            #endif
        }

        /// Stops tracking (and sharing) an anchor added with `addWorldAnchor`.
        func removeWorldAnchor(_ handle: UUID) {
            #if canImport(ARKit)
                guard let request = worldAnchorStore.removeRequest(handle), let anchor = request.anchor else { return }
                worldAnchorStore.unmarkInstalled(anchor.id)
                let provider = currentWorldTracking()
                guard provider.state == .running else { return }
                Task {
                    do {
                        try await provider.removeAnchor(anchor)
                        print("XR world anchor removed: id=\(anchor.id)")
                    } catch {
                        print("⚠️ XR world anchor remove failed: id=\(anchor.id), error=\(error)")
                    }
                }
            #else
                _ = handle
            #endif
        }

        /// Receives every world-anchor update ARKit reports — own anchors and
        /// the ones shared by nearby participants — on an arbitrary thread.
        /// - Returns: an id for `removeWorldAnchorObserver`.
        func addWorldAnchorObserver(_ handler: @escaping @Sendable (XRWorldAnchorUpdate) -> Void) -> UUID {
            worldAnchorStore.addObserver(handler)
        }

        func removeWorldAnchorObserver(_ id: UUID) {
            worldAnchorStore.removeObserver(id)
        }
    }

    #if canImport(ARKit)
        extension UntoldEngineXR {
            /// Hands every requested anchor to `provider` once. An anchor that a
            /// previous provider already knew is re-created with the same pose,
            /// since an anchor instance belongs to the provider that added it.
            func installRequestedWorldAnchors(into provider: WorldTrackingProvider) async {
                for handle in worldAnchorStore.handles {
                    guard let request = worldAnchorStore.request(handle) else { continue }
                    let anchor: WorldAnchor
                    if let existing = request.anchor, worldAnchorStore.markInstalled(existing.id, in: provider) {
                        anchor = existing
                    } else if request.anchor == nil {
                        anchor = Self.makeWorldAnchor(request)
                        worldAnchorStore.update(handle) { $0.anchor = anchor }
                        guard worldAnchorStore.markInstalled(anchor.id, in: provider) else { continue }
                    } else {
                        continue // already installed in this provider
                    }

                    do {
                        try await provider.addAnchor(anchor)
                        print("XR world anchor installed: id=\(anchor.id), shared=\(request.sharedWithNearbyParticipants)")
                    } catch {
                        // Typical after a provider restart: the old instance is
                        // refused. Re-create once with the same pose.
                        worldAnchorStore.unmarkInstalled(anchor.id)
                        let fresh = Self.makeWorldAnchor(request)
                        worldAnchorStore.update(handle) { $0.anchor = fresh }
                        guard worldAnchorStore.markInstalled(fresh.id, in: provider) else { continue }
                        do {
                            try await provider.addAnchor(fresh)
                            print("XR world anchor re-created: id=\(fresh.id) (was \(anchor.id)), shared=\(request.sharedWithNearbyParticipants), after: \(error)")
                        } catch {
                            worldAnchorStore.unmarkInstalled(fresh.id)
                            print("⚠️ XR world anchor add failed: id=\(fresh.id), shared=\(request.sharedWithNearbyParticipants), error=\(error)")
                        }
                    }
                }
            }

            private static func makeWorldAnchor(_ request: XRWorldAnchorStore.Request) -> WorldAnchor {
                if #available(visionOS 26.0, *) {
                    return WorldAnchor(
                        originFromAnchorTransform: request.originFromAnchorTransform,
                        sharedWithNearbyParticipants: request.sharedWithNearbyParticipants
                    )
                }
                return WorldAnchor(originFromAnchorTransform: request.originFromAnchorTransform)
            }

            /// Forwards the provider's anchor stream to the observers. Restarted
            /// for every provider instance, before it runs.
            func restartWorldAnchorMonitor(with provider: WorldTrackingProvider) {
                worldAnchorMonitorTask?.cancel()
                let store = worldAnchorStore
                worldAnchorMonitorTask = Task(priority: .utility) {
                    for await update in provider.anchorUpdates {
                        if Task.isCancelled { break }
                        let anchor = update.anchor
                        let event: XRWorldAnchorUpdate.Event
                        switch update.event {
                        case .added: event = .added
                        case .updated: event = .updated
                        case .removed: event = .removed
                        @unknown default: event = .updated
                        }
                        let shared: Bool
                        if #available(visionOS 26.0, *) {
                            shared = anchor.isSharedWithNearbyParticipants
                        } else {
                            shared = false
                        }
                        store.notify(XRWorldAnchorUpdate(
                            id: anchor.id,
                            originFromAnchorTransform: anchor.originFromAnchorTransform,
                            isTracked: anchor.isTracked,
                            isSharedWithNearbyParticipants: shared,
                            isOwn: store.ownAnchorIDs.contains(anchor.id),
                            event: event
                        ))
                    }
                }
            }
        }
    #endif
#endif
