import Foundation
import CoreLocation

struct TripSample: Codable {
    var t: TimeInterval          // secondes depuis le départ
    var lat: Double?
    var lon: Double?
    var speed: Double
    var pwm: Double?
    var voltage: Double
    var battery: Double
    var temp: Double
    var current: Double
}

struct Trip: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var wheelName: String
    var brand: String
    var distance: Double = 0       // km
    var maxSpeed: Double = 0
    var maxPWM: Double?
    var maxTemp: Double = 0
    var rideSeconds: Double?
    var energyWh: Double?
    var recoveredWh: Double?
    var maxPower: Double?
    var batteryStart: Double = 0
    var batteryEnd: Double = 0
    var samples: [TripSample] = []

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Vitesse moyenne en mouvement (échantillons > 3 km/h).
    var avgSpeed: Double {
        let moving = samples.filter { $0.speed > 3 }
        guard !moving.isEmpty else { return 0 }
        return moving.reduce(0) { $0 + $1.speed } / Double(moving.count)
    }

    /// Consommation en % de batterie par km.
    var consumption: Double? {
        guard distance >= 1, batteryStart > batteryEnd else { return nil }
        return (batteryStart - batteryEnd) / distance
    }

    var coordinates: [CLLocationCoordinate2D] {
        samples.compactMap { s in
            guard let lat = s.lat, let lon = s.lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}

/// Enregistre automatiquement les trajets (télémétrie 1 Hz + GPS).
final class TripRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TripRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var currentDistance: Double = 0
    @Published private(set) var lastLocation: CLLocation?
    // Statistiques en direct du trajet en cours
    @Published private(set) var rideSeconds: Double = 0
    @Published private(set) var energyWh: Double = 0
    @Published private(set) var recoveredWh: Double = 0
    @Published private(set) var maxPower: Double = 0
    var averageSpeed: Double { rideSeconds > 30 ? currentDistance / (rideSeconds / 3600) : 0 }
    var averagePower: Double { rideSeconds > 30 ? energyWh / (rideSeconds / 3600) : 0 }

    private let location = CLLocationManager()
    private var trip: Trip?
    private var startTotal: Double?
    private var lastSampleTime = Date.distantPast
    private var stoppedSince: Date?
    private var disconnectTimer: Timer?
    private var gpsDistance: Double = 0
    private var locationActive = false
    private var lastGPS: CLLocation?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .otherNavigation
        location.distanceFilter = 3
        location.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        guard Prefs.gpsEnabled else { return }
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: location.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Active le GPS en continu (sortie de groupe).
    func ensureLocation() {
        guard !locationActive else { return }
        locationActive = true
        location.allowsBackgroundLocationUpdates = location.authorizationStatus == .authorizedAlways
            || location.authorizationStatus == .authorizedWhenInUse
        location.startUpdatingLocation()
    }

    /// Position ponctuelle (utilisée par l'alerte de chute).
    func requestOneShotLocation() {
        location.requestLocation()
    }

    // MARK: - Enregistrement

    func ingest(_ d: WheelData, wheelName: String) {
        disconnectTimer?.invalidate()
        disconnectTimer = nil

        // Zones GPS : il faut la position même hors enregistrement de trajet
        if Prefs.gpsEnabled, !ZoneManager.shared.zones.isEmpty, !locationActive {
            locationActive = true
            location.allowsBackgroundLocationUpdates = location.authorizationStatus == .authorizedAlways
                || location.authorizationStatus == .authorizedWhenInUse
            location.startUpdatingLocation()
        }
        if Prefs.workshopMode { return }

        if trip == nil {
            guard Prefs.autoTrips, abs(d.speed) >= 3 else { return }
            start(d, wheelName: wheelName)
        }
        guard var t = trip else { return }

        // Fin automatique après 5 minutes d'arrêt
        if abs(d.speed) < 1 {
            if stoppedSince == nil { stoppedSince = Date() }
            if let since = stoppedSince, Date().timeIntervalSince(since) > 300 {
                stop()
                return
            }
        } else {
            stoppedSince = nil
        }

        let now = Date()
        guard now.timeIntervalSince(lastSampleTime) >= 1 else { return }
        let dt = lastSampleTime == .distantPast ? 1 : min(5, now.timeIntervalSince(lastSampleTime))
        lastSampleTime = now
        if abs(d.speed) >= 2 { rideSeconds += dt }
        if let p = d.power {
            if p >= 0 { energyWh += p * dt / 3600 } else { recoveredWh += -p * dt / 3600 }
            maxPower = max(maxPower, p)
        }

        let loc = Prefs.gpsEnabled ? lastLocation : nil
        let fresh = loc.map { now.timeIntervalSince($0.timestamp) < 5 } ?? false
        t.samples.append(TripSample(
            t: now.timeIntervalSince(t.start),
            lat: fresh ? loc?.coordinate.latitude : nil,
            lon: fresh ? loc?.coordinate.longitude : nil,
            speed: abs(d.speed),
            pwm: d.hasPWM ? d.pwm : nil,
            voltage: d.voltage,
            battery: d.batteryPercent,
            temp: d.temperature,
            current: d.phaseCurrent))
        t.end = now
        t.maxSpeed = max(t.maxSpeed, abs(d.speed))
        t.maxTemp = max(t.maxTemp, d.temperature)
        if d.hasPWM { t.maxPWM = max(t.maxPWM ?? 0, d.pwm) }
        t.batteryEnd = d.batteryPercent
        t.rideSeconds = rideSeconds
        if d.hasBatteryCurrent {
            t.energyWh = energyWh
            t.recoveredWh = recoveredWh
            t.maxPower = maxPower
        }
        if let s0 = startTotal, d.totalDistance > 0, d.totalDistance >= s0 {
            t.distance = d.totalDistance - s0
        } else {
            t.distance = gpsDistance / 1000
        }
        trip = t
        currentDistance = t.distance

        if t.samples.count % 30 == 0 { TripStore.shared.save(t) }   // sauvegarde régulière
    }

    func startManually() {
        let d = BLEManager.shared.data
        if trip == nil { start(d, wheelName: BLEManager.shared.connectedName ?? "Roue") }
    }

    private func start(_ d: WheelData, wheelName: String) {
        trip = Trip(start: Date(), end: Date(), wheelName: wheelName, brand: d.brand.shortLabel,
                    batteryStart: d.batteryPercent, batteryEnd: d.batteryPercent)
        startTotal = d.totalDistance > 0 ? d.totalDistance : nil
        gpsDistance = 0
        lastGPS = nil
        stoppedSince = nil
        currentDistance = 0
        rideSeconds = 0
        energyWh = 0
        recoveredWh = 0
        maxPower = 0
        lastSampleTime = .distantPast
        isRecording = true
        LiveShare.shared.tripStateChanged(recording: true)
        if Prefs.gpsEnabled {
            location.allowsBackgroundLocationUpdates = location.authorizationStatus == .authorizedAlways
                || location.authorizationStatus == .authorizedWhenInUse
            location.showsBackgroundLocationIndicator = true
            location.startUpdatingLocation()
            locationActive = true
        }
    }

    func stop() {
        guard let t = trip else { return }
        trip = nil
        isRecording = false
        LiveShare.shared.tripStateChanged(recording: false)
        if !LiveShare.shared.active && (ZoneManager.shared.zones.isEmpty || BLEManager.shared.state != .connected) {
            location.stopUpdatingLocation()
            locationActive = false
        }
        if t.samples.count >= 10 {
            TripStore.shared.save(t)
        } else {
            TripStore.shared.delete(id: t.id)   // trajet trop court : ignoré
        }
    }

    func wheelDisconnected() {
        if trip == nil {
            if LiveShare.shared.active || GroupRide.shared.active { return }
            location.stopUpdatingLocation()
            locationActive = false
            return
        }
        // Fin du trajet si la roue ne revient pas dans les 2 minutes
        disconnectTimer?.invalidate()
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 30 {
            if let prev = lastGPS, isRecording { gpsDistance += loc.distance(from: prev) }
            lastGPS = loc
            lastLocation = loc
            ZoneManager.shared.check(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }
}

/// Stockage des trajets (un fichier JSON par trajet).
final class TripStore: ObservableObject {
    static let shared = TripStore()

    @Published private(set) var trips: [Trip] = []

    private let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        trips = files.compactMap { try? decoder.decode(Trip.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    func save(_ trip: Trip) {
        if let data = try? JSONEncoder().encode(trip) {
            try? data.write(to: folder.appendingPathComponent("\(trip.id.uuidString).json"), options: .atomic)
        }
        if let i = trips.firstIndex(where: { $0.id == trip.id }) { trips[i] = trip } else { trips.insert(trip, at: 0) }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
        trips.removeAll { $0.id == id }
    }

    // MARK: - Statistiques

    func distance(since date: Date) -> Double {
        trips.filter { $0.start >= date }.reduce(0) { $0 + $1.distance }
    }

    var totalDistance: Double { trips.reduce(0) { $0 + $1.distance } }

    /// Consommation moyenne (% batterie / km) sur les 10 derniers trajets de plus d'1 km.
    var averageConsumption: Double? {
        let values = trips.prefix(10).compactMap { $0.consumption }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Distance par jour sur les 7 derniers jours (le plus ancien en premier).
    func dailyDistances(days: Int = 7) -> [(day: Date, km: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let km = trips.filter { $0.start >= day && $0.start < next }.reduce(0) { $0 + $1.distance }
            return (day, km)
        }
    }

    // MARK: - Export

    func exportGPX(_ trip: Trip) -> URL? {
        let iso = ISO8601DateFormatter()
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LynxDash" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(trip.wheelName) \(iso.string(from: trip.start))</name><trkseg>

        """
        for s in trip.samples {
            guard let lat = s.lat, let lon = s.lon else { continue }
            let time = iso.string(from: trip.start.addingTimeInterval(s.t))
            gpx += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\"><time>\(time)</time></trkpt>\n"
        }
        gpx += "</trkseg></trk></gpx>\n"
        return write(gpx, name: "trajet-\(fileStamp(trip.start)).gpx")
    }

    func exportCSV(_ trip: Trip) -> URL? {
        var csv = "temps_s;latitude;longitude;vitesse_kmh;pwm_pct;tension_v;batterie_pct;temperature_c;courant_a\n"
        for s in trip.samples {
            let cols: [String] = [
                String(format: "%.0f", s.t),
                s.lat.map { String($0) } ?? "",
                s.lon.map { String($0) } ?? "",
                String(format: "%.1f", s.speed),
                s.pwm.map { String(format: "%.0f", $0) } ?? "",
                String(format: "%.2f", s.voltage),
                String(format: "%.0f", s.battery),
                String(format: "%.1f", s.temp),
                String(format: "%.1f", s.current)
            ]
            csv += cols.joined(separator: ";") + "\n"
        }
        return write(csv, name: "trajet-\(fileStamp(trip.start)).csv")
    }

    private func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.string(from: date)
    }

    private func write(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
