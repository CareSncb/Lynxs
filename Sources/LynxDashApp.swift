import SwiftUI

@main
struct LynxDashApp: App {
    @StateObject private var ble = BLEManager.shared

    init() {
        PhoneWatchBridge.shared.activate()
        LimiterNotification.shared.activate()
        _ = HelmetTrigger.shared
        ControlActions.handler = { cmd in await ControlHandler.run(cmd) }
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
                        case "pair":
                            if !FleetSync.shared.handlePairLink(url) { ble.limiterMessage = "Lien d'association illisible" }
                        case "rdv":
                            ble.limiterMessage = AppointmentStore.shared.importLink(url)
                                ? "Demande de rendez-vous ajoutée dans le menu atelier ✓"
                                : "Lien de rendez-vous illisible"

                        default:
                            break
                        }
                    }
                }
        }
    }
}
