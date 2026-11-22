import Foundation
import UIKit

// MARK: - Journal des roues clients

struct WheelVisit: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var totalKm: Double
    var voltage: Double
    var battery: Double
    var firmware: String
    var speedLimit: Double?
    var batterySag: Double?
    var work: String
}

struct WheelRecord: Codable, Identifiable {
    var id: String                 // identifiant Bluetooth de la roue
    var name: String
    var brand: String
    var model: String
    var client: String = ""
    var phone: String = ""
    var visits: [WheelVisit] = []
}

final class WorkshopStore: ObservableObject {
    static let shared = WorkshopStore()

    @Published private(set) var records: [WheelRecord] = []

    private let file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("atelier.json")

    init() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([WheelRecord].self, from: data) {
            records = list
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: file, options: .atomic) }
    }

    func record(id: String) -> WheelRecord? { records.first { $0.id == id } }

    func upsert(_ r: WheelRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.insert(r, at: 0) }
        records.sort { ($0.visits.last?.date ?? .distantPast) > ($1.visits.last?.date ?? .distantPast) }
        persist()
    }

    func delete(id: String) {
        records.removeAll { $0.id == id }
        persist()
    }

    /// Ajoute une intervention pour la roue actuellement connectée.
    func addVisit(client: String, phone: String, work: String) -> (WheelRecord, WheelVisit)? {
        let ble = BLEManager.shared
        guard ble.state == .connected, let id = ble.currentWheelID else { return nil }
        let d = ble.data
        var r = record(id: id) ?? WheelRecord(id: id, name: ble.connectedName ?? "Roue",
                                               brand: ble.activeBrand.shortLabel, model: d.model ?? "")
        if !client.isEmpty { r.client = client }
        if !phone.isEmpty { r.phone = phone }
        if let m = d.model { r.model = m }
        let visit = WheelVisit(date: Date(), totalKm: d.totalDistance, voltage: d.voltage,
                               battery: d.batteryPercent, firmware: d.firmwareString,
                               speedLimit: d.speedLimitKnown ? d.speedLimit : nil,
                               batterySag: BatteryTest.shared.result?.sagPerCell, work: work)
        r.visits.append(visit)
        upsert(r)
        return (r, visit)
    }
}

// MARK: - Fiche diagnostic PDF

enum DiagnosticReport {
    static func makePDF(record: WheelRecord, visit: WheelVisit, data: WheelData, cells: Int) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        df.locale = Locale(identifier: "fr_BE")

        let pdf = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 40
            let left: CGFloat = 40

