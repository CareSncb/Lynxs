import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Vidéo de télémétrie à incruster (CapCut, iMovie, LumaFusion…)

enum OverlayBackground: String, CaseIterable, Identifiable {
    case green = "Fond vert (incrustation)"
    case alpha = "Transparent (HEVC alpha)"
    var id: String { rawValue }
}

enum OverlayLayout: String, CaseIterable, Identifiable {
    case vertical = "Vertical 9:16"
    case horizontal = "Horizontal 16:9"
    var id: String { rawValue }
    var size: CGSize { self == .vertical ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080) }
}

final class OverlayRenderer {
    let trip: Trip
    let from: Double
    let to: Double
    let background: OverlayBackground
    let layout: OverlayLayout
    let fps: Int32 = 15
    private let logo = UIImage(named: "Logo")

    init(trip: Trip, from: Double, to: Double, background: OverlayBackground, layout: OverlayLayout) {
        self.trip = trip; self.from = from; self.to = to; self.background = background; self.layout = layout
    }

    /// Valeurs interpolées entre deux échantillons (1 par seconde) pour une animation fluide.
    private func sample(at t: Double) -> TripSample? {
        let s = trip.samples
        guard !s.isEmpty else { return nil }
        guard let j = s.firstIndex(where: { $0.t >= t }) else { return s.last }
        if j == 0 { return s[0] }
        let a = s[j - 1], b = s[j]
        let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var out = a
        out.t = t
        out.speed = mix(a.speed, b.speed)
        if let pa = a.pwm, let pb = b.pwm { out.pwm = mix(pa, pb) }
        out.voltage = mix(a.voltage, b.voltage)
        out.battery = mix(a.battery, b.battery)
        out.temp = mix(a.temp, b.temp)
        out.current = mix(a.current, b.current)
        if let la = a.lat, let lb = b.lat, let oa = a.lon, let ob = b.lon { out.lat = mix(la, lb); out.lon = mix(oa, ob) }
        return out
    }

    func render(progress: @escaping (Double) -> Void) async throws -> URL {
        let size = layout.size
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynxdash-overlay-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: background == .alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let route = trip.coordinates
        let total = Int((to - from) * Double(fps))
        for frame in 0..<max(1, total) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            try Task.checkCancellation()
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { break }
            let t = from + Double(frame) / Double(fps)
            draw(into: buffer, size: size, sample: sample(at: t), route: route)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            if frame % 15 == 0 { let p = Double(frame) / Double(total); await MainActor.run { progress(p) } }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private func draw(into buffer: CVPixelBuffer, size: CGSize, sample s: TripSample?, route: [CLLocationCoordinate2D]) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // repère UIKit (origine en haut à gauche)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        if background == .green {
            ctx.setFillColor(UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        } else {
            ctx.clear(CGRect(origin: .zero, size: size))
        }
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        guard let s else { return }

        let vertical = layout == .vertical
        let panel = vertical
            ? CGRect(x: 60, y: size.height - 620, width: size.width - 120, height: 520)
            : CGRect(x: 60, y: size.height - 400, width: 900, height: 340)
        let orange = UIColor(red: 1, green: 0.5, blue: 0.1, alpha: 1)
        let ember = UIColor(red: 0.9, green: 0.12, blue: 0.1, alpha: 1)
        let gold = UIColor(red: 1, green: 0.74, blue: 0.28, alpha: 1)

        // Panneau sombre arrondi
        UIColor(white: 0, alpha: 0.55).setFill()
        UIBezierPath(roundedRect: panel, cornerRadius: 40).fill()

        // Jauge PWM (arc)
        let gaugeR: CGFloat = vertical ? 170 : 130
        let center = CGPoint(x: panel.minX + gaugeR + 40, y: panel.minY + gaugeR + 50)
        let start = CGFloat.pi * 0.75, sweep = CGFloat.pi * 1.5
        let track = UIBezierPath(arcCenter: center, radius: gaugeR, startAngle: start, endAngle: start + sweep, clockwise: true)
        track.lineWidth = 22; track.lineCapStyle = .round
        UIColor(white: 1, alpha: 0.15).setStroke(); track.stroke()
        let pwm = min(100, max(0, s.pwm ?? 0))
        if pwm > 0 {
            let arc = UIBezierPath(arcCenter: center, radius: gaugeR, startAngle: start,
                                   endAngle: start + sweep * CGFloat(pwm / 100), clockwise: true)
            arc.lineWidth = 22; arc.lineCapStyle = .round
            (pwm >= 80 ? ember : (pwm >= 60 ? orange : gold)).setStroke(); arc.stroke()
        }
        // Vitesse au centre
        func text(_ str: String, _ font: UIFont, _ color: UIColor, center c: CGPoint) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let sz = (str as NSString).size(withAttributes: attrs)
            (str as NSString).draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
        }
        func textLeft(_ str: String, _ font: UIFont, _ color: UIColor, at p: CGPoint) {
            (str as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
        }
        let big = UIFont.systemFont(ofSize: vertical ? 150 : 115, weight: .heavy)
        text(String(format: "%.0f", s.speed), big, .white, center: CGPoint(x: center.x, y: center.y - 10))
        text("km/h", .systemFont(ofSize: 34, weight: .semibold), UIColor(white: 1, alpha: 0.7), center: CGPoint(x: center.x, y: center.y + 80))
        if let p = s.pwm {
            text(String(format: "PWM %.0f %%", p), .systemFont(ofSize: 30, weight: .bold), orange,
                 center: CGPoint(x: center.x, y: center.y + gaugeR + 10))
        }

        // Colonne de valeurs
        let colX = center.x + gaugeR + 60
        var y = panel.minY + 50
        let label = UIFont.systemFont(ofSize: 30, weight: .medium)
        let value = UIFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        for (l, v, c) in [("Batterie", String(format: "%.0f %%", s.battery), UIColor.green),
                          ("Tension", String(format: "%.1f V", s.voltage), gold),
                          ("Temp.", String(format: "%.0f °C", s.temp), ember)] {
            textLeft(l, label, UIColor(white: 1, alpha: 0.6), at: CGPoint(x: colX, y: y))
            textLeft(v, value, c, at: CGPoint(x: colX, y: y + 32))
            y += 105
        }

        // Mini-carte du parcours (vertical : au-dessus du panneau)
        if route.count > 1 {
            let mapRect = vertical
                ? CGRect(x: size.width - 420, y: panel.minY - 440, width: 360, height: 360)
                : CGRect(x: size.width - 440, y: size.height - 420, width: 380, height: 360)
            UIColor(white: 0, alpha: 0.45).setFill()
            UIBezierPath(roundedRect: mapRect, cornerRadius: 30).fill()
            let lats = route.map(\.latitude), lons = route.map(\.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
            let span = max(maxLat - minLat, (maxLon - minLon) * cos(minLat * .pi / 180), 1e-6)
            let inner = mapRect.insetBy(dx: 30, dy: 30)
            func pt(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(x: inner.midX + CGFloat((lon - (minLon + maxLon) / 2) * cos(minLat * .pi / 180) / span) * inner.width,
                        y: inner.midY - CGFloat((lat - (minLat + maxLat) / 2) / span) * inner.height)
            }
            let path = UIBezierPath()
            for (i, c) in route.enumerated() {
                let p = pt(c.latitude, c.longitude)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.lineWidth = 6; path.lineJoinStyle = .round
            orange.setStroke(); path.stroke()
            if let lat = s.lat, let lon = s.lon {
                let p = pt(lat, lon)
                ember.setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)).fill()
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
                ring.lineWidth = 5; ring.stroke()
            }
        }

        // Logo et nom de la roue
        let logoRect = CGRect(x: panel.maxX - 130, y: panel.maxY - 130, width: 100, height: 100)
        if let logo {
            ctx.saveGState()
            UIBezierPath(ovalIn: logoRect).addClip()
            logo.draw(in: logoRect)
            ctx.restoreGState()
        }
        textLeft(trip.wheelName, .systemFont(ofSize: 30, weight: .bold), UIColor(white: 1, alpha: 0.85),
                 at: CGPoint(x: panel.minX + 40, y: panel.maxY - 60))
    }
}

