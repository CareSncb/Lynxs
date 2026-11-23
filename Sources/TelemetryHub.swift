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
    static var workshopMode: Bool { bool("workshopMode", false) }
    /// Télécommande Apple Watch via l'écran « À l'écoute » (sans app montre).
    static var watchRemote: Bool { bool("watchRemote", true) }
    /// Notification avec boutons Brider / Débrider à la connexion (visible sur la montre).
    static var limiterNotification: Bool { bool("limiterNotification", true) }
    /// Notification météo à la connexion de la roue.
    static var weatherAlerts: Bool { bool("weatherAlerts", true) }
    /// Marge de sécurité mini avant les bips (%, 0 = désactivée).
    static var marginAlarm: Double { d.object(forKey: "marginAlarm") as? Double ?? 20 }
    /// Vitesse max à vide batterie pleine (km/h), pour estimer la marge sans PWM.
    static var topSpeedAtFull: Double { d.object(forKey: "topSpeedAtFull") as? Double ?? 0 }
    /// Bips progressifs générés (sinon son système).
    static var alarmBeeps: Bool { bool("alarmBeeps", true) }
    /// Courant moyen sur 15 s déclenchant l'alarme de charge prolongée (A, 0 = désactivée).
    static var currentAlarm: Double { d.object(forKey: "currentAlarm") as? Double ?? 0 }
    static var autoLight: Bool { bool("autoLight", false) }
    static var engineSound: Bool { bool("engineSound", false) }
    static var engineStyle: String { d.string(forKey: "engineStyle") ?? EngineSound.Style.electric.rawValue }
    static var engineVolume: Double { d.object(forKey: "engineVolume") as? Double ?? 0.6 }
    static var kwhPrice: Double { d.object(forKey: "kwhPrice") as? Double ?? 0.35 }
    static var batteryWh: Double { d.object(forKey: "batteryWh") as? Double ?? 0 }
    static var storageReminder: Bool { bool("storageReminder", true) }
}

/// Distribue chaque trame de télémétrie aux services de l'appli (appelé sur le thread principal).
final class TelemetryHub {
    static let shared = TelemetryHub()

    private var sessionStarted = false

    func ingest(_ d: WheelData, manager: BLEManager) {
        if !sessionStarted {
            sessionStarted = true
            RideWeather.shared.wheelConnected()
            ChargeAssistant.shared.wheelConnected(name: manager.connectedName)
            Leaderboard.shared.publishMyStats()
        }
        BlackBox.shared.ingest(d, manager: manager)
        BatteryHealth.shared.ingest(d, manager: manager)
        SafetyAlarms.shared.ingest(d, manager: manager)
        ChargeAssistant.shared.ingest(d)
        AutoLight.shared.ingest(manager: manager)
        EngineSound.shared.ingest(d, manager: manager)
        TripRecorder.shared.ingest(d, wheelName: manager.connectedName ?? "Roue")
        SafetyMonitor.shared.ingest(d, manager: manager)
        VoiceAnnouncer.shared.ingest(d, manager: manager)
        LiveActivityController.shared.update(d, manager: manager)
        PhoneWatchBridge.shared.pushLive(d, manager: manager)
        BatteryTest.shared.ingest(d)
        WheelMonitors.shared.ingest(d, manager: manager)
        WidgetBridge.shared.update(d, manager: manager)
        WatchRemote.shared.start()
        WatchRemote.shared.refresh()
        LimiterNotification.shared.connected(manager: manager)
    }

    func wheelDisconnected() {
        sessionStarted = false
        BlackBox.shared.wheelDisconnected()
        BatteryHealth.shared.wheelDisconnected()
        let ble = BLEManager.shared
        WheelFinder.wheelDisconnected(name: ble.connectedName, battery: ble.data.batteryPercent)
        ChargeAssistant.shared.wheelDisconnected(name: ble.connectedName, battery: ble.data.batteryPercent)
        SafetyAlarms.shared.wheelDisconnected()
        AutoLight.shared.wheelDisconnected()
        EngineSound.shared.wheelDisconnected()
        TripRecorder.shared.wheelDisconnected()
        SafetyMonitor.shared.wheelDisconnected()
        LiveActivityController.shared.end()
        PhoneWatchBridge.shared.pushDisconnected()
        WidgetBridge.shared.disconnected()
        WatchRemote.shared.stop()
        LimiterNotification.shared.disconnected()
    }
}
