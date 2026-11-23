import AVFoundation
import AudioToolbox
import Foundation

// MARK: - Marge de sécurité, bips progressifs, alarme de charge prolongée

/// Calcule en continu la réserve de puissance (marge de sécurité) et pilote les bips.
///
/// Marge = 100 % − charge moteur. La charge vient du PWM quand la roue l'envoie ;
/// sinon elle est estimée : vitesse / vitesse max théorique à la tension actuelle.
/// Plus la marge fond sous le seuil, plus les bips sont rapprochés et aigus.
final class SafetyAlarms: ObservableObject {
    static let shared = SafetyAlarms()

    /// Marge de sécurité en % (nil si incalculable).
    @Published private(set) var margin: Double?
    /// 0 = aucun danger, 1 = critique.
    @Published private(set) var severity: Double = 0
    @Published private(set) var sustainedLoad = false

    private var lastBeep = Date.distantPast
    private var lastVibrate = Date.distantPast
    private var currents: [(Date, Double)] = []
    private var lastLoadWarning = Date.distantPast
    private var lastLoadBeep = Date.distantPast

    /// Charge moteur en % (0–100+).
    static func load(_ d: WheelData, cells: Int) -> Double? {
        if d.hasPWM { return d.pwm }
        let top = Prefs.topSpeedAtFull
        guard top > 0, cells > 0, d.voltage > 0 else { return nil }
        let full = 4.2 * Double(cells)
        let vmax = top * d.voltage / full
        guard vmax > 1 else { return nil }
        // Le couple demandé grignote aussi la réserve : ~0,1 % par ampère de phase
        return abs(d.speed) / vmax * 100 + abs(d.phaseCurrent) * 0.1
    }

    func ingest(_ d: WheelData, manager: BLEManager) {
        let now = Date()
        var level = 0.0

        // 1. Marge de sécurité
        if let load = Self.load(d, cells: manager.cellCount) {
            let m = max(0, 100 - load)
            margin = m
            let threshold = Prefs.marginAlarm
            if threshold > 0, m < threshold, abs(d.speed) > 5 {
                level = max(level, min(1, (threshold - m) / threshold))
            }
        } else {
            margin = nil
        }

        // 2. Seuils fixes (vitesse, PWM) réglés dans l'appli
        let speedHit = manager.speedAlarm > 0 && abs(d.speed) >= manager.speedAlarm
        let pwmHit = d.hasPWM && manager.pwmAlarm > 0 && d.pwm >= manager.pwmAlarm
        if speedHit || pwmHit { level = max(level, 0.35) }
        if pwmHit { level = max(level, min(1, 0.35 + (d.pwm - manager.pwmAlarm) / 30)) }

        severity = level
        if level > 0 { beepIfDue(level: level, now: now) }

        // 3. Charge élevée prolongée (montée raide, vent de face…)
        checkSustained(d, now: now)
    }

