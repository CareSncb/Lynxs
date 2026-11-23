import AVFoundation
import Foundation

// MARK: - Son moteur virtuel (dans les écouteurs)

/// Synthétise en direct un son de moteur dont la hauteur suit la vitesse et le volume la charge.
final class EngineSound {
    static let shared = EngineSound()

    enum Style: String, CaseIterable, Identifiable {
        case electric = "Électrique (turbine)"
        case v8 = "Thermique (V8)"
        case scifi = "Science-fiction"
        var id: String { rawValue }
    }

    private(set) var isRunning = false
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    // Paramètres lus par le fil audio
    private var targetFreq = 40.0
    private var targetGain = 0.0
    private var freq = 40.0
    private var gain = 0.0
    private var phase = 0.0
    private var phase2 = 0.0
    private var noiseSeed: UInt32 = 12345
    private var style: Style = .electric
    private var sampleRate = 44100.0

    func ingest(_ d: WheelData, manager: BLEManager) {
        guard Prefs.engineSound else { if isRunning { stop() }; return }
        if !isRunning { start() }
        let speed = abs(d.speed)
        style = Style(rawValue: Prefs.engineStyle) ?? .electric
        let load = SafetyAlarms.load(d, cells: manager.cellCount) ?? min(100, speed * 2)
        switch style {
        case .electric: targetFreq = 60 + speed * 9
        case .v8:
            // passage de « rapports » tous les 12 km/h
            let gear = floor(speed / 12)
            targetFreq = 28 + (speed - gear * 12) * 4.5 + gear * 6
        case .scifi: targetFreq = 90 + speed * 14
        }
        let volume = Double(Prefs.engineVolume)
        targetGain = speed < 1 ? 0.04 * volume : (0.10 + 0.25 * min(1, load / 100)) * volume
    }

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        if !WatchRemote.shared.isActive {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        let format = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: mono) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let out = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<Int(frameCount) {
                // lissage pour éviter les sauts
                self.freq += (self.targetFreq - self.freq) * 0.0008
                self.gain += (self.targetGain - self.gain) * 0.0005
                self.phase += self.freq / self.sampleRate
                if self.phase >= 1 { self.phase -= 1 }
                self.phase2 += self.freq * 0.5 / self.sampleRate
                if self.phase2 >= 1 { self.phase2 -= 1 }
                out[i] = Float(self.sample() * self.gain)
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        do { try engine.start(); isRunning = true } catch { isRunning = false }
    }

    private func noise() -> Double {
        noiseSeed = noiseSeed &* 1664525 &+ 1013904223
        return Double(noiseSeed) / Double(UInt32.max) * 2 - 1
    }

    private func sample() -> Double {
        let saw = phase * 2 - 1
        let sine = sin(2 * .pi * phase)
        switch style {
        case .electric:
            // turbine : fondamentale douce + sifflement aigu à 8×
            let whine = sin(2 * .pi * phase * 8) * 0.35
            return sine * 0.6 + whine + noise() * 0.03
        case .v8:
            // grondement : dent de scie + sous-harmonique + irrégularités
            let sub = phase2 < 0.5 ? 0.5 : -0.5
            return saw * 0.5 + sub * 0.4 + noise() * 0.12 * (0.5 + sine * 0.5)
        case .scifi:
            let wob = sin(2 * .pi * phase2 * 3)
            return sin(2 * .pi * phase * (1 + 0.02 * wob)) * 0.7 + sin(2 * .pi * phase * 3) * 0.2
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        isRunning = false
        gain = 0
        if !WatchRemote.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func wheelDisconnected() { stop() }
}
