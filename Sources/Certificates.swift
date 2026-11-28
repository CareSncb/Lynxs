import Charts
import CoreImage.CIFilterBuiltins
import CryptoKit
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Outils PDF communs

enum PDFKitLite {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 en points

    static func qr(_ text: String, size: CGFloat) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Petit moteur de mise en page : texte ligne par ligne, avec saut de page.
    final class Writer {
        let ctx: UIGraphicsPDFRendererContext
        var y: CGFloat = 40
        let margin: CGFloat = 40
        var width: CGFloat { PDFKitLite.page.width - 2 * margin }

        init(_ ctx: UIGraphicsPDFRendererContext) { self.ctx = ctx }

        func ensure(_ h: CGFloat) {
            if y + h > PDFKitLite.page.height - 50 { ctx.beginPage(); y = 40 }
        }

        @discardableResult
        func text(_ s: String, size: CGFloat = 11, bold: Bool = false, color: UIColor = .black,
                  align: NSTextAlignment = .left, x: CGFloat? = nil, w: CGFloat? = nil) -> CGFloat {
            let p = NSMutableParagraphStyle(); p.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: color, .paragraphStyle: p]
            let ww = w ?? width
            let h = (s as NSString).boundingRect(with: CGSize(width: ww, height: 2000), options: .usesLineFragmentOrigin,
                                                 attributes: attrs, context: nil).height
            ensure(h)
            (s as NSString).draw(in: CGRect(x: x ?? margin, y: y, width: ww, height: h + 2), withAttributes: attrs)
            y += h + 4
            return h
        }

        func row(_ label: String, _ value: String) {
            ensure(18)
            let start = y
            text(label, size: 11, color: .darkGray, w: 200)
            let after = y
            y = start
            text(value, size: 11, bold: true, x: margin + 210, w: width - 210)
            y = max(y, after)
        }

        func line() {
            ensure(10)
            let c = ctx.cgContext
            c.setStrokeColor(UIColor(white: 0.8, alpha: 1).cgColor)
            c.setLineWidth(0.5)
            c.move(to: CGPoint(x: margin, y: y + 3)); c.addLine(to: CGPoint(x: margin + width, y: y + 3))
            c.strokePath()
            y += 10
        }

        func header(title: String) {
            if let logo = UIImage(named: "Logo") {
                let r = CGRect(x: margin, y: y, width: 60, height: 60)
                ctx.cgContext.saveGState()
                UIBezierPath(ovalIn: r).addClip()
                logo.draw(in: r)
                ctx.cgContext.restoreGState()
            }
            let top = y
            text(Business.name, size: 18, bold: true, x: margin + 72, w: width - 72)
            for l in Business.headerLines { text(l, size: 9, color: .darkGray, x: margin + 72, w: width - 72) }
            y = max(y, top + 66)
            text(title, size: 20, bold: true, color: UIColor(red: 0.85, green: 0.35, blue: 0.05, alpha: 1))
            line()
        }
    }

    static func render(name: String, _ body: (Writer) -> Void) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                body(Writer(ctx))
            }
            return url
        } catch { return nil }
    }
}

// MARK: - Certificat de bridage

