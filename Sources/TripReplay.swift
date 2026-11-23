import Charts
import MapKit
import SwiftUI

// MARK: - Rejouer un trajet : curseur sur le graphique ↔ position sur la carte

struct TripReplayView: View {
    let trip: Trip
    @State private var index: Double = 0
    @State private var playing = false
    @State private var position: MapCameraPosition = .automatic
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var samples: [TripSample] { trip.samples }
    private var current: TripSample? {
        guard !samples.isEmpty else { return nil }
        return samples[min(samples.count - 1, max(0, Int(index)))]
    }

    /// Dernière position GPS connue jusqu'à l'échantillon courant.
    private var currentCoordinate: CLLocationCoordinate2D? {
        guard !samples.isEmpty else { return nil }
        var i = min(samples.count - 1, max(0, Int(index)))
        while i >= 0 {
            if let lat = samples[i].lat, let lon = samples[i].lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
            i -= 1
        }
        return nil
    }

    private var chartPoints: [TripSample] {
        let step = max(1, samples.count / 300)
        return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                if trip.coordinates.count > 1 {
                    MapPolyline(coordinates: trip.coordinates).stroke(Theme.accent, lineWidth: 4)
                }
                if let c = currentCoordinate {
                    Annotation("", coordinate: c) {
                        Circle().fill(Theme.ember).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: Theme.ember, radius: 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                if let s = current {
                    HStack {
                        readout(String(format: "%.1f", s.speed), "km/h", .cyan)
                        readout(s.pwm.map { String(format: "%.0f", $0) } ?? "—", "% PWM", .orange)
                        readout(String(format: "%.1f", s.voltage), "V", Theme.gold)
                        readout(String(format: "%.0f", s.current), "A", .yellow)
                        readout(String(format: "%.0f", s.temp), "°C", .red)
                    }
                    Text(timeText(s.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(Array(chartPoints.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("t", s.t), y: .value("km/h", s.speed), series: .value("", "v"))
                            .foregroundStyle(.cyan)
                        if let p = s.pwm {
                            LineMark(x: .value("t", s.t), y: .value("PWM", p), series: .value("", "p"))
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                    }
                    if let s = current {
                        RuleMark(x: .value("t", s.t)).foregroundStyle(.white)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 110)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                guard let plot = proxy.plotFrame else { return }
                                let x = g.location.x - geo[plot].origin.x
                                if let t: Double = proxy.value(atX: x) { seek(to: t) }
                            })
                    }
                }
                HStack(spacing: 16) {
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36))
                            .foregroundStyle(Theme.accent)
                    }
                    Slider(value: $index, in: 0...Double(max(1, samples.count - 1)), step: 1)
                        .tint(Theme.accent)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Rejouer")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in
            guard playing else { return }
            // lecture ×10 (1 échantillon par seconde de trajet)
            if index < Double(samples.count - 1) { index += 1 } else { playing = false }
        }
        .onChange(of: Int(index)) { _, _ in follow() }
    }

    private func readout(_ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func seek(to t: Double) {
        guard let i = samples.firstIndex(where: { $0.t >= t }) else { return }
        index = Double(i)
    }

    private func follow() {
        guard playing, let c = currentCoordinate else { return }
        position = .camera(MapCamera(centerCoordinate: c, distance: 900))
    }

    private func timeText(_ t: Double) -> String {
        let s = Int(t)
        let clock = trip.start.addingTimeInterval(t).formatted(date: .omitted, time: .standard)
        return String(format: "%d:%02d", s / 60, s % 60) + " · " + clock
    }
}
