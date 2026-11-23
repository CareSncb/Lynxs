import AVFoundation
import Foundation

/// Annonces vocales dans les écouteurs (la musique est baissée pendant l'annonce).
final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceAnnouncer()

    private let synth = AVSpeechSynthesizer()
    private var lastPeriodic = Date()
    private var lastBatteryStep: Int?
    private var lastPWMWarning = Date.distantPast

    override init() {
        super.init()
        synth.delegate = self
    }

    func ingest(_ d: WheelData, manager: BLEManager) {
        guard Prefs.voiceEnabled else { return }
        let now = Date()

        // Annonce périodique
        if now.timeIntervalSince(lastPeriodic) >= Double(Prefs.voiceInterval * 60) {
            lastPeriodic = now
            var text = "\(Int(abs(d.speed).rounded())) kilomètres heure, batterie \(Int(d.batteryPercent.rounded())) pour cent"
            let trip = TripRecorder.shared.currentDistance
            if trip >= 0.1 { text += String(format: ", %.1f kilomètres parcourus", trip).replacingOccurrences(of: ".", with: ",") }
            speak(text)
        }

        // Batterie : à chaque palier de 10 %
        if Prefs.voiceBattery {
            let step = Int(d.batteryPercent / 10)
            if let last = lastBatteryStep, step < last {
                speak("Batterie \(step * 10) pour cent")
            }
            lastBatteryStep = step
        }

        // PWM élevé
        if Prefs.voicePWM, d.hasPWM, manager.pwmAlarm > 0, d.pwm >= manager.pwmAlarm,
           now.timeIntervalSince(lastPWMWarning) > 10 {
            lastPWMWarning = now
            speak("Attention, PWM \(Int(d.pwm))", urgent: true)
        }
    }

    func speak(_ text: String, urgent: Bool = false) {
        if urgent && synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        guard !synth.isSpeaking else { return }
        let session = AVAudioSession.sharedInstance()
        // La télécommande montre tient déjà une session .playback : la voix passe par elle.
        if !WatchRemote.shared.isActive {
            try? session.setCategory(.playback, mode: .voicePrompt,
                                     options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        }
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Ne pas couper la session si la télécommande montre l'utilise
        guard !WatchRemote.shared.isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