enum BridleCertificate {
    static func make(ble: BLEManager) -> URL? {
        let d = ble.data
        let now = Date()
        let wheel = ble.connectedName ?? "Roue"
        let model = d.model ?? ble.activeBrand.shortLabel
        let verified = ble.isLimited
        let fields = "\(wheel)|\(model)|\(Int(d.totalDistance))|\(Int(now.timeIntervalSince1970))|\(verified ? 25 : 0)"
        let ref = SHA256.hash(data: Data(fields.utf8)).prefix(5).map { String(format: "%02X", $0) }.joined()
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short; df.locale = Locale(identifier: "fr_BE")
        let qrText = """
        \(Business.name) — Certificat de bridage
        Roue : \(wheel) (\(model))
        Limite : 25 km/h \(verified ? "vérifiée sur la roue" : "non vérifiée")
        Compteur : \(Int(d.totalDistance)) km
        Date : \(df.string(from: now))
        Réf. : \(ref)
        """
        let file = "certificat-bridage-\(wheel.replacingOccurrences(of: " ", with: "-")).pdf"
        return PDFKitLite.render(name: file) { w in
            w.header(title: "Certificat de bridage à 25 km/h")
            w.text("🇧🇪  Engin de déplacement motorisé — réglementation belge", size: 12, bold: true)
            w.text("La vitesse maximale de cette gyroroue a été limitée à 25 km/h en atelier par \(Business.name). Le bridage est contrôlé en permanence par l'application : toute modification de la limite est détectée et la roue est rebridée automatiquement.", size: 11)
            w.y += 6
            w.row("Roue", wheel)
            w.row("Marque / modèle", model)
            w.row("Firmware", d.firmwareString)
            w.row("Compteur kilométrique", String(format: "%.0f km", d.totalDistance))
            w.row("Limite réglée dans la roue", d.speedLimitKnown ? String(format: "%.0f km/h", d.speedLimit) : "non communiquée par la roue")
            w.row("Vérification", verified ? "Limite de 25 km/h lue sur la roue ✓" : "Roue non connectée ou limite non lisible")
            w.row("Date et heure", df.string(from: now))
            w.row("Référence", ref)
            w.line()
            if let q = PDFKitLite.qr(qrText, size: 150) {
                w.ensure(170)
                q.draw(in: CGRect(x: w.margin, y: w.y, width: 150, height: 150))
                let top = w.y
                w.text("Le QR code reprend les informations ci-dessus.", size: 10, color: .darkGray,
                       x: w.margin + 170, w: w.width - 170)
                w.text("Cachet de l'atelier :", size: 10, color: .darkGray, x: w.margin + 170, w: w.width - 170)
                w.y = top + 160
            }
            w.text("Document généré par l'application de l'atelier \(Business.name). Il atteste l'état de la roue au moment de sa création.", size: 9, color: .gray)
        }
    }
}

struct CertificateButton: View {
    @EnvironmentObject var ble: BLEManager
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) { Label("Partager le certificat de bridage (PDF)", systemImage: "doc.badge.checkmark") }
            } else {
                Button { url = BridleCertificate.make(ble: ble) } label: {
                    Label("Créer le certificat de bridage (PDF)", systemImage: "doc.badge.checkmark")
                }
            }
        }
        .onChange(of: ble.isLimited) { _, _ in url = nil }
    }
}

// MARK: - Journal des débridages détectés

struct TamperEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var wheel: String
    var limitFound: Double
    var speed: Double
    var latitude: Double?
    var longitude: Double?
}

enum TamperLog {
    private static let key = "tamperLog"

    static var all: [TamperEvent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([TamperEvent].self, from: data) else { return [] }
        return list
    }

    static func record(wheel: String, limit: Double, speed: Double) {
        var list = all
        let loc = TripRecorder.shared.lastLocation
        list.insert(TamperEvent(date: Date(), wheel: wheel, limitFound: limit, speed: speed,
                                latitude: loc?.coordinate.latitude, longitude: loc?.coordinate.longitude), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(200))) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct TamperLogView: View {
    @State private var events = TamperLog.all

    var body: some View {
        List {
            if events.isEmpty {
                Text("Aucun débridage détecté sur cet iPhone.").foregroundStyle(.secondary)
            }
            ForEach(events) { e in
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.wheel).font(.headline)
                    Text(e.date.formatted(date: .long, time: .standard)).font(.caption)
                    Text(String(format: "Limite trouvée : %.0f km/h · vitesse %.0f km/h → rebridée à 25", e.limitFound, e.speed))
                        .font(.caption).foregroundStyle(Theme.ember)
                    if let lat = e.latitude, let lon = e.longitude,
                       let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=D%C3%A9bridage") {
                        Link("Voir l'endroit", destination: url).font(.caption)
                    }
                }
            }
            if !events.isEmpty {
                Section {
                    Button("Effacer le journal", role: .destructive) { TamperLog.clear(); events = [] }
                }
            }
        }
        .themedList()
        .navigationTitle("Débridages détectés")
    }
}

// MARK: - Rapport d'accident (boîte noire + photos)

