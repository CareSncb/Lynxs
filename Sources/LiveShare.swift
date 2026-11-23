import CoreLocation
import SwiftUI

/// Partage du trajet en direct : la position est publiée toutes les 5 s sur un sujet ntfy.sh secret,
/// et une page web (docs/suivi.html, publiée par GitHub Pages) l'affiche sur une carte.
final class LiveShare: ObservableObject {
    static let shared = LiveShare()

    static let pageURL = "https://caresncb.github.io/lynxs/suivi.html"

    @Published private(set) var active = false
    @Published private(set) var lastSent: Date?
    @Published private(set) var error: String?
    @Published private(set) var channels: String?
    @AppStorage("liveShareCode") private(set) var code = ""
    @AppStorage("liveShareName") var displayName = ""
    @AppStorage("liveShareAuto") var autoWithTrips = false

    private var timer: Timer?

    var link: URL? { code.isEmpty ? nil : URL(string: "\(LiveShare.pageURL)#\(code)") }

    var shareMessage: String {
        let who = displayName.isEmpty ? "Je" : displayName
        return "\(who) roule en gyroroue : suis le trajet en direct ici 👉 \(link?.absoluteString ?? "")"
    }

    /// Canal dérivé du code (le code lui-même n'est jamais envoyé).
    private var channel: String { LiveCrypto.channel(for: code) }
    private var trail: [[Double]] = []

    /// Nouveau code secret (l'ancien lien ne fonctionne plus).
    func regenerateCode() {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        code = String((0..<12).map { _ in chars.randomElement()! })
    }

    func start() {
        if code.isEmpty { regenerateCode() }
        active = true
        error = nil
        trail = []
        TripRecorder.shared.requestPermission()
        TripRecorder.shared.ensureLocation()
        publish()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.publish() }
    }

    func stop() {
        guard active else { return }
        timer?.invalidate()
        active = false
        send(["ended": true, "trail": trail, "ts": Date().timeIntervalSince1970, "name": displayName])
    }

    /// Démarrage / arrêt automatique avec l'enregistrement des trajets.
    func tripStateChanged(recording: Bool) {
        guard autoWithTrips else { return }
        if recording && !active { start() }
        if !recording && active { stop() }
    }

    private func publish() {
        guard active else { return }
        guard let loc = TripRecorder.shared.lastLocation else {
            error = "En attente du GPS… (autorise la localisation pour LynxDash)"
            TripRecorder.shared.ensureLocation()
            return
        }
        let ble = BLEManager.shared
        let connected = ble.state == .connected
        trail.append([(loc.coordinate.latitude * 1e5).rounded() / 1e5, (loc.coordinate.longitude * 1e5).rounded() / 1e5])
        if trail.count > 150 { trail.removeFirst(trail.count - 150) }
        let payload: [String: Any] = [
            "trail": trail,
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy,
            "speed": connected ? abs(ble.data.speed) : max(0, loc.speed * 3.6),
            "battery": connected ? ble.data.batteryPercent : -1,
            "trip": TripRecorder.shared.currentDistance,
            "wheel": ble.connectedName ?? "",
            "name": displayName,
            "limited": ble.isLimited,
            "ts": Date().timeIntervalSince1970
        ]
        send(payload)
    }

    /// Envoie le message chiffré sur deux canaux indépendants (MQTT et ntfy) :
    /// il suffit que l'un des deux passe.
    private func send(_ payload: [String: Any], completion: ((String?) -> Void)? = nil) {
        guard !code.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let sealed = LiveCrypto.seal(json, code: code) else { return }
        let body = Data(sealed.utf8)
        let group = DispatchGroup()
        var mqttProblem: String?
        var ntfyProblem: String?

        group.enter()
        MQTTPublisher.shared.publish(topic: "lynxdash/live/\(channel)", payload: body, retain: true) { problem in
            mqttProblem = problem
            group.leave()
        }

        group.enter()
        var req = URLRequest(url: URL(string: "https://ntfy.sh/lynxdash-live-\(channel)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, err in
            if let err = err as NSError? {
                ntfyProblem = LiveShare.describe(err)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                ntfyProblem = "ntfy.sh a refusé (code \(http.statusCode))"
            }
            DispatchQueue.main.async { group.leave() }
        }.resume()

        group.notify(queue: .main) { [weak self] in
            self?.channels = "MQTT \(mqttProblem == nil ? "✓" : "✗") · ntfy \(ntfyProblem == nil ? "✓" : "✗")"
            let problem: String? = (mqttProblem != nil && ntfyProblem != nil)
                ? "Aucun canal ne passe.\nMQTT : \(mqttProblem!)\nntfy : \(ntfyProblem!)" : nil
            if let problem {
                self?.error = problem
            } else {
                self?.error = nil
                self?.lastSent = Date()
            }
            completion?(problem)
        }
    }

    private static func describe(_ err: NSError) -> String {
        switch err.code {
        case NSURLErrorNotConnectedToInternet:
            return "Pas d'accès Internet pour LynxDash : vérifie Réglages iPhone > LynxDash > Données cellulaires"
        case NSURLErrorTimedOut:
            return "Le serveur ntfy.sh ne répond pas (délai dépassé)"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Impossible de trouver ntfy.sh (DNS / bloqueur de pubs ?)"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
            let under = err.userInfo[NSUnderlyingErrorKey] as? NSError
            let tls = (err.userInfo["_kCFStreamErrorCodeKey"] as? Int).map { " TLS \($0)" } ?? ""
            return "Connexion sécurisée à ntfy.sh refusée (code \(err.code)\(tls), \(under?.code ?? 0)). Le réseau mobile filtre peut-être ce site."
        default:
            return "Erreur réseau \(err.code) : \(err.localizedDescription)"
        }
    }

    /// Envoie un message de test et renvoie le résultat lisible.
    func test(completion: @escaping (String) -> Void) {
        if code.isEmpty { regenerateCode() }
        send(["test": true, "ts": Date().timeIntervalSince1970]) { problem in
            completion(problem ?? "✅ Partage opérationnel (\(self.channels ?? ""))")
        }
    }
}

