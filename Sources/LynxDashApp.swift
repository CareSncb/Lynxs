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
                .onOpenURL { url in
                    // lynxdash://brider · lynxdash://debrider · lynxdash://basculer
                    Task { @MainActor in
                        let ble = BLEManager.shared
                        switch url.host ?? "" {
                        case "brider":
                            let o = await ble.engageLimiter()
                            ble.limiterMessage = o.message(for: .engage)
                        case "debrider":
                            let o = await ble.releaseLimiter()
                            ble.limiterMessage = o.message(for: .release)
                        case "basculer", "toggle":
                            ble.limiterMessage = await LimiterToggle.run()
                        default:
                            break
                        }
                    }
                }
        }
    }
}
