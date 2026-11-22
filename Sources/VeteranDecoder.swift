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
        if Int(f[3]) >= 47 {
            guard d.crcValid else { return nil }
            d.newProtocol = true
        }

        d.batteryPercent = estimateBattery(voltage: d.voltage, cells: cellCount)
        return d
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
