import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer

/// Télécommande Apple Watch SANS app montre.
///
/// L'appli se présente comme un lecteur audio (elle joue du silence). L'écran « À l'écoute »
/// de la montre (et de l'écran verrouillé, des AirPods, de CarPlay…) la pilote alors :
/// - titre du « morceau » : vitesse et état du bridage, mis à jour en direct ;
/// - Lecture/Pause : brider / débrider, avec confirmation (deux appuis en moins de 5 s) ;
/// - Suivant : klaxon ;
/// - Précédent : annonce vocale de l'état (vitesse, batterie, bridage).
///
/// Aucune signature particulière n'est nécessaire côté montre : tout se passe sur l'iPhone.
final class WatchRemote {
    static let shared = WatchRemote()

    /// Vrai quand la télécommande tient la session audio (les autres sons doivent la respecter).
    private(set) var isActive = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    private var commandsReady = false
    private var observers: [NSObjectProtocol] = []

    private var armedUntil = Date.distantPast
    private var flash: (text: String, until: Date)?
    private var lastInfo = Date.distantPast
    private var busy = false
    private var lastStartAttempt = Date.distantPast

    private static let confirmWindow: TimeInterval = 5

    // MARK: - Démarrage / arrêt

    func start() {
        guard Prefs.watchRemote, !isActive else { return }
        // Une session audio ne démarre pas toujours en arrière-plan : on réessaie toutes les 10 s.
        guard Date().timeIntervalSince(lastStartAttempt) > 10 else { return }
        lastStartAttempt = Date()
        let session = AVAudioSession.sharedInstance()
        // .playback sans « mix » : indispensable pour devenir l'app « À l'écoute ».
        guard (try? session.setCategory(.playback, mode: .default, options: [])) != nil,
              (try? session.setActive(true)) != nil else { return }
        setupEngine()
        guard startEngine() else { return }
        setupCommands(enabled: true)
        observeSession()
        isActive = true
        refresh(force: true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        player.stop()
        engine.stop()
        setupCommands(enabled: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Appelé quand le réglage change dans l'appli.
    func settingChanged() {
        lastStartAttempt = .distantPast
        if !Prefs.watchRemote { stop() }
        else if BLEManager.shared.state == .connected { start() }
    }

    // MARK: - Audio silencieux

    private func setupEngine() {
        guard !engineReady else { return }
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engineReady = true
    }

    @discardableResult
    private func startEngine() -> Bool {
        do {
            if !engine.isRunning { try engine.start() }
        } catch { return false }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frames = AVAudioFrameCount(max(format.sampleRate, 8000))   // 1 s de silence
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
        buf.frameLength = frames   // le tampon est déjà rempli de zéros
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        return true
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        // Après un appel, Siri, etc. : on reprend la main.
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isActive,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.startEngine()
            self.refresh(force: true)
        })
        // Écouteurs branchés / débranchés : le moteur audio s'arrête, on le relance.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.startEngine()
        })
    }

    /// À appeler après un son (klaxon, annonce) qui a pu modifier la session audio.
    func reclaimSession() {
        guard isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        if !engine.isRunning || !player.isPlaying { startEngine() }
    }

    // MARK: - Commandes « À l'écoute »

    private func setupCommands(enabled: Bool) {
        let cc = MPRemoteCommandCenter.shared()
        if enabled && !commandsReady {
            commandsReady = true
            let press: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
                DispatchQueue.main.async { self?.limiterPressed() }
                return .success
            }
            cc.togglePlayPauseCommand.addTarget(handler: press)
            cc.playCommand.addTarget(handler: press)
            cc.pauseCommand.addTarget(handler: press)
            cc.nextTrackCommand.addTarget { _ in
                DispatchQueue.main.async {
                    HornPlayer.shared.horn()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { WatchRemote.shared.reclaimSession() }
                }
                return .success
            }
            cc.previousTrackCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.announceStatus() }
                return .success
            }
        }
        for c in [cc.togglePlayPauseCommand, cc.playCommand, cc.pauseCommand,
                  cc.nextTrackCommand, cc.previousTrackCommand] {
            c.isEnabled = enabled
        }
        // Pas de barre de progression ni d'avance rapide
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
    }

    /// Premier appui : demande confirmation. Second appui dans les 5 s : bride / débride.
    private func limiterPressed() {
        guard !busy else { return }
        let ble = BLEManager.shared
        guard ble.state == .connected else {
            show("Roue non connectée")
            return
        }
        let engaged = ble.isLimited || ble.pendingAction == .engage
        let now = Date()
        if now > armedUntil {
            armedUntil = now.addingTimeInterval(Self.confirmWindow)
            show(engaged ? "Appuie encore pour DÉBRIDER" : "Appuie encore pour BRIDER 25",
                 seconds: Self.confirmWindow)
            UIImpact.tap()
            return
        }
        armedUntil = .distantPast
        busy = true
        show(engaged ? "Débridage…" : "Bridage…", seconds: 15)
        Task { @MainActor in
            let text = await LimiterToggle.run()
            ble.limiterMessage = text
            self.busy = false
            self.show(text, seconds: 5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { WatchRemote.shared.reclaimSession() }
        }
    }

    private func announceStatus() {
        let ble = BLEManager.shared
        guard ble.state == .connected else {
            VoiceAnnouncer.shared.speak("Roue non connectée", urgent: true)
            return
        }
        let d = ble.data
        var text = "\(Int(abs(d.speed).rounded())) kilomètres heure, batterie \(Int(d.batteryPercent.rounded())) pour cent"
        if ble.isLimited { text += ", roue bridée à 25" }
        else if ble.pendingAction == .engage { text += ", bridage en attente" }
        else { text += ", roue débridée" }
        VoiceAnnouncer.shared.speak(text, urgent: true)
    }

    // MARK: - Affichage (titre du « morceau »)

    private func show(_ text: String, seconds: TimeInterval = 4) {
        flash = (text, Date().addingTimeInterval(seconds))
        refresh(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in
            self?.refresh(force: true)
        }
    }

    /// Met à jour l'écran « À l'écoute » (au plus une fois par seconde).
    func refresh(force: Bool = false) {
        guard isActive else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastInfo) >= 1 else { return }
        lastInfo = now

        let ble = BLEManager.shared
        let d = ble.data
        let connected = ble.state == .connected
        let lock: String
        if ble.pendingAction != nil { lock = "⏳" }
        else if ble.isLimited { lock = "🔒 25" }
        else { lock = "🔓" }

        var title = connected ? "\(Int(abs(d.speed).rounded())) km/h  \(lock)" : "Roue déconnectée"
        if let f = flash, f.until > now { title = f.text } else { flash = nil }

        var details = ["\(Int(d.batteryPercent.rounded())) %"]
        if d.hasPWM { details.append("PWM \(Int(d.pwm.rounded())) %") }
        details.append("\(Int(d.temperature.rounded())) °C")
        let trip = TripRecorder.shared.currentDistance
        if trip >= 0.1 { details.append(String(format: "%.1f km", trip)) }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: connected ? details.joined(separator: " · ") : "LynxDash",
            MPMediaItemPropertyAlbumTitle: ble.connectedName ?? "LynxDash",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }
}

/// Petite vibration de confirmation sur l'iPhone.
enum UIImpact {
    static func tap() {
        AudioServicesPlaySystemSound(1519)   // « peek » haptique
    }
}
