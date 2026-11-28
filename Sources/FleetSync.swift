import CryptoKit
import Security
import SwiftUI

// MARK: - Suivi à distance des roues clients (avec leur accord)
//
// L'iPhone de l'atelier crée une paire de clés. Le client s'associe en ouvrant un lien
// (ou QR code) lynxdash://pair?k=<clé publique>. Son appli publie ensuite l'état de sa roue
// en message MQTT « retenu », chiffré pour la clé publique de l'atelier : seul l'iPhone de
// l'atelier (clé privée dans le trousseau) peut le lire. Aucun serveur à payer.

struct FleetReport: Codable, Identifiable, Hashable {
    var id: String { client }
    var client: String            // identifiant anonyme de l'appareil
    var name: String
    var phone: String
    var wheel: String
    var brand: String
    var model: String
    var km: Double
    var battery: Double
    var voltage: Double
    var resistance: Double?
    var cellDiffMV: Double?
    var tamperCount: Int
    var lastTamper: Date?
    var errors: [String]
    var appVersion: String
    var date: Date

    var alerts: [String] {
        var a: [String] = []
        if tamperCount > 0 { a.append("\(tamperCount) débridage(s) détecté(s)") }
        if let d = cellDiffMV, d >= 80 { a.append(String(format: "Cellules déséquilibrées (%.0f mV)", d)) }
        if !errors.isEmpty { a.append("\(errors.count) erreur(s) roue") }
        if Date().timeIntervalSince(date) > 30 * 86400 { a.append("Pas de nouvelles depuis 30 jours") }
        return a
    }
}

enum FleetCrypto {
    private static let account = "be.gyrocare.lynxdash.fleetkey"

    /// Clé privée de l'atelier (créée au premier besoin, gardée dans le trousseau).
    static func atelierKey(create: Bool) -> Curve25519.KeyAgreement.PrivateKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d)
        }
        guard create else { return nil }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                  kSecValueData as String: key.rawRepresentation,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromB64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func channel(for pub: Data) -> String {
        SHA256.hash(data: pub).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func symmetric(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("lynxdash-fleet".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    /// Chiffre pour la clé publique de l'atelier : clé éphémère (32 o) + AES-GCM.
    static func seal(_ data: Data, for pub: Data) -> String? {
        guard let atelier = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub) else { return nil }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? eph.sharedSecretFromKeyAgreement(with: atelier),
              let box = try? AES.GCM.seal(data, using: symmetric(secret)), let combined = box.combined else { return nil }
        return (eph.publicKey.rawRepresentation + combined).base64EncodedString()
    }

    static func open(_ b64: String, with key: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard let raw = Data(base64Encoded: b64), raw.count > 32,
              let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw.prefix(32)),
              let secret = try? key.sharedSecretFromKeyAgreement(with: eph),
              let box = try? AES.GCM.SealedBox(combined: raw.dropFirst(32)) else { return nil }
        return try? AES.GCM.open(box, using: symmetric(secret))
    }
}

final class FleetSync: ObservableObject {
    static let shared = FleetSync()

    // Côté client
    @AppStorage("fleetAtelierKey") private var atelierKeyB64 = ""
    @AppStorage("fleetAtelierName") var atelierName = ""
    @AppStorage("fleetConsent") var consent = false
    @Published var pendingPairing: (key: String, name: String)?

    // Côté atelier
    @Published private(set) var reports: [FleetReport] = []
    @Published private(set) var status: String?
    private var fetcher: MQTTFetcher?
    private var lastPublish = Date.distantPast

    var paired: Bool { !atelierKeyB64.isEmpty }

    private var clientID: String {
        if let id = UserDefaults.standard.string(forKey: "fleetClientID") { return id }
        let id = String(UUID().uuidString.prefix(12)).lowercased()
        UserDefaults.standard.set(id, forKey: "fleetClientID")
        return id
    }

    private func base(for pub: Data) -> String { "lynxdash/fleet/\(FleetCrypto.channel(for: pub))" }

    // MARK: Association

