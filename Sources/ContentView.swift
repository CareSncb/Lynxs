import SwiftUI
import UIKit

/// Écran principal à onglets.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var safety = SafetyMonitor.shared
    @AppStorage("onboardingDone") private var onboardingDone = false
    @ObservedObject private var fleet = FleetSync.shared

    var body: some View {
        ZStack {
        TabView {
            ContentView()
                .tabItem { Label("Roue", systemImage: "gauge.with.dots.needle.67percent") }
            TripsView()
                .tabItem { Label("Trajets", systemImage: "map") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: Binding(get: { safety.fallCountdown != nil }, set: { _ in })) {
            FallAlertView()
        }

            // Assistant de première installation : affiché par-dessus l'appli (pas en feuille
            // modale, qui se faisait fermer aussitôt par les autres fenêtres au lancement).
            // Il ne se ferme qu'avec « Terminer ».
            if !onboardingDone {
                OnboardingView()
                    .environmentObject(ble)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: onboardingDone)
        .onAppear { UpdateChecker.shared.checkIfNeeded() }
        // Association au suivi de l'atelier (lien lynxdash://pair)
        .sheet(isPresented: Binding(get: { fleet.pendingPairing != nil }, set: { if !$0 { fleet.pendingPairing = nil } })) {
            FleetConsentView()
        }
    }
}

struct FallAlertView: View {
    @ObservedObject private var safety = SafetyMonitor.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.fall").font(.system(size: 80)).foregroundStyle(.red)
            Text("Chute détectée ?").font(.largeTitle.bold())
            Text("Ton contact sera prévenu dans").font(.title3)
            Text("\(safety.fallCountdown ?? 0) s")
                .font(.system(size: 72, weight: .heavy, design: .rounded))
                .monospacedDigit()
            Button {
                safety.cancelFallAlert()
            } label: {
                Text("Je vais bien")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal)
        }
        .padding()
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var recorder = TripRecorder.shared
    @ObservedObject private var safety = SafetyMonitor.shared
    @State private var showScanner = false
    @State private var showHandlebar = false
    @State private var showWheelSettings = false
    @State private var lightOn = false
    @State private var askAtelierCode = false
    @State private var showAtelier = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    private var connected: Bool { ble.state == .connected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    UpdateBanner()
                    hero
                    // Mention de bridage définitif : toujours visible (preuve de bonne foi du client)
                    if ble.isPermanentlyLimited { PermanentLimitBadge() }
                    ChargeCard()
                    ProfileBar()
                    quickActions
                    WeatherCard()
                    SpeedGauge(speed: abs(ble.data.speed), pwm: ble.data.pwm,
                               showPWM: ble.data.hasPWM, maxSpeed: ble.maxSpeed)
                        .frame(height: 250)
                        .glassCard()
                    DashboardGrid()
                    if !ble.isPermanentlyLimited { LimiterCard() }
                    ControlsCard()
                    AntiTheftCard()
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showHandlebar) {
                HandlebarView().environmentObject(ble)
            }
            .sheet(isPresented: $showScanner) {
                ScannerView().environmentObject(ble)
            }
            .sheet(isPresented: $showWheelSettings) {
                NavigationStack { WheelSettingsView() }.environmentObject(ble)
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onReceive(NotificationCenter.default.publisher(for: .autoLightChanged)) { note in
            if let on = note.object as? Bool { lightOn = on }
        }
        // Menu atelier caché (le code est demandé depuis l'en-tête, une seule feuille par vue)
        .sheet(isPresented: $showAtelier) { AtelierHiddenView().environmentObject(ble) }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            GyrocareLogo(size: 48)
                .contentShape(Circle())
                // Accès atelier caché : appui long de 2 s sur le logo, puis code atelier.
                // simultaneousGesture : le défilement de l'écran ne l'annule pas.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 2, maximumDistance: 40).onEnded { _ in
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        askAtelierCode = true
                    }
                )
                .pinProtected($askAtelierCode, title: "Code atelier", atelierOnly: true) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showAtelier = true }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(ble.connectedName ?? "LynxDash")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.caption).foregroundStyle(.white.opacity(0.75))
                    if let model = ble.data.model {
                        Text("· \(model)").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
            }
            Spacer()
            Menu {
                if connected || ble.state == .connecting {
                    Button("Déconnecter", role: .destructive) { ble.disconnect() }
                }
                Button("Chercher une roue") { showScanner = true }
                if !ble.knownWheels.isEmpty {
                    Button("Reconnecter mes roues") { ble.connectKnownWheels() }
                }
            } label: {
                Image(systemName: connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 8)
    }

    private var statusColor: Color {
        switch ble.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .red
        }
    }

    private var statusText: String {
        switch ble.state {
        case .connected: return ble.framesReceived == 0 ? "Connecté, en attente…" : "Connecté"
        case .connecting: return "Connexion automatique…"
        case .scanning: return "Recherche…"
        case .bluetoothOff: return "Bluetooth désactivé"
        case .unauthorized: return "Bluetooth non autorisé"
        case .idle: return "Non connecté"
        }
    }

    // MARK: Illustration + batterie

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                WheelPhoto()
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .saturation(connected ? 1 : 0.55)
                    .overlay(alignment: .topTrailing) {
                        if lightOn {
                            Label("Phare", systemImage: "headlight.high.beam.fill")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.gold.opacity(0.9), in: Capsule())
                                .foregroundStyle(.black)
                                .padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(connected ? String(format: "%.0f", ble.data.batteryPercent) : "—")
                            .font(.system(size: 48, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("%").font(.title3.bold())
                        Spacer()
                        Text("GYROCARE")
                            .font(.caption.weight(.black))
                            .kerning(2)
                            .foregroundStyle(Theme.brandGradient)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    // Jauge de batterie aux couleurs du coucher de soleil
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(batteryGradient)
                                .frame(width: geo.size.width * (connected ? max(0, min(1, ble.data.batteryPercent / 100)) : 0))
                                .animation(.easeOut(duration: 0.8), value: ble.data.batteryPercent)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
            HStack {
                infoPill(icon: "bolt.fill", text: connected ? String(format: "%.1f V", ble.data.voltage) : "— V")
                infoPill(icon: "road.lanes", text: rangeText)
                infoPill(icon: "thermometer.medium", text: connected ? String(format: "%.0f °C", ble.data.temperature) : "— °C")
            }
        }
        .glassCard(padding: 10)
    }

    private var batteryGradient: LinearGradient {
        let p = ble.data.batteryPercent
        let colors: [Color] = p < 20 ? [Theme.ember, .red] : (p < 40 ? [Theme.ember, Theme.accent] : [Theme.ember, Theme.accent, Theme.gold])
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var rangeText: String {
        guard connected, let e = RangePredictor.estimate(battery: ble.data.batteryPercent, wheelName: ble.connectedName)
        else { return "Autonomie —" }
        return String(format: "≈ %.0f km", e.km)
    }

    private func infoPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    // MARK: Actions rapides

    private var quickActions: some View {
        HStack {
            QuickActionButton(icon: lightOn ? "lightbulb.fill" : "lightbulb", label: "Phare", active: lightOn) {
                guard ble.supportsLight else {
                    ble.limiterMessage = "Phare : commande pas encore disponible pour \(ble.activeBrand.shortLabel)"
                    return
                }
                lightOn.toggle()
                ble.setLight(lightOn ? .on : .off)
            }
            Spacer()
            QuickActionButton(icon: "speaker.wave.3.fill", label: "Klaxon") { safety.horn() }
            Spacer()
            if ble.isPermanentlyLimited {
                QuickActionButton(icon: "lock.shield.fill", label: "25 km/h", active: true) {
                    ble.limiterMessage = PinLock.lockedMessage
                }
            } else {
                QuickActionButton(icon: ble.isLimited ? "lock.fill" : (ble.pendingAction != nil ? "hourglass" : "lock.open"),
                                  label: "Bridage", active: ble.isLimited || ble.pendingAction == .engage) {
                    Task { @MainActor in ble.limiterMessage = await LimiterToggle.run() }
                }
            }
            Spacer()
            QuickActionButton(icon: "rectangle.expand.vertical", label: "Guidon") { showHandlebar = true }
            Spacer()
            QuickActionButton(icon: "slider.horizontal.3", label: "Réglages") { showWheelSettings = true }
        }
        .disabled(!connected && ble.state != .idle)
        .padding(.horizontal, 4)
    }

    // MARK: Données en temps réel

    private var realtimeGrid: some View {
        let d = ble.data
        return VStack(alignment: .leading, spacing: 10) {
            Text("Temps réel").font(.headline).foregroundStyle(.white)
            LazyVGrid(columns: columns, spacing: 10) {
                MetricTile(icon: "speedometer", title: "Vitesse", value: String(format: "%.1f", abs(d.speed)), tint: .cyan)
                MetricTile(icon: "flag.checkered", title: "Max", value: String(format: "%.1f", ble.maxSpeed), tint: .purple)
                MetricTile(icon: "chart.line.uptrend.xyaxis", title: "Moyenne",
                           value: recorder.averageSpeed > 0 ? String(format: "%.1f", recorder.averageSpeed) : "—", tint: .teal)
                MetricTile(icon: "gauge.with.dots.needle.67percent", title: "PWM",
                           value: d.hasPWM ? String(format: "%.0f %%", d.pwm) : "—", tint: pwmColor(d.pwm))
                MetricTile(icon: "bolt.horizontal.fill", title: d.hasBatteryCurrent ? "Courant" : "Courant ph.",
                           value: String(format: "%.1f A", d.phaseCurrent), tint: .yellow)
                MetricTile(icon: "powerplug.fill", title: "Puissance",
                           value: d.power.map { String(format: "%.0f W", $0) } ?? "—", tint: .orange)
                MetricTile(icon: "point.topleft.down.curvedto.point.bottomright.up", title: "Trajet",
                           value: String(format: "%.2f km", max(d.tripDistance, recorder.currentDistance)), tint: .green)
                MetricTile(icon: "road.lanes", title: "Total", value: String(format: "%.0f km", d.totalDistance), tint: .green)
                MetricTile(icon: "timer", title: "Temps", value: durationText(recorder.rideSeconds), tint: .mint)
                MetricTile(icon: "speedometer", title: "Limite",
                           value: d.speedLimitKnown ? String(format: "%.0f km/h", d.speedLimit) : "—", tint: .orange)
                MetricTile(icon: "leaf.fill", title: "Énergie",
                           value: d.hasBatteryCurrent ? String(format: "%.0f Wh", recorder.energyWh) : "—", tint: .green)
                MetricTile(icon: "arrow.triangle.2.circlepath", title: "Récupérée",
                           value: d.hasBatteryCurrent ? String(format: "%.0f Wh", recorder.recoveredWh) : "—", tint: .blue)
            }
        }
        .glassCard()
    }
}

/// Réglages envoyés à la roue (phare, pédales…) et informations du véhicule.
struct WheelSettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var showControlScreen = false

    var body: some View {
        List {
            Section("Véhicule") {
                LabeledContent("Nom", value: ble.connectedName ?? "—")
                LabeledContent("Marque", value: ble.activeBrand.label)
                LabeledContent("Modèle", value: ble.data.model ?? "—")
                LabeledContent("Firmware", value: ble.data.firmwareString)
                LabeledContent("Compteur", value: String(format: "%.0f km", ble.data.totalDistance))
                LabeledContent("Limite actuelle", value: ble.data.speedLimitKnown ? String(format: "%.0f km/h", ble.data.speedLimit) : "—")
            }
            Section {
                ControlsCard().listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section {
                NavigationLink { MaintenanceView() } label: { Label("Entretien", systemImage: "calendar.badge.clock") }
                NavigationLink { EventLogView() } label: { Label("Journal d'erreurs", systemImage: "exclamationmark.triangle") }
                NavigationLink { BatteryHealthView() } label: { Label("Santé de la batterie", systemImage: "heart.text.square") }
                NavigationLink { BatteryCellsView() } label: { Label("Cellules de la batterie", systemImage: "battery.100percent") }
                NavigationLink { BlackBoxListView() } label: { Label("Boîte noire", systemImage: "record.circle") }
                CertificateButton()
                Button { showControlScreen = true } label: { Label("Écran Contrôle (police)", systemImage: "checkmark.shield") }
                NavigationLink { AppointmentRequestView() } label: { Label("Rendez-vous chez \(Business.name)", systemImage: "calendar.badge.plus") }
            }
            if ble.activeBrand == .inmotion {
                Section {
                    Text("Sur la P6, seuls la limite de vitesse et la télémétrie sont confirmés. Les autres réglages de l'appli InMotion (phares, son, pédales, verrouillage…) arriveront après une capture Bluetooth de l'appli officielle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .themedList()
        .navigationTitle("Réglages de la roue")
        .fullScreenCover(isPresented: $showControlScreen) { ControlScreenView().environmentObject(ble) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
    }
}

func pwmColor(_ pwm: Double) -> Color {
    if pwm >= 80 { return .red }
    if pwm >= 60 { return .orange }
    return .green
}

// MARK: - Bandeau d'état

struct StatusBanner: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline)
            Spacer()
            if ble.state == .connected {
                Text("\(ble.framesReceived) trames").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var color: Color {
        switch ble.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .red
        }
    }

    private var text: String {
        switch ble.state {
        case .bluetoothOff: return "Bluetooth désactivé"
        case .unauthorized: return "Accès Bluetooth refusé (Réglages > LynxDash)"
        case .idle: return "Non connecté"
        case .scanning: return "Recherche…"
        case .connecting: return "Connexion à \(ble.connectedName ?? "la roue")…"
        case .connected:
            if ble.framesReceived == 0 { return "Connecté, en attente de données…" }
            return "Connecté"
        }
    }
}

// MARK: - Compteur de vitesse

struct SpeedGauge: View {
    let speed: Double
    let pwm: Double
    var showPWM: Bool = true
    let maxSpeed: Double
    private let scaleMax: Double = 80

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * min(speed / scaleMax, 1))
                .stroke(pwmColor(pwm), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.2), value: speed)
            VStack(spacing: 2) {
                Text(String(format: "%.0f", speed))
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h").font(.title3).foregroundStyle(.secondary)
                if showPWM {
                    Text(String(format: "PWM %.0f %%", pwm))
                        .font(.headline)
                        .foregroundStyle(pwmColor(pwm))
                        .padding(.top, 4)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Batterie

struct BatteryBar: View {
    let percent: Double
    let voltage: Double
    let charging: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: charging ? "battery.100.bolt" : "battery.75")
                Text(String(format: "%.0f %%", percent)).font(.title2.bold()).monospacedDigit()
                Spacer()
                Text(String(format: "%.1f V", voltage)).font(.title3).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(percent / 100))
                }
            }
            .frame(height: 14)
        }
        .glassCard()
    }

    private var color: Color {
        if percent < 20 { return .red }
        if percent < 40 { return .orange }
        return .green
    }
}

