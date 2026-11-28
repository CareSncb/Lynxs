import Charts
import SwiftUI

// MARK: - Boîte noire : les 60 dernières secondes de télémétrie, figées en cas d'incident

struct BlackBoxSample: Codable, Hashable {
    var t: Double          // secondes, 0 = moment de l'incident
    var speed: Double
    var pwm: Double?
    var voltage: Double
    var current: Double
    var temp: Double
    var battery: Double
    var pitch: Double?
}

struct BlackBoxRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var reason: String
    var wheelName: String
    var cells: Int
    var latitude: Double?
    var longitude: Double?
    var samples: [BlackBoxSample]

    var maxSpeed: Double { samples.map(\.speed).max() ?? 0 }
    var maxPWM: Double? { samples.compactMap(\.pwm).max() }
    var minVoltage: Double { samples.map(\.voltage).filter { $0 > 0 }.min() ?? 0 }

    /// Ce qui s'est passé juste avant l'incident, en une phrase.
    var summary: String {
        let before = samples.filter { $0.t <= 0 && $0.t >= -5 }
        var parts: [String] = []
        if let v = before.map(\.speed).max() { parts.append(String(format: "%.0f km/h", v)) }
        if let p = before.compactMap(\.pwm).max() { parts.append(String(format: "PWM max %.0f %%", p)) }
        if let low = before.map(\.voltage).filter({ $0 > 0 }).min(), cells > 0 {
            parts.append(String(format: "%.2f V/cellule mini", low / Double(cells)))
        }
        return parts.joined(separator: " · ")
    }
}

final class BlackBox: ObservableObject {
    static let shared = BlackBox()

    @Published private(set) var records: [BlackBoxRecord] = []

    private struct Live { var date: Date; var s: BlackBoxSample }
    private var buffer: [Live] = []
    private var pending: (reason: String, date: Date)?
    private var lastTrigger = Date.distantPast
    private var lastPWMTrigger = Date.distantPast

    private static let keepBefore: TimeInterval = 60
    private static let keepAfter: TimeInterval = 10
    private static let maxRecords = 50

    private let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boite-noire", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { load() }

    // MARK: Enregistrement

    func ingest(_ d: WheelData, manager: BLEManager) {
        let now = Date()
        buffer.append(Live(date: now, s: BlackBoxSample(
            t: 0, speed: abs(d.speed), pwm: d.hasPWM ? d.pwm : nil, voltage: d.voltage,
            current: d.phaseCurrent, temp: d.temperature, battery: d.batteryPercent,
            pitch: d.hasPitch ? d.pitchAngle : nil)))
        let horizon = Self.keepBefore + Self.keepAfter + 2
        if let first = buffer.first, now.timeIntervalSince(first.date) > horizon {
            buffer.removeAll { now.timeIntervalSince($0.date) > horizon }
        }

        // Déclencheur automatique : PWM très élevé (risque de coupure moteur)
        if d.hasPWM, d.pwm >= 90, now.timeIntervalSince(lastPWMTrigger) > 120 {
            lastPWMTrigger = now
            trigger("PWM à \(Int(d.pwm)) %")
        }

        if let p = pending, now.timeIntervalSince(p.date) >= Self.keepAfter { save() }
    }

    /// Fige les 60 s précédentes (plus 10 s après) sous un motif.
    func trigger(_ reason: String) {
        let now = Date()
        guard pending == nil, now.timeIntervalSince(lastTrigger) > 15 else { return }
        lastTrigger = now
        pending = (reason, now)
    }

    /// La roue s'est déconnectée : on enregistre tout de suite ce qu'on a.
    func wheelDisconnected() {
        if let last = buffer.last, Date().timeIntervalSince(last.date) < 3, last.s.speed >= 12 {
            if pending == nil { pending = ("Coupure Bluetooth en roulant", last.date) }
        }
        if pending != nil { save() }
        buffer.removeAll()
    }