    /// Lien lynxdash://pair?k=…&n=… ouvert sur l'iPhone du client.
    func handlePairLink(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let k = items.first(where: { $0.name == "k" })?.value, FleetCrypto.fromB64url(k)?.count == 32 else { return false }
        pendingPairing = (k, items.first(where: { $0.name == "n" })?.value ?? Business.name)
        return true
    }

    func acceptPairing() {
        guard let p = pendingPairing else { return }
        atelierKeyB64 = p.key
        atelierName = p.name
        consent = true
        pendingPairing = nil
        lastPublish = .distantPast
        publishIfNeeded(force: true)
    }

    func unpair() {
        if let pub = FleetCrypto.fromB64url(atelierKeyB64) {
            MQTTPublisher.shared.publish(topic: "\(base(for: pub))/\(clientID)", payload: Data(), retain: true) { _ in }
        }
        consent = false
        atelierKeyB64 = ""
        atelierName = ""
    }

    /// Lien d'association à faire ouvrir par le client (QR code ou message).
    static func pairingLink() -> URL? {
        guard let key = FleetCrypto.atelierKey(create: true) else { return nil }
        var c = URLComponents()
        c.scheme = "lynxdash"; c.host = "pair"
        c.queryItems = [URLQueryItem(name: "k", value: FleetCrypto.b64url(key.publicKey.rawRepresentation)),
                        URLQueryItem(name: "n", value: Business.name)]
        return c.url
    }

    // MARK: Publication (client)

    /// Toutes les 15 min roue connectée, et à la déconnexion.
    func publishIfNeeded(force: Bool = false) {
        guard consent, let pub = FleetCrypto.fromB64url(atelierKeyB64) else { return }
        guard force || Date().timeIntervalSince(lastPublish) > 900 else { return }
        let ble = BLEManager.shared
        guard ble.state == .connected || force, ble.data.voltage > 0 else { return }
        lastPublish = Date()
        let d = ble.data
        var cellDiff: Double?
        if let packs = d.bmsCells {
            cellDiff = packs.compactMap { CellStats($0, count: ble.cellCount)?.diff }.max().map { $0 * 1000 }
        }
        let tamper = TamperLog.all
        let defaults = UserDefaults.standard
        let report = FleetReport(
            client: clientID, name: defaults.string(forKey: "rdvName") ?? "", phone: defaults.string(forKey: "rdvPhone") ?? "",
            wheel: ble.connectedName ?? "Roue", brand: ble.activeBrand.shortLabel, model: d.model ?? "",
            km: d.totalDistance, battery: d.batteryPercent, voltage: d.voltage,
            resistance: BatteryHealth.shared.sessionResistance ?? BatteryHealth.shared.history(for: ble.currentWheelID).last?.milliohm,
            cellDiffMV: cellDiff, tamperCount: tamper.count, lastTamper: tamper.first?.date,
            errors: ble.eventLog.filter(\.isError).prefix(5).map(\.message),
            appVersion: String(BuildInfo.commit.prefix(7)), date: Date())
        guard let json = try? JSONEncoder().encode(report), let sealed = FleetCrypto.seal(json, for: pub) else { return }
        MQTTPublisher.shared.publish(topic: "\(base(for: pub))/\(clientID)", payload: Data(sealed.utf8), retain: true) { _ in }
    }

    // MARK: Lecture (atelier)

    func refresh() {
        guard let key = FleetCrypto.atelierKey(create: true) else { status = "Clé atelier indisponible"; return }
        status = "Chargement…"
        let f = MQTTFetcher()
        fetcher = f
        f.fetch(filter: "\(base(for: key.publicKey.rawRepresentation))/+", seconds: 5) { [weak self] results, error in
            guard let self else { return }
            self.fetcher = nil
            self.reports = results.values.compactMap { payload in
                guard let text = String(data: payload, encoding: .utf8),
                      let clear = FleetCrypto.open(text, with: key) else { return nil }
                return try? JSONDecoder().decode(FleetReport.self, from: clear)
            }
            .sorted { ($0.alerts.isEmpty ? 1 : 0, $1.date) < ($1.alerts.isEmpty ? 1 : 0, $0.date) }
            self.status = error ?? "\(self.reports.count) roue(s) suivie(s)"
        }
    }
}