// MARK: - Tuile

struct Tile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Bridage

struct LimiterCard: View {
    @EnvironmentObject var ble: BLEManager
    @State private var confirmEngage = false
    @State private var confirmRelease = false
    @State private var askPin = false

    private var engaged: Bool { ble.isLimited || ble.pendingAction == .engage }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.headline)
                Spacer()
                if ble.limiterBusy { ProgressView() }
            }

            if let pending = ble.pendingAction {
                HStack {
                    Image(systemName: "hourglass")
                    Text(pending == .engage ? "Bridage programmé : s'appliquera à l'arrêt"
                                            : "Débridage programmé : s'appliquera à l'arrêt")
                        .font(.subheadline)
                    Spacer()
                    Button("Annuler") { ble.cancelPending() }
                        .font(.subheadline)
                }
                .foregroundStyle(.orange)
            } else if engaged && ble.isPermanentlyLimited {
                Label("Bridée définitivement en atelier", systemImage: "lock.shield.fill")
                    .font(.subheadline.bold()).foregroundStyle(Theme.gold)
            } else {
                HoldButton(title: engaged ? "Maintenir 2 s pour débrider" : "Maintenir 2 s pour brider",
                           tint: engaged ? .green : .orange,
                           disabled: ble.limiterBusy || ble.state != .connected) {
                    if engaged { if PinLock.required { askPin = true } else { confirmRelease = true } }
                    else { confirmEngage = true }
                }
            }

            if ble.isLimited {
                Label("Mode EDM : 25 km/h, vitesse maximale des engins de déplacement motorisés autorisés sur la voie publique en Belgique",
                      systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let message = ble.limiterMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .pinProtected($askPin, title: "Code PIN pour débrider") { run(.release, pinVerified: true) }
        .alert("Brider la roue à 25 km/h ?", isPresented: $confirmEngage) {
            Button("Brider", role: .destructive) { run(.engage) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Si tu roules, le bridage s'appliquera automatiquement dès ton prochain arrêt. La limite actuelle (\(Int(ble.data.speedLimit)) km/h) sera restaurée au débridage.")
        }
        .alert("Débrider la roue ?", isPresented: $confirmRelease) {
            Button("Débrider", role: .destructive) { run(.release) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Retour à la limite d'origine : \(ble.normalLimit.map { "\($0) km/h" } ?? "inconnue").")
        }
    }

    private var title: String {
        if ble.isLimited { return "Bloquée à 25 km/h · voie publique" }
        if ble.pendingAction == .engage { return "Bridage en attente" }
        return "Bridage 25 km/h"
    }

    private var icon: String {
        if ble.pendingAction != nil { return "lock.badge.clock" }
        return ble.isLimited ? "lock.fill" : "lock.open.fill"
    }

    private var tint: Color {
        if ble.pendingAction != nil { return .yellow }
        return ble.isLimited ? .orange : .green
    }

    private func run(_ action: LimiterAction, pinVerified: Bool = false) {
        ble.limiterMessage = nil
        Task { @MainActor in
            let outcome = action == .engage ? await ble.engageLimiter() : await ble.releaseLimiter(pinVerified: pinVerified)
            ble.limiterMessage = outcome.message(for: action)
            UINotificationFeedbackGenerator().notificationOccurred(outcome.isFailure ? .error : .success)
        }
    }
}

/// Bouton à maintenir appuyé : se remplit pendant 2 secondes avant de déclencher l'action.
struct HoldButton: View {
    let title: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.2))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.7))
                    .frame(width: pressing ? geo.size.width : 0)
                    .animation(pressing ? .linear(duration: 2) : .easeOut(duration: 0.2), value: pressing)
            }
            Text(title).font(.headline).frame(maxWidth: .infinity)
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(disabled ? 0.4 : 1)
        .allowsHitTesting(!disabled)
        .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
            pressing = false
            action()
        } onPressingChanged: { isPressing in
            pressing = isPressing
            if isPressing { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }
}

