import CryptoKit
import SwiftUI

// MARK: - Classement et défis entre amis
//
// Chaque membre publie ses statistiques du mois en message MQTT « retenu » (le serveur garde
// le dernier message de chacun). En s'abonnant au groupe, on reçoit immédiatement les stats
// de tous les membres. Les données sont chiffrées avec le code du club : le serveur ne voit rien.

struct ClubStats: Codable, Identifiable, Hashable {
    var id: String { member }
    var member: String          // identifiant aléatoire stable de l'appareil
    var name: String
    var wheel: String
    var month: String           // « 2026-11 »
    var km: Double
    var longestKm: Double
    var daysRidden: Int
    var rides: Int
    var updated: Double
}

struct ClubGoal: Codable, Hashable {
    var month: String
    var km: Double
    var title: String
}

/// Client MQTT minimal pour LIRE des messages retenus (abonnement), sur WebSocket sécurisé.
final class MQTTFetcher: NSObject, URLSessionWebSocketDelegate {
    private let url = URL(string: "wss://broker.hivemq.com:8884/mqtt")!
    private var task: URLSessionWebSocketTask?
    private var buffer = Data()
    private var results: [String: Data] = [:]
    private var completion: (([String: Data], String?) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// Se connecte, s'abonne à `filter`, collecte pendant `seconds` puis se déconnecte.
    func fetch(filter: String, seconds: TimeInterval = 4, completion: @escaping ([String: Data], String?) -> Void) {
        self.completion = completion
        results = [:]
        buffer = Data()
        let t = session.webSocketTask(with: url, protocols: ["mqtt"])
        task = t
        t.resume()
        t.send(.data(MQTTPublisher.connectPacket(clientID: "lynxdash-r-\(UUID().uuidString.prefix(8))"))) { _ in }
        receive(on: t, filter: filter)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: String?) {
        guard let completion else { return }
        self.completion = nil
        if let task { task.send(.data(Data([0xE0, 0x00]))) { _ in }; task.cancel(with: .normalClosure, reason: nil) }
        task = nil
        completion(results, results.isEmpty ? error : nil)
    }

    private func receive(on t: URLSessionWebSocketTask, filter: String) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message { self.buffer.append(d) }
                if case .string(let s) = message { self.buffer.append(Data(s.utf8)) }
                self.parse(on: t, filter: filter)
                self.receive(on: t, filter: filter)
            case .failure(let error):
                self.finish("Réseau : \(error.localizedDescription)")
            }
        }
    }

    /// Découpe le flux en paquets MQTT (un message WebSocket peut en contenir plusieurs).
    private func parse(on t: URLSessionWebSocketTask, filter: String) {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer)
            var multiplier = 1, length = 0, i = 1
            var complete = false
            while i < bytes.count && i <= 4 {
                let b = Int(bytes[i])
                length += (b & 0x7F) * multiplier
                multiplier *= 128
                i += 1
                if b & 0x80 == 0 { complete = true; break }
            }
            guard complete, bytes.count >= i + length else { return }
            let type = bytes[0] >> 4
            let body = Array(bytes[i..<(i + length)])
            buffer = Data(bytes[(i + length)...])

            switch type {
            case 2:   // CONNACK
                if body.count >= 2 && body[1] == 0 {
                    t.send(.data(Self.subscribePacket(filter: filter))) { _ in }
                } else {
                    finish("Connexion refusée par le serveur")
                }
            case 3:   // PUBLISH
                let qos = (bytes[0] >> 1) & 0x03
                guard body.count >= 2 else { continue }
                let tlen = Int(body[0]) << 8 | Int(body[1])
                guard body.count >= 2 + tlen else { continue }
                let topic = String(decoding: body[2..<(2 + tlen)], as: UTF8.self)
                var start = 2 + tlen
                if qos > 0 { start += 2 }
                guard start <= body.count else { continue }
                let payload = Data(body[start...])
                if payload.isEmpty { results.removeValue(forKey: topic) } else { results[topic] = payload }
            default:
                break   // SUBACK, PINGRESP…
            }
        }
    }

    static func subscribePacket(filter: String) -> Data {
        let topic = Data(filter.utf8)
        var body = Data([0x00, 0x01])                                     // identifiant du paquet
        body.append(contentsOf: [UInt8(topic.count >> 8), UInt8(topic.count & 0xFF)])
        body.append(topic)
        body.append(0x00)                                                 // QoS 0
        var len = Data()
        var x = body.count
        repeat {
            var byte = UInt8(x % 128); x /= 128
            if x > 0 { byte |= 0x80 }
            len.append(byte)
        } while x > 0
        return Data([0x82]) + len + body
    }
}

