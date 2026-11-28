import AppIntents

// MARK: - Boutons du Centre de contrôle / écran verrouillé (iOS 18)
//
// Ces intents sont compilés dans l'appli ET dans l'extension widget. Comme ce sont des
// « LiveActivityIntent », iOS les exécute dans le processus de l'APPLI (qui tient la
// connexion Bluetooth avec la roue). L'appli branche le gestionnaire au lancement.

enum ControlCommand: String {
    case horn, light, share
}

enum ControlActions {
    /// Branché par l'appli : exécute la commande et renvoie un message.
    nonisolated(unsafe) static var handler: ((ControlCommand) async -> String)?
}

struct HornControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Klaxon de la roue"
    static var description = IntentDescription("Fait klaxonner la roue (et le téléphone).")
    func perform() async throws -> some IntentResult {
        _ = await ControlActions.handler?(.horn)
        return .result()
    }
}

struct LightControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Phare de la roue"
    static var description = IntentDescription("Allume ou éteint le phare de la roue.")
    func perform() async throws -> some IntentResult {
        _ = await ControlActions.handler?(.light)
        return .result()
    }
}

struct ShareControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Partage de position"
    static var description = IntentDescription("Démarre ou arrête le partage de position en direct.")
    func perform() async throws -> some IntentResult {
        _ = await ControlActions.handler?(.share)
        return .result()
    }
}
