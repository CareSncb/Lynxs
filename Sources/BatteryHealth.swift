import Charts
import SwiftUI

// MARK: - Santé de la batterie : chute de tension sous charge et résistance interne

struct ResistancePoint: Codable, Hashable, Identifiable {
    var id: Date { date }
    var date: Date
    var milliohm: Double       // résistance interne estimée du pack
    var sagPerCell: Double     // plus forte chute de tension par cellule observée
    var km: Double             // compteur de la roue
}

/// Analyse en continu la tension et le courant pour repérer une batterie qui faiblit.
final class BatteryHealth: ObservableObject {
    static let shared = BatteryHealth()

    /// Résistance interne estimée pendant la session en cours (mΩ).
    @Published private(set) var sessionResistance: Double?
    /// Plus forte chute de tension par cellule pendant la session (V).
    @Published private(set) var sessionSag: Double = 0
    @Published private(set) var lastWarning: String?

    private struct Point { var date: Date; var v: Double; var i: Double; var speed: Double }
    private var window: [Point] = []
    private var estimates: [Double] = []
    private var restVoltage: (Date, Double)?
    private var lastLowAlert = Date.distantPast
    private var lastSagAlert = Date.distantPast
    private var trendChecked = false
    private var wheelID: String?

    /// Seuils d'alerte (V par cellule).
    private static let lowUnderLoad = 3.30
    private static let sagWarning = 0.35

    func ingest(_ d: WheelData, manager: BLEManager) {
        guard d.voltage > 0, manager.cellCount > 0 else { return }
        let now = Date()
        let cells = Double(manager.cellCount)
        if wheelID != manager.currentWheelID { reset(); wheelID = manager.currentWheelID }

        // Courant batterie : mesuré (InMotion) ou estimé à partir du courant de phase et du PWM
        let iBatt: Double
        if d.hasBatteryCurrent { iBatt = d.phaseCurrent }
        else if d.hasPWM { iBatt = d.phaseCurrent * max(0, min(1, d.pwm / 100)) }
        else { iBatt = d.phaseCurrent * 0.5 }

        // Tension au repos : roue presque à l'arrêt, courant faible
        if abs(iBatt) < 1.5, abs(d.speed) < 5 {
            restVoltage = (now, d.voltage)
        }

        window.append(Point(date: now, v: d.voltage, i: iBatt, speed: abs(d.speed)))
        window.removeAll { now.timeIntervalSince($0.date) > 30 }

        // Chute de tension par rapport au repos (valable 10 min)
        if let rest = restVoltage, now.timeIntervalSince(rest.0) < 600, iBatt > 5 {
            let sag = max(0, (rest.1 - d.voltage) / cells)
            if sag > sessionSag { sessionSag = sag }
            if sag >= Self.sagWarning, d.batteryPercent > 30, now.timeIntervalSince(lastSagAlert) > 300 {
                lastSagAlert = now
                warn(String(format: "Forte chute de tension sous effort (%.2f V par cellule) : batterie fatiguée ou connexion à vérifier", sag),
                     blackBox: "Chute de tension anormale")
            }
        }

        // Cellules trop basses sous charge alors que la batterie n'est pas vide : risque de coupure
        let perCell = d.voltage / cells
        if perCell < Self.lowUnderLoad, d.batteryPercent > 20, abs(d.speed) > 10,
           now.timeIntervalSince(lastLowAlert) > 120 {
            lastLowAlert = now
            warn(String(format: "Tension basse sous effort : %.2f V par cellule. Ralentis, risque de coupure.", perCell),
                 blackBox: "Tension basse sous effort", speak: true)
        }

        estimateResistance(now: now)
    }

    /// Régression tension / courant sur 30 s : la pente donne la résistance interne.
    private func estimateResistance(now: Date) {
        guard window.count >= 20 else { return }
        let iMin = window.map(\.i).min() ?? 0, iMax = window.map(\.i).max() ?? 0
        guard iMax - iMin >= 10 else { return }   // il faut des variations de charge franches
        let n = Double(window.count)
        let mi = window.reduce(0) { $0 + $1.i } / n
        let mv = window.reduce(0) { $0 + $1.v } / n
        var cov = 0.0, varI = 0.0, varV = 0.0
        for p in window {
            cov += (p.i - mi) * (p.v - mv)
            varI += (p.i - mi) * (p.i - mi)
            varV += (p.v - mv) * (p.v - mv)
        }
        guard varI > 0, varV > 0 else { return }
        let r = -cov / varI                         // Ω
        let corr = -cov / (varI.squareRoot() * varV.squareRoot())
        guard corr > 0.7, r > 0.005, r < 1.0 else { return }
        estimates.append(r * 1000)
        if estimates.count > 200 { estimates.removeFirst(estimates.count - 200) }
        window.removeAll()                           // fenêtre suivante indépendante
        sessionResistance = median(estimates)
    }

