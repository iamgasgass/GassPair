import SwiftUI

@main
struct GassPairApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                PairingController.shared.appBecameActive()
            }
        }
    }
}
