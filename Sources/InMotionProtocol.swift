import Foundation

/// Protocole InMotion « V2 » (requête / réponse), implémenté pour la P6.
/// Repris d'EUC World 2.68 : trames AA AA <flags> <longueur> <données> <XOR>,
/// réponses avec échappement A5, valeurs little-endian.
final class InMotionProtocol: WheelProtocol {
    let brand: WheelBrand = .inmotion
    let usesPolling = true
    var cellCount: Int = 36
    let speedLimitRange: ClosedRange<Int> = 10...120
    private(set) var crcFailures = 0
    private(set) var rejectedFrames = 0

    private var raw: [UInt8] = []
    private var state = WheelData()

    // Requête / réponse
    private enum Request { case id, values, total, write(kmh: Int?) }
    private var awaiting: Request?
    private var sentAt = Date.distantPast
    private var writeQueue: [(bytes: [UInt8], kmh: Int?)] = []
    private var cycle = 0
    private var modelSeries: Int?

    init() {
        state.brand = .inmotion
        state.hasPWM = true
        state.hasBatteryCurrent = true
    }

    func reset() {
        raw.removeAll()
        awaiting = nil
    }

    // MARK: - Trames

    static func frame(flags: UInt8, data: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0xAA, 0xAA, flags, UInt8(truncatingIfNeeded: data.count)] + data
        f.append(f.reduce(0, ^))
        return f
    }

    private static let readID = frame(flags: 0x11, data: [0x02, 0x01])
    private static let readValues = frame(flags: 0x14, data: [0x04])
    private static let readTotal = frame(flags: 0x14, data: [0x11])

    func initialCommands() -> [WheelCommand] { [] }   // tout passe par poll()

    /// Appelé régulièrement : renvoie la prochaine requête à envoyer, ou nil.
    func poll(now: Date) -> [UInt8]? {
        if awaiting != nil {
            guard now.timeIntervalSince(sentAt) > 1.0 else { return nil }   // délai dépassé : on relance
            awaiting = nil
        }
        sentAt = now
        if !writeQueue.isEmpty {
            let w = writeQueue.removeFirst()
            awaiting = .write(kmh: w.kmh)
            return w.bytes
        }
        if modelSeries == nil {
            awaiting = .id
            return InMotionProtocol.readID
        }
        cycle += 1
        if cycle % 20 == 0 {
            awaiting = .total
            return InMotionProtocol.readTotal
        }
        awaiting = .values
        return InMotionProtocol.readValues
    }

    func settingsBlockReason() -> String? {
        guard let s = modelSeries else { return "Modèle InMotion pas encore identifié" }
        return s == 13 ? nil : "Seule la P6 est gérée pour l'instant"
    }

    func speedLimitCommands(kmh: Int) -> [WheelCommand] {
        let v = UInt16(clamping: kmh * 100)
        let bytes = InMotionProtocol.frame(flags: 0x14, data: [0x60, 0x21, UInt8(v & 0xFF), UInt8(v >> 8)])
        writeQueue.append((bytes, kmh))
        return []   // envoyé par poll() dans la file requête / réponse
    }

    let supportsSpecialLight = false
    let specialLightLabel = ""

    /// Phare (WheelLog, InMotion V2) : 60 50 <0|1>, envoyé dans la file requête / réponse.
    func lightCommands(_ mode: LightMode) -> [WheelCommand] {
        writeQueue.append((InMotionProtocol.frame(flags: 0x14, data: [0x60, 0x50, mode == .off ? 0 : 1]), nil))
        return []
    }

    /// Klaxon (WheelLog, InMotion V2, famille V13 / V14 dont la P6 est la plus proche) : 60 51 02 64.
    func hornCommands() -> [WheelCommand] {
        writeQueue.append((InMotionProtocol.frame(flags: 0x14, data: [0x60, 0x51, 0x02, 0x64]), nil))
        return [WheelCommand([])]   // non vide : signale que la roue gère le klaxon
    }
    func pedalsCommands(_ mode: PedalsMode) -> [WheelCommand] { [] }

    // MARK: - Réception

    func feed(_ data: Data) -> [WheelData] {
        raw.append(contentsOf: data)
        var results: [WheelData] = []

        while true {
            guard let start = findHeader() else {
                if raw.count > 1 { raw.removeFirst(raw.count - 1) }
                break
            }
            if start > 0 { raw.removeFirst(start) }
            // Déséchappement progressif (A5 précède un octet AA ou A5 littéral)
            var frame: [UInt8] = [0xAA, 0xAA]
            var i = 2
            var escaped = false
            var needed: Int?
            while i < raw.count {
                let b = raw[i]
                i += 1
                if b == 0xA5 && !escaped { escaped = true; continue }
                escaped = false
                frame.append(b)
                if frame.count == 4 { needed = Int(frame[3]) + 5 }
                if let n = needed, frame.count >= n { break }
            }
            guard let n = needed, frame.count >= n else { break }   // trame incomplète
            raw.removeFirst(i)
            let check = frame[0..<(n - 1)].reduce(0, ^)
            guard check == frame[n - 1] else {
                crcFailures += 1
                continue
            }
            if handle(Array(frame[4..<(n - 1)])) { results.append(state) }
        }
        if raw.count > 2048 { raw.removeAll() }
        return results
    }

    private func findHeader() -> Int? {
        guard raw.count >= 2 else { return nil }
        for i in 0..<(raw.count - 1) where raw[i] == 0xAA && raw[i + 1] == 0xAA { return i }
        return nil
    }

    private func handle(_ d: [UInt8]) -> Bool {
        guard let cmd = d.first else { return false }
        let request = awaiting
        awaiting = nil

        switch cmd {
        case 0x82 where d.count > 4 && d[1] == 0x01:   // identification du modèle
            modelSeries = Int(d[3])
            state.model = d[3] == 13 ? "InMotion P6" : "InMotion (série \(d[3]), non gérée)"
            return true

        case 0x84 where d.count >= 65:   // données temps réel (même format que la V9)
            guard modelSeries == 13 else { return false }
            let voltage = Double(Bytes.s16le(d, 1)) / 100
            guard voltage > 20, voltage < 250 else { rejectedFrames += 1; return false }
            state.voltage = voltage
            state.phaseCurrent = Double(Bytes.s16le(d, 3)) / 100
            state.speed = Double(Bytes.s16le(d, 9)) / 100
            state.pwm = abs(Double(Bytes.s16le(d, 15))) / 100
            state.temperature = Double(Int8(bitPattern: d[59])) + 80
            state.batteryPercent = estimateBattery(voltage: voltage, cells: cellCount)
            return true

        case 0x91 where d.count >= 5:   // compteur total (centièmes de km)
            state.totalDistance = Double(UInt32(Bytes.u16le(d, 1)) | UInt32(Bytes.u16le(d, 3)) << 16) / 100
            return true

        default:
            // Accusé de réception d'une écriture de limite de vitesse
            if case .write(let kmh?) = request {
                let ok = d.count <= 2 || d[2] == 0
                if ok {
                    state.speedLimit = Double(kmh)
                    state.speedLimitKnown = true
                    UserDefaults.standard.set(kmh, forKey: "inmotionLastLimit")
                }
                return true
            }
            return false
        }
    }

    /// Dernière limite connue (la P6 ne la renvoie pas dans ses réglages).
    func restoreKnownLimit() {
        if let v = UserDefaults.standard.object(forKey: "inmotionLastLimit") as? Int {
            state.speedLimit = Double(v)
            state.speedLimitKnown = true
        }
    }
}
