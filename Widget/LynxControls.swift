import SwiftUI
import WidgetKit

// Boutons à ajouter dans le Centre de contrôle, sur l'écran verrouillé ou sur le bouton Action.

struct HornControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "be.gyrocare.lynxdash.control.horn") {
            ControlWidgetButton(action: HornControlIntent()) {
                Label("Klaxon", systemImage: "speaker.wave.3.fill")
            }
        }
        .displayName("Klaxon")
        .description("Fait klaxonner ta gyroroue.")
    }
}

struct LightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "be.gyrocare.lynxdash.control.light") {
            ControlWidgetButton(action: LightControlIntent()) {
                Label("Phare", systemImage: "headlight.high.beam.fill")
            }
        }
        .displayName("Phare")
        .description("Allume ou éteint le phare de ta gyroroue.")
    }
}

struct ShareControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "be.gyrocare.lynxdash.control.share") {
            ControlWidgetButton(action: ShareControlIntent()) {
                Label("Partage", systemImage: "location.fill.viewfinder")
            }
        }
        .displayName("Partage de position")
        .description("Démarre ou arrête le partage de position en direct.")
    }
}
