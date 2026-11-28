import Foundation

/// Protocole BLE Leaperkim / Veteran (Lynx, Lynx S, Sherman, Patton, Abrams…) et Nosfet.
/// Trame : DC 5A 5C <len> <données…> [CRC32 sur les firmwares récents]
/// Offsets et commandes vérifiés dans EUC World 2.68.
final class VeteranDecoder: WheelProtocol {
    let brand: WheelBrand = .leaperkim
    var cellCount: Int = 36
    let speedLimitRange: ClosedRange<Int> = 10...200
    private(set) var crcFailures = 0
    private(set) var rejectedFrames = 0

    private var buffer: [UInt8] = []
    private var last = WheelData()
    private var events: [VeteranEvent] = []
    /// BMS intelligent (Lynx = modèle 5, Sherman L = 6, Lynx S = 9…) : 2 packs, jusqu'à 42 cellules.
    private var bmsCells: [[Double]] = [Array(repeating: 0, count: 42), Array(repeating: 0, count: 42)]
    private var bmsTemps: [[Double]] = [Array(repeating: 0, count: 6), Array(repeating: 0, count: 6)]
    private var bmsSeen = false

    var supportsEventLog: Bool { last.newProtocol }

    func eventLogRequest() -> [WheelCommand] {
        last.newProtocol ? [WheelCommand(VeteranEvent.requestCommand)] : []
    }

    func drainEvents() -> [VeteranEvent] {
        defer { events.removeAll() }
        return events
    }

    func reset() {
        buffer.removeAll()
    }

    func initialCommands() -> [WheelCommand] { [] }   // la roue envoie ses données en continu

    func settingsBlockReason() -> String? {
        last.newProtocol ? nil : "Firmware de la roue non compatible (trames sans CRC)"
    }

    func speedLimitCommands(kmh: Int) -> [WheelCommand] {
        [WheelCommand(VeteranDecoder.speedLimitCommand(kmh: kmh))]
    }

    let supportsSpecialLight = false
    let specialLightLabel = ""

    func lightCommands(_ mode: LightMode) -> [WheelCommand] {
        // Comme WheelLog (open source) : commande texte pour TOUS les modèles, Lynx / Lynx S compris.
        // (L'ancienne trame « LkAp 107 » n'était pas la bonne.)
        let on = mode != .off
        return [WheelCommand(Array((on ? "SetLightON" : "SetLightOFF").utf8))]
    }

    /// Bip de la roue (repris de WheelLog, open source) :
    /// nouveau protocole → 4C 6B 41 70 0E 00 80 80 80 01 + CRC32 (CA 87 E6 6F), ancien → « b ».
    func hornCommands() -> [WheelCommand] {
        // Choix selon le numéro de modèle (firmware / 1000) comme WheelLog : ≥ 3 → trame LkAp
        // (Sherman S, Patton, Lynx = 5, Lynx S = 9, Oryx, Nosfet…), sinon « b ».
        if last.firmwareRaw / 1000 >= 3 || last.newProtocol {
            return [WheelCommand(VeteranDecoder.command(107, payload: [0x00, 0x80, 0x80, 0x80, 0x01]))]
        }
        return [WheelCommand(Array("b".utf8))]
    }

    func pedalsCommands(_ mode: PedalsMode) -> [WheelCommand] {
        // Comme WheelLog : commande texte pour tous les modèles (SETh / SETm / SETs)
        let text = mode == .hard ? "SETh" : (mode == .medium ? "SETm" : "SETs")
        return [WheelCommand(Array(text.utf8))]
    }

    func feed(_ data: Data) -> [WheelData] {
        buffer.append(contentsOf: data)
        var results: [WheelData] = []

        while true {
            guard let start = findHeader() else {
                if buffer.count > 2 { buffer.removeFirst(buffer.count - 2) }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }

            let len = Int(buffer[3])
            guard len >= 32 && len <= 250 else {
                rejectedFrames += 1
                buffer.removeFirst(1)
                continue
            }
            let total = len + 4
            guard buffer.count >= total else { break }

            let frame = Array(buffer[0..<total])
            if let decoded = parse(frame) {
                last = decoded
                results.append(decoded)
                buffer.removeFirst(total)
            } else {
                rejectedFrames += 1
                buffer.removeFirst(1)
            }
        }

        if buffer.count > 1024 { buffer.removeAll() }
        return results
    }

    private func findHeader() -> Int? {
        guard buffer.count >= 3 else { return nil }
        for i in 0...(buffer.count - 3)
        where buffer[i] == 0xDC && buffer[i + 1] == 0x5A && buffer[i + 2] == 0x5C {
            return i
        }
        return nil
    }

