import SwiftUI

// MARK: - Tableau de bord personnalisable (tuiles au choix, dans l'ordre voulu)

enum DashTile: String, CaseIterable, Identifiable {
    case speed, maxSpeed, average, pwm, margin, current, power, trip, total, time
    case limit, energy, recovered, temperature, voltage, cellVoltage, range, resistance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "Vitesse"
        case .maxSpeed: return "Max"
        case .average: return "Moyenne"
        case .pwm: return "PWM"
        case .margin: return "Marge"
        case .current: return "Courant"
        case .power: return "Puissance"
        case .trip: return "Trajet"
        case .total: return "Total"
        case .time: return "Temps"
        case .limit: return "Limite"
        case .energy: return "Énergie"
        case .recovered: return "Récupérée"
        case .temperature: return "Temp."
        case .voltage: return "Tension"
        case .cellVoltage: return "V/cellule"
        case .range: return "Autonomie"
        case .resistance: return "Batterie"
        }
    }

    var icon: String {
        switch self {
        case .speed: return "speedometer"
        case .maxSpeed: return "flag.checkered"
        case .average: return "chart.line.uptrend.xyaxis"
        case .pwm: return "gauge.with.dots.needle.67percent"
        case .margin: return "shield.lefthalf.filled"
        case .current: return "bolt.horizontal.fill"
        case .power: return "powerplug.fill"
        case .trip: return "point.topleft.down.curvedto.point.bottomright.up"
        case .total: return "road.lanes"
        case .time: return "timer"
        case .limit: return "speedometer"
        case .energy: return "leaf.fill"
        case .recovered: return "arrow.triangle.2.circlepath"
        case .temperature: return "thermometer.medium"
        case .voltage: return "bolt.fill"
        case .cellVoltage: return "battery.75"
        case .range: return "fuelpump.fill"
        case .resistance: return "heart.text.square"
        }
    }

    static let defaultOrder: [DashTile] = [.speed, .margin, .pwm, .current, .power, .range,
                                           .trip, .total, .time, .limit, .temperature, .cellVoltage]
}

struct DashboardGrid: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var recorder = TripRecorder.shared
    @ObservedObject private var alarms = SafetyAlarms.shared
    @ObservedObject private var health = BatteryHealth.shared
    @AppStorage("dashTiles") private var stored = ""
    @State private var editing = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    private var tiles: [DashTile] {
        let list = stored.split(separator: ",").compactMap { DashTile(rawValue: String($0)) }
        return list.isEmpty ? DashTile.defaultOrder : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Temps réel").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { editing = true } label: {
                    Image(systemName: "square.grid.3x3.square").foregroundStyle(Theme.accent)
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(tiles) { t in
                    MetricTile(icon: t.icon, title: t.title, value: value(t), tint: tint(t))
                }
            }
        }
        .glassCard()
        .sheet(isPresented: $editing) {
            DashboardEditor(stored: $stored, current: tiles)
        }
    }

    private func value(_ t: DashTile) -> String {
        let d = ble.data
        let connected = ble.state == .connected
        switch t {
        case .speed: return String(format: "%.1f", abs(d.speed))
        case .maxSpeed: return String(format: "%.1f", ble.maxSpeed)
        case .average: return recorder.averageSpeed > 0 ? String(format: "%.1f", recorder.averageSpeed) : "—"
        case .pwm: return d.hasPWM ? String(format: "%.0f %%", d.pwm) : "—"
        case .margin: return alarms.margin.map { String(format: "%.0f %%", $0) } ?? "—"
        case .current: return String(format: "%.1f A", d.phaseCurrent)
        case .power: return d.power.map { String(format: "%.0f W", $0) } ?? "—"
        case .trip: return String(format: "%.2f km", max(d.tripDistance, recorder.currentDistance))
        case .total: return String(format: "%.0f km", d.totalDistance)
        case .time:
            let s = Int(recorder.rideSeconds)
            return s >= 3600 ? String(format: "%dh%02d", s / 3600, (s % 3600) / 60) : String(format: "%d:%02d", s / 60, s % 60)
        case .limit: return d.speedLimitKnown ? String(format: "%.0f km/h", d.speedLimit) : "—"
        case .energy: return d.hasBatteryCurrent ? String(format: "%.0f Wh", recorder.energyWh) : "—"
        case .recovered: return d.hasBatteryCurrent ? String(format: "%.0f Wh", recorder.recoveredWh) : "—"
        case .temperature: return connected ? String(format: "%.0f °C", d.temperature) : "—"
        case .voltage: return connected ? String(format: "%.1f V", d.voltage) : "—"
        case .cellVoltage: return connected && ble.cellCount > 0 ? String(format: "%.2f V", d.voltage / Double(ble.cellCount)) : "—"
        case .range:
            guard connected, let e = RangePredictor.estimate(battery: d.batteryPercent, wheelName: ble.connectedName) else { return "—" }
            return String(format: "%.0f km", e.km)
        case .resistance: return health.sessionResistance.map { String(format: "%.0f mΩ", $0) } ?? "—"
        }
    }

    private func tint(_ t: DashTile) -> Color {
        let d = ble.data
        switch t {
        case .speed: return .cyan
        case .maxSpeed: return .purple
        case .average: return .teal
        case .pwm: return d.pwm >= 80 ? .red : (d.pwm >= 60 ? .orange : .green)
        case .margin:
            guard let m = alarms.margin else { return .white }
            return m < 15 ? .red : (m < 30 ? .orange : .green)
        case .current: return alarms.sustainedLoad ? .red : .yellow
        case .power: return .orange
        case .trip, .total, .energy: return .green
        case .time: return .mint
        case .limit: return Theme.accent
        case .recovered: return .blue
        case .temperature: return d.temperature >= 60 ? .red : Theme.gold
        case .voltage, .cellVoltage: return Theme.gold
        case .range: return .green
        case .resistance: return .pink
        }
    }
}

struct DashboardEditor: View {
    @Binding var stored: String
    @State var current: [DashTile]
    @Environment(\.dismiss) private var dismiss

    private var hidden: [DashTile] { DashTile.allCases.filter { !current.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section("Affichées (glisse pour réordonner)") {
                    ForEach(current) { t in Label(t.title, systemImage: t.icon) }
                        .onMove { current.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { current.remove(atOffsets: $0) }
                }
                if !hidden.isEmpty {
                    Section("Disponibles") {
                        ForEach(hidden) { t in
                            Button { current.append(t) } label: {
                                Label(t.title, systemImage: t.icon)
                            }
                        }
                    }
                }
                Section {
                    Button("Revenir à la disposition d'origine") { current = DashTile.defaultOrder }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Tableau de bord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        stored = current.map(\.rawValue).joined(separator: ",")
                        dismiss()
                    }
                }
            }
        }
    }
}
