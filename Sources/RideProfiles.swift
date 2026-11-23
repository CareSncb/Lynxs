import AppIntents
import SwiftUI

// MARK: - Profils de conduite (bridage + pédales + alarmes en un geste)

enum ProfileLimit: String, Codable, CaseIterable, Identifiable {
    case restricted, original, unchanged
    var id: String { rawValue }
    var label: String {
        switch self {
        case .restricted: return "Bridée à 25 km/h"
        case .original: return "Limite d'origine"
        case .unchanged: return "Ne pas toucher"
        }
    }
}

struct RideProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var limit: ProfileLimit
    var pedals: Int?              // PedalsMode.rawValue, nil = ne pas toucher
    var speedAlarm: Double?       // nil = ne pas toucher, 0 = désactivée
    var pwmAlarm: Double?
    var marginAlarm: Double?

    static let defaults: [RideProfile] = [
        RideProfile(name: "Ville", icon: "building.2.fill", limit: .restricted,
                    pedals: PedalsMode.soft.rawValue, speedAlarm: 23, pwmAlarm: 70, marginAlarm: 30),
        RideProfile(name: "Balade", icon: "leaf.fill", limit: .original,
                    pedals: PedalsMode.medium.rawValue, speedAlarm: 0, pwmAlarm: 75, marginAlarm: 25),
        RideProfile(name: "Sport", icon: "flame.fill", limit: .original,
                    pedals: PedalsMode.hard.rawValue, speedAlarm: 0, pwmAlarm: 80, marginAlarm: 20)
    ]
}

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [RideProfile] { didSet { persist() } }
    @Published private(set) var activeID: UUID?

    init() {
        if let data = UserDefaults.standard.data(forKey: "rideProfiles"),
           let p = try? JSONDecoder().decode([RideProfile].self, from: data), !p.isEmpty {
            profiles = p
        } else {
            profiles = RideProfile.defaults
        }
        if let s = UserDefaults.standard.string(forKey: "activeRideProfile") { activeID = UUID(uuidString: s) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "rideProfiles") }
    }

    /// Applique un profil. Renvoie un message à afficher / annoncer.
    @MainActor
    func apply(_ p: RideProfile) async -> String {
        let ble = BLEManager.shared
        guard ble.state == .connected else { return "Roue non connectée" }
        var parts: [String] = []
        if let v = p.speedAlarm { ble.speedAlarm = v }
        if let v = p.pwmAlarm { ble.pwmAlarm = v }
        if let v = p.marginAlarm { UserDefaults.standard.set(v, forKey: "marginAlarm") }
        if let raw = p.pedals, let mode = PedalsMode(rawValue: raw), ble.supportsPedals {
            ble.setPedals(mode)
            parts.append("pédales \(mode.label.lowercased())")
        }
        switch p.limit {
        case .restricted:
            if !ble.isLimited { parts.append(await ble.engageLimiter().message(for: .engage)) }
        case .original:
            if ble.isLimited || ble.pendingAction == .engage {
                parts.append(await ble.releaseLimiter().message(for: .release))
            }
        case .unchanged:
            break
        }
        activeID = p.id
        UserDefaults.standard.set(p.id.uuidString, forKey: "activeRideProfile")
        let text = "Profil \(p.name)" + (parts.isEmpty ? " ✓" : " : " + parts.joined(separator: ", "))
        ble.limiterMessage = text
        return text
    }

    func profile(named name: String) -> RideProfile? {
        profiles.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

// MARK: - Siri / Raccourcis / bouton Action

struct RideProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Profil de conduite"
    static var defaultQuery = RideProfileQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct RideProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [RideProfileEntity] {
        ProfileManager.shared.profiles.filter { identifiers.contains($0.id) }
            .map { RideProfileEntity(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [RideProfileEntity] {
        ProfileManager.shared.profiles.map { RideProfileEntity(id: $0.id, name: $0.name) }
    }
}

struct ApplyRideProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Appliquer un profil de conduite"
    static var description = IntentDescription("Applique bridage, pédales et alarmes d'un profil (Ville, Balade, Sport…).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Profil") var profile: RideProfileEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await BLEManager.shared.waitForTelemetry(timeout: 12)
        guard let p = ProfileManager.shared.profiles.first(where: { $0.id == profile.id }) else {
            return .result(dialog: "Profil introuvable")
        }
        let text = await ProfileManager.shared.apply(p)
        VoiceAnnouncer.shared.speak(text.replacingOccurrences(of: " ✓", with: ""), urgent: true)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}

// MARK: - Écrans

struct ProfileBar: View {
    @ObservedObject private var manager = ProfileManager.shared
    @EnvironmentObject var ble: BLEManager
    @State private var busy = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.profiles) { p in
                    let active = manager.activeID == p.id
                    Button {
                        busy = true
                        Task { @MainActor in
                            _ = await manager.apply(p)
                            busy = false
                        }
                    } label: {
                        Label(p.name, systemImage: p.icon)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(active ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                            .foregroundStyle(active ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || ble.state != .connected)
                }
                NavigationLink {
                    ProfilesEditorView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .padding(9)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

struct ProfilesEditorView: View {
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        List {
            Section {
                ForEach($manager.profiles) { $p in
                    NavigationLink {
                        ProfileEditView(profile: $p)
                    } label: {
                        Label(p.name, systemImage: p.icon)
                    }
                }
                .onDelete { manager.profiles.remove(atOffsets: $0) }
                .onMove { manager.profiles.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    manager.profiles.append(RideProfile(name: "Nouveau", icon: "star.fill", limit: .unchanged))
                } label: {
                    Label("Ajouter un profil", systemImage: "plus")
                }
            } footer: {
                Text("Siri : « Appliquer un profil de conduite » dans Raccourcis, ou bouton Action › Raccourci › LynxDash.")
            }
        }
        .themedList()
        .navigationTitle("Profils de conduite")
        .toolbar { EditButton() }
    }
}

struct ProfileEditView: View {
    @Binding var profile: RideProfile
    private let icons = ["building.2.fill", "leaf.fill", "flame.fill", "moon.fill", "cloud.rain.fill", "figure.and.child.holdinghands", "star.fill", "bolt.fill"]

    private func optionalBinding(_ kp: WritableKeyPath<RideProfile, Double?>, default def: Double) -> Binding<Bool> {
        Binding(get: { profile[keyPath: kp] != nil },
                set: { profile[keyPath: kp] = $0 ? def : nil })
    }

    var body: some View {
        Form {
            Section {
                TextField("Nom", text: $profile.name)
                Picker("Icône", selection: $profile.icon) {
                    ForEach(icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                .pickerStyle(.navigationLink)
            }
            Section("Bridage") {
                Picker("Limite", selection: $profile.limit) {
                    ForEach(ProfileLimit.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Pédales") {
                Picker("Dureté", selection: Binding(get: { profile.pedals ?? -1 }, set: { profile.pedals = $0 < 0 ? nil : $0 })) {
                    Text("Ne pas toucher").tag(-1)
                    ForEach(PedalsMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Alarmes") {
                Toggle("Régler l'alarme de vitesse", isOn: optionalBinding(\.speedAlarm, default: 25))
                if let v = profile.speedAlarm {
                    Stepper(v == 0 ? "Vitesse : désactivée" : "Vitesse : \(Int(v)) km/h",
                            value: Binding(get: { v }, set: { profile.speedAlarm = $0 }), in: 0...80, step: 1)
                }
                Toggle("Régler l'alarme PWM", isOn: optionalBinding(\.pwmAlarm, default: 75))
                if let v = profile.pwmAlarm {
                    Stepper("PWM : \(Int(v)) %", value: Binding(get: { v }, set: { profile.pwmAlarm = $0 }), in: 0...95, step: 5)
                }
                Toggle("Régler la marge de sécurité", isOn: optionalBinding(\.marginAlarm, default: 25))
                if let v = profile.marginAlarm {
                    Stepper("Marge mini : \(Int(v)) %", value: Binding(get: { v }, set: { profile.marginAlarm = $0 }), in: 0...50, step: 5)
                }
            }
        }
        .themedList()
        .navigationTitle(profile.name)
    }
}
