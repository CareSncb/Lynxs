import AVFoundation
import SwiftUI

// MARK: - Bridage quand le casque Bluetooth se déconnecte

/// Surveille la sortie audio de l'iPhone.
/// - Casque (ex. « X1 Plus ») absent alors que la roue est connectée → bridage à 25 km/h
///   (au prochain arrêt si elle roule), y compris si on part sans casque.
/// - Casque présent (mode atelier caché activé sur cet iPhone) → la roue est débridée (mode test).
/// Sans ce mode, toutes les roues restent bridées d'office à 25 km/h.
final class HelmetTrigger: ObservableObject {
    static let shared = HelmetTrigger()

    @AppStorage("helmetTriggerAtelier") var enabled = false
    @AppStorage("helmetName") var helmetName = "X1 Plus"

    /// Le casque est-il actuellement connecté comme sortie audio ?
    @Published private(set) var helmetConnected = false
    @Published private(set) var lastEvent: String?

    private var lastPoll = Date.distantPast
    private var observer: NSObjectProtocol?
    private var lastAction = Date.distantPast
    private var busy = false

    /// Débridage autorisé : mode casque activé sur cet iPhone ET casque connecté.
    var authorizesUnlock: Bool { enabled && helmetConnected }

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.poll(force: true)
        }
        poll(force: true)
    }

    /// Noms des sorties audio actuelles (pour vérifier le nom exact du casque).
    static var currentOutputs: [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
    }

    private func matches(_ name: String) -> Bool {
        let target = helmetName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return false }
        return name.range(of: target, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Appelé à chaque trame de la roue (vérification toutes les 2 s) et à chaque changement de sortie audio.
    func poll(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPoll) >= 2 else { return }
        lastPoll = now
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
        let present = route.contains { port in
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port.portType) && matches(port.portName)
        }
        if present != helmetConnected { helmetConnected = present }
        BLEManager.shared.refreshLockState()
        enforce(now: now)
    }

    /// Casque connecté → débridage (hors zone GPS) ; casque absent → le bridage d'office reprend.
    private func enforce(now: Date) {
        let ble = BLEManager.shared
        guard enabled, ble.state == .connected, !busy,
              now.timeIntervalSince(lastAction) >= 10 else { return }
        let engaged = ble.isLimited || ble.pendingAction == .engage
        if helmetConnected && engaged && ZoneManager.shared.activeZone == nil {
            act(now) {
                let outcome = await ble.releaseLimiter()
                VoiceAnnouncer.shared.speak("Casque connecté, mode test", urgent: true)
                return "Casque \(self.helmetName) connecté : " + outcome.message(for: .release)
            }
        } else if !helmetConnected && !engaged {
            act(now) {
                let outcome = await ble.engageLimiter()
                VoiceAnnouncer.shared.speak("Casque absent, bridage à 25", urgent: true)
                return "Casque \(self.helmetName) absent : " + outcome.message(for: .engage)
            }
        }
    }

    func wheelDisconnected() {}

    private func act(_ now: Date, _ work: @escaping @MainActor () async -> String) {
        busy = true
        lastAction = now
        Task { @MainActor in
            let text = await work()
            BLEManager.shared.limiterMessage = text
            self.lastEvent = text
            SafetyMonitor.shared.notify(title: "Casque", body: text)
            PhoneWatchBridge.shared.sendAlert(text)
            self.busy = false
        }
    }
}

struct HelmetTriggerSection: View {
    @ObservedObject private var helmet = HelmetTrigger.shared
    @State private var outputs = HelmetTrigger.currentOutputs

    var body: some View {
        Section {
            Toggle("Débridage par casque (cet iPhone)", isOn: helmet.$enabled)
                .onChange(of: helmet.enabled) { _, _ in BLEManager.shared.refreshLockState() }
            HStack {
                Text("Nom du casque")
                Spacer()
                TextField("X1 Plus", text: helmet.$helmetName)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
            LabeledContent("État") {
                Text(helmet.helmetConnected ? "Connecté ✓" : "Non détecté")
                    .foregroundStyle(helmet.helmetConnected ? .green : .secondary)
            }
            LabeledContent("Sortie audio actuelle") {
                Text(outputs.joined(separator: ", ")).foregroundStyle(.secondary)
            }
            if let e = helmet.lastEvent { Text(e).font(.caption).foregroundStyle(Theme.accent) }
        } header: {
            Text("Casque Bluetooth")
        } footer: {
            Text("Casque allumé et connecté à cet iPhone : la roue est débridée (mode test, terrain privé). Casque éteint : elle se rebride à 25 km/h, au prochain arrêt si tu roules. Le nom doit correspondre à celui affiché dans « Sortie audio actuelle » casque allumé.")
        }
        .onAppear { outputs = HelmetTrigger.currentOutputs; helmet.poll(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { outputs = HelmetTrigger.currentOutputs }
        }
    }
}
