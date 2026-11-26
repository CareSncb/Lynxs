import AVFoundation
import SwiftUI

// MARK: - Bridage quand le casque Bluetooth se déconnecte

/// Surveille la sortie audio de l'iPhone.
/// - Casque (ex. « X1 Plus ») absent alors que la roue est connectée → bridage à 25 km/h
///   (au prochain arrêt si elle roule), y compris si on part sans casque.
/// - Casque présent → la roue est débridée, mais seulement si c'est le casque qui l'avait bridée
///   (pas un bridage manuel, une zone ou un bridage définitif).
final class HelmetTrigger: ObservableObject {
    static let shared = HelmetTrigger()

    @AppStorage("helmetTrigger") var enabled = true
    @AppStorage("helmetName") var helmetName = "X1 Plus"

    /// Le casque est-il actuellement connecté comme sortie audio ?
    @Published private(set) var helmetConnected = false
    @Published private(set) var lastEvent: String?

    private var lastPoll = Date.distantPast
    private var observer: NSObjectProtocol?
    private var lastAction = Date.distantPast
    private var connectedSince: Date?
    private var busy = false

    /// Bridage posé par le casque pour cette roue (mémorisé entre deux connexions).
    private var engagedByHelmet: Bool {
        get { BLEManager.shared.currentWheelID.map { UserDefaults.standard.bool(forKey: "helmetEngaged-\($0)") } ?? false }
        set { if let id = BLEManager.shared.currentWheelID { UserDefaults.standard.set(newValue, forKey: "helmetEngaged-\(id)") } }
    }

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
        helmetConnected = present
        enforce(now: now)
    }

    /// Applique la règle « casque absent = bridée, casque présent = libre ».
    private func enforce(now: Date) {
        let ble = BLEManager.shared
        guard enabled, ble.state == .connected else { connectedSince = nil; return }
        if connectedSince == nil { connectedSince = now }
        // On laisse 15 s au casque pour se connecter après la roue, et 10 s entre deux actions
        guard !busy, now.timeIntervalSince(connectedSince ?? now) >= 15,
              now.timeIntervalSince(lastAction) >= 10 else { return }
        let engaged = ble.isLimited || ble.pendingAction == .engage

        if !helmetConnected && !engaged {
            act(now) {
                let outcome = await ble.engageLimiter()
                if case .failed = outcome { return "Bridage impossible : " + outcome.message(for: .engage) }
                self.engagedByHelmet = true
                VoiceAnnouncer.shared.speak("Casque absent, bridage à 25", urgent: true)
                return "Casque \(self.helmetName) absent : " + outcome.message(for: .engage)
            }
        } else if helmetConnected && engaged && engagedByHelmet {
            if ble.isPermanentlyLimited || ZoneManager.shared.activeZone != nil {
                engagedByHelmet = false     // un autre bridage prend le relais
                return
            }
            if PinLock.required {
                lastAction = now
                lastEvent = "Casque connecté, mais débridage protégé par code : active « iPhone de l'atelier » ou débride à la main"
                return
            }
            act(now) {
                let outcome = await ble.releaseLimiter()
                if case .failed = outcome { return "Débridage impossible : " + outcome.message(for: .release) }
                self.engagedByHelmet = false
                VoiceAnnouncer.shared.speak("Casque connecté, débridage", urgent: true)
                return "Casque \(self.helmetName) connecté : " + outcome.message(for: .release)
            }
        }
    }

    func wheelDisconnected() { connectedSince = nil }

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
            Toggle("Bridée sans casque, libre avec casque", isOn: helmet.$enabled)
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
            Text("Sans le casque (éteint ou jamais connecté 15 s après la roue), la roue se bride à 25 km/h, au prochain arrêt si tu roules. Casque reconnecté : elle est débridée, seulement si c'est le casque qui l'avait bridée (un bridage manuel, une zone ou un bridage définitif restent en place). Le débridage automatique demande « iPhone de l'atelier » activé ou aucun code. Le nom doit correspondre à celui affiché dans « Sortie audio actuelle » casque allumé.")
        }
        .onAppear { outputs = HelmetTrigger.currentOutputs; helmet.poll(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { outputs = HelmetTrigger.currentOutputs }
        }
    }
}
