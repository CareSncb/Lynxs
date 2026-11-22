import SwiftUI
import UIKit

/// Écran principal à onglets.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var safety = SafetyMonitor.shared

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Roue", systemImage: "gauge.with.dots.needle.67percent") }
            TripsView()
                .tabItem { Label("Trajets", systemImage: "map") }
            WorkshopView()
                .tabItem { Label("Atelier", systemImage: "wrench.and.screwdriver") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: Binding(get: { safety.fallCountdown != nil }, set: { _ in })) {
            FallAlertView()
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
    @State private var showScanner = false
    @State private var showHandlebar = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    StatusBanner()

                    SpeedGauge(speed: abs(ble.data.speed),
                               pwm: ble.data.pwm,
                               showPWM: ble.data.hasPWM,
                               maxSpeed: ble.maxSpeed)
                        .frame(height: 280)

                    BatteryBar(percent: ble.data.batteryPercent,
                               voltage: ble.data.voltage,
                               charging: ble.data.isCharging)

                    LimiterCard()

                    ControlsCard()

                    AntiTheftCard()

                    LazyVGrid(columns: columns, spacing: 12) {
                        Tile(title: "PWM", value: ble.data.hasPWM ? String(format: "%.0f %%", ble.data.pwm) : "—",
                             icon: "gauge.with.dots.needle.67percent",
                             tint: pwmColor(ble.data.pwm))
                        Tile(title: "Courant phase", value: String(format: "%.1f A", ble.data.phaseCurrent),
                             icon: "bolt.fill", tint: .yellow)
                        Tile(title: "Température", value: String(format: "%.1f °C", ble.data.temperature),
                             icon: "thermometer.medium",
                             tint: ble.data.temperature >= 65 ? .red : .orange)
                        Tile(title: "Limite roue",
                             value: ble.data.speedLimitKnown ? String(format: "%.0f km/h", ble.data.speedLimit) : "—",
                             icon: "speedometer", tint: .cyan)
                        Tile(title: "Trajet", value: String(format: "%.2f km", ble.data.tripDistance),
                             icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .green)
                        Tile(title: "Total", value: String(format: "%.0f km", ble.data.totalDistance),
                             icon: "road.lanes", tint: .green)
                        Tile(title: "Vitesse max", value: String(format: "%.1f km/h", ble.maxSpeed),
                             icon: "flag.checkered", tint: .purple)
                        Tile(title: ble.activeBrand.shortLabel, value: ble.data.model ?? ble.data.firmwareString,
                             icon: "cpu", tint: .gray)
                    }
                }
                .padding()
            }
            .navigationTitle(ble.connectedName ?? "LynxDash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showHandlebar = true } label: {
                        Label("Mode guidon", systemImage: "rectangle.expand.vertical")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if ble.state == .connected || ble.state == .connecting {
                        Button("Déconnecter", role: .destructive) { ble.disconnect() }
                    } else {
                        Menu {
                            Button("Chercher une roue") { showScanner = true }
                            if !ble.knownWheels.isEmpty {
                                Button("Reconnecter mes roues") { ble.connectKnownWheels() }
                            }
                        } label: {
                            Label("Connecter", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showHandlebar) {
                HandlebarView().environmentObject(ble)
            }
            .sheet(isPresented: $showScanner) {
                ScannerView().environmentObject(ble)
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
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
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Bridage

struct LimiterCard: View {
    @EnvironmentObject var ble: BLEManager
    @State private var confirmEngage = false
    @State private var confirmRelease = false

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
            } else {
                HoldButton(title: engaged ? "Maintenir 2 s pour débrider" : "Maintenir 2 s pour brider",
                           tint: engaged ? .green : .orange,
                           disabled: ble.limiterBusy || ble.state != .connected) {
                    if engaged { confirmRelease = true } else { confirmEngage = true }
                }
            }

            if let message = ble.limiterMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        if ble.isLimited { return "Bridée à 25 km/h" }
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

    private func run(_ action: LimiterAction) {
        ble.limiterMessage = nil
        Task { @MainActor in
            let outcome = action == .engage ? await ble.engageLimiter() : await ble.releaseLimiter()
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

            Picker("Pédales", selection: $pedals) {
                ForEach(PedalsMode.allCases) { Text("Pédales \($0.label.lowercased())").tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: pedals) { _, mode in ble.setPedals(mode) }
        }
        .disabled(ble.state != .connected)
        .opacity(ble.state == .connected ? 1 : 0.5)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Antivol

struct AntiTheftCard: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var safety = SafetyMonitor.shared
    @State private var confirm = false

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
                    Task { await safety.disarmAntiTheft() }
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
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .alert("Armer l'antivol ?", isPresented: $confirm) {
            Button("Armer") { Task { await safety.armAntiTheft() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La roue sera bridée à \(SafetyMonitor.antiTheftLimit) km/h jusqu'au désarmement.")
        }
    }
}
