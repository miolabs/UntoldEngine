//
//  UntoldXRPresenterView.swift
//  UntoldEngineXRRealityKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(visionOS)
    import Metal
    import RealityKit
    import SwiftUI
    import UntoldEngine
    import UntoldEngineXR

    /// The engine presented by RealityKit: what a game puts in its `ImmersiveSpace` instead of a
    /// `CompositorLayer` when it wants the system's space (Spatial Personas in a SharePlay session,
    /// native entities, SwiftUI attachments). It builds the presenter and the engine on the
    /// headset's runtime, hands the engine to the game once (`onReady`: the callbacks, the scene),
    /// runs the engine's loop on a thread of its own, posts the presenter's tickets from the
    /// RealityKit frame, and forwards the space's pinches to the engine. On disappearing it ends
    /// the loop and shuts the engine down as the compositor apps do.
    @available(visionOS 2.0, *)
    public struct UntoldXRPresenterView: View {
        private let configuration: XRRealityKitPresenterConfiguration
        private let immersionMode: XRImmersionMode
        private let onReady: @MainActor (UntoldEngineXR, XRRealityKitPresenter) -> Void
        private let onShutdown: (@MainActor () -> Void)?
        @State private var session = XRPresenterSession()

        /// - Parameters:
        ///   - configuration: the presenter's sizes, frustum, lead and depth rules.
        ///   - immersionMode: what the engine writes where nothing is drawn: `.mixed` leaves the
        ///     passthrough, `.full` black. The space's own `immersionStyle` is the game's to set.
        ///   - onReady: the engine and the presenter, once, before the loop starts: install the
        ///     game's callbacks and build the scene here, and keep the references if the game needs
        ///     them (the presenter for its statistics).
        ///   - onShutdown: after the engine is shut down, as the view disappears.
        public init(
            configuration: XRRealityKitPresenterConfiguration = .init(),
            immersionMode: XRImmersionMode = .mixed,
            onReady: @escaping @MainActor (UntoldEngineXR, XRRealityKitPresenter) -> Void,
            onShutdown: (@MainActor () -> Void)? = nil
        ) {
            self.configuration = configuration
            self.immersionMode = immersionMode
            self.onReady = onReady
            self.onShutdown = onShutdown
        }

        public var body: some View {
            RealityView { content in
                await session.open(in: content, configuration: configuration, immersionMode: immersionMode, onReady: onReady)
            }
            .gesture(
                SpatialEventGesture(coordinateSpace: .immersiveSpace)
                    .onChanged { events in session.runtime?.enqueueSpatialEvents(events) }
                    .onEnded { events in session.runtime?.enqueueSpatialEvents(events) }
            )
            .onDisappear {
                session.close()
                onShutdown?()
            }
        }
    }

    /// What the view holds while it is on: the presenter, the runtime, the engine, the update
    /// subscription and the loop's thread.
    @available(visionOS 2.0, *)
    @MainActor
    final class XRPresenterSession {
        private(set) var presenter: XRRealityKitPresenter?
        private(set) var runtime: XRRuntime?
        private(set) var xr: UntoldEngineXR?
        private var subscription: RealityKit.EventSubscription?
        private var thread: Thread?

        func open(
            in content: RealityViewContent,
            configuration: XRRealityKitPresenterConfiguration,
            immersionMode: XRImmersionMode,
            onReady: @MainActor (UntoldEngineXR, XRRealityKitPresenter) -> Void
        ) async {
            guard xr == nil else { return }
            guard let device = MTLCreateSystemDefaultDevice() else {
                Logger.logWarning(message: "XR presenter: no Metal device")
                return
            }
            do {
                let presenter = try await XRRealityKitPresenter(device: device, configuration: configuration)
                let runtime = XRRuntime()
                let source = RealityKitFrameSource(presenter: presenter, runtime: runtime)
                guard let xr = UntoldEngineXR(frameSource: source, runtime: runtime, device: device) else {
                    Logger.logWarning(message: "XR presenter: the engine could not be created")
                    return
                }
                xr.setImmersionMode(xrImmersionMode: immersionMode)
                content.add(presenter.root)
                let inputTarget = try await XRPresenterInput.makeTargetEntity(radius: configuration.inputTargetRadius)
                content.add(inputTarget)
                self.presenter = presenter
                self.runtime = runtime
                self.xr = xr

                onReady(xr, presenter)

                // The engine's queue exists once the engine does.
                presenter.start(commandQueue: renderInfo.commandQueue)
                subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                    MainActor.assumeIsolated {
                        presenter.update()
                    }
                }
                let thread = Thread {
                    xr.start()
                    xr.runLoop()
                }
                thread.name = "Untold XR Render Thread"
                thread.qualityOfService = .userInteractive
                self.thread = thread
                thread.start()
                let foveated = presenter.foveation.map { " through its \($0.profile.rawValue) rate map (screen \($0.screenSize.x)×\($0.screenSize.y))" } ?? ""
                print("XR presenter: running, \(presenter.textureSize.x)×\(presenter.textureSize.y) per eye\(foveated), grids \(presenter.grid.columns)×\(presenter.grid.rows), \(presenter.usesShaderGraphMaterial ? "eye material" : "fallback material")")
            } catch {
                Logger.logWarning(message: "XR presenter: could not be created: \(error)")
            }
        }

        /// Shuts the engine down in one more frame of the loop, then ends the exchange (the
        /// loop's thread ends with it). The engine destroys the world's entities at the start
        /// of a frame and runs the shutdown's completion then; stopping the presenter first
        /// would leave that to the next session's first frame, which would lose its camera.
        func close() {
            subscription?.cancel()
            subscription = nil
            if let xr, let presenter {
                presenter.stop(after: { done in shutdownUntoldEngineXR(xr, completion: done) })
            } else {
                presenter?.stop()
            }
            xr = nil
            runtime = nil
            presenter = nil
            thread = nil
        }
    }
#endif
