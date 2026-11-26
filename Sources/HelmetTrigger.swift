import AVFoundation
import SwiftUI

// MARK: - Bridage quand le casque Bluetooth se déconnecte

/// Surveille la sortie audio de l'iPhone. Quand le casque choisi (ex. « X1 Plus ») disparaît
/// alors que la roue est connectée, la roue est bridée à 25 km/h (au prochain arrêt si elle roule).
final class HelmetTrigger: ObservableObject {
    static let shared = HelmetTrigger()

    @AppStorage("helmetTrigger") var enabled = true
    @AppStorage("helmetName") var helmetName = "X1 Plus"

    /// Le casque est-il actuellement connecté comme sortie audio ?
    @Published private(set) var helmetConnected = false
    @Published private(set) var lastEvent: String?

    private var lastPoll = Date.distantPast
    private var observer: NSObjectProtocol?

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
        if helmetConnected && !present { helmetLost() }
        helmetConnected = present
    }

    private func helmetLost() {
        let ble = BLEManager.shared
        guard enabled, ble.state == .connected else { return }
        guard !ble.isLimited, ble.pendingAction != .engage else {
            lastEvent = "\(helmetName) déconnecté (roue déjà bridée)"
            return
        }
        Task { @MainActor in
            let outcome = await ble.engageLimiter()
            let text = "Casque \(helmetName) éteint : " + outcome.message(for: .engage)
            ble.limiterMessage = text
            lastEvent = text
            VoiceAnnouncer.shared.speak("Casque éteint, bridage à 25", urgent: true)
            SafetyMonitor.shared.notify(title: "Casque déconnecté", body: text)
            PhoneWatchBridge.shared.sendAlert(text)
        }
    }
}

struct HelmetTriggerSection: View {
    @ObservedObject private var helmet = HelmetTrigger.shared
    @State private var outputs = HelmetTrigger.currentOutputs

    var body: some View {
        Section {
            Toggle("Brider quand le casque s'éteint", isOn: helmet.$enabled)
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
            Text("Quand le casque disparaît des sorties audio de l'iPhone alors que la roue est connectée, la roue se bride à 25 km/h (au prochain arrêt si tu roules). Le nom doit correspondre à celui affiché dans « Sortie audio actuelle » quand le casque est allumé.")
        }
        .onAppear { outputs = HelmetTrigger.currentOutputs; helmet.poll(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { outputs = HelmetTrigger.currentOutputs }
        }
    }
}
