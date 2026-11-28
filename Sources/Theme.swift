import UIKit
import SwiftUI

/// Identité visuelle Gyrocare : coucher de soleil orange, rouge braise et noir carbone.
enum Theme {
    /// Orange coucher de soleil (couleur principale).
    static let accent = Color(red: 1.0, green: 0.50, blue: 0.10)
    /// Rouge de la coque de la gyroroue.
    static let ember = Color(red: 0.90, green: 0.12, blue: 0.10)
    /// Or du soleil.
    static let gold = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let sunsetTop = Color(red: 0.22, green: 0.08, blue: 0.04)
    static let sunsetMid = Color(red: 0.62, green: 0.16, blue: 0.06)
    static let sunsetLow = Color(red: 1.0, green: 0.48, blue: 0.12)
    static let night = Color(red: 0.035, green: 0.02, blue: 0.02)

    /// Dégradé de marque (titres, boutons, anneaux).
    static let brandGradient = LinearGradient(colors: [gold, accent, ember],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Logo Gyrocare rond avec halo orange.
struct GyrocareLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.brandGradient, lineWidth: max(1.5, size * 0.04)))
            .shadow(color: Theme.accent.opacity(0.55), radius: size * 0.2)
    }
}

/// Photo de la gyroroue au coucher du soleil, avec voile sombre pour lire le texte par-dessus.
struct WheelPhoto: View {
    var name = "WheelHero"

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .overlay(
                LinearGradient(colors: [.clear, .clear, Theme.night.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            )
    }
}

/// Fond animé discret, commun à tous les écrans.
struct AppBackground: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sunsetTop, Theme.night, Theme.night], startPoint: .top, endPoint: .bottom)
            // Soleil couchant qui dérive lentement
            RadialGradient(colors: [Theme.gold.opacity(0.35), .clear],
                           center: phase ? UnitPoint(x: 0.2, y: 0.0) : UnitPoint(x: 0.8, y: 0.02),
                           startRadius: 2, endRadius: 160)
            RadialGradient(colors: [Theme.sunsetLow.opacity(0.55), .clear],
                           center: phase ? UnitPoint(x: 0.25, y: 0.05) : UnitPoint(x: 0.75, y: 0.0),
                           startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Theme.sunsetMid.opacity(0.6), .clear],
                           center: phase ? UnitPoint(x: 0.9, y: 0.25) : UnitPoint(x: 0.1, y: 0.3),
                           startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { phase.toggle() }
        }
    }
}

struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View { modifier(GlassCard(padding: padding)) }

    /// Listes et formulaires transparents sur le fond de l'appli.
    func themedList() -> some View {
        self.scrollContentBackground(.hidden).background(AppBackground())
            .scrollDismissesKeyboard(.interactively)   // glisser vers le bas ferme le clavier
            .keyboardDoneButton()
    }

    /// Bouton « OK » au-dessus du clavier (le pavé numérique n'a pas de touche Retour).
    func keyboardDoneButton() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("OK") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .bold()
            }
        }
    }
}

/// Illustration vectorielle d'une gyroroue (vue de côté), dessinée par l'appli.
struct WheelIllustration: View {
    var battery: Double
    var connected: Bool
    var lightOn: Bool = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Anneau de batterie
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: s * 0.035)
                Circle()
                    .trim(from: 0, to: connected ? battery / 100 : 0)
                    .stroke(AngularGradient(colors: [.red, .orange, .yellow, .green, .green],
                                            center: .center),
                            style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: battery)

                // Pneu
                Circle()
                    .stroke(Color.black.opacity(0.85), lineWidth: s * 0.11)
                    .frame(width: s * 0.62, height: s * 0.62)
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                    .frame(width: s * 0.73, height: s * 0.73)
                // Moyeu
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.2, height: s * 0.2)
                // Coque
                RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.10)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.42, height: s * 0.5)
                    .offset(y: -s * 0.06)
                    .overlay(
                        Capsule().fill(Theme.accent.opacity(connected ? 0.9 : 0.3))
                            .frame(width: s * 0.05, height: s * 0.22)
                            .offset(y: -s * 0.08)
                    )
                // Poignée
                Capsule()
                    .stroke(Color(white: 0.45), lineWidth: s * 0.025)
                    .frame(width: s * 0.16, height: s * 0.09)
                    .offset(y: -s * 0.33)
                // Pédales
                Capsule().fill(Color(white: 0.55))
                    .frame(width: s * 0.2, height: s * 0.035)
                    .offset(x: -s * 0.26, y: s * 0.06)
                Capsule().fill(Color(white: 0.55))
                    .frame(width: s * 0.2, height: s * 0.035)
                    .offset(x: s * 0.26, y: s * 0.06)
                // Phare
                if lightOn {
                    Circle().fill(Color.yellow.opacity(0.9))
                        .frame(width: s * 0.05)
                        .shadow(color: .yellow, radius: 12)
                        .offset(x: 0, y: -s * 0.2)
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Petit bouton rond translucide (actions rapides).
struct QuickActionButton: View {
    let icon: String
    let label: String
    var active = false
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 54, height: 54)
                    .background(active ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15)))
                    .foregroundStyle(active ? .black : .white)
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Tuile de donnée en temps réel avec icône.
struct MetricTile: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
