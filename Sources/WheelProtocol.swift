import Foundation

enum WheelBrand: String, CaseIterable, Identifiable {
    case auto, leaperkim, begode, kingsong, inmotion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatique"
        case .leaperkim: return "Leaperkim / Veteran / Nosfet"
        case .begode: return "Begode / Gotway / Extreme Bull"
        case .kingsong: return "Kingsong"
        case .inmotion: return "InMotion P6"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "—"
        case .leaperkim: return "Leaperkim"
        case .begode: return "Begode"
        case .kingsong: return "Kingsong"
        case .inmotion: return "InMotion"
        }
    }
}

/// Données télémétrie normalisées, quelle que soit la marque.
struct WheelData: Equatable {
    var brand: WheelBrand = .auto
    var model: String?
    var voltage: Double = 0          // V
    var speed: Double = 0            // km/h (négatif = marche arrière)
    var tripDistance: Double = 0     // km
    var totalDistance: Double = 0    // km
    var phaseCurrent: Double = 0     // A
    var temperature: Double = 0      // °C
    var pitchAngle: Double = 0       // °
    var pwm: Double = 0              // %
    var hasPWM = false
    var hasPitch = false
    /// Courant batterie disponible (InMotion) : permet de calculer la puissance réelle.
    var hasBatteryCurrent = false
    var power: Double? { hasBatteryCurrent ? voltage * phaseCurrent : nil }
    var batteryPercent: Double = 0
    var chargeMode: Int = 0
    var pedalsMode: Int = 0
    var firmwareRaw: Int = 0
    var firmwareText: String?

    /// Alerte de vitesse réglée dans la roue (km/h, 0 = inconnue).
    var speedAlert: Double = 0
    /// Limite de vitesse / tiltback réglée dans la roue (km/h).
    var speedLimit: Double = 0
    var speedLimitKnown = false

    var crcChecked = false
    var crcValid = false
    var newProtocol = false          // Leaperkim : trames longues avec CRC

    /// Tensions de chaque cellule (V) par pack, pour les roues à BMS intelligent (Leaperkim Lynx…).
    var bmsCells: [[Double]]?
    /// Températures des sondes de chaque pack (°C).
    var bmsTemps: [[Double]]?

    var isCharging: Bool { chargeMode != 0 }

    var firmwareString: String {
        if let t = firmwareText { return t }
        guard firmwareRaw > 0 else { return "—" }
        return String(format: "%03d.%01d.%02d",
                      firmwareRaw / 1000, (firmwareRaw % 1000) / 100, firmwareRaw % 100)
    }
}

/// Commande à envoyer, suivie d'un délai avant la suivante.
struct WheelCommand {
    let bytes: [UInt8]
    let delayAfter: TimeInterval

    init(_ bytes: [UInt8], delayAfter: TimeInterval = 0.12) {
        self.bytes = bytes
        self.delayAfter = delayAfter
    }
}

enum LightMode: Int, CaseIterable, Identifiable {
    case off = 0, on = 1, special = 2
    var id: Int { rawValue }
}

enum PedalsMode: Int, CaseIterable, Identifiable {
    case hard = 0, medium = 1, soft = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .hard: return "Dur"
        case .medium: return "Moyen"
        case .soft: return "Souple"
        }
    }
}

protocol WheelProtocol: AnyObject {
    var brand: WheelBrand { get }
    var cellCount: Int { get set }
    var crcFailures: Int { get }
    var rejectedFrames: Int { get }
    var speedLimitRange: ClosedRange<Int> { get }

    func reset()
    /// Ajoute un paquet BLE et renvoie l'état mis à jour après chaque trame complète.
    func feed(_ data: Data) -> [WheelData]
    /// Commandes envoyées juste après l'abonnement aux notifications.
    func initialCommands() -> [WheelCommand]
    /// Raison spécifique à la marque empêchant d'envoyer un réglage (nil = OK).
    func settingsBlockReason() -> String?
    /// Séquence de commandes pour régler la limite de vitesse.
    func speedLimitCommands(kmh: Int) -> [WheelCommand]
    /// Phare : éteint / allumé / mode spécial (stroboscope Begode, auto Kingsong). Vide = non géré.
    func lightCommands(_ mode: LightMode) -> [WheelCommand]
    var supportsSpecialLight: Bool { get }
    var specialLightLabel: String { get }
    /// Mode des pédales.
    func pedalsCommands(_ mode: PedalsMode) -> [WheelCommand]
    /// Bip / klaxon de la roue elle-même. Vide = non géré.
    func hornCommands() -> [WheelCommand]
    /// Journal d'événements (Leaperkim uniquement pour l'instant).
    var supportsEventLog: Bool { get }
    func eventLogRequest() -> [WheelCommand]
    func drainEvents() -> [VeteranEvent]
    /// Protocoles requête / réponse (InMotion) : prochaine requête à envoyer.
    var usesPolling: Bool { get }
    func poll(now: Date) -> [UInt8]?
}

extension WheelProtocol {
    var supportsEventLog: Bool { false }
    func hornCommands() -> [WheelCommand] { [] }
    func eventLogRequest() -> [WheelCommand] { [] }
    func drainEvents() -> [VeteranEvent] { [] }
    var usesPolling: Bool { false }
    func poll(now: Date) -> [UInt8]? { nil }
}

enum ProtocolDetector {
    /// Reconnaît la marque à partir des premiers octets reçus.
    static func detect(_ buf: [UInt8]) -> WheelBrand? {
        let n = buf.count
        guard n >= 3 else { return nil }
        for i in 0..<n {
            if i + 2 < n, buf[i] == 0xDC, buf[i + 1] == 0x5A, buf[i + 2] == 0x5C {
                return .leaperkim
            }
            if i + 19 < n, buf[i] == 0xAA, buf[i + 1] == 0x55,
               buf[i + 18] == 0x5A, buf[i + 19] == 0x5A {
                return .kingsong
            }
            if i + 23 < n, buf[i] == 0x55, buf[i + 1] == 0xAA,
               buf[i + 20] == 0x5A, buf[i + 21] == 0x5A, buf[i + 22] == 0x5A, buf[i + 23] == 0x5A {
                return .begode
            }
        }
        return nil
    }

    static func make(_ brand: WheelBrand) -> WheelProtocol? {
        switch brand {
        case .leaperkim: return VeteranDecoder()
        case .begode: return BegodeProtocol()
        case .kingsong: return KingsongProtocol()
        case .inmotion: return InMotionProtocol()
        case .auto: return nil
        }
    }
}

/// Estimation linéaire par cellule (3,30 V = 0 %, 4,15 V = 100 %).
func estimateBattery(voltage: Double, cells: Int) -> Double {
    guard cells > 0 else { return 0 }
    let cell = voltage / Double(cells)
    return min(100, max(0, (cell - 3.30) / (4.15 - 3.30) * 100.0))
}

// MARK: - Lecture d'octets

enum Bytes {
    static func u16be(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func s16be(_ b: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16be(b, i)))) }
    static func u32be(_ b: [UInt8], _ i: Int) -> Int { u16be(b, i) << 16 | u16be(b, i + 2) }
    static func u16le(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func s16le(_ b: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16le(b, i)))) }
    /// 32 bits Kingsong : deux mots little-endian, mot de poids fort en premier.
    static func u32ks(_ b: [UInt8], _ i: Int) -> Int { u16le(b, i) << 16 | u16le(b, i + 2) }
}
