import Foundation

/// Protocole BLE Kingsong.
/// Trames de 20 octets : AA 55 <données…> <type @16> 14 5A 5A, valeurs little-endian.
/// Alarmes et tiltback : lecture 0x98 (réponse 0xB5/0xA4), écriture 0x85, mot de passe 0x99 (réponse 0xE7),
/// comme dans EUC World 2.68.
final class KingsongProtocol: WheelProtocol {
    let brand: WheelBrand = .kingsong
    var cellCount: Int = 20
    let speedLimitRange: ClosedRange<Int> = 10...99
    private(set) var crcFailures = 0
    private(set) var rejectedFrames = 0

    private var buffer: [UInt8] = []
    private var state = WheelData()

    /// Alarmes actuelles de la roue : [alarme 1, alarme 2, alarme 3, tiltback].
    private var alarms: [Int]?
    private var password: [UInt8]?
    private let savedAlarmsKey = "ksSavedAlarms"

    init() {
        state.brand = .kingsong
    }

    func reset() {
        buffer.removeAll()
    }

    static func frame(_ cmd: UInt8, _ fill: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 20)
        f[0] = 0xAA; f[1] = 0x55
        f[16] = cmd; f[17] = 0x14; f[18] = 0x5A; f[19] = 0x5A
        fill(&f)
        return f
    }

    func initialCommands() -> [WheelCommand] {
        [
            WheelCommand(KingsongProtocol.frame(0x9B), delayAfter: 0.3),   // nom / modèle
            WheelCommand(KingsongProtocol.frame(0x99), delayAfter: 0.3),   // mot de passe des alarmes
            WheelCommand(KingsongProtocol.frame(0x98), delayAfter: 0.3)    // alarmes + tiltback
        ]
    }

    func settingsBlockReason() -> String? {
        alarms == nil ? "Alarmes de la roue pas encore lues, patiente quelques secondes" : nil
    }

    func speedLimitCommands(kmh: Int) -> [WheelCommand] {
        guard let current = alarms else { return [] }
        let defaults = UserDefaults.standard
        var a = Array(current.prefix(3))

        if kmh < current[3] {
            // Bridage : on mémorise les alarmes d'origine, puis on les ramène sous la nouvelle limite
            if current[3] > kmh { defaults.set(current, forKey: savedAlarmsKey) }
            a = a.map { min($0, kmh) }
        } else if let saved = defaults.array(forKey: savedAlarmsKey) as? [Int],
                  saved.count == 4, saved[3] == kmh {
            // Débridage : on restaure les alarmes d'origine
            a = Array(saved.prefix(3))
        }

        let pw = password
        let write = KingsongProtocol.frame(0x85) { f in
            f[2] = UInt8(clamping: a[0])
            f[4] = UInt8(clamping: a[1])
            f[6] = UInt8(clamping: a[2])
            f[8] = UInt8(clamping: kmh)
            if let pw = pw {
                for (i, byte) in pw.prefix(6).enumerated() { f[10 + i] = byte }
            }
        }
        return [
            WheelCommand(write, delayAfter: 0.4),
            WheelCommand(KingsongProtocol.frame(0x98), delayAfter: 0.2)   // relecture pour vérifier
        ]
    }

    func feed(_ data: Data) -> [WheelData] {
        buffer.append(contentsOf: data)
        var results: [WheelData] = []

        while buffer.count >= 20 {
            guard let start = findFrame() else {
                if buffer.count > 19 { buffer.removeFirst(buffer.count - 19) }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            let frame = Array(buffer[0..<20])
            buffer.removeFirst(20)
            if parse(frame) { results.append(state) } else { rejectedFrames += 1 }
        }
        if buffer.count > 1024 { buffer.removeAll() }
        return results
    }

    private func findFrame() -> Int? {
        guard buffer.count >= 20 else { return nil }
        for i in 0...(buffer.count - 20)
        where buffer[i] == 0xAA && buffer[i + 1] == 0x55
            && buffer[i + 18] == 0x5A && buffer[i + 19] == 0x5A {
            return i
        }
        return nil
    }

    private func parse(_ f: [UInt8]) -> Bool {
        switch f[16] {
        case 0xA9:   // données temps réel
            let voltage = Double(Bytes.u16le(f, 2)) / 100.0
            let speed = Double(Bytes.s16le(f, 4)) / 100.0
            guard voltage > 10, voltage < 250, abs(speed) < 150 else { return false }
            state.voltage = voltage
            state.speed = speed
            state.totalDistance = Double(Bytes.u32ks(f, 6)) / 1000.0
            state.phaseCurrent = Double(Bytes.s16le(f, 10)) / 100.0
            state.temperature = Double(Bytes.s16le(f, 12)) / 100.0
            state.batteryPercent = estimateBattery(voltage: voltage, cells: cellCount)
            return true
        case 0xB9:   // distance du trajet
            state.tripDistance = Double(Bytes.u32ks(f, 2)) / 1000.0
            return true
        case 0xF5:   // charge CPU / PWM
            state.pwm = Double(f[15])
            state.hasPWM = true
            return true
        case 0xB5, 0xA4:   // alarmes et tiltback
            let values = [Int(f[4]), Int(f[6]), Int(f[8]), Int(f[10])]
            alarms = values
            state.speedAlert = Double(values[0])
            state.speedLimit = Double(values[3])
            state.speedLimitKnown = true
            return true
        case 0xE7:   // mot de passe des alarmes
            let pw = Array(f[2..<8])
            let printable = pw.allSatisfy { $0 >= 0x30 && $0 <= 0x7A }
            password = printable ? pw : nil
            return true
        case 0xBB:   // nom du modèle
            let bytes = f[2..<16].prefix(while: { $0 != 0 })
            if let name = String(bytes: bytes, encoding: .ascii), !name.isEmpty {
                state.model = name
            }
            return true
        default:
            return true
        }
    }
}
