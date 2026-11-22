import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

@main
struct LynxWatchApp: App {
    @StateObject private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchRoot().environmentObject(session)
        }
    }
}

/// Reçoit la télémétrie relayée par l'iPhone (la roue n'accepte qu'une connexion Bluetooth).
final class WatchSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published var connected = false
    @Published var limited = false
    @Published var pending = ""
    @Published var limit: Double = -1
    @Published var speed: Double = 0
    @Published var battery: Double = 0
    @Published var voltage: Double = 0
    @Published var pwm: Double = 0
    @Published var hasPWM = false
    @Published var temp: Double = 0
    @Published var trip: Double = 0
    @Published var name = ""
    @Published var antiTheft = false
    @Published var recording = false
    @Published var message: String?
    @Published var alert: String?
    @Published var busy = false
    @Published var lastUpdate: Date?

    private var pwmAlarm: Double = 0
    private var lastHaptic = Date.distantPast
    private var lastComplicationSave = Date.distantPast
    private var lastComplicationReload = Date.distantPast
    private var lastConnected: Bool?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var engaged: Bool { limited || pending == "engage" }

    func send(_ action: String) {
        guard WCSession.default.activationState == .activated else {
            message = "Connexion à l'iPhone…"
            return
        }
        busy = true
        WCSession.default.sendMessage(["action": action], replyHandler: { reply in
            DispatchQueue.main.async {
                self.busy = false
                self.apply(reply)
                if action != "status", let m = reply["message"] as? String {
                    WKInterfaceDevice.current().play(m.contains("impossible") ? .failure : .success)
                }
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                self.busy = false
                self.message = "iPhone injoignable : ouvre LynxDash sur l'iPhone"
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }

    private func apply(_ p: [String: Any]) {
        if (p["type"] as? String) == "alert" {
            alert = p["message"] as? String
            for i in 0..<4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                    WKInterfaceDevice.current().play(.notification)
                }
            }
            return
        }
        connected = p["connected"] as? Bool ?? false
        limited = p["limited"] as? Bool ?? false
        pending = p["pending"] as? String ?? ""
        limit = p["limit"] as? Double ?? -1
        name = p["name"] as? String ?? ""
        antiTheft = p["antiTheft"] as? Bool ?? false
        recording = p["recording"] as? Bool ?? false
        pwmAlarm = p["pwmAlarm"] as? Double ?? 0
        if let v = p["speed"] as? Double { speed = v }
        if let v = p["battery"] as? Double { battery = v }
        if let v = p["voltage"] as? Double { voltage = v }
        if let v = p["pwm"] as? Double { pwm = v }
        if let v = p["hasPWM"] as? Bool { hasPWM = v }
        if let v = p["temp"] as? Double { temp = v }
        if let v = p["trip"] as? Double { trip = v }
        if let m = p["message"] as? String { message = m }
        if !connected { speed = 0 }
        lastUpdate = Date()
        updateComplication()

        // Alerte PWM au poignet
        if connected, hasPWM, pwmAlarm > 0, pwm >= pwmAlarm, Date().timeIntervalSince(lastHaptic) > 1 {
            lastHaptic = Date()
            WKInterfaceDevice.current().play(.directionDown)
        }
    }

    /// Partage l'état avec la complication du cadran (budget de rafraîchissement limité).
    private func updateComplication() {
        let now = Date()
        guard now.timeIntervalSince(lastComplicationSave) > 20 || lastConnected != connected else { return }
        lastComplicationSave = now
        var snap = WidgetSnapshot.load()
        if !name.isEmpty { snap.wheelName = name }
        snap.battery = battery
        snap.voltage = voltage
        snap.speed = speed
        snap.connected = connected
        snap.limited = limited
        snap.updated = now
        snap.save()
        if lastConnected != connected || now.timeIntervalSince(lastComplicationReload) > 600 {
            lastComplicationReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
        lastConnected = connected
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.apply(message) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { self.apply(userInfo) }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            if !session.receivedApplicationContext.isEmpty { self.apply(session.receivedApplicationContext) }
            self.send("status")
        }
    }
}

