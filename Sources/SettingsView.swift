import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private let cellOptions = [16, 20, 24, 30, 32, 36, 40, 42]

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
