import ActivityKit
import Foundation

/// Affiche vitesse, batterie et PWM sur l'écran verrouillé et dans la Dynamic Island.
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<LynxActivityAttributes>?
    private var lastState: LynxActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    func update(_ d: WheelData, manager: BLEManager) {
        guard Prefs.liveActivity, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = LynxActivityAttributes.ContentState(
            speed: Int(abs(d.speed).rounded()),
            battery: Int(d.batteryPercent.rounded()),
            pwm: Int(d.pwm.rounded()),
            hasPWM: d.hasPWM,
            temperature: Int(d.temperature.rounded()),
            tripKm: TripRecorder.shared.currentDistance,
            limited: manager.isLimited,
            pending: manager.pendingAction != nil,
            connected: true)

        if activity == nil {
            // Une Live Activity ne peut démarrer qu'avec l'appli au premier plan
            let attributes = LynxActivityAttributes(wheelName: manager.connectedName ?? "Roue")
            activity = try? Activity.request(attributes: attributes,
                                             content: ActivityContent(state: state, staleDate: nil),
                                             pushType: nil)
            lastState = state
            lastUpdate = Date()
            return
        }

        // iOS limite la fréquence des mises à jour : au plus une toutes les 2 s, et seulement si ça change
        guard state != lastState, Date().timeIntervalSince(lastUpdate) >= 2, let activity else { return }
        lastState = state
        lastUpdate = Date()
        Task {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60)))
        }
    }

    func end() {
        guard let activity else { return }
        var final = lastState ?? LynxActivityAttributes.ContentState(
            speed: 0, battery: 0, pwm: 0, hasPWM: false, temperature: 0,
            tripKm: 0, limited: false, pending: false, connected: false)
        final.connected = false
        final.speed = 0
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(300)))
        }
    }
}
