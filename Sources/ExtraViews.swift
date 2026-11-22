import MapKit
import SwiftUI

// MARK: - Mode guidon

struct HandlebarView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let d = ble.data
        let alarm = d.hasPWM && ble.pwmAlarm > 0 && d.pwm >= ble.pwmAlarm
        ZStack {
            (alarm ? Color.red : Color.black).ignoresSafeArea()
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: ble.isLimited ? "lock.fill" : "lock.open")
                        .foregroundStyle(ble.isLimited ? .orange : .gray)
                    Spacer()
                    Text(String(format: "%.0f °C", d.temperature))
                        .foregroundStyle(d.temperature >= 65 ? .red : .white)
                }
                .font(.title2.bold())

                Spacer()
                Text(String(format: "%.0f", abs(d.speed)))
                    .font(.system(size: 200, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                Text("km/h").font(.title).foregroundStyle(.gray)
                if d.hasPWM {
                    Text(String(format: "PWM %.0f %%", d.pwm))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(alarm ? .white : pwmColor(d.pwm))
                }
                Spacer()

                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.15))
                            RoundedRectangle(cornerRadius: 10)
                                .fill(d.batteryPercent < 20 ? Color.red : (d.batteryPercent < 40 ? .orange : .green))
                                .frame(width: geo.size.width * CGFloat(d.batteryPercent / 100))
                        }
                    }
                    .frame(height: 28)
                    HStack {
                        Text(String(format: "%.0f %%", d.batteryPercent))
                        Spacer()
                        Text(String(format: "%.1f km", TripRecorder.shared.currentDistance))
                    }
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                }
                Text("Toucher deux fois pour quitter").font(.caption).foregroundStyle(.gray)
            }
            .padding()
        }
        .onTapGesture(count: 2) { dismiss() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .statusBarHidden()
    }
}

// MARK: - Entretien

struct MaintenanceView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var items: [MaintenanceItem] = []
    @State private var newName = ""
    @State private var newInterval = 500.0

    var body: some View {
        List {
            if ble.state != .connected {
                Text("Connecte la roue pour voir son entretien.").foregroundStyle(.secondary)
            } else {
                Section {
                    LabeledContent("Compteur", value: String(format: "%.0f km", ble.data.totalDistance))
                }
                Section("À surveiller") {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.name).font(.headline)
                                Spacer()
                                Button("Fait") {
                                    item.lastDoneKm = ble.data.totalDistance
                                    item.notifiedAtKm = nil
                                    save()
                                }
                                .buttonStyle(.bordered)
                            }
                            let due = item.dueIn(total: ble.data.totalDistance)
                            ProgressView(value: min(1, max(0, 1 - due / item.intervalKm)))
                                .tint(due <= 0 ? .red : (due < item.intervalKm * 0.2 ? .orange : .green))
                            Text(due <= 0 ? String(format: "En retard de %.0f km", -due)
                                          : String(format: "Dans %.0f km (tous les %.0f km)", due, item.intervalKm))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in items.remove(atOffsets: idx); save() }
                }
                Section("Ajouter") {
                    TextField("Nom (ex. huile roulements)", text: $newName)
                    Stepper(String(format: "Tous les %.0f km", newInterval), value: $newInterval, in: 50...10000, step: 50)
                    Button("Ajouter") {
                        items.append(MaintenanceItem(name: newName, intervalKm: newInterval, lastDoneKm: ble.data.totalDistance))
                        newName = ""
                        save()
                    }
                    .disabled(newName.isEmpty)
                }
            }
        }
        .navigationTitle("Entretien")
        .onAppear { items = ble.maintenanceItems }
    }

    private func save() { ble.updateMaintenance(items) }
}

// MARK: - Zones de bridage

struct ZonesView: View {
    @ObservedObject private var manager = ZoneManager.shared
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var draft: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var radius = 300.0

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(manager.zones) { z in
                        MapCircle(center: z.coordinate, radius: z.radius)
                            .foregroundStyle(.orange.opacity(0.25))
                            .stroke(.orange, lineWidth: 2)
                        Annotation(z.name, coordinate: z.coordinate) {
                            Image(systemName: "lock.fill").foregroundStyle(.orange)
                        }
                    }
                    if let draft {
                        MapCircle(center: draft, radius: radius)
                            .foregroundStyle(.blue.opacity(0.2))
                            .stroke(.blue, lineWidth: 2)
                    }
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { draft = c }
                }
            }
            .frame(maxHeight: .infinity)

            Form {
                if draft != nil {
                    Section("Nouvelle zone") {
                        TextField("Nom (ex. centre-ville)", text: $name)
                        VStack(alignment: .leading) {
                            Text(String(format: "Rayon : %.0f m", radius))
                            Slider(value: $radius, in: 50...3000, step: 50)
                        }
                        Button("Enregistrer la zone") {
                            if let c = draft {
                                manager.zones.append(LimitZone(name: name.isEmpty ? "Zone" : name,
                                                               latitude: c.latitude, longitude: c.longitude, radius: radius))
                            }
                            draft = nil
                            name = ""
                        }
                    }
                } else {
                    Section {
                        Text("Touche la carte pour placer une zone. En y entrant, la roue est bridée à 25 km/h au prochain arrêt. En sortant, elle retrouve sa limite habituelle au prochain arrêt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Zones") {
                    ForEach(manager.zones) { z in
                        HStack {
                            Text(z.name)
                            Spacer()
                            Text(String(format: "%.0f m", z.radius)).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { manager.zones.remove(atOffsets: $0) }
                }
            }
            .frame(height: 300)
        }
        .navigationTitle("Zones de bridage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Journal d'erreurs

struct EventLogView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var errorsOnly = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await ble.downloadEventLog() }
                } label: {
                    HStack {
                        Label("Télécharger le journal de la roue", systemImage: "arrow.down.doc")
                        if ble.eventLogDownloading { Spacer(); ProgressView() }
                    }
                }
                .disabled(!ble.supportsEventLog || ble.eventLogDownloading)
                Toggle("Erreurs uniquement", isOn: $errorsOnly)
            } footer: {
                Text(ble.supportsEventLog
                     ? "Leaperkim (firmware récent) : la roue envoie son historique d'événements et d'erreurs."
                     : "Disponible sur les Leaperkim / Nosfet à firmware récent, roue connectée.")
            }
            Section("\(filtered.count) événement(s)") {
                ForEach(filtered) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: e.isError ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(e.isError ? .orange : .secondary)
                            Text(e.message).font(.subheadline)
                        }
                        HStack {
                            Text("#\(e.index) · code \(e.code)")
                            if let date = e.date { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Journal d'erreurs")
    }

    private var filtered: [VeteranEvent] {
        errorsOnly ? ble.eventLog.filter(\.isError) : ble.eventLog
    }
}
