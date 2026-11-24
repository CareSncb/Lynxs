import MapKit
import SwiftUI
import UserNotifications

// MARK: - Détection fiable de la charge

/// La roue ne peut pas charger en roulant. On ne déclare « en charge » que si elle est
/// immobile depuis 30 s, ET que la roue l'indique ou que la tension monte nettement
/// (≥ 0,5 V en 2 min, mesurée uniquement à l'arrêt : la remontée de tension après
/// un effort ne compte pas). Le moindre mouvement annule tout de suite.
final class ChargeDetector {
    private var stillSince: Date?
    private var stillVoltages: [(Date, Double)] = []
    /// Certaines roues (ex. Leaperkim) envoient un « mode de charge » non nul même en roulant :
    /// dans ce cas on ne s'y fie plus et on se base uniquement sur la tension.
    private var flagUnreliable = false

    func update(_ d: WheelData, now: Date = Date()) -> Bool {
        if d.isCharging && abs(d.speed) >= 3 { flagUnreliable = true }
        if abs(d.speed) >= 0.8 || abs(d.phaseCurrent) > 8 {
            stillSince = nil
            stillVoltages.removeAll()
            return false
        }
        if stillSince == nil { stillSince = now }
        // on ignore les 20 premières secondes d'arrêt (récupération de tension après l'effort)
        if let s = stillSince, now.timeIntervalSince(s) > 20 {
            stillVoltages.append((now, d.voltage))
            stillVoltages.removeAll { now.timeIntervalSince($0.0) > 180 }
        }
        guard let s = stillSince, now.timeIntervalSince(s) >= 30 else { return false }
        if d.isCharging && !flagUnreliable { return true }
        guard let first = stillVoltages.first, now.timeIntervalSince(first.0) >= 120 else { return false }
        return d.voltage - first.1 >= 0.5
    }
}

// MARK: - Assistant de charge

final class ChargeAssistant: ObservableObject {
    static let shared = ChargeAssistant()

    @Published private(set) var charging = false
    @Published private(set) var ratePerMinute: Double?     // % par minute
    @Published private(set) var target: Int = 100
    @Published private(set) var eta: Date?

    private var points: [(Date, Double)] = []
    private let detector = ChargeDetector()

    func ingest(_ d: WheelData) {
        let now = Date()
        let active = detector.update(d, now: now)
        if active != charging { charging = active; if !active { reset() } }
        guard active else { return }

        points.append((now, d.batteryPercent))
        points.removeAll { now.timeIntervalSince($0.0) > 600 }
        let levels = (UserDefaults.standard.array(forKey: "chargeAlertLevels") as? [Int] ?? [80, 100]).sorted()
        target = levels.first { Double($0) > d.batteryPercent + 0.5 } ?? 100
        guard let first = points.first, now.timeIntervalSince(first.0) > 120 else { return }
        let gained = d.batteryPercent - first.1
        let minutes = now.timeIntervalSince(first.0) / 60
        guard gained > 0.2 else { return }
        var rate = gained / minutes
        // Au-delà de 90 %, les chargeurs ralentissent (phase à tension constante)
        if d.batteryPercent > 90 { rate *= 0.6 }
        ratePerMinute = rate
        eta = now.addingTimeInterval(max(0, Double(target) - d.batteryPercent) / rate * 60)
    }

    private func reset() {
        points.removeAll()
        ratePerMinute = nil
        eta = nil
    }

    // MARK: Stockage longue durée

