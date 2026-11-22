import SwiftUI

@main
struct LynxDashApp: App {
    @StateObject private var ble = BLEManager.shared

    init() {
        PhoneWatchBridge.shared.activate()
        SafetyMonitor.shared.requestNotificationPermission()
        TripRecorder.shared.requestPermission()
        _ = TripStore.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
        }
    }
}
