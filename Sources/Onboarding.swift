import CoreLocation
import SwiftUI
import UserNotifications

// MARK: - Assistant de première installation

struct OnboardingView: View {
    @EnvironmentObject var ble: BLEManager
    @AppStorage("onboardingDone") private var done = false
    @AppStorage("emergencyPhone") private var emergencyPhone = ""
    @State private var page = 0
    @State private var showScanner = false
    @State private var notifStatus = "—"
    @State private var hornTested = false

    private let pages = 6

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    wheel.tag(1)
                    location.tag(2)
                    notifications.tag(3)
                    emergency.tag(4)
                    horn.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                HStack {
                    if page > 0 { Button("Retour") { withAnimation { page -= 1 } }.foregroundStyle(.secondary) }
                    Spacer()
                    Button(page == pages - 1 ? "Terminer" : "Suivant") {
                        if page == pages - 1 { done = true } else { withAnimation { page += 1 } }
                    }
                    .font(.headline)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Theme.brandGradient, in: Capsule())
                    .foregroundStyle(.black)
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) { ScannerView().environmentObject(ble) }
    }

    private func pageView<Content: View>(_ icon: String, _ title: String, _ text: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(Theme.brandGradient)
            Text(title).font(.title.bold()).multilineTextAlignment(.center).foregroundStyle(.white)
            Text(text).font(.body).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            content()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            GyrocareLogo(size: 150)
            Text("Bienvenue").font(.largeTitle.bold()).foregroundStyle(.white)
            Text("L'application de ta gyroroue, par l'atelier \(Business.name). Quelques réglages et c'est parti.")
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
            Spacer(); Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var wheel: some View {
        pageView("circle.circle", "Ta roue", "Allume ta roue et connecte-la. L'appli s'y reconnectera ensuite toute seule.") {
            if ble.state == .connected {
                Label("\(ble.connectedName ?? "Roue") connectée", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Picker("Pack batterie", selection: $ble.cellCount) {
                    ForEach(BLEManager.cellOptions, id: \.self) { n in
                        Text("\(n)S — \(String(format: "%.1f", Double(n) * 4.2)) V").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                Text("Vérifie la tension maximale de ta batterie (ex. Lynx S : 151,2 V).")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Button { showScanner = true } label: { Label("Chercher ma roue", systemImage: "antenna.radiowaves.left.and.right") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
    }

    private var location: some View {
        pageView("location.fill", "Position « Toujours »",
                 "Nécessaire pour enregistrer tes trajets, partager ta position et prévenir ton contact en cas de chute, même écran éteint.") {
            Button("Autoriser la position") { TripRecorder.shared.requestPermission() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            Button("Ouvrir les réglages iOS") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.caption)
            Text("Dans Réglages › Position, choisis « Toujours ».").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notifications: some View {
        pageView("bell.badge.fill", "Notifications", "Alertes de batterie, de charge, de météo et de sécurité.") {
            Button("Autoriser les notifications") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                    DispatchQueue.main.async { notifStatus = ok ? "Activées ✓" : "Refusées" }
                }
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            Text(notifStatus).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emergency: some View {
        pageView("cross.case.fill", "Contact d'urgence",
                 "En cas de chute détectée sans réponse de ta part, un SMS avec ta position lui est préparé.") {
            TextField("Téléphone du contact", text: $emergencyPhone)
                .keyboardType(.phonePad)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Text("Facultatif, modifiable plus tard dans Réglages.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var horn: some View {
        pageView("speaker.wave.3.fill", "Test du klaxon", "Vérifie que le son passe bien (téléphone et roue si elle le permet).") {
            Button {
                HornPlayer.shared.horn()
                hornTested = true
            } label: { Label("Klaxonner", systemImage: "speaker.wave.3") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            if hornTested { Text("C'est prêt ! Touche « Terminer ».").foregroundStyle(.green) }
        }
    }
}