    /// Roue déconnectée : si elle dort 2 semaines loin de 60 %, on le rappelle.
    func wheelDisconnected(name: String?, battery: Double) {
        charging = false
        reset()
        let center = UNUserNotificationCenter.current()
        let id = "stockage-\(name ?? "roue")"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard Prefs.storageReminder, battery > 0, battery > 75 || battery < 35 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ta roue dort depuis 2 semaines"
        content.body = String(format: "%@ est restée à %.0f %%. Pour préserver les cellules, stocke-la autour de 50–60 %%.", name ?? "Ta roue", battery)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 14 * 86400, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func wheelConnected(name: String?) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["stockage-\(name ?? "roue")"])
    }

    // MARK: Coût de l'électricité

    /// Coût d'un trajet en euros (énergie mesurée, sinon % de batterie × capacité), rendement chargeur 90 %.
    static func cost(of trip: Trip) -> Double? {
        let price = Prefs.kwhPrice
        guard price > 0 else { return nil }
        var wh = trip.energyWh
        if wh == nil, Prefs.batteryWh > 0, trip.batteryStart > trip.batteryEnd {
            wh = (trip.batteryStart - trip.batteryEnd) / 100 * Prefs.batteryWh
        }
        guard let e = wh, e > 0 else { return nil }
        return e / 0.9 / 1000 * price
    }

    /// Coût moyen aux 100 km sur les derniers trajets.
    static var costPer100km: Double? {
        let trips = TripStore.shared.trips.prefix(20).filter { $0.distance >= 1 }
        let pairs = trips.compactMap { t in cost(of: t).map { ($0, t.distance) } }
        let km = pairs.reduce(0) { $0 + $1.1 }
        guard km >= 5 else { return nil }
        return pairs.reduce(0) { $0 + $1.0 } / km * 100
    }
}

struct ChargeCard: View {
    @ObservedObject private var charge = ChargeAssistant.shared
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        if charge.charging {
            HStack(spacing: 14) {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.brandGradient)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "En charge · %.0f %% → %d %%", ble.data.batteryPercent, charge.target))
                        .font(.headline).foregroundStyle(.white)
                    if let eta = charge.eta, let rate = charge.ratePerMinute {
                        Text("Prête vers \(eta.formatted(date: .omitted, time: .shortened)) · \(String(format: "%.1f", rate * 60)) %/h")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    } else {
                        Text("Calcul du temps restant…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .glassCard()
        }
    }
}

// MARK: - Où est ma roue ?