// MARK: - Écrans

/// Atelier : lien d'association et état des roues clients.
struct FleetView: View {
    @ObservedObject private var fleet = FleetSync.shared
    @State private var link = FleetSync.pairingLink()

    var body: some View {
        List {
            Section {
                if let link, let qr = PDFKitLite.qr(link.absoluteString, size: 220) {
                    HStack { Spacer(); Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)); Spacer() }
                    ShareLink(item: link) { Label("Envoyer le lien d'association", systemImage: "link") }
                }
            } header: {
                Text("Associer un client")
            } footer: {
                Text("Le client scanne ce QR code avec l'appareil photo de son iPhone (ou ouvre le lien), puis accepte. Son appli envoie ensuite l'état de sa roue, chiffré : seul cet iPhone peut le lire.")
            }
            Section {
                Button { fleet.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                if let s = fleet.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(fleet.reports) { r in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.name.isEmpty ? "Client \(r.client.prefix(4))" : r.name).font(.headline)
                        Text("\(r.brand) \(r.model.isEmpty ? r.wheel : r.model) · \(Int(r.km)) km").font(.caption)
                        Text("Mis à jour \(r.date.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "Batterie %.0f %% · %.1f V", r.battery, r.voltage)
                             + (r.resistance.map { String(format: " · %.0f mΩ", $0) } ?? "")
                             + (r.cellDiffMV.map { String(format: " · écart %.0f mV", $0) } ?? ""))
                            .font(.caption2)
                        ForEach(r.alerts, id: \.self) { a in
                            Label(a, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.ember)
                        }
                        if !r.errors.isEmpty { Text(r.errors.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary) }
                        if !r.phone.isEmpty {
                            HStack(spacing: 16) {
                                if let tel = URL(string: "tel:\(r.phone.filter { $0.isNumber || $0 == "+" })") {
                                    Link(destination: tel) { Label("Appeler", systemImage: "phone.fill") }
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Roues des clients")
        .onAppear { fleet.refresh() }
    }
}

/// Client : demande d'accord après ouverture du lien d'association.
struct FleetConsentView: View {
    @ObservedObject private var fleet = FleetSync.shared
    @AppStorage("rdvName") private var name = ""
    @AppStorage("rdvPhone") private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        GyrocareLogo(size: 52)
                        Text("Partager l'état de ta roue avec \(fleet.pendingPairing?.name ?? Business.name) ?").font(.headline)
                    }
                    Text("L'atelier verra : modèle et kilométrage de la roue, batterie, santé des cellules, erreurs enregistrées et débridages détectés. Jamais ta position ni tes trajets. Les données sont chiffrées : seul l'atelier peut les lire. Tu peux arrêter à tout moment dans Réglages.")
                        .font(.callout)
                }
                Section("Pour que l'atelier te reconnaisse") {
                    TextField("Prénom et nom", text: $name)
                    TextField("Téléphone", text: $phone).keyboardType(.phonePad)
                }
                Section {
                    Button("Accepter et partager") { fleet.acceptPairing() }.bold()
                    Button("Refuser", role: .cancel) { fleet.pendingPairing = nil }
                }
            }
            .themedList()
            .navigationTitle("Suivi par l'atelier")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct FleetClientSection: View {
    @ObservedObject private var fleet = FleetSync.shared

    var body: some View {
        if fleet.paired {
            Section {
                Toggle("Partager l'état de ma roue avec \(fleet.atelierName)", isOn: fleet.$consent)
                Button("Ne plus être suivi par l'atelier", role: .destructive) { fleet.unpair() }
            } header: {
                Text("Suivi par l'atelier")
            } footer: {
                Text("Modèle, kilométrage, batterie, cellules, erreurs et débridages détectés, chiffrés. Jamais ta position.")
            }
        }
    }
}
