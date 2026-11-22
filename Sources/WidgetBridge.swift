import Foundation
import WidgetKit

/// Met à jour les données des widgets d'écran d'accueil.
final class WidgetBridge {
    static let shared = WidgetBridge()

    private var lastSave = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastBattery = -1

    func update(_ d: WheelData, manager: BLEManager) {
        let now = Date()
        guard now.timeIntervalSince(lastSave) >= 30 else { return }
        lastSave = now
        var s = WidgetSnapshot.load()
        s.wheelName = manager.connectedName ?? s.wheelName
        s.battery = d.batteryPercent
        s.voltage = d.voltage
        s.speed = abs(d.speed)
        s.connected = true
        s.limited = manager.isLimited
        s.todayKm = TripStore.shared.distance(since: Calendar.current.startOfDay(for: now))
            + TripRecorder.shared.currentDistance
        s.weekKm = TripStore.shared.distance(since: now.addingTimeInterval(-7 * 86400))
            + TripRecorder.shared.currentDistance
        s.updated = now
        s.save()

        // Rafraîchissement limité (iOS impose un budget) : changement de 5 % ou toutes les 15 min
        let battery = Int(d.batteryPercent / 5)
        if battery != lastBattery || now.timeIntervalSince(lastReload) > 900 {
            lastBattery = battery
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func disconnected() {
        var s = WidgetSnapshot.load()
        s.connected = false
        s.speed = 0
        s.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
