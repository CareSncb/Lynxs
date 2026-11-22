import ActivityKit
import Foundation

/// Données de la Live Activity (écran verrouillé + Dynamic Island), partagées avec l'extension widget.
struct LynxActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var speed: Int
        var battery: Int
        var pwm: Int
        var hasPWM: Bool
        var temperature: Int
        var tripKm: Double
        var limited: Bool
        var pending: Bool
        var connected: Bool
    }

    var wheelName: String
}