    private func parse(_ f: [UInt8]) -> WheelData? {
        guard f.count >= 36 else { return nil }
        var d = WheelData()
        d.brand = .leaperkim

        d.voltage       = Double(Bytes.u16be(f, 4)) / 100.0
        d.speed         = Double(Bytes.s16be(f, 6)) / 10.0
        d.tripDistance  = Double(Bytes.u16be(f, 10) << 16 | Bytes.u16be(f, 8)) / 1000.0
        d.totalDistance = Double(Bytes.u16be(f, 14) << 16 | Bytes.u16be(f, 12)) / 1000.0
        d.firmwareRaw   = Int(f[30]) * 65536 + Bytes.u16be(f, 28)
        let modelId = d.firmwareRaw / 1000
        let currentSign: Double = modelId >= 3 ? -1 : 1   // comme EUC World
        d.phaseCurrent  = Double(Bytes.s16be(f, 16)) / 10.0 * currentSign
        d.temperature   = Double(Bytes.s16be(f, 18)) / 100.0
        d.chargeMode    = Bytes.u16be(f, 22)
        d.speedAlert    = Double(Bytes.u16be(f, 24)) / 10.0
        d.speedLimit    = Double(Bytes.u16be(f, 26)) / 10.0
        d.speedLimitKnown = true
        d.pedalsMode    = Int(f[31])
        d.pitchAngle    = Double(Bytes.s16be(f, 32)) / 100.0
        d.hasPitch      = true
        d.pwm           = Double(Bytes.u16be(f, 34)) / 100.0
        d.hasPWM        = true

        guard d.voltage > 20, d.voltage < 220 else { return nil }
        guard abs(d.speed) < 150 else { return nil }
        guard d.temperature > -40, d.temperature < 150 else { return nil }

        if f.count >= 42 {
            d.crcChecked = true
            let computed = crc32(f[0..<(f.count - 4)])
            let given = UInt32(Bytes.u32be(f, f.count - 4))
            d.crcValid = (computed == given)
            if !d.crcValid { crcFailures += 1 }
        }

        // Comme EUC World : à partir de 47 octets de données, le CRC est obligatoire
        // Firmware récent : toutes les vraies trames ont un CRC. Une trame sans CRC valide
        // est alors un collage de deux paquets Bluetooth : on la rejette.
        if last.newProtocol && !(d.crcChecked && d.crcValid) { return nil }
        if Int(f[3]) >= 47 {
            guard d.crcValid else { return nil }
            d.newProtocol = true
        }

        parseSmartBMS(f, model: modelId)
        if bmsSeen { d.bmsCells = bmsCells; d.bmsTemps = bmsTemps }

        d.batteryPercent = estimateBattery(voltage: d.voltage, cells: cellCount)
        if d.newProtocol, let entries = VeteranEvent.parse(frame: f) { events.append(contentsOf: entries) }
        return d
    }

    /// BMS intelligent, d'après WheelLog (open source) : l'octet 46 indique le paquet
    /// (1-3 = pack 1, 5-7 = pack 2) ; cellules en mV big-endian.
    private func parseSmartBMS(_ f: [UInt8], model: Int) {
        guard model >= 5, f.count > 46 else { return }
        let pnum = Int(f[46])
        let pack = pnum < 4 ? 0 : 1
        func u16(_ o: Int) -> Int? { o + 1 < f.count ? Bytes.u16be(f, o) : nil }
        func s16(_ o: Int) -> Int? { o + 1 < f.count ? Bytes.s16be(f, o) : nil }
        switch pnum {
        case 1, 5:
            for i in 0..<15 { if let v = s16(53 + i * 2) { bmsCells[pack][i] = Double(v) / 1000 } }
            bmsSeen = true
        case 2, 6:
            for i in 0..<15 { if let v = u16(53 + i * 2) { bmsCells[pack][i + 15] = Double(v) / 1000 } }
        case 3, 7:
            for i in 0..<12 { if let v = u16(59 + i * 2) { bmsCells[pack][i + 30] = Double(v) / 1000 } }
            for i in 0..<6 { if let v = s16(47 + i * 2) { bmsTemps[pack][i] = Double(v) / 100 } }
        default:
            break
        }
    }

    // MARK: - Commandes

    /// Trame : 'L' <cmd> 'A' 'p' <longueur totale> <données> <CRC32 big-endian>
    static func command(_ cmd: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x4C, cmd, 0x41, 0x70, UInt8(truncatingIfNeeded: payload.count + 9)]
        frame.append(contentsOf: payload)
        let crc = crc32(frame)
        frame.append(UInt8(truncatingIfNeeded: (crc >> 24) & 0xFF))
        frame.append(UInt8(truncatingIfNeeded: (crc >> 16) & 0xFF))
        frame.append(UInt8(truncatingIfNeeded: (crc >> 8) & 0xFF))
        frame.append(UInt8(truncatingIfNeeded: crc & 0xFF))
        return frame
    }

    /// 25 km/h → 4C 64 41 70 11 01 02 80 80 80 80 80 19 FE C4 04 ED
    static func speedLimitCommand(kmh: Int) -> [UInt8] {
        command(100, payload: [0x01, 0x02, 0x80, 0x80, 0x80, 0x80, 0x80, UInt8(truncatingIfNeeded: kmh)])
    }
}

// MARK: - CRC32 (IEEE 802.3)

private let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
    }
    return c
}

func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in bytes {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}
