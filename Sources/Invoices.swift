import SwiftUI
import UIKit

// MARK: - Coordonnées de l'atelier

enum Business {
    private static var d: UserDefaults { .standard }
    static var name: String { d.string(forKey: "bizName").flatMap { $0.isEmpty ? nil : $0 } ?? "Gyrocare" }
    static var address: String { d.string(forKey: "bizAddress") ?? "" }
    static var phone: String { d.string(forKey: "bizPhone") ?? "" }
    static var email: String { d.string(forKey: "bizEmail") ?? "" }
    static var website: String { d.string(forKey: "bizWebsite") ?? "gyrocare.be" }
    static var vat: String { d.string(forKey: "bizVAT") ?? "" }
    static var iban: String { d.string(forKey: "bizIBAN") ?? "" }
    static var vatRate: Double { d.object(forKey: "bizVATRate") as? Double ?? 21 }

    static var headerLines: [String] {
        [address, [phone, email].filter { !$0.isEmpty }.joined(separator: " · "), website,
         vat.isEmpty ? "" : "TVA \(vat)"].filter { !$0.isEmpty }
    }
}

// MARK: - Modèle

struct CatalogItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var price: Double        // HTVA
}

struct InvoiceLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Double
    var unitPrice: Double    // HTVA
    var total: Double { quantity * unitPrice }
}

enum InvoiceKind: String, Codable, CaseIterable {
    case quote, invoice
    var label: String { self == .quote ? "Devis" : "Facture" }
    var prefix: String { self == .quote ? "D" : "F" }
}

struct Invoice: Codable, Identifiable {
    var id = UUID()
    var kind: InvoiceKind
    var number: String
    var date = Date()
    var client: String = ""
    var clientAddress: String = ""
    var phone: String = ""
    var email: String = ""
    var wheel: String = ""
    var lines: [InvoiceLine] = []
    var vatRate: Double = Business.vatRate
    var notes: String = ""
    var paid = false

    var subtotal: Double { lines.reduce(0) { $0 + $1.total } }
    var vat: Double { subtotal * vatRate / 100 }
    var total: Double { subtotal + vat }
}

final class InvoiceStore: ObservableObject {
    static let shared = InvoiceStore()

    @Published var invoices: [Invoice] = [] { didSet { persist() } }
    @Published var catalog: [CatalogItem] = [] { didSet { persist() } }

    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("factures.json")

    private struct Stored: Codable {
        var invoices: [Invoice]
        var catalog: [CatalogItem]
    }

    init() {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            invoices = s.invoices
            catalog = s.catalog
        } else {
            catalog = [
                CatalogItem(name: "Main d'œuvre (1 h)", price: 50),
                CatalogItem(name: "Diagnostic", price: 30),
                CatalogItem(name: "Changement de pneu (main d'œuvre)", price: 60),
                CatalogItem(name: "Chambre à air", price: 15),
                CatalogItem(name: "Mise à jour firmware", price: 20)
            ]
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(invoices: invoices, catalog: catalog)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Numérotation continue par année : F-2026-0001, D-2026-0001…
    func nextNumber(_ kind: InvoiceKind, date: Date = Date()) -> String {
        let year = Calendar.current.component(.year, from: date)
        let prefix = "\(kind.prefix)-\(year)-"
        let last = invoices.filter { $0.number.hasPrefix(prefix) }
            .compactMap { Int($0.number.dropFirst(prefix.count)) }.max() ?? 0
        return prefix + String(format: "%04d", last + 1)
    }

    func save(_ inv: Invoice) {
        if let i = invoices.firstIndex(where: { $0.id == inv.id }) { invoices[i] = inv } else { invoices.insert(inv, at: 0) }
    }

    func convertToInvoice(_ quote: Invoice) -> Invoice {
        var inv = quote
        inv.id = UUID()
        inv.kind = .invoice
        inv.number = nextNumber(.invoice)
        inv.date = Date()
        inv.notes = (quote.notes.isEmpty ? "" : quote.notes + "\n") + "Selon devis \(quote.number)."
        save(inv)
        return inv
    }
}

// MARK: - PDF

enum InvoicePDF {
    static func make(_ inv: Invoice) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let money = NumberFormatter()
        money.numberStyle = .currency
        money.locale = Locale(identifier: "fr_BE")
        func m(_ v: Double) -> String { money.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v) }

        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            ctx.beginPage()
            let left: CGFloat = 40, right = page.width - 40
            var y: CGFloat = 40

