import Foundation
import UserNotifications

/// Notification « LynxDash connecté » avec les boutons Brider 25 / Débrider.
/// iPhone verrouillé, elle s'affiche sur l'Apple Watch avec ses boutons : l'action
/// s'exécute sur l'iPhone, sans app montre.
final class LimiterNotification: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LimiterNotification()

    private static let category = "LYNX_LIMITER"
    private static let engageID = "LYNX_ENGAGE"
    private static let releaseID = "LYNX_RELEASE"
    private static let noteID = "lynx-limiter"
    private static let resultID = "lynx-limiter-result"

    private var posted = false

    /// À appeler au lancement de l'appli (avant toute notification).
    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let engage = UNNotificationAction(identifier: Self.engageID, title: "🔒 Brider à 25 km/h", options: [])
        let release = UNNotificationAction(identifier: Self.releaseID, title: "🔓 Débrider", options: [])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [engage, release],
                                         intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
    }

    func connected(manager: BLEManager) {
        guard Prefs.limiterNotification, !posted else { return }
        posted = true
        let content = UNMutableNotificationContent()
        content.title = "LynxDash connecté"
        content.body = "\(manager.connectedName ?? "Roue") · appuie longuement (ou fais défiler sur la montre) pour brider / débrider."
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .active
        content.threadIdentifier = "lynx-limiter"
        let req = UNNotificationRequest(identifier: Self.noteID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func disconnected() {
        posted = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.noteID])
    }

    private func postResult(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "LynxDash"
        content.body = text
        content.categoryIdentifier = Self.category   // les boutons restent disponibles
        content.threadIdentifier = "lynx-limiter"
        content.sound = .default
        let req = UNNotificationRequest(identifier: Self.resultID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        guard action == Self.engageID || action == Self.releaseID else {
            completionHandler()
            return
        }
        Task { @MainActor in
            let ble = BLEManager.shared
            await ble.waitForTelemetry(timeout: 12)
            let text: String
            if action == Self.engageID {
                if ble.isLimited {
                    text = "La roue est déjà bridée à 25 km/h"
                } else {
                    text = await ble.engageLimiter().message(for: .engage)
                }
            } else if PinLock.isSet {
                text = PinLock.lockedMessage
            } else {
                text = await ble.releaseLimiter().message(for: .release)
            }
            ble.limiterMessage = text
            VoiceAnnouncer.shared.speak(text.replacingOccurrences(of: " ✓", with: ""), urgent: true)
            self.postResult(text)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Appli ouverte : les alertes de sécurité restent visibles ; la notification
        // de commande va seulement dans le centre de notifications.
        if notification.request.content.categoryIdentifier == Self.category {
            completionHandler([.list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }
}
