import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct LynxWatchApp: App {
    @StateObject private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchView().environmentObject(session)
        }
    }
}

final class WatchSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published var connected = false
    @Published var limited = false
    @Published var pending = ""
    @Published var limit: Double = -1
    @Published var speed: Double = 0
    @Published var battery: Double = 0
    @Published var name = ""
    @Published var message: String?
    @Published var busy = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ action: String) {
        guard WCSession.default.activationState == .activated else {
            message = "Connexion à l'iPhone…"
            return
        }
        busy = true
        WCSession.default.sendMessage(["action": action], replyHandler: { reply in
            DispatchQueue.main.async {
                self.busy = false
                self.apply(reply)
                if action != "status" {
                    WKInterfaceDevice.current().play(self.message?.contains("impossible") == true ? .failure : .success)
                }
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                self.busy = false
                self.message = "iPhone injoignable : ouvre LynxDash sur l'iPhone"
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }

    private func apply(_ reply: [String: Any]) {
        connected = reply["connected"] as? Bool ?? false
        limited = reply["limited"] as? Bool ?? false
        pending = reply["pending"] as? String ?? ""
        limit = reply["limit"] as? Double ?? -1
        speed = reply["speed"] as? Double ?? 0
        battery = reply["battery"] as? Double ?? 0
        name = reply["name"] as? String ?? ""
        if let m = reply["message"] as? String { message = m }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { self.send("status") }
    }
}

struct WatchView: View {
    @EnvironmentObject var session: WatchSession
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: session.pending.isEmpty ? (session.limited ? "lock.fill" : "lock.open.fill") : "hourglass")
                    .font(.title2)
                    .foregroundStyle(session.pending.isEmpty ? (session.limited ? Color.orange : Color.green) : Color.yellow)

                Text(statusText)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if session.connected {
                    Text(String(format: "%.0f km/h · %.0f %%", session.speed, session.battery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    confirm = true
                } label: {
                    Label(engaged ? "Débrider" : "Brider 25", systemImage: engaged ? "lock.open" : "lock")
                        .frame(maxWidth: .infinity)
                }
                .tint(engaged ? .green : .orange)
                .disabled(session.busy || !session.connected)

                if session.busy { ProgressView() }

                if let m = session.message {
                    Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                Button("Actualiser") { session.send("status") }
                    .font(.footnote)
            }
            .padding(.horizontal, 4)
        }
        .confirmationDialog(engaged ? "Débrider la roue ?" : "Brider à 25 km/h ?",
                            isPresented: $confirm) {
            Button(engaged ? "Oui, débrider" : "Oui, brider", role: .destructive) {
                session.send(engaged ? "release" : "engage")
            }
            Button("Annuler", role: .cancel) {}
        }
        .onAppear { session.send("status") }
    }

    private var engaged: Bool { session.limited || session.pending == "engage" }

    private var statusText: String {
        guard session.connected else { return "Roue non connectée" }
        let limit = session.limit >= 0 ? String(format: "%.0f km/h", session.limit) : "—"
        if session.pending == "engage" { return "Bridage en attente de l'arrêt" }
        if session.pending == "release" { return "Débridage en attente de l'arrêt" }
        return session.limited ? "Bridée à 25 km/h" : "Limite : \(limit)"
    }
}