    private func save() {
        guard let p = pending else { return }
        pending = nil
        let samples = buffer
            .filter { $0.date.timeIntervalSince(p.date) >= -Self.keepBefore }
            .map { live -> BlackBoxSample in
                var s = live.s
                s.t = live.date.timeIntervalSince(p.date)
                return s
            }
        guard samples.count >= 3 else { return }
        let ble = BLEManager.shared
        let loc = TripRecorder.shared.lastLocation
        let record = BlackBoxRecord(date: p.date, reason: p.reason, wheelName: ble.connectedName ?? "Roue",
                                    cells: ble.cellCount, latitude: loc?.coordinate.latitude,
                                    longitude: loc?.coordinate.longitude, samples: samples)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: folder.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
        }
        records.insert(record, at: 0)
        trim()
    }

    // MARK: Stockage

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        records = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(BlackBoxRecord.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    private func trim() {
        while records.count > Self.maxRecords, let old = records.popLast() {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(old.id.uuidString).json"))
        }
    }

    func delete(_ id: UUID) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
    }

    func exportCSV(_ r: BlackBoxRecord) -> URL? {
        var csv = "t_s,vitesse_kmh,pwm_pct,tension_v,courant_a,temp_c,batterie_pct,inclinaison_deg\n"
        for s in r.samples {
            csv += String(format: "%.2f,%.1f,%@,%.2f,%.1f,%.1f,%.0f,%@\n",
                          s.t, s.speed, s.pwm.map { String(format: "%.1f", $0) } ?? "",
                          s.voltage, s.current, s.temp, s.battery,
                          s.pitch.map { String(format: "%.1f", $0) } ?? "")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boite-noire-\(df.string(from: r.date)).csv")
        do { try csv.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}

// MARK: - Écrans

struct BlackBoxListView: View {
    @ObservedObject private var box = BlackBox.shared
    @EnvironmentObject var ble: BLEManager
    @State private var saved = false

    var body: some View {
        List {
            Section {
                Button {
                    box.trigger("Enregistrement manuel")
                    saved = true
                } label: {
                    Label("Figer les 60 dernières secondes", systemImage: "record.circle")
                }
                .disabled(ble.state != .connected)
                if saved {
                    Text("Enregistré dans 10 s (on garde aussi la suite).").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("La boîte noire garde en permanence la dernière minute de télémétrie. Elle se fige toute seule en cas de chute détectée, de coupure Bluetooth en roulant, de PWM au-delà de 90 %, de surchauffe ou de chute de tension anormale.")
            }
            Section("Incidents") {
                if box.records.isEmpty {
                    Text("Aucun incident enregistré").foregroundStyle(.secondary)
                }
                ForEach(box.records) { r in
                    NavigationLink {
                        BlackBoxDetailView(record: r)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.reason).font(.headline)
                            Text("\(r.date.formatted(date: .abbreviated, time: .standard)) · \(r.wheelName)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(r.summary).font(.caption2).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { box.delete(box.records[i].id) }
                }
            }
        }
        .themedList()
        .navigationTitle("Boîte noire")
    }
}

struct BlackBoxDetailView: View {
    let record: BlackBoxRecord

    private enum Metric: String, CaseIterable, Identifiable {
        case speed = "Vitesse", pwm = "PWM", voltage = "Tension", current = "Courant", temp = "Temp."
        var id: String { rawValue }
    }
    @State private var metric: Metric = .speed

    private func value(_ s: BlackBoxSample) -> Double? {
        switch metric {
        case .speed: return s.speed
        case .pwm: return s.pwm
        case .voltage: return s.voltage
        case .current: return s.current
        case .temp: return s.temp
        }
    }

    private var unit: String {
        switch metric {
        case .speed: return "km/h"
        case .pwm: return "%"
        case .voltage: return "V"
        case .current: return "A"
        case .temp: return "°C"
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Motif", value: record.reason)
                LabeledContent("Date", value: record.date.formatted(date: .long, time: .standard))
                LabeledContent("Roue", value: record.wheelName)
                LabeledContent("Vitesse max", value: String(format: "%.0f km/h", record.maxSpeed))
                if let p = record.maxPWM { LabeledContent("PWM max", value: String(format: "%.0f %%", p)) }
                LabeledContent("Tension mini", value: record.cells > 0
                               ? String(format: "%.1f V (%.2f V/cell.)", record.minVoltage, record.minVoltage / Double(record.cells))
                               : String(format: "%.1f V", record.minVoltage))
            }
            Section {
                Picker("Mesure", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Chart {
                    ForEach(record.samples, id: \.self) { s in
                        if let v = value(s) {
                            LineMark(x: .value("Temps", s.t), y: .value(unit, v))
                                .foregroundStyle(Theme.brandGradient)
                                .interpolationMethod(.monotone)
                        }
                    }
                    RuleMark(x: .value("Incident", 0))
                        .foregroundStyle(Theme.ember)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("incident").font(.caption2).foregroundStyle(Theme.ember)
                        }
                }
                .chartXAxisLabel("secondes")
                .chartYAxisLabel(unit)
                .frame(height: 240)
            } footer: {
                Text("0 s = moment de l'incident. Les valeurs négatives sont avant, les positives après.")
            }
            if let lat = record.latitude, let lon = record.longitude,
               let maps = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=Incident") {
                Section {
                    Link(destination: maps) { Label("Voir l'endroit sur Plans", systemImage: "map") }
                }
            }
            AccidentReportSection(record: record)
            if let csv = BlackBox.shared.exportCSV(record) {
                Section {
                    ShareLink(item: csv) { Label("Exporter en CSV", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .themedList()
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
    }
}
