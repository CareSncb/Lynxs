import Foundation

/// Protocole BLE Begode / Gotway / Extreme Bull (firmware d'origine).
/// Trames de 24 octets : 55 AA <données…> <type @18> 18 5A 5A 5A 5A, valeurs big-endian.
/// Le réglage de tiltback reprend la séquence d'EUC World 2.68 : "W", "Y", dizaines, unités.
final class BegodeProtocol: WheelProtocol {
    let brand: WheelBrand = .begode
    var cellCount: Int = 24
    let speedLimitRange: ClosedRange<Int> = 10...99
    private(set) var crcFailures = 0
    private(set) var rejectedFrames = 0

    private var buffer: [UInt8] = []
    private var state = WheelData()

    init() {
        state.brand = .begode
    }

    func reset() {
        buffer.removeAll()
    }

    func initialCommands() -> [WheelCommand] { [] }

    func settingsBlockReason() -> String? {
        state.speedLimitKnown ? nil : "Réglages de la roue pas encore reçus, patiente quelques secondes"
    }

    func speedLimitCommands(kmh: Int) -> [WheelCommand] {
        let tens = UInt8(48 + (kmh / 10) % 10)
        let ones = UInt8(48 + kmh % 10)
        return [
            WheelCommand([0x57], delayAfter: 0.1),   // 'W'
            WheelCommand([0x59], delayAfter: 0.1),   // 'Y'
            WheelCommand([tens], delayAfter: 0.1),
            WheelCommand([ones], delayAfter: 0.1)
        ]
    }

    func feed(_ data: Data) -> [WheelData] {
        buffer.append(contentsOf: data)
        var results: [WheelData] = []

        while buffer.count >= 24 {
            guard let start = findFrame() else {
                if buffer.count > 23 { buffer.removeFirst(buffer.count - 23) }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            let frame = Array(buffer[0..<24])
            buffer.removeFirst(24)
            if parse(frame) { results.append(state) } else { rejectedFrames += 1 }
        }
        if buffer.count > 1024 { buffer.removeAll() }
        return results
    }

    private func findFrame() -> Int? {
        guard buffer.count >= 24 else { return nil }
        for i in 0...(buffer.count - 24)
        where buffer[i] == 0x55 && buffer[i + 1] == 0xAA
            && buffer[i + 20] == 0x5A && buffer[i + 21] == 0x5A
            && buffer[i + 22] == 0x5A && buffer[i + 23] == 0x5A {
            return i
        }
        return nil
    }

    private func parse(_ f: [UInt8]) -> Bool {
        let scale = Double(cellCount) / 16.0   // la tension brute est donnée pour 16S (67,2 V)
        switch f[18] {
        case 0x00:
            let voltage = Double(Bytes.u16be(f, 2)) / 100.0 * scale
            let speed = Double(Bytes.s16be(f, 4)) * 0.036
            guard voltage > 10, voltage < 250, abs(speed) < 150 else { return false }
            state.voltage = voltage
            state.speed = speed
            state.tripDistance = Double(Bytes.u32be(f, 6)) / 1000.0
            state.phaseCurrent = Double(Bytes.s16be(f, 10)) / 100.0
            state.temperature = Double(Bytes.s16be(f, 12)) / 340.0 + 36.53   // capteur MPU6050
            state.pwm = abs(Double(Bytes.s16be(f, 14))) / 10.0
            state.hasPWM = true
            state.batteryPercent = estimateBattery(voltage: voltage, cells: cellCount)
            return true
        case 0x04:
            state.totalDistance = Double(Bytes.u32be(f, 2)) / 1000.0
            let settings = Bytes.u16be(f, 6)
            state.pedalsMode = (settings >> 13) & 0x03
            let tiltback = Bytes.u16be(f, 10)
            state.speedLimit = tiltback >= 100 ? 0 : Double(tiltback)   // 0 = tiltback désactivé
            state.speedLimitKnown = true
            return true
        default:
            return true   // autres trames (firmware, BMS…) ignorées
        }
    }
}
