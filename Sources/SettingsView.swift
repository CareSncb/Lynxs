import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private let cellOptions = [16, 20, 24, 30, 32, 36, 40, 42]

    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("autoTrips") private var autoTrips = true
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @AppStorage("voiceInterval") private var voiceInterval = 5
    @AppStorage("voiceBattery") private var voiceBattery = true
    @AppStorage("voicePWM") private var voicePWM = true
    @AppStorage("fallDetection") private var fallDetection = false
    @AppStorage("emergencyPhone") private var emergencyPhone = ""
    @AppStorage("ntfyTopic") private var ntfyTopic = ""
    @AppStorage("liveActivity") private var liveActivity = true
    @AppStorage("watchPWMAlerts") private var watchPWMAlerts = true
    @AppStorage("tempAlert") private var tempAlert = 65.0
    @State private var chargeLevels: Set<Int> = Set(UserDefaults.standard.array(forKey: "chargeAlertLevels") as? [Int] ?? [80, 100])

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Marque", selection: $ble.preferredBrand) {
                        ForEach(WheelBrand.allCases) { brand in
                            Text(brand.label).tag(brand)
                        }
                    }
                    if ble.preferredBrand == .auto {
                        row("Détectée", ble.activeBrand == .auto ? "En attente…" : ble.activeBrand.label)
                    }
                } header: {
                    Text("Roue")
                } footer: {
                    Text("InMotion n'est pas encore géré.")
                }

                Section {
                    Toggle("Connexion automatique", isOn: $ble.autoConnect)
                    ForEach(ble.knownWheels.sorted(by: { $0.value < $1.value }), id: \.key) { item in
                        let id = item.key
                        HStack {
                            Text(item.value)
                            Spacer()
                            if id == ble.currentWheelID && ble.state == .connected {
                                Text("Connectée").font(.caption).foregroundStyle(.green)
                            }
                        }
                        .swipeActions {
                            Button("Oublier", role: .destructive) { ble.forgetWheel(id) }
                        }
                    }
                } header: {
                    Text("Mes roues")
                } footer: {
                    Text("Dès qu'une de ces roues s'allume, l'iPhone s'y connecte tout seul, même appli fermée ou téléphone verrouillé (sauf si tu as fermé l'appli en la balayant). La montre reçoit les données via l'iPhone : une roue n'accepte qu'une seule connexion Bluetooth.")
                }

                Section {
                    Picker("Batterie", selection: $ble.cellCount) {
                        ForEach(cellOptions, id: \.self) { n in
                            Text(String(format: "%dS – %.1f V", n, Double(n) * 4.2)).tag(n)
                        }
                    }
                } header: {
                    Text("Pack batterie (\(ble.activeBrand == .auto ? "roue non détectée" : ble.activeBrand.shortLabel))")
                } footer: {
                    Text("Lynx S : 36S (151,2 V). Sur Begode, ce réglage sert aussi à calculer la tension. Le pourcentage est une estimation.")
                }

                Section {
                    Stepper(value: limitBinding, in: 0...99, step: 1) {
                        HStack {
                            Text("Limite normale")
                            Spacer()
                            Text(limitText).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Débridage")
                } footer: {
                    Text("Valeur restaurée quand tu débrides. Elle est mémorisée automatiquement au premier bridage. 0 = tiltback désactivé (Begode).")
                }

                Section {
                    Toggle("Enregistrer les trajets automatiquement", isOn: $autoTrips)
                    Toggle("Tracé GPS", isOn: $gpsEnabled)
                        .onChange(of: gpsEnabled) { _, on in if on { TripRecorder.shared.requestPermission() } }
                } header: {
                    Text("Trajets")
                } footer: {
                    Text("Pour enregistrer le GPS téléphone verrouillé, autorise la localisation « Toujours ».")
                }

                Section("Annonces vocales") {
                    Toggle("Annonces dans les écouteurs", isOn: $voiceEnabled)
                    if voiceEnabled {
                        Stepper("Toutes les \(voiceInterval) min", value: $voiceInterval, in: 1...30)
                        Toggle("Paliers de batterie (10 %)", isOn: $voiceBattery)
                        Toggle("Alerte PWM", isOn: $voicePWM)
                        Button("Tester") { VoiceAnnouncer.shared.speak("25 kilomètres heure, batterie 80 pour cent") }
                    }
                }

                Section {
                    Toggle("Détection de chute", isOn: $fallDetection)
                    if fallDetection {
                        TextField("Téléphone du contact (SMS)", text: $emergencyPhone)
                            .keyboardType(.phonePad)
                        TextField("Sujet ntfy (envoi automatique)", text: $ntfyTopic)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Sécurité")
                } footer: {
                    Text("Après une chute probable, un compte à rebours de 30 s démarre avec sirène. Sans réponse : iOS prépare un SMS avec ta position (tu dois appuyer sur Envoyer, Apple n'autorise pas l'envoi automatique). Pour un envoi 100 % automatique, ton contact installe l'appli gratuite « ntfy » et s'abonne au même sujet (choisis un nom unique, ex. gyrocare-ton-prenom-1234).")
                }

                Section {
                    ForEach([80, 90, 100], id: \.self) { level in
                        Toggle("Charge à \(level) %", isOn: Binding(
                            get: { chargeLevels.contains(level) },
                            set: { on in
                                if on { chargeLevels.insert(level) } else { chargeLevels.remove(level) }
                                UserDefaults.standard.set(Array(chargeLevels), forKey: "chargeAlertLevels")
                            }))
                    }
                    Stepper(tempAlert == 0 ? "Alerte température : désactivée" : String(format: "Alerte température : %.0f °C", tempAlert),
                            value: $tempAlert, in: 0...90, step: 5)
                } header: {
                    Text("Alertes charge et température")
                } footer: {
                    Text("La roue doit rester connectée à l'iPhone pendant la charge. L'alerte température prévient aussi quand la température monte vite.")
                }

                Section("Écran verrouillé et montre") {
                    Toggle("Live Activity (Dynamic Island)", isOn: $liveActivity)
                    Toggle("Vibration PWM sur la montre", isOn: $watchPWMAlerts)
                }

                Section("Alarmes du téléphone (son + vibration)") {
                    Stepper(value: $ble.speedAlarm, in: 0...90, step: 1) {
                        HStack {
                            Text("Vitesse")
                            Spacer()
                            Text(ble.speedAlarm == 0 ? "Désactivée" : String(format: "%.0f km/h", ble.speedAlarm))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $ble.pwmAlarm, in: 0...100, step: 5) {
                        HStack {
                            Text("PWM")
                            Spacer()
                            Text(ble.pwmAlarm == 0 ? "Désactivée" : String(format: "%.0f %%", ble.pwmAlarm))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Réglages lus dans la roue") {
                    row("Alerte vitesse", ble.data.speedAlert > 0 ? String(format: "%.0f km/h", ble.data.speedAlert) : "—")
                    row("Limite / tiltback", ble.data.speedLimitKnown ? String(format: "%.0f km/h", ble.data.speedLimit) : "—")
                    row("Modèle", ble.data.model ?? "—")
                    row("Firmware", ble.data.firmwareString)
                    Button("Remettre la vitesse max à zéro") { ble.resetMaxSpeed() }
                }

                Section("Diagnostic") {
                    row("Trames reçues", "\(ble.framesReceived)")
                    row("Trames rejetées", "\(ble.rejectedFrames)")
                    if ble.activeBrand == .leaperkim {
                        row("CRC", ble.data.crcChecked ? (ble.data.crcValid ? "OK" : "Échecs : \(ble.crcFailures)") : "Non présent")
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private var limitBinding: Binding<Int> {
        Binding(get: { ble.normalLimit ?? 0 }, set: { ble.normalLimit = $0 })
    }

    private var limitText: String {
        guard let v = ble.normalLimit else { return "Inconnue" }
        return v == 0 ? "Désactivé" : "\(v) km/h"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
