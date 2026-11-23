import CryptoKit
import Foundation

/// Chiffrement de bout en bout du partage en direct.
/// La clé et le nom du canal sont dérivés du code secret contenu dans le lien (après le #),
/// qui n'est jamais envoyé aux serveurs : eux ne voient que des données chiffrées.
enum LiveCrypto {
    static func key(for code: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("lynxdash-key:\(code)".utf8)))
    }

    static func channel(for code: String) -> String {
        let digest = SHA256.hash(data: Data("lynxdash-topic:\(code)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// AES-256-GCM : base64(nonce 12 octets + texte chiffré + tag 16 octets).
    static func seal(_ data: Data, code: String) -> String? {
        guard let box = try? AES.GCM.seal(data, using: key(for: code)), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }
}

/// Client MQTT minimal (publication uniquement) sur WebSocket sécurisé.
/// Serveur public HiveMQ : aucun compte nécessaire.
final class MQTTPublisher: NSObject, URLSessionWebSocketDelegate {
    static let shared = MQTTPublisher()

    private let url = URL(string: "wss://broker.hivemq.com:8884/mqtt")!
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var pingTimer: Timer?
    private var queue: [(Data, (String?) -> Void)] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private let clientID = "lynxdash-\(UUID().uuidString.prefix(8))"

    func publish(topic: String, payload: Data, retain: Bool, completion: @escaping (String?) -> Void) {
        let packet = MQTTPublisher.publishPacket(topic: topic, payload: payload, retain: retain)
        if ready, let task {
            send(packet, on: task, completion: completion)
        } else {
            queue.append((packet, completion))
            if task == nil { connect() }
        }
    }

    func disconnect() {
        pingTimer?.invalidate()
        if let task { task.send(.data(Data([0xE0, 0x00]))) { _ in } ; task.cancel(with: .normalClosure, reason: nil) }
        task = nil
        ready = false
    }

    private func connect() {
        let t = session.webSocketTask(with: url, protocols: ["mqtt"])
        task = t
        ready = false
        t.resume()
        t.send(.data(MQTTPublisher.connectPacket(clientID: clientID))) { [weak self] error in
            if let error { self?.fail("MQTT : \(error.localizedDescription)") }
        }
        receive(on: t)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.ready, let task = self.task else { return }
            task.send(.data(Data([0xC0, 0x00]))) { _ in }   // PINGREQ
        }
        // Pas de réponse en 10 s : échec
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.task === t, !self.ready else { return }
            self.fail("Le serveur MQTT ne répond pas")
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message, d.first == 0x20 {   // CONNACK
                    if d.count >= 4 && d[3] == 0 {
                        self.ready = true
                        let pending = self.queue
                        self.queue.removeAll()
                        for (packet, completion) in pending { self.send(packet, on: t, completion: completion) }
                    } else {
                        self.fail("Connexion MQTT refusée")
                        return
                    }
                }
                self.receive(on: t)
            case .failure(let error):
                self.fail("MQTT : \(error.localizedDescription)")
            }
        }
    }

    private func send(_ packet: Data, on t: URLSessionWebSocketTask, completion: @escaping (String?) -> Void) {
        t.send(.data(packet)) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.fail("MQTT : \(error.localizedDescription)")
                    completion("MQTT : \(error.localizedDescription)")
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func fail(_ message: String) {
        task?.cancel()
        task = nil
        ready = false
        let pending = queue
        queue.removeAll()
        for (_, completion) in pending { completion(message) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === task { task = nil; ready = false }
    }

    // MARK: - Paquets MQTT 3.1.1

    private static func string(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
    }

    private static func remainingLength(_ n: Int) -> Data {
        var x = n
        var out = Data()
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    static func connectPacket(clientID: String) -> Data {
        var body = string("MQTT")
        body.append(contentsOf: [0x04, 0x02, 0x00, 0x3C])   // niveau 4, session propre, keepalive 60 s
        body.append(string(clientID))
        return Data([0x10]) + remainingLength(body.count) + body
    }

    static func publishPacket(topic: String, payload: Data, retain: Bool) -> Data {
        let body = string(topic) + payload
        return Data([retain ? 0x31 : 0x30]) + remainingLength(body.count) + body
    }
}
