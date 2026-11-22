import Foundation
import WatchConnectivity

/// Pont iPhone ↔ Apple Watch.
/// La roue n'accepte qu'une seule connexion Bluetooth : c'est l'iPhone qui s'y connecte
/// et qui relaie la télémétrie en direct vers la montre.
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()

    private var lastPush = Date.distantPast
    private var lastContext = Date.distantPast

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return nil }
        return s
    }

    private func payload(_ d: WheelData?, manager: BLEManager, message: String? = nil) -> [String: Any] {
        var p: [String: Any] = [
            "type": "live",
            "connected": manager.state == .connected,
            "limited": manager.isLimited,
            "pending": manager.pendingAction?.rawValue ?? "",
            "limit": manager.data.speedLimitKnown ? manager.data.speedLimit : -1,
            "name": manager.connectedName ?? "",
            "pwmAlarm": Prefs.watchPWMAlerts ? manager.pwmAlarm : 0,
            "antiTheft": SafetyMonitor.shared.antiTheftArmed,
            "recording": TripRecorder.shared.isRecording,
            "ts": Date().timeIntervalSince1970
        ]
        if let d {
            p["speed"] = abs(d.speed)
            p["battery"] = d.batteryPercent
            p["voltage"] = d.voltage
            p["pwm"] = d.pwm
            p["hasPWM"] = d.hasPWM
            p["temp"] = d.temperature
            p["trip"] = TripRecorder.shared.currentDistance
        }
        if let message { p["message"] = message }
        return p
    }

    /// Envoi en direct (1 fois par seconde) si la montre est joignable, sinon contexte (toutes les 10 s).
    func pushLive(_ d: WheelData, manager: BLEManager) {
        guard let s = session else { return }
        let now = Date()
        if s.isReachable {
            guard now.timeIntervalSince(lastPush) >= 1 else { return }
            lastPush = now
            s.sendMessage(payload(d, manager: manager), replyHandler: nil, errorHandler: nil)
        } else if now.timeIntervalSince(lastContext) >= 10 {
            lastContext = now
            try? s.updateApplicationContext(payload(d, manager: manager))
        }
    }

    func pushDisconnected() {
        guard let s = session else { return }
        let p = payload(nil, manager: BLEManager.shared)
        if s.isReachable { s.sendMessage(p, replyHandler: nil, errorHandler: nil) }
        try? s.updateApplicationContext(p)
    }

    /// Alerte forte sur la montre (chute, antivol…).
    func sendAlert(_ text: String) {
        guard let s = session else { return }
        let p: [String: Any] = ["type": "alert", "message": text]
        if s.isReachable {
            s.sendMessage(p, replyHandler: nil, errorHandler: nil)
        } else {
            s.transferUserInfo(p)
        }
    }

    @MainActor
    private func handle(action: String) async -> String? {
        let ble = BLEManager.shared
        switch action {
        case "engage":
            await ble.waitForTelemetry(timeout: 8)
            return await ble.engageLimiter().message(for: .engage)
        case "release":
            await ble.waitForTelemetry(timeout: 8)
            return await ble.releaseLimiter().message(for: .release)
        case "cancelPending":
            ble.cancelPending()
            return "Action programmée annulée"
        case "fallOK":
            SafetyMonitor.shared.cancelFallAlert()
            return "Alerte annulée"
        case "stopAlarm":
            SafetyMonitor.shared.stopSiren()
            return "Alarme arrêtée"
        case "light_on":
            ble.setLight(.on); return "Phare allumé"
        case "light_off":
            ble.setLight(.off); return "Phare éteint"
        case "horn":
            SafetyMonitor.shared.horn(); return nil
        default:
            return nil
        }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let action = message["action"] as? String ?? "status"
        Task { @MainActor in
            let text = await self.handle(action: action)
            let ble = BLEManager.shared
            replyHandler(self.payload(ble.framesReceived > 0 ? ble.data : nil, manager: ble, message: text))
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
