import CoreLocation
import Foundation

// MARK: - Profils par roue

struct MaintenanceItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var intervalKm: Double
    var lastDoneKm: Double
    var notifiedAtKm: Double?

    func dueIn(total: Double) -> Double { intervalKm - (total - lastDoneKm) }

    static func defaults(total: Double) -> [MaintenanceItem] {
        [
            MaintenanceItem(name: "Pression des pneus", intervalKm: 200, lastDoneKm: total),
            MaintenanceItem(name: "Serrage visserie et axe", intervalKm: 500, lastDoneKm: total),
            MaintenanceItem(name: "Usure du pneu", intervalKm: 1500, lastDoneKm: total),
            MaintenanceItem(name: "Nettoyage et contrôle général", intervalKm: 2000, lastDoneKm: total)
        ]
    }
}

struct WheelProfile: Codable {
    var cells: Int?
    var speedAlarm: Double?
    var pwmAlarm: Double?
    var normalLimit: Int?
    var maintenance: [MaintenanceItem]?
}

final class ProfileStore {
    static let shared = ProfileStore()
    private let key = "wheelProfiles"

    private(set) var profiles: [String: WheelProfile] = {
        guard let data = UserDefaults.standard.data(forKey: "wheelProfiles"),
              let p = try? JSONDecoder().decode([String: WheelProfile].self, from: data) else { return [:] }
        return p
    }()

    func profile(_ id: String) -> WheelProfile? { profiles[id] }

    func update(_ id: String, _ change: (inout WheelProfile) -> Void) {
        var p = profiles[id] ?? WheelProfile()
        change(&p)
        profiles[id] = p
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Alertes charge, température et entretien

final class WheelMonitors {
    static let shared = WheelMonitors()

    private var voltageHistory: [(Date, Double)] = []
    private var tempHistory: [(Date, Double)] = []
    private var chargeLevelsNotified: Set<Int> = []
    private var lastChargingSeen = Date.distantPast
    private var lastTempAlert = Date.distantPast

    func ingest(_ d: WheelData, manager: BLEManager) {
        let now = Date()
        checkCharge(d, now: now)
        checkTemperature(d, now: now)
        checkMaintenance(d, manager: manager)
    }

    private func checkCharge(_ d: WheelData, now: Date) {
        voltageHistory.append((now, d.voltage))
        voltageHistory.removeAll { now.timeIntervalSince($0.0) > 180 }

        // En charge : indiqué par la roue, ou tension qui monte à l'arrêt
        var charging = d.isCharging
        if !charging, abs(d.speed) < 0.5, let first = voltageHistory.first,
           now.timeIntervalSince(first.0) > 90, d.voltage - first.1 > 0.3 {
            charging = true
        }
        if charging {
            lastChargingSeen = now
        } else if now.timeIntervalSince(lastChargingSeen) > 300 {
            chargeLevelsNotified.removeAll()   // nouvelle session de charge
            return
        }
        guard charging else { return }

        let levels = UserDefaults.standard.array(forKey: "chargeAlertLevels") as? [Int] ?? [80, 100]
        for level in levels.sorted() where !chargeLevelsNotified.contains(level) {
            let reached = level >= 100 ? d.batteryPercent >= 99.5 : d.batteryPercent >= Double(level)
            if reached {
                chargeLevelsNotified.insert(level)
                let text = level >= 100 ? "Ta roue est complètement chargée" : "Ta roue est chargée à \(level) %"
                SafetyMonitor.shared.notify(title: "Charge", body: text)
                PhoneWatchBridge.shared.sendAlert(text)
            }
        }
    }

    private func checkTemperature(_ d: WheelData, now: Date) {
        tempHistory.append((now, d.temperature))
        tempHistory.removeAll { now.timeIntervalSince($0.0) > 60 }
        let limit = UserDefaults.standard.object(forKey: "tempAlert") as? Double ?? 65
        guard limit > 0, now.timeIntervalSince(lastTempAlert) > 60 else { return }

        // Tendance en °C par minute
        var slope = 0.0
        if let first = tempHistory.first, now.timeIntervalSince(first.0) > 20 {
            slope = (d.temperature - first.1) / now.timeIntervalSince(first.0) * 60
        }
        let predicted = d.temperature + slope * 2   // dans 2 minutes
        var text: String?
        if d.temperature >= limit {
            text = String(format: "Température contrôleur %.0f °C : ralentis", d.temperature)
        } else if slope > 1.5, predicted >= limit, d.temperature >= limit - 10 {
            text = String(format: "Température en hausse rapide (%.0f °C, +%.0f °C/min)", d.temperature, slope)
        }
        if let text {
            lastTempAlert = now
            SafetyMonitor.shared.notify(title: "Surchauffe", body: text)
            PhoneWatchBridge.shared.sendAlert(text)
            VoiceAnnouncer.shared.speak(text, urgent: true)
        }
    }

    private func checkMaintenance(_ d: WheelData, manager: BLEManager) {
        guard d.totalDistance > 0, let id = manager.currentWheelID,
              var items = ProfileStore.shared.profile(id)?.maintenance else { return }
        var changed = false
        for i in items.indices where items[i].dueIn(total: d.totalDistance) <= 0 && items[i].notifiedAtKm == nil {
            items[i].notifiedAtKm = d.totalDistance
            changed = true
            SafetyMonitor.shared.notify(title: "Entretien", body: "\(items[i].name) : à faire sur \(manager.connectedName ?? "ta roue")")
        }
        if changed { ProfileStore.shared.update(id) { $0.maintenance = items } }
    }
}

// MARK: - Zones de bridage GPS

struct LimitZone: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double   // mètres

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    func contains(_ loc: CLLocation) -> Bool {
        loc.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius
    }
}

final class ZoneManager: ObservableObject {
    static let shared = ZoneManager()

    @Published var zones: [LimitZone] = [] { didSet { persist() } }
    @Published private(set) var activeZone: LimitZone?
    private var engagedByZone = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "limitZones"),
           let z = try? JSONDecoder().decode([LimitZone].self, from: data) {
            zones = z
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(zones) { UserDefaults.standard.set(data, forKey: "limitZones") }
    }

    /// Appelé à chaque position GPS. Le bridage/débridage est programmé et s'applique au prochain arrêt.
    func check(_ loc: CLLocation) {
        guard !zones.isEmpty else { return }
        let inside = zones.first { $0.contains(loc) }
        let ble = BLEManager.shared
        if let zone = inside, activeZone == nil {
            activeZone = zone
            if !ble.isLimited && ble.pendingAction != .engage {
                engagedByZone = true
                Task { @MainActor in
                    let outcome = await ble.engageLimiter()
                    if case .failed = outcome { self.engagedByZone = false }
                }
                SafetyMonitor.shared.notify(title: "Zone « \(zone.name) »",
                                            body: "Bridage à 25 km/h au prochain arrêt")
            }
        } else if inside == nil, activeZone != nil {
            let name = activeZone?.name ?? ""
            activeZone = nil
            if engagedByZone {
                engagedByZone = false
                if PinLock.isSet {
                    SafetyMonitor.shared.notify(title: "Sortie de la zone « \(name) »",
                                                body: "La roue reste bridée : débride avec ton code PIN dans l'appli")
                    return
                }
                Task { @MainActor in _ = await ble.releaseLimiter() }
                SafetyMonitor.shared.notify(title: "Sortie de la zone « \(name) »",
                                            body: "Débridage au prochain arrêt")
            }
        }
    }
}