struct ParkedWheel: Codable, Identifiable {
    var id: String { name }
    var name: String
    var lat: Double
    var lon: Double
    var date: Date
    var battery: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum WheelFinder {
    private static let key = "parkedWheels"

    static var all: [ParkedWheel] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ParkedWheel].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    /// Mémorise la dernière position connue au moment de la déconnexion.
    static func wheelDisconnected(name: String?, battery: Double) {
        guard let name, let loc = TripRecorder.shared.lastLocation,
              Date().timeIntervalSince(loc.timestamp) < 600 else { return }
        var list = all.filter { $0.name != name }
        list.insert(ParkedWheel(name: name, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                date: Date(), battery: battery), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(10))) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct WheelFinderView: View {
    @State private var wheels = WheelFinder.all
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(wheels) { w in
                    Annotation(w.name, coordinate: w.coordinate) {
                        Image(systemName: "circle.circle.fill")
                            .font(.title)
                            .foregroundStyle(Theme.accent)
                            .background(Circle().fill(.black))
                    }
                }
            }
            .frame(maxHeight: .infinity)
            List {
                if wheels.isEmpty {
                    Text("La position est mémorisée chaque fois qu'une roue se déconnecte (GPS actif pendant le trajet).")
                        .foregroundStyle(.secondary)
                }
                ForEach(wheels) { w in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(w.name).font(.headline)
                        Text("Déconnectée \(w.date.formatted(.relative(presentation: .named))) · \(Int(w.battery)) %")
                            .font(.caption).foregroundStyle(.secondary)
                        if let url = URL(string: "https://maps.apple.com/?daddr=\(w.lat),\(w.lon)&dirflg=w") {
                            Link(destination: url) { Label("Itinéraire à pied", systemImage: "figure.walk") }
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(height: 240)
            .themedList()
        }
        .navigationTitle("Où est ma roue ?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Carte des prises partagées (club)

struct ChargingSpot: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var note: String
    var lat: Double
    var lon: Double
    var addedBy: String
    var author: String
    var date: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

final class ChargingSpots: ObservableObject {
    static let shared = ChargingSpots()
    @Published private(set) var spots: [ChargingSpot] = []
    @Published private(set) var status: String?
    private var fetcher: MQTTFetcher?

    private var board: Leaderboard { Leaderboard.shared }

    func refresh() {
        guard board.hasClub else { status = "Rejoins d'abord un club (Trajets › Classement et défis)"; return }
        status = "Chargement…"
        let f = MQTTFetcher()
        fetcher = f
        f.fetch(filter: "\(board.base)/spots/+") { [weak self] results, error in
            guard let self else { return }
            self.fetcher = nil
            self.spots = results.values.compactMap { payload in
                guard let text = String(data: payload, encoding: .utf8),
                      let clear = Leaderboard.decrypt(text, code: self.board.cryptoCode) else { return nil }
                return try? JSONDecoder().decode(ChargingSpot.self, from: clear)
            }
            .sorted { $0.date > $1.date }
            self.status = error ?? "\(self.spots.count) prise(s) partagée(s)"
        }
    }

    func add(name: String, note: String, at c: CLLocationCoordinate2D) {
        guard board.hasClub else { return }
        let spot = ChargingSpot(id: UUID().uuidString.prefix(10).lowercased(), name: name, note: note,
                                lat: c.latitude, lon: c.longitude, addedBy: board.memberID, author: board.myName,
                                date: Date().timeIntervalSince1970)
        guard let json = try? JSONEncoder().encode(spot), let sealed = LiveCrypto.seal(json, code: board.cryptoCode) else { return }
        spots.insert(spot, at: 0)
        MQTTPublisher.shared.publish(topic: "\(board.base)/spots/\(spot.id)", payload: Data(sealed.utf8), retain: true) { _ in }
    }

    func remove(_ spot: ChargingSpot) {
        spots.removeAll { $0.id == spot.id }
        // message retenu vide = suppression sur le serveur
        MQTTPublisher.shared.publish(topic: "\(board.base)/spots/\(spot.id)", payload: Data(), retain: true) { _ in }
    }
}

struct ChargingSpotsView: View {
    @ObservedObject private var store = ChargingSpots.shared
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var picked: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var note = ""
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(store.spots) { s in
                        Marker(s.name, systemImage: "powerplug.fill", coordinate: s.coordinate).tint(Theme.accent)
                    }
                    if let picked {
                        Marker("Nouvelle prise", systemImage: "plus", coordinate: picked).tint(Theme.ember)
                    }
                }
                .onTapGesture { p in
                    if let c = proxy.convert(p, from: .local) { picked = c; adding = true }
                }
            }
            .frame(maxHeight: .infinity)
            List {
                Section {
                    if let s = store.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        picked = TripRecorder.shared.lastLocation?.coordinate
                        adding = picked != nil
                        if picked == nil { TripRecorder.shared.requestOneShotLocation() }
                    } label: {
                        Label("Ajouter une prise à ma position", systemImage: "location.fill")
                    }
                } footer: {
                    Text("Ou touche la carte à l'endroit voulu. Les prises sont partagées avec ton club (chiffrées avec son code).")
                }
                ForEach(store.spots) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.name).font(.headline)
                        if !s.note.isEmpty { Text(s.note).font(.caption) }
                        HStack {
                            Text("Ajoutée par \(s.author)").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let url = URL(string: "https://maps.apple.com/?daddr=\(s.lat),\(s.lon)") {
                                Link("Itinéraire", destination: url).font(.caption)
                            }
                        }
                    }
                    .swipeActions {
                        if s.addedBy == Leaderboard.shared.memberID {
                            Button("Supprimer", role: .destructive) { store.remove(s) }
                        }
                    }
                }
            }
            .frame(height: 280)
            .themedList()
        }
        .navigationTitle("Prises partagées")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .alert("Nouvelle prise", isPresented: $adding) {
            TextField("Nom (ex. Café du Parc)", text: $name)
            TextField("Infos (horaires, consommation…)", text: $note)
            Button("Annuler", role: .cancel) { picked = nil }
            Button("Partager") {
                if let c = picked, !name.isEmpty { store.add(name: name, note: note, at: c) }
                picked = nil; name = ""; note = ""
            }
        }
    }
}