final class Leaderboard: ObservableObject {
    static let shared = Leaderboard()

    @AppStorage("clubCode") var code = ""
    @AppStorage("clubName") var myName = ""
    @Published private(set) var members: [ClubStats] = []
    @Published private(set) var goal: ClubGoal?
    @Published private(set) var status: String?
    @Published private(set) var loading = false

    private var fetcher: MQTTFetcher?

    /// Identifiant anonyme de l'appareil dans le club.
    private var memberID: String {
        if let id = UserDefaults.standard.string(forKey: "clubMemberID") { return id }
        let id = UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(String(id), forKey: "clubMemberID")
        return String(id)
    }

    private var cleanCode: String { code.trimmingCharacters(in: .whitespaces).lowercased() }
    private var base: String { "lynxdash/club/\(LiveCrypto.channel(for: "club:" + cleanCode))" }

    static var currentMonth: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: Mes statistiques

    func myStats() -> ClubStats {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let trips = TripStore.shared.trips.filter { $0.start >= monthStart }
        let days = Set(trips.map { cal.startOfDay(for: $0.start) }).count
        let wheel = trips.first?.wheelName ?? BLEManager.shared.connectedName ?? ""
        return ClubStats(member: memberID, name: myName, wheel: wheel, month: Self.currentMonth,
                         km: trips.reduce(0) { $0 + $1.distance },
                         longestKm: trips.map(\.distance).max() ?? 0,
                         daysRidden: days, rides: trips.count, updated: Date().timeIntervalSince1970)
    }

    /// Publie mes stats (message retenu). Appelé à la connexion de la roue et à l'ouverture du classement.
    func publishMyStats(completion: ((String?) -> Void)? = nil) {
        guard !cleanCode.isEmpty, !myName.isEmpty,
              let json = try? JSONEncoder().encode(myStats()),
              let sealed = LiveCrypto.seal(json, code: "club:" + cleanCode) else { completion?(nil); return }
        MQTTPublisher.shared.publish(topic: "\(base)/stats/\(memberID)", payload: Data(sealed.utf8), retain: true) { err in
            completion?(err)
        }
    }

    func setGoal(km: Double, title: String) {
        guard !cleanCode.isEmpty else { return }
        let g = ClubGoal(month: Self.currentMonth, km: km, title: title)
        guard let json = try? JSONEncoder().encode(g),
              let sealed = LiveCrypto.seal(json, code: "club:" + cleanCode) else { return }
        goal = g
        MQTTPublisher.shared.publish(topic: "\(base)/goal", payload: Data(sealed.utf8), retain: true) { _ in }
    }

    // MARK: Lecture du club

    func refresh() {
        guard !cleanCode.isEmpty, !myName.isEmpty else {
            status = "Choisis un code de club et ton prénom"
            return
        }
        loading = true
        status = "Chargement du classement…"
        publishMyStats { [weak self] _ in self?.fetchAll() }
    }

