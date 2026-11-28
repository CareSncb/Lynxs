import Foundation

/// Exécution, dans l'appli, des boutons du Centre de contrôle.
enum ControlHandler {
    @MainActor
    static func run(_ cmd: ControlCommand) async -> String {
        let ble = BLEManager.shared
        switch cmd {
        case .horn:
            HornPlayer.shared.horn()
            return "Klaxon"
        case .light:
            guard ble.state == .connected else { return "Roue non connectée" }
            let on = !UserDefaults.standard.bool(forKey: "controlLightOn")
            UserDefaults.standard.set(on, forKey: "controlLightOn")
            ble.setLight(on ? .on : .off)
            NotificationCenter.default.post(name: .autoLightChanged, object: on)
            return on ? "Phare allumé" : "Phare éteint"
        case .share:
            let share = LiveShare.shared
            if share.active { share.stop(); return "Partage arrêté" }
            share.start()
            return "Partage démarré"
        }
    }
}
