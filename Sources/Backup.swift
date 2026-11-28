import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sauvegarde et restauration (trajets, roues, réglages, fiches, factures…)

enum BackupManager {
    struct Payload: Codable {
        var format = 1
        var date: Date
        var defaults: Data            // réglages (property list)
        var files: [String: Data]     // fichiers du dossier Documents (chemin relatif → contenu)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func export() -> URL? {
        let id = Bundle.main.bundleIdentifier ?? "be.gyrocare.lynxdash"
        let domain = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        guard let defaults = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0) else { return nil }
        var files: [String: Data] = [:]
        if let e = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: url) else { continue }
                let rel = url.path.replacingOccurrences(of: documents.path + "/", with: "")
                files[rel] = data
            }
        }
        let payload = Payload(date: Date(), defaults: defaults, files: files)
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LynxDash-sauvegarde-\(df.string(from: Date())).json")
        do { try json.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Restaure une sauvegarde. Renvoie un message pour l'utilisateur.
    static func restore(from url: URL) -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let domain = try? PropertyListSerialization.propertyList(from: payload.defaults, format: nil) as? [String: Any]
        else { return "Fichier de sauvegarde illisible" }
        let id = Bundle.main.bundleIdentifier ?? "be.gyrocare.lynxdash"
        UserDefaults.standard.setPersistentDomain(domain, forName: id)
        var written = 0
        for (rel, content) in payload.files {
            guard !rel.contains("..") else { continue }
            let dest = documents.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? content.write(to: dest, options: .atomic)) != nil { written += 1 }
        }
        let when = payload.date.formatted(date: .long, time: .shortened)
        return "Sauvegarde du \(when) restaurée (\(written) fichiers). Ferme complètement l'appli puis rouvre-la pour tout recharger."
    }
}

struct BackupSection: View {
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmRestore: URL?

    var body: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) { Label("Enregistrer la sauvegarde (Fichiers, AirDrop…)", systemImage: "square.and.arrow.up") }
            } else {
                Button { exportURL = BackupManager.export() } label: {
                    Label("Créer une sauvegarde", systemImage: "externaldrive.badge.plus")
                }
            }
            Button { importing = true } label: { Label("Restaurer une sauvegarde", systemImage: "externaldrive.badge.checkmark") }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Sauvegarde")
        } footer: {
            Text("Trajets, roues, réglages, boîte noire, fiches atelier, factures et rendez-vous dans un seul fichier. À faire avant de réinstaller l'appli ou de changer de certificat de signature.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { confirmRestore = url }
        }
        .alert("Remplacer les données actuelles ?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Annuler", role: .cancel) { confirmRestore = nil }
            Button("Restaurer", role: .destructive) {
                if let u = confirmRestore { message = BackupManager.restore(from: u) }
                confirmRestore = nil
            }
        } message: {
            Text("Les réglages et fichiers de la sauvegarde remplacent ceux de cet iPhone.")
        }
    }
}