    /// Fin de session : enregistre la mesure et compare aux précédentes.
    func wheelDisconnected() {
        defer { reset() }
        guard let id = wheelID, let r = sessionResistance, estimates.count >= 5 else { return }
        let km = BLEManager.shared.data.totalDistance
        var history: [ResistancePoint] = []
        ProfileStore.shared.update(id) { p in
            var h = p.batteryHistory ?? []
            h.append(ResistancePoint(date: Date(), milliohm: r, sagPerCell: self.sessionSag, km: km))
            if h.count > 120 { h.removeFirst(h.count - 120) }
            p.batteryHistory = h
            history = h
        }
        // Tendance : +30 % par rapport à la moyenne des 5 sessions précédentes
        let previous = history.dropLast().suffix(5).map(\.milliohm)
        if previous.count >= 3 {
            let avg = previous.reduce(0, +) / Double(previous.count)
            if r > avg * 1.3 {
                SafetyMonitor.shared.notify(
                    title: "Santé de la batterie",
                    body: String(format: "Résistance interne en hausse (%.0f mΩ contre %.0f mΩ habituellement). Fais contrôler la batterie et les connecteurs.", r, avg))
            }
        }
    }

    func history(for id: String?) -> [ResistancePoint] {
        guard let id else { return [] }
        return ProfileStore.shared.profile(id)?.batteryHistory ?? []
    }

    private func warn(_ text: String, blackBox: String, speak: Bool = false) {
        DispatchQueue.main.async { self.lastWarning = text }
        SafetyMonitor.shared.notify(title: "Batterie", body: text)
        PhoneWatchBridge.shared.sendAlert(text)
        BlackBox.shared.trigger(blackBox)
        if speak { VoiceAnnouncer.shared.speak(text, urgent: true) }
    }

    private func reset() {
        window.removeAll()
        estimates.removeAll()
        restVoltage = nil
        sessionResistance = nil
        sessionSag = 0
    }

    private func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Verdict lisible pour une résistance par cellule-série (mΩ du pack / nombre de cellules en série).
    static func verdict(milliohm: Double, cells: Int) -> (String, Color) {
        guard cells > 0 else { return ("—", .secondary) }
        let perSeries = milliohm / Double(cells)
        if perSeries < 4 { return ("Excellente", .green) }
        if perSeries < 6.5 { return ("Bonne", .green) }
        if perSeries < 9 { return ("Correcte, à surveiller", .orange) }
        return ("Fatiguée", Theme.ember)
    }
}

struct BatteryHealthView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var health = BatteryHealth.shared

    var body: some View {
        let history = health.history(for: ble.currentWheelID)
        List {
            Section("Session en cours") {
                if let r = health.sessionResistance {
                    let v = BatteryHealth.verdict(milliohm: r, cells: ble.cellCount)
                    LabeledContent("Résistance interne", value: String(format: "%.0f mΩ", r))
                    LabeledContent("État") { Text(v.0).foregroundStyle(v.1).bold() }
                } else {
                    Text("Roule quelques minutes avec des accélérations franches pour obtenir une mesure.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Plus forte chute / cellule", value: health.sessionSag > 0 ? String(format: "%.2f V", health.sessionSag) : "—")
                if let w = health.lastWarning {
                    Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.ember).font(.caption)
                }
            }
            if !history.isEmpty {
                Section {
                    Chart(history) { p in
                        LineMark(x: .value("Date", p.date), y: .value("mΩ", p.milliohm))
                            .foregroundStyle(Theme.accent)
                        PointMark(x: .value("Date", p.date), y: .value("mΩ", p.milliohm))
                            .foregroundStyle(Theme.gold)
                    }
                    .chartYAxisLabel("mΩ")
                    .frame(height: 200)
                    ForEach(history.suffix(8).reversed()) { p in
                        HStack {
                            Text(p.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(String(format: "%.0f mΩ · %.2f V · %.0f km", p.milliohm, p.sagPerCell, p.km))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Historique de cette roue")
                } footer: {
                    Text("Une résistance qui grimpe au fil des semaines signale des cellules qui vieillissent ou un connecteur qui chauffe.")
                }
            }
            Section {
                Text("Estimation à partir de la tension et du courant envoyés par la roue (le courant batterie est déduit du courant de phase et du PWM quand la roue ne l'envoie pas). C'est un indicateur de tendance, pas une mesure de laboratoire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .themedList()
        .navigationTitle("Santé de la batterie")
    }
}