// MARK: - Commandes de la roue

struct ControlsCard: View {
    @EnvironmentObject var ble: BLEManager
    @State private var light: LightMode = .on
    @State private var pedals: PedalsMode = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Commandes").font(.headline)
                Spacer()
                Button {
                    SafetyMonitor.shared.horn()
                } label: {
                    Label("Klaxon", systemImage: "speaker.wave.3.fill")
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
            }
            Picker("Phare", selection: $light) {
                Text("Phare éteint").tag(LightMode.off)
                Text("Allumé").tag(LightMode.on)
                if ble.supportsSpecialLight { Text(ble.specialLightLabel).tag(LightMode.special) }
            }
            .pickerStyle(.segmented)
            .onChange(of: light) { _, mode in ble.setLight(mode) }
            .disabled(!ble.supportsLight)

            Picker("Pédales", selection: $pedals) {
                ForEach(PedalsMode.allCases) { Text("Pédales \($0.label.lowercased())").tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: pedals) { _, mode in ble.setPedals(mode) }
            .disabled(!ble.supportsPedals)
            if !ble.supportsLight && ble.state == .connected {
                Text("Phare et pédales : commandes pas encore disponibles pour \(ble.activeBrand.shortLabel).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(ble.state != .connected)
        .opacity(ble.state == .connected ? 1 : 0.5)
        .glassCard()
    }
}

// MARK: - Antivol

struct AntiTheftCard: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var safety = SafetyMonitor.shared
    @State private var confirm = false
    @State private var askPinDisarm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: safety.antiTheftArmed ? "shield.lefthalf.filled" : "shield")
                    .foregroundStyle(safety.antiTheftArmed ? .orange : .secondary)
                Text(safety.antiTheftArmed ? "Antivol armé" : "Antivol").font(.headline)
                Spacer()
                if safety.sirenActive {
                    Button("Couper la sirène") { safety.stopSiren() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            Text("Bride la roue à \(SafetyMonitor.antiTheftLimit) km/h et déclenche une sirène sur le téléphone et la montre si elle bouge. Le téléphone doit rester à portée Bluetooth.")
                .font(.caption).foregroundStyle(.secondary)
            Button(safety.antiTheftArmed ? "Désarmer" : "Armer l'antivol") {
                if safety.antiTheftArmed {
                    if PinLock.required { askPinDisarm = true } else { Task { await safety.disarmAntiTheft() } }
                } else {
                    confirm = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(ble.state != .connected && !safety.antiTheftArmed)
            if let m = safety.antiTheftMessage {
                Text(m).font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .pinProtected($askPinDisarm, title: "Code PIN pour désarmer l'antivol") {
            Task { await safety.disarmAntiTheft() }
        }
        .alert("Armer l'antivol ?", isPresented: $confirm) {
            Button("Armer") { Task { await safety.armAntiTheft() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La roue sera bridée à \(SafetyMonitor.antiTheftLimit) km/h jusqu'au désarmement.")
        }
    }
}

/// Bandeau affiché quand la roue est bloquée à 25 km/h.
struct PermanentLimitBadge: View {
    @EnvironmentObject var ble: BLEManager
    @State private var showControl = false

    private var status: String {
        guard ble.state == .connected else { return "Roue non connectée" }
        if ble.isLimited { return "Limite lue sur la roue : 25 km/h ✓" }
        if ble.pendingAction == .engage { return "Bridage en cours d'application…" }
        return "Vérification de la limite…"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("🇧🇪").font(.system(size: 40))
            VStack(alignment: .leading, spacing: 3) {
                Text("Bridée définitivement à 25 km/h")
                    .font(.headline).foregroundStyle(.white)
                Text("Bridage réalisé en atelier par \(Business.name), conforme à la réglementation belge (engin de déplacement motorisé, voie publique).")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                Text((ble.connectedName.map { "\($0) · " } ?? "") + status)
                    .font(.caption2.bold()).foregroundStyle(ble.isLimited ? .green : Theme.gold)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.green)
        }
        .padding(14)
        .background(LinearGradient(colors: [Color.black.opacity(0.55), Color(red: 0.99, green: 0.85, blue: 0.1).opacity(0.25),
                                            Color(red: 0.94, green: 0.2, blue: 0.2).opacity(0.3)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.green.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { showControl = true }
        .fullScreenCover(isPresented: $showControl) { ControlScreenView().environmentObject(ble) }
    }
}

/// Vitesse max (limite restaurée quand le casque débride la roue) — menu atelier caché.
struct MaxSpeedSection: View {
    @EnvironmentObject var ble: BLEManager
    @State private var draft: Double = 40
    @State private var message: String?

    private var current: String {
        guard let v = ble.normalLimit else { return "Inconnue" }
        return v == 0 ? "Désactivée" : "\(v) km/h"
    }

    var body: some View {
        Section {
            LabeledContent("Actuelle", value: current)
            Stepper(value: $draft, in: 10...Double(ble.speedLimitRange.upperBound), step: 1) {
                HStack {
                    Text("Nouvelle vitesse max")
                    Spacer()
                    Text(String(format: "%.0f km/h", draft)).foregroundStyle(.secondary)
                }
            }
            Button("Appliquer la vitesse max") {
                let v = Int(draft)
                message = "Envoi…"
                Task { @MainActor in message = await ble.setMaxSpeed(v) }
            }
            .disabled(ble.state != .connected)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Vitesse maximale et débridage")
        } footer: {
            Text("Limite envoyée à la roue quand le casque la débride. Sans casque, la roue reste à 25 km/h.")
        }
        .onAppear { if let v = ble.normalLimit, v >= 10 { draft = Double(v) } }
    }
}

/// Réglages atelier cachés (appui long sur le logo + code atelier).
struct AtelierHiddenView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var showWorkshop = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showWorkshop = true
                    } label: {
                        Label("Atelier : fiches, factures, RDV, relances", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink { TripHistoryView() } label: { Label("Historique des trajets", systemImage: "map") }
                    NavigationLink { AdvancedSettingsView() } label: { Label("Réglages avancés (montre, alarmes, diagnostic)", systemImage: "gearshape.2") }
                    NavigationLink { ZonesView() } label: { Label("Zones de bridage GPS", systemImage: "mappin.and.ellipse") }
                    NavigationLink { ClientFileListView() } label: { Label("Fiches clients", systemImage: "person.crop.rectangle.stack") }
                    NavigationLink { FleetView() } label: { Label("Roues des clients (suivi à distance)", systemImage: "dot.radiowaves.left.and.right") }
                    NavigationLink { TamperLogView() } label: { Label("Débridages détectés", systemImage: "exclamationmark.shield") }
                    NavigationLink { LoanView() } label: { Label("Roue de prêt", systemImage: "arrow.left.arrow.right.circle") }
                    NavigationLink { BatteryCellsView() } label: { Label("Cellules de la batterie", systemImage: "battery.100percent") }
                } header: {
                    Text(Business.name)
                }
                MaxSpeedSection()
                HelmetTriggerSection()
                Section {
                    Text("Sans le casque, toutes les roues restent bridées à 25 km/h. Ces réglages n'existent que sur cet iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .themedList()
            .navigationTitle("Atelier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .sheet(isPresented: $showWorkshop) { WorkshopView().environmentObject(ble) }
        }
    }
}

struct BelgiumBadge: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("🇧🇪").font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bloquée à 25 km/h").font(.headline).foregroundStyle(.white)
                Text("Mode autorisé sur la voie publique en Belgique (engin de déplacement motorisé)")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.green)
        }
        .padding(14)
        .background(LinearGradient(colors: [Color.green.opacity(0.35), Color.green.opacity(0.12)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.green.opacity(0.5)))
    }
}
