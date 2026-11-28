import SwiftUI

// MARK: - Roue de prêt (pendant une réparation)

struct WheelLoan: Codable, Identifiable {
    var id = UUID()
    var wheelID: String
    var wheelName: String
    var borrower: String
    var phone: String
    var start: Date
    var startKm: Double
    var startBattery: Double
    var end: Date?
    var endKm: Double?
    var endBattery: Double?
    var incidents: [String] = []
    var notes: String = ""

    var km: Double? { endKm.map { max(0, $0 - startKm) } }
    var active: Bool { end == nil }
}

final class LoanStore: ObservableObject {
    static let shared = LoanStore()
    @Published private(set) var loans: [WheelLoan] = []
    private let key = "wheelLoans"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let l = try? JSONDecoder().decode([WheelLoan].self, from: data) { loans = l }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(loans) { UserDefaults.standard.set(data, forKey: key) }
    }

    func activeLoan(for wheelID: String?) -> WheelLoan? {
        loans.first { $0.active && $0.wheelID == wheelID }
    }

    func start(borrower: String, phone: String, notes: String, ble: BLEManager) {
        guard let id = ble.currentWheelID else { return }
        loans.insert(WheelLoan(wheelID: id, wheelName: ble.connectedName ?? "Roue", borrower: borrower, phone: phone,
                               start: Date(), startKm: ble.data.totalDistance, startBattery: ble.data.batteryPercent,
                               notes: notes), at: 0)
        persist()
    }

    func finish(_ loanID: UUID, ble: BLEManager) {
        guard let i = loans.firstIndex(where: { $0.id == loanID }) else { return }
        var l = loans[i]
        l.end = Date()
        l.endKm = ble.data.totalDistance
        l.endBattery = ble.data.batteryPercent
        // Erreurs enregistrées par la roue pendant le prêt (Leaperkim : journal téléchargé)
        l.incidents = ble.eventLog
            .filter { $0.isError && ($0.date.map { $0 >= l.start } ?? false) }
            .map { e in "\(e.date?.formatted(date: .abbreviated, time: .shortened) ?? "—") : \(e.message)" }
        loans[i] = l
        persist()
    }

    func delete(_ id: UUID) { loans.removeAll { $0.id == id }; persist() }
}

struct LoanView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject private var store = LoanStore.shared
    @State private var borrower = ""
    @State private var phone = ""
    @State private var notes = ""
    @State private var downloading = false

    var body: some View {
        let active = store.activeLoan(for: ble.currentWheelID)
        List {
            if ble.state != .connected {
                Section { Text("Connecte la roue de prêt pour démarrer ou clôturer un prêt.").foregroundStyle(.secondary) }
            } else if let loan = active {
                Section("Prêt en cours — \(loan.wheelName)") {
                    LabeledContent("Emprunteur", value: loan.borrower)
                    LabeledContent("Depuis", value: loan.start.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Km parcourus", value: String(format: "%.1f km", max(0, ble.data.totalDistance - loan.startKm)))
                    LabeledContent("Batterie", value: String(format: "%.0f %% (départ %.0f %%)", ble.data.batteryPercent, loan.startBattery))
                    if ble.supportsEventLog {
                        Button {
                            downloading = true
                            Task { @MainActor in await ble.downloadEventLog(); downloading = false }
                        } label: {
                            HStack { Label("Lire le journal d'erreurs de la roue", systemImage: "list.bullet.rectangle"); if downloading { Spacer(); ProgressView() } }
                        }
                        Text("\(ble.eventLog.filter { $0.isError && ($0.date.map { $0 >= loan.start } ?? false) }.count) erreur(s) pendant le prêt")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Clôturer le prêt (retour de la roue)") { store.finish(loan.id, ble: ble) }
                        .disabled(downloading)
                }
            } else {
                Section {
                    TextField("Nom de l'emprunteur", text: $borrower)
                    TextField("Téléphone", text: $phone).keyboardType(.phonePad)
                    TextField("État au départ (rayures, pneu…)", text: $notes, axis: .vertical)
                    Button("Démarrer le prêt de \(ble.connectedName ?? "cette roue")") {
                        store.start(borrower: borrower, phone: phone, notes: notes, ble: ble)
                        borrower = ""; phone = ""; notes = ""
                    }
                    .disabled(borrower.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Nouveau prêt")
                } footer: {
                    Text("Le compteur et la batterie sont relevés au départ. Au retour, reconnecte la roue : l'appli calcule les km parcourus et relève les erreurs enregistrées par la roue pendant le prêt.")
                }
            }
            if !store.loans.filter({ !$0.active }).isEmpty {
                Section("Historique") {
                    ForEach(store.loans.filter { !$0.active }) { l in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(l.wheelName) · \(l.borrower)").font(.headline)
                            Text("\(l.start.formatted(date: .abbreviated, time: .omitted)) → \(l.end?.formatted(date: .abbreviated, time: .omitted) ?? "—")")
                                .font(.caption)
                            Text(String(format: "%.1f km · batterie %.0f %% → %.0f %%", l.km ?? 0, l.startBattery, l.endBattery ?? 0))
                                .font(.caption).foregroundStyle(.secondary)
                            if !l.incidents.isEmpty {
                                Text(l.incidents.joined(separator: "\n")).font(.caption2).foregroundStyle(Theme.ember)
                            }
                            if !l.notes.isEmpty { Text("État au départ : \(l.notes)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { idx in
                        let done = store.loans.filter { !$0.active }
                        for i in idx { store.delete(done[i].id) }
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Roue de prêt")
    }
}