struct WatchRoot: View {
    @EnvironmentObject var s: WatchSession

    var body: some View {
        TabView {
            DashboardPage()
            LimiterPage()
            ControlsPage()
        }
        .tabViewStyle(.verticalPage)
        .sheet(isPresented: Binding(get: { s.alert != nil }, set: { if !$0 { s.alert = nil } })) {
            AlertPage()
        }
        .onAppear { s.send("status") }
    }
}

struct DashboardPage: View {
    @EnvironmentObject var s: WatchSession

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Circle().fill(s.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(s.connected ? s.name : "Roue non connectée").font(.caption2).lineLimit(1)
                Spacer()
                if s.recording { Image(systemName: "record.circle").foregroundStyle(.red).font(.caption2) }
                if s.engaged { Image(systemName: "lock.fill").foregroundStyle(.orange).font(.caption2) }
            }
            Text(String(format: "%.0f", s.speed))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(pwmColor)
            Text("km/h").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(String(format: "%.0f %%", s.battery), systemImage: "battery.75")
                Spacer()
                if s.hasPWM {
                    Text(String(format: "PWM %.0f", s.pwm)).foregroundStyle(pwmColor)
                }
            }
            .font(.caption)
            HStack {
                Text(String(format: "%.0f °C", s.temp))
                Spacer()
                Text(String(format: "%.1f km", s.trip))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var pwmColor: Color {
        guard s.hasPWM else { return .primary }
        if s.pwm >= 80 { return .red }
        if s.pwm >= 60 { return .orange }
        return .primary
    }
}

struct LimiterPage: View {
    @EnvironmentObject var s: WatchSession
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: s.pending.isEmpty ? (s.limited ? "lock.fill" : "lock.open.fill") : "hourglass")
                    .font(.title2)
                    .foregroundStyle(s.pending.isEmpty ? (s.limited ? Color.orange : Color.green) : Color.yellow)
                Text(statusText).font(.headline).multilineTextAlignment(.center)

                Button {
                    confirm = true
                } label: {
                    Label(s.engaged ? "Débrider" : "Brider 25", systemImage: s.engaged ? "lock.open" : "lock")
                        .frame(maxWidth: .infinity)
                }
                .tint(s.engaged ? .green : .orange)
                .disabled(s.busy || !s.connected)

                if s.busy { ProgressView() }
                if let m = s.message {
                    Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .confirmationDialog(s.engaged ? "Débrider la roue ?" : "Brider à 25 km/h ?", isPresented: $confirm) {
            Button(s.engaged ? "Oui, débrider" : "Oui, brider", role: .destructive) {
                s.send(s.engaged ? "release" : "engage")
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var statusText: String {
        guard s.connected else { return "Roue non connectée" }
        if s.pending == "engage" { return "Bridage en attente de l'arrêt" }
        if s.pending == "release" { return "Débridage en attente de l'arrêt" }
        let limit = s.limit >= 0 ? String(format: "%.0f km/h", s.limit) : "—"
        return s.limited ? "Bridée à 25 km/h" : "Limite : \(limit)"
    }
}

struct ControlsPage: View {
    @EnvironmentObject var s: WatchSession

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button { s.send("horn") } label: {
                    Label("Klaxon", systemImage: "speaker.wave.3.fill").frame(maxWidth: .infinity)
                }
                .tint(.yellow)
                HStack {
                    Button { s.send("light_on") } label: { Image(systemName: "lightbulb.fill") }
                    Button { s.send("light_off") } label: { Image(systemName: "lightbulb.slash") }
                }
                .disabled(!s.connected)
                if s.antiTheft {
                    Label("Antivol armé", systemImage: "shield.lefthalf.filled").foregroundStyle(.orange)
                    Button("Couper la sirène") { s.send("stopAlarm") }
                }
            }
        }
    }
}

struct AlertPage: View {
    @EnvironmentObject var s: WatchSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.red)
            Text(s.alert ?? "").font(.headline).multilineTextAlignment(.center)
            Button("Je vais bien") {
                s.send("fallOK")
                s.send("stopAlarm")
                s.alert = nil
            }
            .tint(.green)
        }
    }
}