struct LiveShareView: View {
    @ObservedObject private var share = LiveShare.shared
    @State private var testResult: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: share.active ? "dot.radiowaves.up.forward" : "location.slash")
                        .font(.title2)
                        .foregroundStyle(share.active ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(share.active ? "Partage en cours" : "Partage arrêté").font(.headline)
                        if let d = share.lastSent, share.active {
                            Text("Dernière position envoyée à \(d.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let c = share.channels { Text(c).font(.caption2).foregroundStyle(.secondary) }
                        if let e = share.error { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
                Button(share.active ? "Arrêter le partage" : "Démarrer le partage") {
                    share.active ? share.stop() : share.start()
                }
                .tint(share.active ? .red : .green)
                Button("Tester la connexion") {
                    testResult = "Test en cours…"
                    share.test { testResult = $0 }
                }
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section {
                TextField("Ton prénom (affiché sur la carte)", text: share.$displayName)
                if let link = share.link {
                    ShareLink(item: link, message: Text(share.shareMessage)) {
                        Label("Envoyer le lien (Messages, WhatsApp…)", systemImage: "square.and.arrow.up")
                    }
                    Text(link.absoluteString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Button("Créer mon lien de suivi") { share.regenerateCode() }
                }
                Toggle("Partager automatiquement pendant les trajets", isOn: share.$autoWithTrips)
            } header: {
                Text("Lien de suivi")
            } footer: {
                Text("Le lien reste le même d'un trajet à l'autre : envoie-le une fois à ta femme et garde-le en favori. Elle voit ta position, ton tracé, ta vitesse et ta batterie, mises à jour toutes les 5 secondes, uniquement quand le partage est actif.")
            }

            Section {
                Button("Changer de lien", role: .destructive) { share.regenerateCode() }
            } footer: {
                Text("Crée un nouveau lien secret : l'ancien ne montre plus rien. Les positions sont chiffrées de bout en bout : les serveurs gratuits HiveMQ et ntfy.sh qui les transportent ne peuvent pas les lire, seul le lien permet de les déchiffrer.")
            }
        }
        .themedList()
        .navigationTitle("Partage en direct")
    }
}
