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
    }
}
