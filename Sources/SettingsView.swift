import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private let cellOptions = BLEManager.cellOptions

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
    @AppStorage("watchRemote") private var watchRemote = true
    @AppStorage("limiterNotification") private var limiterNotification = true
    @AppStorage("weatherAlerts") private var weatherAlerts = true
    @AppStorage("marginAlarm") private var marginAlarm = 20.0
    @AppStorage("topSpeedAtFull") private var topSpeedAtFull = 0.0
    @AppStorage("alarmBeeps") private var alarmBeeps = true
    @AppStorage("currentAlarm") private var currentAlarm = 0.0
    @AppStorage("autoLight") private var autoLight = false
    @AppStorage("hornMode") private var hornMode = "both"
    @ObservedObject private var helmet = HelmetTrigger.shared
    @AppStorage("engineSound") private var engineSound = false
    @AppStorage("engineStyle") private var engineStyle = EngineSound.Style.electric.rawValue
    @AppStorage("engineVolume") private var engineVolume = 0.6
    @AppStorage("kwhPrice") private var kwhPrice = 0.35
    @AppStorage("batteryWh") private var batteryWh = 0.0
    @AppStorage("storageReminder") private var storageReminder = true
    @AppStorage("tempAlert") private var tempAlert = 65.0
    @State private var maxSpeedDraft: Double = 40
    @State private var askPinMaxSpeed = false
    @State private var maxSpeedMessage: String?
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
                    Text("InMotion : seule la P6 est gérée. La P6 ne communique pas sa limite actuelle : règle ta « Limite normale » ci-dessous avant le premier bridage pour pouvoir débrider ensuite.")
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
                    Text("Lynx S : 36S (151,2 V). InMotion P6 : 56S (235,2 V). Corrigé automatiquement si la tension mesurée dépasse le pack choisi. Sur Begode, ce réglage sert aussi à calculer la tension. Le pourcentage est une estimation.")
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

                Section {
                    Stepper(marginAlarm == 0 ? "Marge de sécurité : désactivée" : "Bips sous \(Int(marginAlarm)) % de marge",
                            value: $marginAlarm, in: 0...50, step: 5)
                    if !ble.data.hasPWM {
                        Stepper(topSpeedAtFull == 0 ? "Vitesse max à 100 % : à régler" : "Vitesse max à 100 % : \(Int(topSpeedAtFull)) km/h",
                                value: $topSpeedAtFull, in: 0...120, step: 1)
                    }
                    Toggle("Bips progressifs dans les écouteurs", isOn: $alarmBeeps)
                    Button("Tester les bips") {
                        for (i, f) in [1100.0, 1500, 1900, 2200].enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) { Beeper.shared.beep(frequency: f, duration: 0.08) }
                        }
                    }
                    Stepper(currentAlarm == 0 ? "Charge prolongée : désactivée" : "Charge prolongée : \(Int(currentAlarm)) A sur 15 s",
                            value: $currentAlarm, in: 0...200, step: 10)
                } header: {
                    Text("Alarmes de sécurité")
                } footer: {
                    Text("La marge de sécurité est la réserve de puissance restante (100 % − PWM). Sous le seuil, les bips s'accélèrent et montent dans les aigus à mesure que la marge fond. Sans PWM envoyé par la roue, elle est estimée avec la vitesse max à pleine charge. Les alarmes vitesse et PWM de la roue utilisent les mêmes bips.")
                }

                Section {
                    Toggle("Phare automatique (coucher du soleil)", isOn: $autoLight)
                    Picker("Klaxon", selection: $hornMode) {
                        Text("Roue + téléphone").tag("both")
                        Text("Roue seulement").tag("wheel")
                        Text("Téléphone seulement").tag("phone")
                    }
                    Toggle("Son moteur virtuel", isOn: $engineSound)
                    if engineSound {
                        Picker("Style", selection: $engineStyle) {
                            ForEach(EngineSound.Style.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        Slider(value: $engineVolume, in: 0.1...1) { Text("Volume") }
                    }
                } header: {
                    Text("Ambiance")
                } footer: {
                    Text("Phare : allumé 10 min avant le coucher du soleil, éteint après le lever (calculé selon ta position). Un réglage manuel est respecté jusqu'au prochain changement jour/nuit.")
                }

                Section {
                    HStack {
                        Text("Prix du kWh")
                        Spacer()
                        TextField("0,35", value: $kwhPrice, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        Text("€")
                    }
                    HStack {
                        Text("Capacité batterie")
                        Spacer()
                        TextField("ex. 1800", value: $batteryWh, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                        Text("Wh")
                    }
                    if let c = ChargeAssistant.costPer100km {
                        LabeledContent("Coût moyen", value: String(format: "%.2f € / 100 km", c))
                    }
                    Toggle("Rappel de stockage (2 semaines)", isOn: $storageReminder)
                } header: {
                    Text("Charge et coût")
                } footer: {
                    Text("Le rappel prévient si la roue reste 2 semaines sans rouler à plus de 75 % ou moins de 35 % : stockée vers 50–60 %, la batterie vieillit moins vite.")
                }

                FleetClientSection()
                BackupSection()

                Section {
                    Button {
                        UserDefaults.standard.set(false, forKey: "onboardingDone")
                    } label: {
                        Label("Revoir le guide de démarrage", systemImage: "sparkles")
                    }
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

            }
            .themedList()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func applyMaxSpeed() {
        let v = Int(maxSpeedDraft)
        maxSpeedMessage = "Envoi…"
        Task { @MainActor in maxSpeedMessage = await ble.setMaxSpeed(v) }
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

/// Réglages avancés (montre, alarmes, lecture de la roue, diagnostic) — menu atelier caché.
struct AdvancedSettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @AppStorage("liveActivity") private var liveActivity = true
    @AppStorage("watchPWMAlerts") private var watchPWMAlerts = true
    @AppStorage("watchRemote") private var watchRemote = true
    @AppStorage("limiterNotification") private var limiterNotification = true
    @AppStorage("weatherAlerts") private var weatherAlerts = true

    var body: some View {
        Form {
            Section {
                Toggle("Live Activity (Dynamic Island + montre)", isOn: $liveActivity)
                Toggle("Télécommande « À l'écoute »", isOn: $watchRemote)
                    .onChange(of: watchRemote) { _, _ in WatchRemote.shared.settingChanged() }
                Toggle("Notification Brider / Débrider", isOn: $limiterNotification)
                Toggle("Alerte météo au départ", isOn: $weatherAlerts)
                Toggle("Vibration PWM sur la montre (app montre)", isOn: $watchPWMAlerts)
            } header: {
                Text("Écran verrouillé et Apple Watch")
            } footer: {
                Text("Sans app montre : l'écran « À l'écoute » de la Watch affiche la vitesse. Lecture/Pause = brider ou débrider (appuie 2 fois pour confirmer), Suivant = klaxon, Précédent = annonce vocale. La télécommande met ta musique en pause tant que la roue est connectée : désactive-la si tu écoutes de la musique.")
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
                row("Valeurs aberrantes filtrées", "\(ble.outliersRejected)")
                if ble.activeBrand == .leaperkim {
                    row("CRC", ble.data.crcChecked ? (ble.data.crcValid ? "OK" : "Échecs : \(ble.crcFailures)") : "Non présent")
                }
            }
        }
        .themedList()
        .navigationTitle("Réglages avancés")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
