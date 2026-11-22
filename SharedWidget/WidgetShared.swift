import Foundation

/// Données partagées entre l'appli et ses widgets / complications (groupe d'apps).
struct WidgetSnapshot: Codable {
    var wheelName: String = "LynxDash"
    var battery: Double = 0
    var voltage: Double = 0
    var speed: Double = 0
    var connected: Bool = false
    var limited: Bool = false
    var todayKm: Double = 0
    var weekKm: Double = 0
    var updated: Date = .distantPast

    static let appGroup = "group.be.gyrocare.lynxdash"
    private static let key = "widgetSnapshot"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: key),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { WidgetSnapshot.defaults?.set(data, forKey: WidgetSnapshot.key) }
    }

    var ageText: String {
        guard updated > .distantPast else { return "Jamais connectée" }
        let minutes = Int(Date().timeIntervalSince(updated) / 60)
        if connected && minutes < 2 { return "En direct" }
        if minutes < 60 { return "Il y a \(minutes) min" }
        if minutes < 1440 { return "Il y a \(minutes / 60) h" }
        return "Il y a \(minutes / 1440) j"
    }
}