    private func beepIfDue(level: Double, now: Date) {
        // de 1 bip/s (début) à 8 bips/s (critique)
        let interval = 1.0 - 0.875 * level
        guard now.timeIntervalSince(lastBeep) >= interval else { return }
        lastBeep = now
        if Prefs.alarmBeeps {
            Beeper.shared.beep(frequency: 1100 + 1100 * level, duration: level > 0.7 ? 0.05 : 0.08)
        } else {
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
        if now.timeIntervalSince(lastVibrate) > 0.9 {
            lastVibrate = now
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func checkSustained(_ d: WheelData, now: Date) {
        let limit = Prefs.currentAlarm
        guard limit > 0 else { sustainedLoad = false; return }
        currents.append((now, abs(d.phaseCurrent)))
        currents.removeAll { now.timeIntervalSince($0.0) > 15 }
        guard let first = currents.first, now.timeIntervalSince(first.0) > 12 else { return }
        let avg = currents.reduce(0) { $0 + $1.1 } / Double(currents.count)
        sustainedLoad = avg >= limit
        guard sustainedLoad else { return }
        if now.timeIntervalSince(lastLoadBeep) > 4 {
            lastLoadBeep = now
            Beeper.shared.beep(frequency: 520, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { Beeper.shared.beep(frequency: 520, duration: 0.18) }
        }
        if now.timeIntervalSince(lastLoadWarning) > 60 {
            lastLoadWarning = now
            VoiceAnnouncer.shared.speak("Charge élevée depuis 15 secondes, \(Int(avg)) ampères. Ralentis ou laisse refroidir.", urgent: true)
            PhoneWatchBridge.shared.sendAlert("Charge élevée prolongée (\(Int(avg)) A)")
        }
    }

    func wheelDisconnected() {
        margin = nil
        severity = 0
        sustainedLoad = false
        currents.removeAll()
    }
}

/// Bips courts générés à la volée, audibles par-dessus la musique (qui est baissée un instant).
final class Beeper {
    static let shared = Beeper()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var ready = false
    private var idleWork: DispatchWorkItem?
    private var ownsSession = false

    private func prepare() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if !WatchRemote.shared.isActive && !EngineSound.shared.isRunning {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            ownsSession = true
        }
        try? session.setActive(true)
        if !ready {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            ready = true
        }
        if !engine.isRunning { try? engine.start() }
        return engine.isRunning
    }

    func beep(frequency: Double, duration: Double, volume: Float = 0.9) {
        guard prepare() else { return }
        let format = player.outputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 44100
        let frames = AVAudioFrameCount(rate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let env = min(1, t / 0.005, (duration - t) / 0.01)       // évite les clics
            let v = Float(sin(2 * .pi * frequency * t) * max(0, env)) * volume
            for ch in 0..<Int(format.channelCount) { buf.floatChannelData?[ch][i] = v }
        }
        player.scheduleBuffer(buf, at: nil, options: [])
        if !player.isPlaying { player.play() }

        // Rend le son aux autres applis après 2 s de silence
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ownsSession, !WatchRemote.shared.isActive, !EngineSound.shared.isRunning else { return }
            self.ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - Phare automatique (coucher / lever du soleil)

enum SolarTimes {
    /// Heures de lever et de coucher du soleil (algorithme NOAA simplifié), en Date.
    static func sunriseSunset(date: Date, latitude: Double, longitude: Double) -> (rise: Date, set: Date)? {
        let cal = Calendar(identifier: .gregorian)
        guard let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) else { return nil }
        let rad = Double.pi / 180
        let gamma = 2 * Double.pi / 365 * (Double(dayOfYear) - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let zenith = 90.833 * rad
        let cosHA = cos(zenith) / (cos(latitude * rad) * cos(decl)) - tan(latitude * rad) * tan(decl)
        guard cosHA >= -1, cosHA <= 1 else { return nil }   // jour ou nuit polaire
        let ha = acos(cosHA) / rad
        let riseMin = 720 - 4 * (longitude + ha) - eqTime     // minutes UTC
        let setMin = 720 - 4 * (longitude - ha) - eqTime
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let midnightUTC = utc.date(from: comps) else { return nil }
        return (midnightUTC.addingTimeInterval(riseMin * 60), midnightUTC.addingTimeInterval(setMin * 60))
    }

    static func isDark(at date: Date = Date(), location: CLLocationLike) -> Bool {
        guard let t = sunriseSunset(date: date, latitude: location.lat, longitude: location.lon) else { return false }
        // 10 min de marge : on allume un peu avant le coucher, on éteint un peu après le lever
        return date < t.rise.addingTimeInterval(600) || date > t.set.addingTimeInterval(-600)
    }
}

struct CLLocationLike { var lat: Double; var lon: Double }

final class AutoLight {
    static let shared = AutoLight()
    private var lastCheck = Date.distantPast
    private var applied: Bool?

    func ingest(manager: BLEManager) {
        guard Prefs.autoLight, manager.supportsLight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 30 else { return }
        lastCheck = now
        // Position GPS, sinon Bruxelles par défaut
        let loc = TripRecorder.shared.lastLocation
        let here = CLLocationLike(lat: loc?.coordinate.latitude ?? 50.85, lon: loc?.coordinate.longitude ?? 4.35)
        let dark = SolarTimes.isDark(location: here)
        // On n'agit qu'au changement jour/nuit : un réglage manuel entre-temps est respecté
        guard applied != dark else { return }
        applied = dark
        manager.setLight(dark ? .on : .off)
        NotificationCenter.default.post(name: .autoLightChanged, object: dark)
    }

    func wheelDisconnected() { applied = nil }
}

extension Notification.Name {
    static let autoLightChanged = Notification.Name("autoLightChanged")
}
