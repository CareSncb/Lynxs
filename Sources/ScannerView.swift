import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ZStack(alignment: .bottomLeading) {
                        WheelPhoto(name: "WheelPortrait")
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        HStack(spacing: 10) {
                            GyrocareLogo(size: 40)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("GYROCARE").font(.headline.weight(.black)).kerning(2)
                                    .foregroundStyle(Theme.brandGradient)
                                Text("Allume ta roue, on s'occupe du reste")
                                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .padding(12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
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
            .themedList()
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
