import SwiftUI

// MARK: - Écran « Contrôle » : à montrer en cas de contrôle de police

struct ControlScreenView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var certificate: URL?
    @State private var savedBrightness: CGFloat = 0.5

    private var connected: Bool { ble.state == .connected }

    private var qrText: String {
        let d = ble.data
        return """
        \(Business.name) — Bridage 25 km/h
        Roue : \(ble.connectedName ?? "—") \(d.model ?? "")
        Limite lue : \(d.speedLimitKnown ? String(format: "%.0f km/h", d.speedLimit) : "—")
        Compteur : \(Int(d.totalDistance)) km
        \(Date().formatted(date: .numeric, time: .standard))
        """
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 0) {
                        Color(red: 0.08, green: 0.08, blue: 0.08)
                        Color(red: 0.99, green: 0.85, blue: 0.14)
                        Color(red: 0.94, green: 0.2, blue: 0.25)
                    }
                    .frame(width: 150, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 30)

                    Text("Bridée à 25 km/h").font(.system(size: 40, weight: .black)).foregroundStyle(.white)
                    Text("Engin de déplacement motorisé — conforme à la réglementation belge")
                        .font(.headline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))

                    // Preuve en direct : limite lue dans la roue + heure qui défile
                    VStack(spacing: 6) {
                        if connected && ble.isLimited {
                            Label("Limite lue sur la roue : 25 km/h", systemImage: "checkmark.seal.fill")
                                .font(.title3.bold()).foregroundStyle(.green)
                        } else if connected {
                            Label("Vérification de la limite…", systemImage: "hourglass").font(.title3.bold()).foregroundStyle(Theme.gold)
                        } else {
                            Label("Roue non connectée", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(.title3.bold()).foregroundStyle(Theme.gold)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(ctx.date.formatted(date: .long, time: .standard))
                                .font(.title3.monospacedDigit()).foregroundStyle(.white)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 8) {
                        row("Roue", ble.connectedName ?? "—")
                        row("Marque / modèle", "\(ble.activeBrand.shortLabel) \(ble.data.model ?? "")")
                        row("Compteur", connected ? String(format: "%.0f km", ble.data.totalDistance) : "—")
                        row("Vitesse actuelle", connected ? String(format: "%.0f km/h", abs(ble.data.speed)) : "—")
                        row("Bridage réalisé par", "\(Business.name) (atelier)")
                    }
                    .padding()
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    if let qr = PDFKitLite.qr(qrText, size: 260) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }

                    if let certificate {
                        ShareLink(item: certificate) { Label("Envoyer le certificat (PDF)", systemImage: "doc.badge.checkmark") }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    } else {
                        Button { certificate = BridleCertificate.make(ble: ble) } label: {
                            Label("Certificat de bridage (PDF)", systemImage: "doc.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                    Button("Fermer") { dismiss() }.foregroundStyle(.white.opacity(0.7)).padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIScreen.main.brightness = savedBrightness }
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l).foregroundStyle(.white.opacity(0.6)); Spacer(); Text(v).bold().foregroundStyle(.white) }
    }
}