struct OverlayVideoView: View {
    let trip: Trip
    @State private var from: Double = 0
    @State private var to: Double = 60
    @State private var background: OverlayBackground = .green
    @State private var layout: OverlayLayout = .vertical
    @State private var progress: Double?
    @State private var output: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var duration: Double { trip.samples.last?.t ?? 0 }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $layout) {
                    ForEach(OverlayLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Fond", selection: $background) {
                    ForEach(OverlayBackground.allCases) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("Fond vert : dans CapCut, ajoute la vidéo en incrustation puis « Supprimer l'arrière-plan › Clé chromatique ». Transparent : directement superposable dans iMovie, LumaFusion ou Final Cut.")
            }
            Section("Passage du trajet") {
                LabeledContent("Début", value: clock(from))
                Slider(value: $from, in: 0...max(1, duration - 5))
                    .onChange(of: from) { _, f in if to <= f { to = min(duration, f + 30) } }
                LabeledContent("Fin", value: clock(to))
                Slider(value: $to, in: 0...max(1, duration))
                Text(String(format: "Durée : %d:%02d (10 min max)", Int(to - from) / 60, Int(to - from) % 60))
                    .font(.caption).foregroundStyle(to - from > 600 ? Theme.ember : .secondary)
            }
            Section {
                if let p = progress {
                    ProgressView(value: p) { Text("Création de la vidéo…") }.tint(Theme.accent)
                    Button("Annuler", role: .destructive) { task?.cancel(); progress = nil }
                } else if let output {
                    ShareLink(item: output) { Label("Enregistrer / partager la vidéo", systemImage: "square.and.arrow.up") }
                    Button("Recommencer") { self.output = nil }
                } else {
                    Button { render() } label: { Label("Créer la vidéo", systemImage: "film") }
                        .disabled(to - from < 2 || to - from > 600)
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.ember) }
            } footer: {
                Text("Astuce : note l'heure de début de ta vidéo GoPro pour caler le passage. L'heure de chaque instant du trajet s'affiche ci-dessus.")
            }
        }
        .themedList()
        .navigationTitle("Vidéo incrustée")
        .onAppear { to = min(duration, 60) }
        .onDisappear { task?.cancel() }
    }

    private func clock(_ t: Double) -> String {
        trip.start.addingTimeInterval(t).formatted(date: .omitted, time: .standard)
            + String(format: "  (%d:%02d)", Int(t) / 60, Int(t) % 60)
    }

    private func render() {
        error = nil
        progress = 0
        let renderer = OverlayRenderer(trip: trip, from: from, to: to, background: background, layout: layout)
        task = Task.detached(priority: .userInitiated) {
            do {
                let url = try await renderer.render { p in progress = p }
                await MainActor.run { output = url; progress = nil }
            } catch is CancellationError {
                await MainActor.run { progress = nil }
            } catch {
                await MainActor.run { self.error = "Échec : \(error.localizedDescription)"; progress = nil }
            }
        }
    }
}
