import Foundation
import WatchConnectivity

/// Reçoit les commandes de l'Apple Watch et y répond avec l'état de la roue.
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    private func status(message: String? = nil) -> [String: Any] {
        let ble = BLEManager.shared
        var reply: [String: Any] = [
            "connected": ble.state == .connected,
            "limited": ble.isLimited,
            "limit": ble.data.speedLimitKnown ? ble.data.speedLimit : -1,
            "speed": abs(ble.data.speed),
            "battery": ble.data.batteryPercent,
            "name": ble.connectedName ?? ""
        ]
        if let message { reply["message"] = message }
        return reply
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let action = message["action"] as? String ?? "status"
        Task { @MainActor in
            let ble = BLEManager.shared
            var text: String?
            switch action {
            case "engage":
                await ble.waitForTelemetry(timeout: 8)
                text = await ble.engageLimiter() ?? "Bridée à 25 km/h"
            case "release":
                await ble.waitForTelemetry(timeout: 8)
                text = await ble.releaseLimiter() ?? "Débridée"
            default:
                break
            }
            replyHandler(self.status(message: text))
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
