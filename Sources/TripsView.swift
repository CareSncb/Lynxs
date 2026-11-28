import Charts
import MapKit
import SwiftUI

struct TripsView: View {
    @ObservedObject private var store = TripStore.shared
    @ObservedObject private var recorder = TripRecorder.shared
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if recorder.isRecording {
                        HStack {
                            Image(systemName: "record.circle").foregroundStyle(.red)
                            Text(String(format: "Enregistrement en cours · %.2f km", recorder.currentDistance))
                            Spacer()
                            Button("Arrêter") { recorder.stop() }
                        }
                    } else {
                        Button {
                            recorder.startManually()
                        } label: {
                            Label("Démarrer un trajet maintenant", systemImage: "record.circle")
                        }
                        .disabled(ble.state != .connected)
                    }
                } footer: {
                    Text("Les trajets démarrent tout seuls au-dessus de 3 km/h et s'arrêtent après 5 minutes d'arrêt.")
                }

                Section {
                    NavigationLink { LiveShareView() } label: {
                        Label("Partage en direct", systemImage: "dot.radiowaves.up.forward")
                    }
                    NavigationLink { GroupRideView() } label: {
                        Label("Sortie de groupe", systemImage: "person.3.fill")
                    }
                    NavigationLink { RangeCheckView() } label: {
                        Label("Est-ce que j'y arrive ?", systemImage: "fuelpump.fill")
                    }
                    NavigationLink { LeaderboardView() } label: {
                        Label("Classement et défis entre amis", systemImage: "trophy.fill")
                    }
                    NavigationLink { ChargingSpotsView() } label: {
                        Label("Prises partagées du club", systemImage: "powerplug.fill")
                    }
                    NavigationLink { WheelFinderView() } label: {
                        Label("Où est ma roue ?", systemImage: "location.magnifyingglass")
                    }
                }

            }
            .themedList()
            .navigationTitle("Trajets")
        }
    }
}

/// Historique des trajets (statistiques + liste) — accessible depuis le menu atelier caché.
struct TripHistoryView: View {
    @ObservedObject private var store = TripStore.shared

    var body: some View {
        List {
            Section {
                StatsCard()
            }
            Section("Trajets") {
                if store.trips.isEmpty {
                    Text("Aucun trajet pour l'instant").foregroundStyle(.secondary)
                }
                ForEach(store.trips) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        TripRow(trip: trip)
                    }
                }
                .onDelete { idx in
                    for i in idx { store.delete(id: store.trips[i].id) }
                }
            }
        }
        .themedList()
        .navigationTitle("Historique des trajets")
    }
}

