import SwiftUI

@main
struct LynxDashApp: App {
    @StateObject private var ble = BLEManager.shared

    init() {
        PhoneWatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
        }
    }
}
