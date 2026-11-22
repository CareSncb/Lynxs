import Foundation

/// Réglages partagés (lus par les services, modifiés via @AppStorage dans les vues).
enum Prefs {
    private static var d: UserDefaults { .standard }
    private static func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    static var gpsEnabled: Bool { bool("gpsEnabled", true) }
    static var autoTrips: Bool { bool("autoTrips", true) }
    static var voiceEnabled: Bool { bool("voiceEnabled", false) }
    static var voiceInterval: Int { d.object(forKey: "voiceInterval") as? Int ?? 5 }   // minutes
    static var voiceBattery: Bool { bool("voiceBattery", true) }
    static var voicePWM: Bool { bool("voicePWM", true) }
    static var fallDetection: Bool { bool("fallDetection", false) }
    static var emergencyPhone: String { d.string(forKey: "emergencyPhone") ?? "" }
    static var ntfyTopic: String { d.string(forKey: "ntfyTopic") ?? "" }
    static var liveActivity: Bool { bool("liveActivity", true) }
    static var watchPWMAlerts: Bool { bool("watchPWMAlerts", true) }
}

/// Distribue chaque trame de télémétrie aux services de l'appli (appelé sur le thread principal).
final class TelemetryHub {
    static let shared = TelemetryHub()

    func ingest(_ d: WheelData, manager: BLEManager) {
        TripRecorder.shared.ingest(d, wheelName: manager.connectedName ?? "Roue")
        SafetyMonitor.shared.ingest(d, manager: manager)
        VoiceAnnouncer.shared.ingest(d, manager: manager)
        LiveActivityController.shared.update(d, manager: manager)
        PhoneWatchBridge.shared.pushLive(d, manager: manager)
        BatteryTest.shared.ingest(d)
    }

    func wheelDisconnected() {
        TripRecorder.shared.wheelDisconnected()
        SafetyMonitor.shared.wheelDisconnected()
        LiveActivityController.shared.end()
        PhoneWatchBridge.shared.pushDisconnected()
    }
}
