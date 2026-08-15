import SwiftUI

/// Peloton CRPE 2027 — macOS / iOS application.
///
/// ## How to read this project
///
/// The app comes in two halves, deliberately sealed off from each other:
///
/// - **`duel-crpe-2027.html`** — all of the domain. The peloton, the rivals,
///   the probability model, the interface, *and* the definition of what an
///   event is (`PROJECTION`). A developer adding a feature works there and
///   nowhere else.
/// - **`Sync/` and `Bridge/`** — a generic synchronization engine that knows
///   nothing about the CRPE. It carries opaque events between devices,
///   through a shared folder (iCloud Drive). It does not change when the
///   domain changes.
///
/// The synchronization principle fits in three sentences:
/// each device writes **only its own file** (so iCloud never has a conflict to
/// arbitrate); the files hold **the history of the actions**, not the final
/// state (so bringing two devices together loses nothing); and a **complete
/// local copy** keeps the app usable offline (so iCloud is nothing but a
/// transport). The details are documented in `Sync/SyncEngine.swift`.
@main
struct PelotonApp: App {

    @Environment(\.scenePhase) private var scenePhase

    /// The bridge and its engine live for as long as the app does.
    @State private var bridge = WebBridge(engine: SyncEngine())

    init() {
        DeviceIdentity.refreshName()
        NotificationScheduler.requestAuthorizationOnce()
    }

    var body: some Scene {
        #if os(macOS)
        // `Window` and not `WindowGroup`: otherwise ⌘N opens a second window,
        // hence a second copy of the page, over the same data.
        Window("Peloton", id: "main") { content }
            .defaultSize(width: 540, height: 880)
        #else
        WindowGroup { content }
        #endif
    }

    private var content: some View {
        ContentView(bridge: bridge)
            .onChange(of: scenePhase, initial: true) { _, phase in
                // In the foreground: watch the folder and read it back right
                // away. In the background: release the watch.
                //
                // Nothing to "flush" or hurry to save when going to sleep —
                // every action was already written the moment it happened.
                bridge.setActive(phase == .active)
            }
    }
}
