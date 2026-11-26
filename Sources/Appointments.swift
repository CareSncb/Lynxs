import SwiftUI
import UserNotifications

// MARK: - Demandes de rendez-vous (client → atelier)

/// Demande envoyée par un client depuis son appli. Elle voyage dans un lien lynxdash://rdv?d=…
/// que l'atelier ouvre sur son iPhone pour l'ajouter directement dans le menu atelier.
struct AppointmentRequest: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var client: String
    var phone: String
    var wheel: String
    var brand: String
    var model: String
    var totalKm: Double
    var battery: Double
    var voltage: Double
    var firmware: String
    var problem: String
    var preferred: Date
    var errors: [String] = []
    var resistance: Double?
    var done = false

    var link: URL? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "lynxdash://rdv?d=\(b64)")
    }

    static func from(_ url: URL) -> AppointmentRequest? {
        guard let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
        var b64 = item.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              var r = try? JSONDecoder().decode(AppointmentRequest.self, from: data) else { return nil }
        r.done = false
        return r
    }

    /// Texte lisible envoyé avec le lien.
    var message: String {
        var lines = [
            "Demande de rendez-vous \(Business.name)",
            "Client : \(client)\(phone.isEmpty ? "" : " — \(phone)")",
            "Roue : \(brand) \(model.isEmpty ? wheel : model) — \(Int(totalKm)) km",
            String(format: "Batterie : %.0f %% (%.1f V) — firmware %@", battery, voltage, firmware),
            "Souhaité : \(preferred.formatted(date: .abbreviated, time: .shortened))",
            "Problème : \(problem.isEmpty ? "—" : problem)"
        ]
        if let r = resistance { lines.append(String(format: "Résistance batterie estimée : %.0f mΩ", r)) }
        if !errors.isEmpty { lines.append("Erreurs roue : " + errors.joined(separator: " ; ")) }
        if let link { lines.append("\nAtelier, ouvre ce lien sur l'iPhone avec LynxDash pour ajouter la demande :\n\(link.absoluteString)") }
        return lines.joined(separator: "\n")
    }
}

final class AppointmentStore: ObservableObject {
    static let shared = AppointmentStore()
    @Published private(set) var requests: [AppointmentRequest] = []

    private let file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rendez-vous.json")

    init() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([AppointmentRequest].self, from: data) {
            requests = list
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(requests) { try? data.write(to: file, options: .atomic) }
    }

    /// Appelé quand l'atelier ouvre un lien lynxdash://rdv.
    @discardableResult
    func importLink(_ url: URL) -> Bool {
        guard let r = AppointmentRequest.from(url) else { return false }
        if !requests.contains(where: { $0.id == r.id }) {
            requests.insert(r, at: 0)
            persist()
        }
        return true
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[i].done = done
        persist()
    }

    func delete(_ id: UUID) {
        requests.removeAll { $0.id == id }
        persist()
    }

    var openCount: Int { requests.filter { !$0.done }.count }
}

// MARK: - Côté client : formulaire de demande

struct AppointmentRequestView: View {
    @EnvironmentObject var ble: BLEManager
    @AppStorage("rdvName") private var name = ""
    @AppStorage("rdvPhone") private var phone = ""
    @State private var problem = ""
    @State private var preferred = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
    @State private var request: AppointmentRequest?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    GyrocareLogo(size: 52)
                    VStack(alignment: .leading) {
                        Text(Business.name).font(.headline)
                        Text("Réparation et entretien de gyroroues").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Toi") {
                TextField("Prénom et nom", text: $name)
                TextField("Téléphone", text: $phone).keyboardType(.phonePad)
            }
            Section("Ta roue") {
                if ble.state == .connected {
                    LabeledContent("Roue", value: "\(ble.activeBrand.shortLabel) \(ble.data.model ?? ble.connectedName ?? "")")
                    LabeledContent("Compteur", value: String(format: "%.0f km", ble.data.totalDistance))
                    Label("Les infos de la roue (batterie, firmware, erreurs) seront jointes", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Connecte ta roue pour joindre son diagnostic automatiquement", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Le problème") {
                TextEditor(text: $problem).frame(minHeight: 90)
                DatePicker("Date souhaitée", selection: $preferred, in: Date()...)
            }
            Section {
                if let request {
                    if !Business.phone.isEmpty, let wa = whatsAppURL(request) {
                        Link(destination: wa) { Label("Envoyer par WhatsApp", systemImage: "message.fill") }
                    }
                    if !Business.email.isEmpty, let mail = mailURL(request) {
                        Link(destination: mail) { Label("Envoyer par e-mail", systemImage: "envelope.fill") }
                    }
                    ShareLink(item: request.message) { Label("Envoyer autrement…", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Préparer la demande") { request = build() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Le message contient un lien que l'atelier ouvre pour retrouver ta demande et le diagnostic de ta roue.")
            }
        }
        .themedList()
        .navigationTitle("Rendez-vous")
        .onChange(of: problem) { _, _ in request = nil }
        .onChange(of: preferred) { _, _ in request = nil }
    }

    private func build() -> AppointmentRequest {
        let d = ble.data
        let connected = ble.state == .connected
        return AppointmentRequest(
            client: name, phone: phone,
            wheel: ble.connectedName ?? "", brand: connected ? ble.activeBrand.shortLabel : "",
            model: d.model ?? "", totalKm: connected ? d.totalDistance : 0,
            battery: connected ? d.batteryPercent : 0, voltage: connected ? d.voltage : 0,
            firmware: connected ? d.firmwareString : "—", problem: problem, preferred: preferred,
            errors: connected ? ble.eventLog.filter(\.isError).prefix(5).map(\.message) : [],
            resistance: BatteryHealth.shared.sessionResistance
                ?? BatteryHealth.shared.history(for: ble.currentWheelID).last?.milliohm)
    }

    private func whatsAppURL(_ r: AppointmentRequest) -> URL? {
        let digits = Business.phone.filter(\.isNumber)
        let intl = digits.hasPrefix("0") ? "32" + String(digits.dropFirst()) : digits   // Belgique par défaut
        var c = URLComponents(string: "https://wa.me/\(intl)")
        c?.queryItems = [URLQueryItem(name: "text", value: r.message)]
        return c?.url
    }

    private func mailURL(_ r: AppointmentRequest) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = Business.email
        c.queryItems = [URLQueryItem(name: "subject", value: "Rendez-vous gyroroue — \(r.client)"),
                        URLQueryItem(name: "body", value: r.message)]
        return c.url
    }
}

// MARK: - Côté atelier : liste des demandes

struct AppointmentInboxView: View {
    @ObservedObject private var store = AppointmentStore.shared

