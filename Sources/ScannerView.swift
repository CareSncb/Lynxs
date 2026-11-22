import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if ble.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Recherche des roues… Allume ta roue.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.discovered) { wheel in
                        Button {
                            ble.connect(wheel)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "circle.circle")
                                Text(wheel.name)
                                Spacer()
                                Text("\(wheel.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Leaperkim/Nosfet, Begode et Kingsong sont reconnues automatiquement. Déconnecte d'abord toute autre appli, comme EUC World.")
                }
            }
            .navigationTitle("Choisir la roue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear { ble.startScan() }
            .onDisappear { ble.stopScan() }
        }
    }
}