struct StatsCard: View {
    @ObservedObject private var store = TripStore.shared
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stat("Aujourd'hui", store.distance(since: Calendar.current.startOfDay(for: Date())))
                stat("7 jours", store.distance(since: Date().addingTimeInterval(-7 * 86400)))
                stat("Total", store.totalDistance)
            }
            Chart(store.dailyDistances(), id: \.day) { item in
                BarMark(x: .value("Jour", item.day, unit: .day), y: .value("km", item.km))
                    .foregroundStyle(.orange)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 110)

            if let c = store.averageConsumption {
                HStack {
                    Label(String(format: "%.1f %% / km", c), systemImage: "bolt.batteryblock")
                    Spacer()
                    if ble.state == .connected, c > 0 {
                        Text(String(format: "Autonomie estimée : %.0f km", ble.data.batteryPercent / c))
                            .fontWeight(.semibold)
                    }
                }
                .font(.subheadline)
            } else {
                Text("Consommation et autonomie : disponibles après quelques trajets de plus d'1 km.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ km: Double) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f km", km)).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            HStack(spacing: 12) {
                Text(String(format: "%.1f km", trip.distance))
                Text(durationText(trip.duration))
                Text(String(format: "max %.0f km/h", trip.maxSpeed))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(trip.wheelName).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func durationText(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    return m >= 60 ? String(format: "%d h %02d", m / 60, m % 60) : "\(m) min"
}

struct TripDetailView: View {
    let trip: Trip
    @State private var gpxURL: URL?
    @State private var csvURL: URL?

    var body: some View {
        List {
            if trip.coordinates.count > 1 {
                Section {
                    Map {
                        MapPolyline(coordinates: trip.coordinates)
                            .stroke(.orange, lineWidth: 4)
                        if let first = trip.coordinates.first {
                            Marker("Départ", coordinate: first).tint(.green)
                        }
                        if let last = trip.coordinates.last {
                            Marker("Arrivée", coordinate: last).tint(.red)
                        }
                    }
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                NavigationLink { TripReplayView(trip: trip) } label: {
                    Label("Rejouer le trajet", systemImage: "play.circle.fill")
                }
                NavigationLink { OverlayVideoView(trip: trip) } label: {
                    Label("Vidéo de télémétrie à incruster", systemImage: "film.stack")
                }
            }

            Section("Résumé") {
                row("Distance", String(format: "%.2f km", trip.distance))
                row("Durée", durationText(trip.duration))
                row("Vitesse moyenne (en mouvement)", String(format: "%.1f km/h", trip.avgSpeed))
                row("Vitesse max", String(format: "%.1f km/h", trip.maxSpeed))
                if let p = trip.maxPWM { row("PWM max", String(format: "%.0f %%", p)) }
                row("Température max", String(format: "%.1f °C", trip.maxTemp))
                row("Batterie", String(format: "%.0f %% → %.0f %%", trip.batteryStart, trip.batteryEnd))
                if let c = trip.consumption { row("Consommation", String(format: "%.1f %% / km", c)) }
                if let r = trip.rideSeconds { row("Temps en mouvement", durationText(r)) }
                if let e = trip.energyWh { row("Énergie consommée", String(format: "%.0f Wh", e)) }
                if let e = trip.recoveredWh { row("Énergie récupérée", String(format: "%.0f Wh", e)) }
                if let p = trip.maxPower { row("Puissance max", String(format: "%.0f W", p)) }
                if let e = trip.energyWh, trip.distance >= 1 { row("Consommation", String(format: "%.1f Wh / km", e / trip.distance)) }
                if let cost = ChargeAssistant.cost(of: trip) { row("Coût électricité", String(format: "%.2f €", cost)) }
                if let t = trip.ambientTemp { row("Température extérieure", String(format: "%.0f °C", t)) }
            }

            Section("Vitesse et PWM") {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("min", s.t / 60), y: .value("km/h", s.speed), series: .value("", "Vitesse"))
                            .foregroundStyle(.blue)
                        if let p = s.pwm {
                            LineMark(x: .value("min", s.t / 60), y: .value("PWM", p), series: .value("", "PWM"))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(height: 180)
                Text("Bleu : vitesse (km/h) · Orange : PWM (%) · Axe horizontal en minutes")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Batterie et température") {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("min", s.t / 60), y: .value("%", s.battery), series: .value("", "Batterie"))
                            .foregroundStyle(.green)
                        LineMark(x: .value("min", s.t / 60), y: .value("°C", s.temp), series: .value("", "Temp"))
                            .foregroundStyle(.red)
                    }
                }
                .frame(height: 160)
                Text("Vert : batterie (%) · Rouge : température (°C)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Exporter") {
                TripShareButton(trip: trip)
                if let gpxURL {
                    ShareLink(item: gpxURL) { Label("Partager le GPX", systemImage: "map") }
                }
                if let csvURL {
                    ShareLink(item: csvURL) { Label("Partager le CSV (toutes les données)", systemImage: "tablecells") }
                }
            }
        }
        .themedList()
        .navigationTitle(trip.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gpxURL = TripStore.shared.exportGPX(trip)
            csvURL = TripStore.shared.exportCSV(trip)
        }
    }

    /// Échantillons réduits à ~400 points pour garder des graphiques fluides.
    private var points: [TripSample] {
        let n = trip.samples.count
        let step = max(1, n / 400)
        return stride(from: 0, to: n, by: step).map { trip.samples[$0] }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
