import Charts
import SwiftUI

struct WorkshopView: View {
    @ObservedObject private var store = WorkshopStore.shared
    @EnvironmentObject var ble: BLEManager
    @State private var showNewVisit = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNewVisit = true
                    } label: {
                        Label("Fiche diagnostic de la roue connectée", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(ble.state != .connected)

                    NavigationLink {
                        BatteryTestView()
                    } label: {
                        Label("Test de batterie", systemImage: "bolt.batteryblock")
                    }
                } footer: {
                    if ble.state != .connected {
                        Text("Connecte la roue du client pour créer une fiche.")
                    }
                }

                Section("Roues suivies") {
                    if store.records.isEmpty {
                        Text("Aucune roue enregistrée").foregroundStyle(.secondary)
                    }
                    ForEach(store.records) { r in
                        NavigationLink {
                            WheelRecordView(recordID: r.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(r.client.isEmpty ? r.name : r.client).font(.headline)
                                Text("\(r.brand) \(r.model) · \(r.visits.count) passage(s)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(id: store.records[i].id) }
                    }
                }
            }
            .navigationTitle("Atelier")
            .sheet(isPresented: $showNewVisit) {
                NewVisitView().environmentObject(ble)
            }
        }
    }
}

struct NewVisitView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var client = ""
    @State private var phone = ""
    @State private var work = ""
    @State private var pdfURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Roue connectée") {
                    LabeledContent("Roue", value: ble.connectedName ?? "—")
                    LabeledContent("Marque", value: ble.activeBrand.shortLabel)
                    LabeledContent("Kilométrage", value: String(format: "%.1f km", ble.data.totalDistance))
                    LabeledContent("Tension", value: String(format: "%.2f V", ble.data.voltage))
                    LabeledContent("Firmware", value: ble.data.firmwareString)
                }
                Section("Client") {
                    TextField("Nom du client", text: $client)
                    TextField("Téléphone", text: $phone).keyboardType(.phonePad)
                }
                Section("Travaux réalisés") {
                    TextEditor(text: $work).frame(minHeight: 100)
                }
                if BatteryTest.shared.result != nil {
                    Section {
                        Label("Le dernier test de batterie sera ajouté à la fiche", systemImage: "checkmark.circle")
                    }
                }
                Section {
                    if let pdfURL {
                        ShareLink(item: pdfURL) {
                            Label("Partager le PDF", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Enregistrer et créer le PDF") { create() }
                    }
                }
            }
            .navigationTitle("Fiche diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .onAppear {
                if let id = ble.currentWheelID, let r = WorkshopStore.shared.record(id: id) {
                    client = r.client
                    phone = r.phone
                }
            }
        }
    }

    private func create() {
        guard let result = WorkshopStore.shared.addVisit(client: client, phone: phone, work: work) else { return }
        let (record, visit) = result
        pdfURL = DiagnosticReport.makePDF(record: record, visit: visit, data: ble.data, cells: ble.cellCount)
    }
}

struct WheelRecordView: View {
    let recordID: String
    @ObservedObject private var store = WorkshopStore.shared
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        if let r = store.record(id: recordID) {
            List {
                Section("Client") {
                    LabeledContent("Nom", value: r.client.isEmpty ? "—" : r.client)
                    LabeledContent("Téléphone", value: r.phone.isEmpty ? "—" : r.phone)
                    LabeledContent("Roue", value: "\(r.brand) \(r.model)")
                }
                Section("Interventions") {
                    ForEach(r.visits.reversed()) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(String(format: "%.0f km · %.1f V · firmware %@", v.totalKm, v.voltage, v.firmware))
                                .font(.caption).foregroundStyle(.secondary)
                            if !v.work.isEmpty { Text(v.work).font(.subheadline) }
                            if let pdf = DiagnosticReport.makePDF(record: r, visit: v, data: ble.data, cells: ble.cellCount) {
                                ShareLink(item: pdf) { Label("PDF", systemImage: "doc.richtext") }
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle(r.client.isEmpty ? r.name : r.client)
        } else {
            Text("Roue introuvable")
        }
    }
}

struct BatteryTestView: View {
    @ObservedObject private var test = BatteryTest.shared
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        List {
            Section {
                Text("Batterie chargée, roue réchauffée. Lance le test puis fais plusieurs accélérations franches pendant 60 secondes, en sécurité. L'appli mesure la chute de tension sous charge.")
                    .font(.subheadline)
            }

            Section {
                if test.running {
                    HStack {
                        ProgressView()
                        Text("Test en cours… \(test.remaining) s")
                        Spacer()
                        Button("Annuler") { test.cancel() }
                    }
                } else {
                    Button("Démarrer le test (60 s)") { test.begin() }
                        .disabled(ble.state != .connected)
                }
            }

            if !test.liveSamples.isEmpty {
                Section("Tension (V) et courant (A)") {
                    Chart {
                        ForEach(Array(test.liveSamples.enumerated()), id: \.offset) { _, s in
                            LineMark(x: .value("s", s.t), y: .value("V", s.v), series: .value("", "Tension"))
                                .foregroundStyle(.green)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 160)
                    Chart {
                        ForEach(Array(test.liveSamples.enumerated()), id: \.offset) { _, s in
                            LineMark(x: .value("s", s.t), y: .value("A", s.i), series: .value("", "Courant"))
                                .foregroundStyle(.yellow)
                        }
                    }
                    .frame(height: 110)
                }
            }

            if let r = test.result {
                Section("Résultat") {
                    LabeledContent("Tension au repos", value: String(format: "%.2f V", r.restVoltage))
                    LabeledContent("Tension mini en charge", value: String(format: "%.2f V", r.minVoltage))
                    LabeledContent("Chute totale", value: String(format: "%.2f V", r.sag))
                    LabeledContent("Chute par cellule (\(r.cells)S)", value: String(format: "%.3f V", r.sagPerCell))
                    LabeledContent("Courant de phase max", value: String(format: "%.0f A", r.maxCurrent))
                    LabeledContent("État estimé", value: r.verdict)
                }
                Section {
                    Text("Repère indicatif : moins de 0,15 V de chute par cellule = bonne batterie, plus de 0,30 V = batterie fatiguée. Le courant mesuré est le courant de phase du moteur, pas celui de la batterie.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Test de batterie")
    }
}