    var body: some View {
        List {
            if store.requests.isEmpty {
                Text("Aucune demande. Les clients envoient leur demande depuis LynxDash (Réglages de la roue › Rendez-vous) ; ouvre le lien reçu pour l'ajouter ici.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.requests) { r in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(r.client).font(.headline)
                        Spacer()
                        if r.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    Text("\(r.brand) \(r.model.isEmpty ? r.wheel : r.model) · \(Int(r.totalKm)) km")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Souhaité : \(r.preferred.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Theme.accent)
                    if !r.problem.isEmpty { Text(r.problem).font(.subheadline) }
                    if let res = r.resistance {
                        Text(String(format: "Batterie %.0f %% · %.1f V · %.0f mΩ", r.battery, r.voltage, res)).font(.caption2)
                    }
                    if !r.errors.isEmpty {
                        Text(r.errors.joined(separator: "\n")).font(.caption2).foregroundStyle(Theme.ember)
                    }
                    HStack(spacing: 16) {
                        if let tel = URL(string: "tel:\(r.phone.filter { $0.isNumber || $0 == "+" })"), !r.phone.isEmpty {
                            Link(destination: tel) { Label("Appeler", systemImage: "phone.fill") }
                        }
                        Button(r.done ? "Rouvrir" : "Traité") { store.setDone(r.id, !r.done) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .opacity(r.done ? 0.6 : 1)
            }
            .onDelete { idx in for i in idx { store.delete(store.requests[i].id) } }
        }
        .themedList()
        .navigationTitle("Demandes de RDV")
    }
}

// MARK: - Relances d'entretien des clients

enum ServiceReminders {
    /// Message de relance prêt à envoyer au client.
    static func message(for r: WheelRecord) -> String {
        let who = r.client.isEmpty ? "" : " \(r.client.split(separator: " ").first.map(String.init) ?? r.client)"
        return "Bonjour\(who), c'est \(Business.name). Ta \(r.brand) \(r.model) arrive à l'heure de son entretien (dernier passage le \(r.visits.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "—")). On fixe un rendez-vous ? \(Business.website)"
    }

    static func whatsApp(for r: WheelRecord) -> URL? {
        let digits = r.phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let intl = digits.hasPrefix("0") ? "32" + String(digits.dropFirst()) : digits
        var c = URLComponents(string: "https://wa.me/\(intl)")
        c?.queryItems = [URLQueryItem(name: "text", value: message(for: r))]
        return c?.url
    }

    static func sms(for r: WheelRecord) -> URL? {
        let num = r.phone.filter { $0.isNumber || $0 == "+" }
        guard !num.isEmpty else { return nil }
        let body = message(for: r).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "sms:\(num)&body=\(body)")
    }

    /// Notification pour l'atelier le jour où il faut relancer le client.
    static func schedule(for r: WheelRecord) {
        let center = UNUserNotificationCenter.current()
        let id = "relance-\(r.id)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let due = r.nextService, due > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Relance client"
        content.body = "\(r.client.isEmpty ? r.name : r.client) : entretien de la \(r.brand) \(r.model) à prévoir"
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: due)
        comps.hour = 10
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

struct ServiceRemindersView: View {
    @ObservedObject private var store = WorkshopStore.shared

    private var due: [WheelRecord] {
        store.records.filter { ($0.nextService ?? .distantFuture) <= Date().addingTimeInterval(14 * 86400) }
            .sorted { ($0.nextService ?? .distantFuture) < ($1.nextService ?? .distantFuture) }
    }

    var body: some View {
        List {
            if due.isEmpty {
                Text("Aucun client à relancer dans les 2 semaines. Fixe la prochaine révision dans la fiche diagnostic.")
                    .foregroundStyle(.secondary)
            }
            ForEach(due) { r in
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.client.isEmpty ? r.name : r.client).font(.headline)
                    Text("\(r.brand) \(r.model)").font(.caption).foregroundStyle(.secondary)
                    if let d = r.nextService {
                        Text(d < Date() ? "En retard depuis le \(d.formatted(date: .abbreviated, time: .omitted))"
                                        : "Révision le \(d.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(d < Date() ? Theme.ember : Theme.accent)
                    }
                    HStack(spacing: 16) {
                        if let wa = ServiceReminders.whatsApp(for: r) {
                            Link(destination: wa) { Label("WhatsApp", systemImage: "message.fill") }
                        }
                        if let sms = ServiceReminders.sms(for: r) {
                            Link(destination: sms) { Label("SMS", systemImage: "bubble.left.fill") }
                        }
                        Button("Reporter d'1 mois") {
                            var copy = r
                            copy.nextService = Calendar.current.date(byAdding: .month, value: 1, to: max(Date(), r.nextService ?? Date()))
                            store.upsert(copy)
                            ServiceReminders.schedule(for: copy)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .themedList()
        .navigationTitle("Relances clients")
    }
}
