import SwiftUI

// MARK: - Avertissement de mise à jour (l'appli s'installe en sideload)

final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available = false
    @Published private(set) var changes: [String] = []
    @Published private(set) var latestDate: Date?

    private let repo = "CareSncb/lynxs"
    static let downloadURL = URL(string: "https://github.com/CareSncb/lynxs/raw/ipa/LynxDash.ipa")!

    /// Vérifie au plus une fois toutes les 6 heures.
    func checkIfNeeded() {
        let last = UserDefaults.standard.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 || available else { return }
        check()
    }

    func check() {
        guard BuildInfo.commit != "dev" else { return }      // version compilée à la main
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
        get("https://api.github.com/repos/\(repo)/commits/ipa") { [weak self] json in
            guard let self, let commit = json["commit"] as? [String: Any],
                  let message = commit["message"] as? String else { return }
            // Message de la branche ipa : « IPA iPhone <sha7> »
            guard let built = message.split(separator: " ").last.map(String.init), built.count >= 7 else { return }
            let mine = String(BuildInfo.commit.prefix(built.count))
            guard built != mine else { DispatchQueue.main.async { self.available = false }; return }
            if let author = commit["committer"] as? [String: Any], let d = author["date"] as? String {
                let date = ISO8601DateFormatter().date(from: d)
                DispatchQueue.main.async { self.latestDate = date }
            }
            self.fetchChanges(from: BuildInfo.commit, to: built)
        }
    }

    /// Liste des nouveautés (premières lignes des commits) entre ma version et la dernière.
    private func fetchChanges(from: String, to: String) {
        get("https://api.github.com/repos/\(repo)/compare/\(from)...\(to)") { [weak self] json in
            let commits = (json["commits"] as? [[String: Any]]) ?? []
            let lines = commits.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
                .map { $0.components(separatedBy: "\n").first ?? $0 }
                .filter { !$0.lowercased().hasPrefix("relance") }
            DispatchQueue.main.async {
                self?.changes = Array(lines.reversed().prefix(15))
                self?.available = true
            }
        }
    }

    private func get(_ url: String, _ done: @escaping ([String: Any]) -> Void) {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            done(json)
        }.resume()
    }
}

struct UpdateBanner: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var showDetails = false

    var body: some View {
        if updates.available {
            Button { showDetails = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nouvelle version disponible").font(.headline).foregroundStyle(.white)
                        Text("Touche pour voir les nouveautés").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .glassCard()
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDetails) { UpdateDetailsView() }
        }
    }
}

struct UpdateDetailsView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let d = updates.latestDate {
                    Section { LabeledContent("Publiée le", value: d.formatted(date: .long, time: .shortened)) }
                }
                Section("Nouveautés") {
                    if updates.changes.isEmpty { Text("Améliorations et corrections").foregroundStyle(.secondary) }
                    ForEach(updates.changes, id: \.self) { Text($0).font(.subheadline) }
                }
                Section {
                    Link(destination: UpdateChecker.downloadURL) {
                        Label("Télécharger la nouvelle version (.ipa)", systemImage: "arrow.down.circle.fill")
                    }
                } footer: {
                    Text("Installe-la ensuite comme d'habitude (Signulous, Sideloadly…). Tes réglages et trajets sont conservés.")
                }
            }
            .themedList()
            .navigationTitle("Mise à jour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
