import AppIntents

/// Actions disponibles dans Raccourcis, Siri et le bouton Action de l'iPhone.
struct BriderIntent: AppIntent {
    static var title: LocalizedStringResource = "Brider la roue à 25 km/h"
    static var description = IntentDescription("Règle la limite de vitesse de la gyroroue connectée à 25 km/h.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ble = BLEManager.shared
        await ble.waitForTelemetry(timeout: 12)
        let text = await ble.engageLimiter().message(for: .engage)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}

struct DebriderIntent: AppIntent {
    static var title: LocalizedStringResource = "Débrider la roue"
    static var description = IntentDescription("Restaure la limite de vitesse d'origine de la gyroroue connectée.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ble = BLEManager.shared
        await ble.waitForTelemetry(timeout: 12)
        let text = await ble.releaseLimiter().message(for: .release)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}

/// Un seul bouton (Flic, bouton Action…) : bride si la roue ne l'est pas, sinon débride.
struct BasculerBridageIntent: AppIntent {
    static var title: LocalizedStringResource = "Basculer le bridage 25 km/h"
    static var description = IntentDescription("Bride la roue si elle ne l'est pas, sinon la débride. Idéal pour un bouton Flic.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await LimiterToggle.run()
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}

enum LimiterToggle {
    /// Bascule le bridage et renvoie le message à afficher / annoncer.
    @MainActor
    static func run() async -> String {
        let ble = BLEManager.shared
        await ble.waitForTelemetry(timeout: 12)
        let engaged = ble.isLimited || ble.pendingAction == .engage
        if engaged && PinLock.required {
            let text = "Roue bridée. " + PinLock.lockedMessage
            VoiceAnnouncer.shared.speak("Débridage protégé par code", urgent: true)
            return text
        }
        let action: LimiterAction = engaged ? .release : .engage
        let outcome = engaged ? await ble.releaseLimiter() : await ble.engageLimiter()
        let text = outcome.message(for: action)
        // Retour sonore : utile quand on appuie sur le Flic sans regarder le téléphone
        VoiceAnnouncer.shared.speak(text.replacingOccurrences(of: " ✓", with: ""), urgent: true)
        return text
    }
}

struct LynxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BriderIntent(),
                    phrases: ["Brider la roue avec \(.applicationName)",
                              "Bride ma roue avec \(.applicationName)"],
                    shortTitle: "Brider 25 km/h",
                    systemImageName: "lock.fill")
        AppShortcut(intent: DebriderIntent(),
                    phrases: ["Débrider la roue avec \(.applicationName)",
                              "Débride ma roue avec \(.applicationName)"],
                    shortTitle: "Débrider",
                    systemImageName: "lock.open.fill")
        AppShortcut(intent: BasculerBridageIntent(),
                    phrases: ["Basculer le bridage avec \(.applicationName)"],
                    shortTitle: "Basculer le bridage",
                    systemImageName: "lock.rotation")
    }
}