            func text(_ s: String, size: CGFloat, bold: Bool = false, color: UIColor = .black) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let rect = CGRect(x: left, y: y, width: page.width - 2 * left, height: 1000)
                let h = (s as NSString).boundingRect(with: rect.size, options: .usesLineFragmentOrigin,
                                                     attributes: attrs, context: nil).height
                (s as NSString).draw(in: rect, withAttributes: attrs)
                y += ceil(h) + 4
            }
            func row(_ label: String, _ value: String) {
                let attrsL: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]
                let attrsV: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 11)]
                (label as NSString).draw(at: CGPoint(x: left, y: y), withAttributes: attrsL)
                (value as NSString).draw(at: CGPoint(x: left + 200, y: y), withAttributes: attrsV)
                y += 17
            }
            func line() {
                UIColor.lightGray.setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: page.width - left, y: y))
                path.stroke()
                y += 10
            }

            if let icon = UIImage(named: "Logo") {
                icon.draw(in: CGRect(x: page.width - left - 50, y: 34, width: 50, height: 50))
            }
            text(Business.name, size: 22, bold: true, color: UIColor.systemOrange)
            for line in Business.headerLines { text(line, size: 9, color: .darkGray) }
            text("Fiche diagnostic gyroroue", size: 15, bold: true)
            text(df.string(from: visit.date), size: 11, color: .darkGray)
            y += 6; line()

            text("Client", size: 13, bold: true)
            row("Nom", record.client.isEmpty ? "—" : record.client)
            row("Téléphone", record.phone.isEmpty ? "—" : record.phone)
            y += 6; line()

            text("Roue", size: 13, bold: true)
            row("Marque", record.brand)
            row("Nom Bluetooth", record.name)
            row("Modèle", record.model.isEmpty ? "—" : record.model)
            row("Firmware", visit.firmware)
            row("Kilométrage total", String(format: "%.1f km", visit.totalKm))
            y += 6; line()

            text("Mesures", size: 13, bold: true)
            row("Tension batterie", String(format: "%.2f V (%dS, %.2f V/cellule)", visit.voltage, cells, visit.voltage / Double(max(cells, 1))))
            row("Charge estimée", String(format: "%.0f %%", visit.battery))
            row("Température contrôleur", String(format: "%.1f °C", data.temperature))
            if let l = visit.speedLimit { row("Limite / tiltback", String(format: "%.0f km/h", l)) }
            if data.speedAlert > 0 { row("Alerte vitesse", String(format: "%.0f km/h", data.speedAlert)) }
            if let r = BatteryTest.shared.result {
                row("Test batterie : tension au repos", String(format: "%.2f V", r.restVoltage))
                row("Test batterie : tension mini en charge", String(format: "%.2f V", r.minVoltage))
                row("Test batterie : chute par cellule", String(format: "%.3f V — %@", r.sagPerCell, r.verdict))
            }
            y += 6; line()

            let errors = BLEManager.shared.eventLog.filter(\.isError).prefix(10)
            if !errors.isEmpty {
                text("Dernières erreurs enregistrées par la roue", size: 13, bold: true)
                for e in errors {
                    let when = e.date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "#\(e.index)"
                    text("\(when) — \(e.message)", size: 10, color: .darkGray)
                }
                y += 6; line()
            }

            text("Travaux réalisés", size: 13, bold: true)
            text(visit.work.isEmpty ? "—" : visit.work, size: 11)

            if record.visits.count > 1 {
                y += 6; line()
                text("Historique", size: 13, bold: true)
                for v in record.visits.dropLast().suffix(8).reversed() {
                    let short = DateFormatter.localizedString(from: v.date, dateStyle: .short, timeStyle: .none)
                    text("\(short) — \(String(format: "%.0f km", v.totalKm)) — \(v.work)", size: 10, color: .darkGray)
                }
            }

            y = page.height - 50
            text("Document généré par LynxDash — valeurs lues dans la roue via Bluetooth, à titre indicatif.",
                 size: 8, color: .gray)
        }

        let safeName = record.client.isEmpty ? record.name : record.client
        let name = "diagnostic-\(safeName.replacingOccurrences(of: " ", with: "_"))-\(Int(visit.date.timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try pdf.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Test de batterie (chute de tension sous charge)

struct BatteryTestResult {
    var restVoltage: Double
    var minVoltage: Double
    var maxCurrent: Double
    var cells: Int
    var samples: [(t: Double, v: Double, i: Double)]

    var sag: Double { restVoltage - minVoltage }
    var sagPerCell: Double { sag / Double(max(cells, 1)) }

    /// Repère indicatif (accélérations franches, roue réchauffée).
    var verdict: String {
        if sagPerCell < 0.15 { return "bonne" }
        if sagPerCell < 0.30 { return "correcte / à surveiller" }
        return "fatiguée"
    }
}

final class BatteryTest: ObservableObject {
    static let shared = BatteryTest()

    @Published private(set) var running = false
    @Published private(set) var remaining = 0
    @Published private(set) var result: BatteryTestResult?
    @Published private(set) var liveSamples: [(t: Double, v: Double, i: Double)] = []

    private var start = Date()
    private var restVoltage: Double = 0
    private var timer: Timer?
    let duration = 60

    func begin() {
        let d = BLEManager.shared.data
        restVoltage = d.voltage
        liveSamples = []
        result = nil
        start = Date()
        remaining = duration
        running = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.remaining -= 1
            if self.remaining <= 0 { t.invalidate(); self.finish() }
        }
    }

    func cancel() {
        timer?.invalidate()
        running = false
    }

    func ingest(_ d: WheelData) {
        guard running else { return }
        let t = Date().timeIntervalSince(start)
        if let last = liveSamples.last, t - last.t < 0.25 { return }
        liveSamples.append((t, d.voltage, abs(d.phaseCurrent)))
        // Tension au repos : la plus haute mesurée à faible courant
        if abs(d.phaseCurrent) < 2 { restVoltage = max(restVoltage, d.voltage) }
    }

    private func finish() {
        running = false
        guard !liveSamples.isEmpty else { return }
        let minV = liveSamples.map(\.v).min() ?? restVoltage
        let maxI = liveSamples.map(\.i).max() ?? 0
        result = BatteryTestResult(restVoltage: restVoltage, minVoltage: minV, maxCurrent: maxI,
                                   cells: BLEManager.shared.cellCount, samples: liveSamples)
    }
}