enum AccidentReport {
    static func make(record r: BlackBoxRecord, photos: [UIImage], notes: String) -> URL? {
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .medium; df.locale = Locale(identifier: "fr_BE")
        let chart = renderChart(r)
        return PDFKitLite.render(name: "rapport-incident-\(Int(r.date.timeIntervalSince1970)).pdf") { w in
            w.header(title: "Rapport d'incident")
            w.row("Date et heure", df.string(from: r.date))
            w.row("Motif", r.reason)
            w.row("Roue", r.wheelName)
            w.row("Vitesse max (60 s)", String(format: "%.0f km/h", r.maxSpeed))
            if let p = r.maxPWM { w.row("PWM max", String(format: "%.0f %%", p)) }
            w.row("Tension mini", String(format: "%.1f V", r.minVoltage))
            if let lat = r.latitude, let lon = r.longitude {
                w.row("Position", String(format: "%.5f, %.5f", lat, lon))
                w.row("Plan", "https://maps.apple.com/?ll=\(lat),\(lon)")
            }
            if let f = RideWeather.shared.forecast, abs(f.fetched.timeIntervalSince(r.date)) < 3 * 3600 {
                w.row("Météo", String(format: "%.0f °C, pluie %d %%, rafales %.0f km/h", f.temperature, f.rainProbability, f.windGusts))
            }
            w.row("Juste avant", r.summary)
            w.line()
            if let chart {
                w.text("Télémétrie (0 s = incident)", size: 12, bold: true)
                let h = w.width * chart.size.height / chart.size.width
                w.ensure(h)
                chart.draw(in: CGRect(x: w.margin, y: w.y, width: w.width, height: h))
                w.y += h + 10
            }
            if !notes.isEmpty {
                w.text("Remarques", size: 12, bold: true)
                w.text(notes, size: 11)
                w.line()
            }
            for (i, img) in photos.enumerated() {
                let maxW = w.width, maxH: CGFloat = 330
                let k = min(maxW / img.size.width, maxH / img.size.height)
                let size = CGSize(width: img.size.width * k, height: img.size.height * k)
                w.ensure(size.height + 24)
                w.text("Photo \(i + 1)", size: 10, color: .darkGray)
                img.draw(in: CGRect(origin: CGPoint(x: w.margin, y: w.y), size: size))
                w.y += size.height + 10
            }
            w.text("Données enregistrées automatiquement par la boîte noire de l'application \(Business.name).", size: 9, color: .gray)
        }
    }

    /// Appelé depuis un bouton (fil principal).
    private static func renderChart(_ r: BlackBoxRecord) -> UIImage? {
        MainActor.assumeIsolated {
            let view = IncidentChart(record: r).frame(width: 515, height: 260).padding(4).background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.uiImage
        }
    }
}

private struct IncidentChart: View {
    let record: BlackBoxRecord
    var body: some View {
        Chart {
            ForEach(record.samples, id: \.self) { s in
                LineMark(x: .value("t", s.t), y: .value("Vitesse", s.speed), series: .value("", "Vitesse (km/h)"))
                    .foregroundStyle(.blue)
                if let p = s.pwm {
                    LineMark(x: .value("t", s.t), y: .value("PWM", p), series: .value("", "PWM (%)"))
                        .foregroundStyle(.orange)
                }
            }
            RuleMark(x: .value("Incident", 0)).foregroundStyle(.red)
        }
        .chartLegend(.visible)
        .environment(\.colorScheme, .light)
    }
}

struct AccidentReportSection: View {
    let record: BlackBoxRecord
    @State private var items: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var notes = ""
    @State private var url: URL?

    var body: some View {
        Section {
            PhotosPicker(selection: $items, maxSelectionCount: 6, matching: .images) {
                Label(photos.isEmpty ? "Ajouter des photos" : "\(photos.count) photo(s) ajoutée(s)", systemImage: "photo.on.rectangle")
            }
            TextField("Remarques (circonstances, témoins…)", text: $notes, axis: .vertical)
            if let url {
                ShareLink(item: url) { Label("Partager le rapport (PDF)", systemImage: "square.and.arrow.up") }
            } else {
                Button { url = AccidentReport.make(record: record, photos: photos, notes: notes) } label: {
                    Label("Créer le rapport d'incident (PDF)", systemImage: "doc.richtext")
                }
            }
        } header: {
            Text("Rapport pour l'assurance")
        }
        .onChange(of: items) { _, new in
            url = nil
            Task {
                var imgs: [UIImage] = []
                for it in new {
                    if let data = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        imgs.append(img)
                    }
                }
                await MainActor.run { photos = imgs }
            }
        }
        .onChange(of: notes) { _, _ in url = nil }
    }
}