    private func fetchAll() {
        let f = MQTTFetcher()
        fetcher = f
        let key = "club:" + cleanCode
        let mine = myStats()
        f.fetch(filter: "\(base)/#") { [weak self] results, error in
            guard let self else { return }
            self.loading = false
            self.fetcher = nil
            var list: [String: ClubStats] = [mine.member: mine]
            var goal: ClubGoal?
            for (topic, payload) in results {
                guard let text = String(data: payload, encoding: .utf8),
                      let clear = Self.open(text, code: key) else { continue }
                if topic.hasSuffix("/goal") {
                    goal = try? JSONDecoder().decode(ClubGoal.self, from: clear)
                } else if let s = try? JSONDecoder().decode(ClubStats.self, from: clear), s.member != mine.member {
                    list[s.member] = s
                }
            }
            // Seules les stats du mois en cours comptent
            self.members = list.values.filter { $0.month == Self.currentMonth }.sorted { $0.km > $1.km }
            if let g = goal, g.month == Self.currentMonth { self.goal = g } else { self.goal = nil }
            self.status = error ?? "\(self.members.count) membre(s) ce mois-ci"
        }
    }

    private static func open(_ base64: String, code: String) -> Data? {
        guard let data = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: LiveCrypto.key(for: code))
    }

    var totalKm: Double { members.reduce(0) { $0 + $1.km } }
}

// MARK: - Écran

struct LeaderboardView: View {
    @ObservedObject private var board = Leaderboard.shared
    @State private var goalKm = 500.0
    @State private var goalTitle = "Défi du mois"
    @State private var editingGoal = false

    private var monthName: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        List {
            Section {
                TextField("Ton prénom", text: board.$myName)
                TextField("Code du club (le même pour tous)", text: board.$code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    board.refresh()
                } label: {
                    HStack {
                        Label("Actualiser le classement", systemImage: "arrow.clockwise")
                        if board.loading { Spacer(); ProgressView() }
                    }
                }
                if let s = board.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Tes amis entrent le même code (ex. gyro-bxl-7421). Seuls ton prénom et tes kilomètres du mois sont partagés, chiffrés avec le code du club.")
            }

            if let goal = board.goal {
                Section("Défi collectif · \(monthName)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(goal.title).font(.headline)
                        ProgressView(value: min(board.totalKm, goal.km), total: max(goal.km, 1))
                            .tint(Theme.accent)
                        Text(String(format: "%.0f / %.0f km ensemble", board.totalKm, goal.km))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if board.totalKm >= goal.km {
                            Label("Défi réussi ! 🎉", systemImage: "trophy.fill").foregroundStyle(Theme.gold)
                        }
                    }
                    Button("Modifier le défi") { editingGoal = true }.font(.caption)
                }
            } else if !board.members.isEmpty {
                Section {
                    Button("Lancer un défi collectif pour ce mois") { editingGoal = true }
                }
            }

            if !board.members.isEmpty {
                Section("Classement · \(monthName)") {
                    ForEach(Array(board.members.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 12) {
                            Text(i < 3 ? ["🥇", "🥈", "🥉"][i] : "\(i + 1)")
                                .font(.title3).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.headline)
                                Text("\(m.rides) trajet(s) · \(m.daysRidden) jour(s) · plus longue \(Int(m.longestKm)) km")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.0f km", m.km))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(i == 0 ? Theme.gold : .white)
                        }
                    }
                }
                Section("Records du mois") {
                    if let longest = board.members.max(by: { $0.longestKm < $1.longestKm }) {
                        LabeledContent("Plus longue sortie", value: "\(longest.name) · \(Int(longest.longestKm)) km")
                    }
                    if let regular = board.members.max(by: { $0.daysRidden < $1.daysRidden }) {
                        LabeledContent("Le plus régulier", value: "\(regular.name) · \(regular.daysRidden) jours")
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Classement")
        .onAppear { if !board.code.isEmpty && !board.myName.isEmpty { board.refresh() } }
        .alert("Défi collectif", isPresented: $editingGoal) {
            TextField("Nom du défi", text: $goalTitle)
            TextField("Objectif (km)", value: $goalKm, format: .number).keyboardType(.numberPad)
            Button("Annuler", role: .cancel) {}
            Button("Lancer") { board.setGoal(km: goalKm, title: goalTitle) }
        } message: {
            Text("Le total des kilomètres de tous les membres ce mois-ci.")
        }
    }
}
