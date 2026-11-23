import AVFoundation
import Security
import SwiftUI

// MARK: - Code PIN de débridage (stocké dans le trousseau iOS)

enum PinLock {
    private static let account = "be.gyrocare.lynxdash.pin"

    static var isSet: Bool { read() != nil }

    static func verify(_ pin: String) -> Bool {
        guard let stored = read() else { return true }
        return pin == stored
    }

    static func set(_ pin: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let pin, !pin.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(pin.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let lockedMessage = "Débridage protégé par code PIN : fais-le depuis l'appli sur l'iPhone"
}

/// Fenêtre de saisie du code PIN.
struct PinPrompt: View {
    let title: String
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill").font(.system(size: 50)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            SecureField("Code PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title.monospacedDigit())
                .padding()
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .focused($focused)
                .onChange(of: pin) { _, _ in wrong = false }
            if wrong { Text("Code incorrect").foregroundStyle(.red) }
            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
                Button("Valider") {
                    if PinLock.verify(pin) {
                        dismiss()
                        onSuccess()
                    } else {
                        wrong = true
                        pin = ""
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(pin.count < 4)
            }
        }
        .padding(30)
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}

extension View {
    /// Exécute `action` après vérification du PIN (directement s'il n'y a pas de PIN).
    func pinProtected(_ isPresented: Binding<Bool>, title: String, action: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) { PinPrompt(title: title, onSuccess: action) }
    }
}

/// Réglage du code PIN dans les Réglages.
struct PinSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPin = ""
    @State private var confirm = ""
    @State private var message: String?
    private let hasPin = PinLock.isSet

    var body: some View {
        Form {
            if hasPin {
                Section("Code actuel") {
                    SecureField("Code actuel", text: $current).keyboardType(.numberPad)
                }
            }
            Section {
                SecureField("Nouveau code (4 à 6 chiffres)", text: $newPin).keyboardType(.numberPad)
                SecureField("Confirmer", text: $confirm).keyboardType(.numberPad)
                Button(hasPin ? "Changer le code" : "Activer le code PIN") { save(remove: false) }
                    .disabled(newPin.count < 4 || newPin.count > 6 || !newPin.allSatisfy(\.isNumber))
            } footer: {
                Text("Le code est demandé pour débrider, désarmer l'antivol et changer la vitesse maximale. Le bridage, lui, reste toujours possible sans code (bouton Flic, montre, Siri…). Le code est stocké dans le trousseau sécurisé de l'iPhone.")
            }
            if hasPin {
                Section {
                    Button("Supprimer le code PIN", role: .destructive) { save(remove: true) }
                }
            }
            if let message { Section { Text(message) } }
        }
        .themedList()
        .navigationTitle("Code PIN")
    }

    private func save(remove: Bool) {
        if hasPin && !PinLock.verify(current) { message = "Code actuel incorrect"; return }
        if remove { PinLock.set(nil); message = "Code PIN supprimé"; dismiss(); return }
        guard newPin == confirm else { message = "Les deux codes ne correspondent pas"; return }
        PinLock.set(newPin)
        message = "Code PIN enregistré ✓"
        dismiss()
    }
}

// MARK: - Klaxon et sirène (audibles même en mode silencieux)

final class HornPlayer {
    static let shared = HornPlayer()

    private let engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var started = false

    private func prepare() {
        let session = AVAudioSession.sharedInstance()
        // .playback : ignore le bouton silencieux de l'iPhone
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        guard !started else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
        try? engine.start()
        started = true
    }

    /// Son généré : klaxon à deux tons, ou sirène montante/descendante.
    private func buffer(siren: Bool, duration: Double) -> AVAudioPCMBuffer? {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        var phase1 = 0.0, phase2 = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let f1: Double, f2: Double
            if siren {
                let sweep = 0.5 + 0.5 * sin(2 * .pi * t * 1.5)
                f1 = 650 + 550 * sweep; f2 = f1 * 1.01
            } else {
                f1 = 415; f2 = 520   // accord de klaxon
            }
            phase1 += 2 * .pi * f1 / rate
            phase2 += 2 * .pi * f2 / rate
            // signal carré adouci (plus puissant qu'un sinus)
            var v = (tanh(4 * sin(phase1)) + tanh(4 * sin(phase2))) * 0.45
            let fade = min(1, t / 0.02, (duration - t) / 0.05)
            v *= max(0, fade)
            for ch in 0..<Int(format.channelCount) { buf.floatChannelData?[ch][i] = Float(v) }
        }
        return buf
    }

    func horn() {
        prepare()
        guard let b = buffer(siren: false, duration: 0.9) else { return }
        player.stop()
        player.scheduleBuffer(b, at: nil, options: .interrupts)
        player.play()
    }

    func siren(seconds: Double) {
        prepare()
        guard let b = buffer(siren: true, duration: 2) else { return }
        player.stop()
        player.scheduleBuffer(b, at: nil, options: [.loops, .interrupts])
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop() }
    }

    func stop() {
        player.stop()
    }
}