            func draw(_ s: String, x: CGFloat, size: CGFloat, bold: Bool = false, color: UIColor = .black, align: NSTextAlignment = .left, width: CGFloat = 300) {
                let style = NSMutableParagraphStyle(); style.alignment = align
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: color, .paragraphStyle: style]
                (s as NSString).draw(in: CGRect(x: x, y: y, width: width, height: size * 3), withAttributes: attrs)
            }

            if let logo = UIImage(named: "Logo") { logo.draw(in: CGRect(x: left, y: y, width: 56, height: 56)) }
            let save = y
            y = save; draw(Business.name, x: left + 66, size: 20, bold: true, color: .systemOrange)
            y += 26
            for line in Business.headerLines { draw(line, x: left + 66, size: 9, color: .darkGray, width: 260); y += 12 }

            y = save
            draw("\(inv.kind.label.uppercased())", x: right - 200, size: 20, bold: true, align: .right, width: 200)
            y += 26; draw("N° \(inv.number)", x: right - 200, size: 11, align: .right, width: 200)
            y += 15; draw(DateFormatter.localizedString(from: inv.date, dateStyle: .long, timeStyle: .none),
                          x: right - 200, size: 10, color: .darkGray, align: .right, width: 200)
            y = max(y, save + 90) + 20

            draw("Client", x: left, size: 10, bold: true, color: .darkGray); y += 14
            for line in [inv.client, inv.clientAddress, inv.phone, inv.email].filter({ !$0.isEmpty }) {
                draw(line, x: left, size: 11); y += 14
            }
            if !inv.wheel.isEmpty { draw("Roue : \(inv.wheel)", x: left, size: 10, color: .darkGray); y += 14 }
            y += 16

            // Tableau
            UIColor.systemOrange.withAlphaComponent(0.15).setFill()
            UIBezierPath(rect: CGRect(x: left, y: y - 4, width: right - left, height: 20)).fill()
            draw("Désignation", x: left + 6, size: 10, bold: true)
            draw("Qté", x: right - 230, size: 10, bold: true, align: .right, width: 50)
            draw("Prix HTVA", x: right - 170, size: 10, bold: true, align: .right, width: 80)
            draw("Total HTVA", x: right - 86, size: 10, bold: true, align: .right, width: 80)
            y += 22
            for line in inv.lines {
                draw(line.name, x: left + 6, size: 10, width: right - left - 250)
                draw(line.quantity == line.quantity.rounded() ? String(format: "%.0f", line.quantity) : String(format: "%.2f", line.quantity),
                     x: right - 230, size: 10, align: .right, width: 50)
                draw(m(line.unitPrice), x: right - 170, size: 10, align: .right, width: 80)
                draw(m(line.total), x: right - 86, size: 10, align: .right, width: 80)
                y += 18
            }
            UIColor.lightGray.setStroke()
            let path = UIBezierPath(); path.move(to: CGPoint(x: right - 250, y: y + 4)); path.addLine(to: CGPoint(x: right, y: y + 4)); path.stroke()
            y += 12
            for (label, value, bold) in [("Total HTVA", inv.subtotal, false),
                                         (String(format: "TVA %.0f %%", inv.vatRate), inv.vat, false),
                                         ("Total TVAC", inv.total, true)] {
                draw(label, x: right - 250, size: 11, bold: bold, width: 140)
                draw(m(value), x: right - 110, size: 11, bold: bold, align: .right, width: 104)
                y += 18
            }
            y += 20
            if !inv.notes.isEmpty { draw(inv.notes, x: left, size: 10, color: .darkGray, width: right - left); y += 40 }
            if inv.kind == .invoice {
                let payment = Business.iban.isEmpty ? "Paiement à réception."
                    : "Paiement sur le compte \(Business.iban), communication : \(inv.number)."
                draw(inv.paid ? "Facture acquittée. Merci !" : payment, x: left, size: 10, bold: true, width: right - left)
            } else {
                draw("Devis valable 30 jours.", x: left, size: 10, width: right - left)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(inv.number).pdf")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

// MARK: - Vues

struct InvoicesView: View {
    @ObservedObject private var store = InvoiceStore.shared
    @State private var editing: Invoice?

    var body: some View {
        List {
            Section {
                Button { editing = Invoice(kind: .quote, number: store.nextNumber(.quote)) } label: {
                    Label("Nouveau devis", systemImage: "doc.badge.plus")
                }
                Button { editing = Invoice(kind: .invoice, number: store.nextNumber(.invoice)) } label: {
                    Label("Nouvelle facture", systemImage: "eurosign.square")
                }
                NavigationLink { CatalogView() } label: { Label("Catalogue pièces et tarifs", systemImage: "list.bullet.rectangle") }
                NavigationLink { BusinessView() } label: { Label("Coordonnées de l'atelier", systemImage: "building.2") }
            }
            Section("Documents") {
                ForEach(store.invoices) { inv in
                    Button { editing = inv } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(inv.kind.label) \(inv.number)").font(.headline)
                                Text(inv.client.isEmpty ? "Sans client" : inv.client).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(String(format: "%.2f €", inv.total)).font(.headline)
                                if inv.kind == .invoice {
                                    Text(inv.paid ? "Payée" : "À payer").font(.caption)
                                        .foregroundStyle(inv.paid ? .green : .orange)
                                }
                            }
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { store.invoices.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Devis et factures")
        .sheet(item: $editing) { inv in InvoiceEditor(invoice: inv) }
    }
}

struct InvoiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InvoiceStore.shared
    @State var invoice: Invoice
    @State private var pdf: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section(invoice.kind.label + " " + invoice.number) {
                    DatePicker("Date", selection: $invoice.date, displayedComponents: .date)
                    if invoice.kind == .invoice { Toggle("Payée", isOn: $invoice.paid) }
                }
                Section("Client") {
                    TextField("Nom", text: $invoice.client)
                    TextField("Adresse", text: $invoice.clientAddress)
                    TextField("Téléphone", text: $invoice.phone).keyboardType(.phonePad)
                    TextField("E-mail", text: $invoice.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Roue", text: $invoice.wheel)
                    if !WorkshopStore.shared.records.isEmpty {
                        Menu("Reprendre un client de l'atelier") {
                            ForEach(WorkshopStore.shared.records) { r in
                                Button(r.client.isEmpty ? r.name : r.client) {
                                    invoice.client = r.client
                                    invoice.phone = r.phone
                                    invoice.wheel = "\(r.brand) \(r.model) (\(r.name))"
                                }
                            }
                        }
                    }
                }
                Section("Lignes") {
                    ForEach($invoice.lines) { $line in
                        VStack(alignment: .leading) {
                            TextField("Désignation", text: $line.name)
                            HStack {
                                Stepper(String(format: "Qté %.0f", line.quantity), value: $line.quantity, in: 0...100, step: 1)
                                TextField("Prix", value: $line.unitPrice, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text("€")
                            }
                        }
                    }
                    .onDelete { invoice.lines.remove(atOffsets: $0) }
                    Menu {
                        ForEach(store.catalog) { item in
                            Button("\(item.name) — \(String(format: "%.2f €", item.price))") {
                                invoice.lines.append(InvoiceLine(name: item.name, quantity: 1, unitPrice: item.price))
                            }
                        }
                        Button("Ligne libre") { invoice.lines.append(InvoiceLine(name: "", quantity: 1, unitPrice: 0)) }
                    } label: {
                        Label("Ajouter une ligne", systemImage: "plus.circle")
                    }
                }
                Section {
                    LabeledContent("Total HTVA", value: String(format: "%.2f €", invoice.subtotal))
                    Stepper(String(format: "TVA %.0f %%", invoice.vatRate), value: $invoice.vatRate, in: 0...21, step: 1)
                    LabeledContent("Total TVAC", value: String(format: "%.2f €", invoice.total)).bold()
                }
                Section("Remarques") {
                    TextEditor(text: $invoice.notes).frame(minHeight: 60)
                }
                Section {
                    Button("Enregistrer et créer le PDF") {
                        store.save(invoice)
                        pdf = InvoicePDF.make(invoice)
                    }
                    if let pdf {
                        ShareLink(item: pdf,
                                  subject: Text("\(invoice.kind.label) \(invoice.number) — \(Business.name)"),
                                  message: Text("Bonjour,\nVoici votre \(invoice.kind.label.lowercased()) \(invoice.number).\n\(Business.name)")) {
                            Label("Envoyer au client (e-mail, WhatsApp…)", systemImage: "square.and.arrow.up")
                        }
                    }
                    if invoice.kind == .quote {
                        Button("Transformer en facture") {
                            store.save(invoice)
                            invoice = store.convertToInvoice(invoice)
                            pdf = nil
                        }
                    }
                }
            }
            .navigationTitle(invoice.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { store.save(invoice); dismiss() } }
            }
        }
    }
}

struct CatalogView: View {
    @ObservedObject private var store = InvoiceStore.shared
    @State private var name = ""
    @State private var price: Double = 0

    var body: some View {
        List {
            Section("Ajouter") {
                TextField("Pièce ou prestation", text: $name)
                HStack {
                    Text("Prix HTVA")
                    TextField("0", value: $price, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("€")
                }
                Button("Ajouter") {
                    store.catalog.append(CatalogItem(name: name, price: price))
                    name = ""; price = 0
                }
                .disabled(name.isEmpty)
            }
            Section("Catalogue") {
                ForEach($store.catalog) { $item in
                    HStack {
                        TextField("Nom", text: $item.name)
                        TextField("Prix", value: $item.price, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        Text("€")
                    }
                }
                .onDelete { store.catalog.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Catalogue")
    }
}

struct BusinessView: View {
    @AppStorage("bizName") private var name = "Gyrocare"
    @AppStorage("bizAddress") private var address = ""
    @AppStorage("bizPhone") private var phone = ""
    @AppStorage("bizEmail") private var email = ""
    @AppStorage("bizWebsite") private var website = "gyrocare.be"
    @AppStorage("bizVAT") private var vat = ""
    @AppStorage("bizIBAN") private var iban = ""
    @AppStorage("bizVATRate") private var vatRate = 21.0

    var body: some View {
        Form {
            Section("Atelier") {
                TextField("Nom", text: $name)
                TextField("Adresse", text: $address)
                TextField("Téléphone", text: $phone).keyboardType(.phonePad)
                TextField("E-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Site web", text: $website).textInputAutocapitalization(.never)
            }
            Section {
                TextField("N° de TVA (ex. BE0123456789)", text: $vat).textInputAutocapitalization(.characters)
                TextField("IBAN pour les paiements", text: $iban).textInputAutocapitalization(.characters)
                Stepper(String(format: "TVA par défaut : %.0f %%", vatRate), value: $vatRate, in: 0...21, step: 1)
            } header: {
                Text("Facturation")
            } footer: {
                Text("Ces informations apparaissent en en-tête des devis, factures et fiches diagnostic.")
            }
        }
        .navigationTitle("Coordonnées")
    }
}
