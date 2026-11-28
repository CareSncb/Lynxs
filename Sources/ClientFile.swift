import SwiftUI

// MARK: - Fiche client complète (toutes les données atelier regroupées par client)

struct ClientEntry: Identifiable {
    var id: String               // téléphone (chiffres) ou nom en minuscules
    var name: String
    var phone: String
    var records: [WheelRecord] = []
    var invoices: [Invoice] = []
    var appointments: [AppointmentRequest] = []
    var loans: [WheelLoan] = []
    var fleet: [FleetReport] = []

    var lastActivity: Date {
        ([records.compactMap { $0.visits.last?.date }, invoices.map(\.date), appointments.map(\.created),
          loans.map(\.start), fleet.map(\.date)].flatMap { $0 }).max() ?? .distantPast
    }
    var wheels: [String] {
        Array(Set(records.map { "\($0.brand) \($0.model)".trimmingCharacters(in: .whitespaces) }
                  + invoices.map(\.wheel) + fleet.map(\.wheel)).filter { !$0.isEmpty }).sorted()
    }
}

enum ClientIndex {
    static func key(name: String, phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        if digits.count >= 6 { return String(digits.suffix(9)) }       // ignore +32 / 0 du début
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func build() -> [ClientEntry] {
        var map: [String: ClientEntry] = [:]
        func entry(_ name: String, _ phone: String) -> String? {
            let k = key(name: name, phone: phone)
            guard !k.isEmpty else { return nil }
            if map[k] == nil { map[k] = ClientEntry(id: k, name: name, phone: phone) }
            if map[k]!.name.isEmpty { map[k]!.name = name }
            if map[k]!.phone.isEmpty { map[k]!.phone = phone }
            return k
        }
        for r in WorkshopStore.shared.records { if let k = entry(r.client, r.phone) { map[k]!.records.append(r) } }
        for i in InvoiceStore.shared.invoices { if let k = entry(i.client, i.phone) { map[k]!.invoices.append(i) } }
        for a in AppointmentStore.shared.requests { if let k = entry(a.client, a.phone) { map[k]!.appointments.append(a) } }
        for l in LoanStore.shared.loans { if let k = entry(l.borrower, l.phone) { map[k]!.loans.append(l) } }
        for f in FleetSync.shared.reports { if let k = entry(f.name, f.phone) { map[k]!.fleet.append(f) } }
        return map.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}

struct ClientFileListView: View {
    @State private var query = ""
    @State private var clients = ClientIndex.build()

    private var filtered: [ClientEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return clients }
        return clients.filter {
            $0.name.lowercased().contains(q) || $0.phone.filter(\.isNumber).contains(q.filter(\.isNumber).isEmpty ? "§" : q.filter(\.isNumber))
                || $0.wheels.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if clients.isEmpty {
                Text("Aucun client pour l'instant : les fiches diagnostic, factures, rendez-vous et prêts apparaîtront ici, regroupés par client.")
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { c in
                NavigationLink { ClientDetailView(client: c) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name.isEmpty ? c.phone : c.name).font(.headline)
                        if !c.wheels.isEmpty { Text(c.wheels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        Text("\(c.records.reduce(0) { $0 + $1.visits.count }) intervention(s) · \(c.invoices.count) document(s)")
                            .font(.caption2).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Nom, téléphone ou roue")
        .themedList()
        .navigationTitle("Fiches clients")
        .onAppear { clients = ClientIndex.build() }
    }
}

struct ClientDetailView: View {
    let client: ClientEntry

    var body: some View {
        List {
            Section {
                if !client.name.isEmpty { LabeledContent("Nom", value: client.name) }
                if !client.phone.isEmpty {
                    LabeledContent("Téléphone", value: client.phone)
                    HStack(spacing: 18) {
                        if let tel = URL(string: "tel:\(client.phone.filter { $0.isNumber || $0 == "+" })") {
                            Link(destination: tel) { Label("Appeler", systemImage: "phone.fill") }
                        }
                        let digits = client.phone.filter(\.isNumber)
                        if let wa = URL(string: "https://wa.me/\(digits.hasPrefix("0") ? "32" + String(digits.dropFirst()) : digits)") {
                            Link(destination: wa) { Label("WhatsApp", systemImage: "message.fill") }
                        }
                    }
                    .font(.caption)
                }
            }
            ForEach(client.records) { r in
                Section("\(r.brand) \(r.model) — \(r.name)") {
                    if let next = r.nextService {
                        LabeledContent("Prochaine révision", value: next.formatted(date: .abbreviated, time: .omitted))
                    }
                    ForEach(r.visits.reversed()) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.bold())
                            Text(String(format: "%.0f km · %.1f V · %.0f %% · firmware %@", v.totalKm, v.voltage, v.battery, v.firmware))
                                .font(.caption).foregroundStyle(.secondary)
                            if !v.work.isEmpty { Text(v.work).font(.caption) }
                        }
                    }
                }
            }
            if !client.invoices.isEmpty {
                Section("Devis et factures") {
                    ForEach(client.invoices) { i in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(i.number).font(.subheadline.bold())
                                Text(i.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.2f €", i.subtotal + i.vat)).font(.subheadline.monospacedDigit())
                            if i.paid { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                }
            }
            if !client.appointments.isEmpty {
                Section("Rendez-vous") {
                    ForEach(client.appointments) { a in
                        VStack(alignment: .leading) {
                            Text(a.preferred.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.bold())
                            if !a.problem.isEmpty { Text(a.problem).font(.caption) }
                        }
                    }
                }
            }
            if !client.loans.isEmpty {
                Section("Prêts de roue") {
                    ForEach(client.loans) { l in
                        Text("\(l.wheelName) · \(l.start.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.0f km", l.km ?? 0))")
                            .font(.caption)
                    }
                }
            }
            ForEach(client.fleet) { f in
                Section("Suivi à distance — \(f.wheel)") {
                    Text(String(format: "%.0f km · batterie %.0f %%", f.km, f.battery) + " · " + f.date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                    ForEach(f.alerts, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.ember) }
                }
            }
        }
        .themedList()
        .navigationTitle(client.name.isEmpty ? "Client" : client.name)
    }
}
