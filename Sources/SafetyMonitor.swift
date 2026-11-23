import AudioToolbox
import Foundation
import UIKit
import UserNotifications

/// Détection de chute et mode antivol.
final class SafetyMonitor: ObservableObject {
    static let shared = SafetyMonitor()

    // Chute
    @Published private(set) var fallCountdown: Int?        // secondes restantes avant l'alerte
    @Published private(set) var fallAlertSent = false
    private var recentSpeeds: [(Date, Double)] = []
    private var countdownTimer: Timer?
    private var lastFallCheck = Date.distantPast

    // Antivol
    @Published private(set) var antiTheftArmed = false
    @Published private(set) var sirenActive = false
    @Published var antiTheftMessage: String?
    private var basePitch: Double?
    /// Limite à restaurer au désarmement (mémorisée, survit à un redémarrage de l'appli).
    private var previousLimit: Int? {
        get { UserDefaults.standard.object(forKey: "antiTheftPrevious") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "antiTheftPrevious") }
    }
    private var sirenTimer: Timer?
    private var sirenEnd = Date.distantPast

    static let antiTheftLimit = 10

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Télémétrie

    func ingest(_ d: WheelData, manager: BLEManager) {
        checkFall(d)
        checkAntiTheft(d)
    }

    func wheelDisconnected() {
        // Coupure brutale en roulant : le moteur a pu se couper (chute probable)
        if Prefs.fallDetection, let last = recentSpeeds.last, Date().timeIntervalSince(last.0) < 2, last.1 >= 12 {
            startFallCountdown(reason: "Roue déconnectée en roulant")
        }
        recentSpeeds.removeAll()
        if antiTheftArmed {
            notify(title: "Antivol", body: "La roue s'est déconnectée : elle est peut-être emportée !")
            PhoneWatchBridge.shared.sendAlert("Antivol : roue déconnectée !")
            startSiren(seconds: 10)
        }
    }

    // MARK: - Chute

    private func checkFall(_ d: WheelData) {
        guard Prefs.fallDetection, fallCountdown == nil else { return }
        let now = Date()
        let speed = abs(d.speed)
        recentSpeeds.append((now, speed))
        recentSpeeds.removeAll { now.timeIntervalSince($0.0) > 3 }

        // Roue couchée (si la roue envoie l'inclinaison) après avoir roulé
        let wasMoving = recentSpeeds.contains { $0.1 >= 10 }
        if d.hasPitch, abs(d.pitchAngle) > 50, wasMoving {
            startFallCountdown(reason: "Roue couchée")
            return
        }
        // Arrêt brutal : de plus de 15 km/h à l'arrêt en moins d'une seconde
        if speed < 2, recentSpeeds.contains(where: { now.timeIntervalSince($0.0) <= 1.0 && $0.1 >= 15 }) {
            startFallCountdown(reason: "Arrêt brutal")
        }
    }

    private func startFallCountdown(reason: String) {
        guard fallCountdown == nil else { return }
        BlackBox.shared.trigger(reason)
        fallAlertSent = false
        fallCountdown = 30
        TripRecorder.shared.requestOneShotLocation()
        notify(title: "Chute détectée ?", body: "\(reason). Ouvre LynxDash et touche « Je vais bien » sinon ton contact sera prévenu dans 30 s.")
        PhoneWatchBridge.shared.sendAlert("Chute détectée ? Touche « Je vais bien »")
        startSiren(seconds: 30)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, let c = self.fallCountdown else { timer.invalidate(); return }
            if c <= 1 {
                timer.invalidate()
                self.fallCountdown = nil
                self.sendFallAlert(reason: reason)
            } else {
                self.fallCountdown = c - 1
            }
        }
    }

    func cancelFallAlert() {
        countdownTimer?.invalidate()
        fallCountdown = nil
        stopSiren()
    }

    private func sendFallAlert(reason: String) {
        stopSiren()
        fallAlertSent = true
        let text = alertText(reason: reason)

        // Envoi automatique via ntfy.sh (le contact s'abonne au sujet dans l'appli ntfy)
        let topic = Prefs.ntfyTopic.trimmingCharacters(in: .whitespaces)
        if !topic.isEmpty, let url = URL(string: "https://ntfy.sh/\(topic)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Chute gyroroue", forHTTPHeaderField: "Title")
            req.setValue("urgent", forHTTPHeaderField: "Priority")
            req.setValue("warning", forHTTPHeaderField: "Tags")
            req.httpBody = text.data(using: .utf8)
            URLSession.shared.dataTask(with: req).resume()
        }

        // SMS pré-rempli (iOS impose d'appuyer sur Envoyer)
        notify(title: "Alerte chute", body: topic.isEmpty
               ? "Touche ici pour envoyer le SMS d'alerte à ton contact."
               : "Ton contact a été prévenu. Touche ici pour aussi lui envoyer un SMS.")
        openSMS(text)
    }

    func alertText(reason: String) -> String {
        var text = "⚠️ Chute possible en gyroroue (\(reason.lowercased()))."
        if let loc = TripRecorder.shared.lastLocation {
            let lat = String(format: "%.5f", loc.coordinate.latitude)
            let lon = String(format: "%.5f", loc.coordinate.longitude)
            text += " Position : https://maps.apple.com/?ll=\(lat),\(lon)&q=Position"
        }
        return text
    }

    func openSMS(_ text: String) {
        let phone = Prefs.emergencyPhone.filter { "+0123456789".contains($0) }
        guard !phone.isEmpty,
              let body = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sms:\(phone)&body=\(body)") else { return }
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active { UIApplication.shared.open(url) }
        }
    }

    // MARK: - Antivol

    /// Arme l'antivol : bride la roue à 10 km/h et surveille tout mouvement.
    @MainActor
    func armAntiTheft() async {
        let ble = BLEManager.shared
        guard ble.state == .connected else {
            antiTheftMessage = "Connecte d'abord la roue"
            return
        }
        // Limite actuelle lue dans la roue, sinon la vitesse max des réglages
        let current = ble.data.speedLimitKnown ? Int(ble.data.speedLimit.rounded()) : nil
        if let c = current, c > SafetyMonitor.antiTheftLimit {
            previousLimit = c
        } else if previousLimit == nil {
            previousLimit = ble.normalLimit
        }
        if let error = await ble.setSpeedLimit(SafetyMonitor.antiTheftLimit) {
            antiTheftMessage = "Bridage antivol impossible (\(error)) — surveillance active quand même"
        } else {
            antiTheftMessage = "Roue bridée à \(SafetyMonitor.antiTheftLimit) km/h, surveillance active"
        }
        basePitch = ble.data.hasPitch ? ble.data.pitchAngle : nil
        antiTheftArmed = true
    }

    @MainActor
    func disarmAntiTheft() async {
        antiTheftArmed = false
        stopSiren()
        let ble = BLEManager.shared
        guard let previous = previousLimit ?? ble.normalLimit, previous > SafetyMonitor.antiTheftLimit else {
            antiTheftMessage = "Antivol désarmé. Limite d'origine inconnue : règle la vitesse max dans Réglages"
            return
        }
        let result = await ble.applyLimitNowOrLater(previous)
        previousLimit = nil
        antiTheftMessage = "Antivol désarmé · \(result)"
    }

    private func checkAntiTheft(_ d: WheelData) {
        guard antiTheftArmed, !sirenActive else { return }
        var moved = abs(d.speed) > 1.5
        if let base = basePitch, d.hasPitch, abs(d.pitchAngle - base) > 10 { moved = true }
        if moved {
            notify(title: "Antivol", body: "Ta roue est en train d'être déplacée !")
            PhoneWatchBridge.shared.sendAlert("Antivol : roue déplacée !")
            startSiren(seconds: 30)
        }
    }

    // MARK: - Sirène / klaxon

    func horn() {
        HornPlayer.shared.horn()
    }

    func startSiren(seconds: TimeInterval) {
        sirenActive = true
        sirenEnd = Date().addingTimeInterval(seconds)
        HornPlayer.shared.siren(seconds: seconds)
        sirenTimer?.invalidate()
        sirenTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] timer in
            guard let self, Date() < self.sirenEnd else {
                timer.invalidate()
                self?.sirenActive = false
                return
            }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stopSiren() {
        HornPlayer.shared.stop()
        sirenTimer?.invalidate()
        sirenActive = false
    }

    // MARK: - Notifications

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
