import MapKit
import SwiftUI

// MARK: - Image de partage d'un trajet

enum TripImage {
    /// Carte du trajet (instantané MapKit + tracé) et statistiques, prête à partager.
    @MainActor
    static func make(_ trip: Trip) async -> UIImage? {
        let coords = trip.coordinates
        var mapImage: UIImage?
        if coords.count > 1 {
            let options = MKMapSnapshotter.Options()
            let rect = coords.reduce(MKMapRect.null) { r, c in
                r.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 1, height: 1)))
            }
            options.mapRect = rect.insetBy(dx: -rect.size.width * 0.15 - 300, dy: -rect.size.height * 0.15 - 300)
            options.size = CGSize(width: 1080, height: 1080)
            options.scale = 1
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            if let snap = try? await MKMapSnapshotter(options: options).start() {
                let renderer = UIGraphicsImageRenderer(size: options.size)
                mapImage = renderer.image { ctx in
                    snap.image.draw(at: .zero)
                    let path = UIBezierPath()
                    for (i, c) in coords.enumerated() {
                        let p = snap.point(for: c)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    UIColor.systemOrange.setStroke()
                    path.lineWidth = 10
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    path.stroke()
                }
            }
        }
        let card = TripShareCard(trip: trip, map: mapImage)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        return renderer.uiImage
    }
}

struct TripShareCard: View {
    let trip: Trip
    let map: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let map {
                    Image(uiImage: map).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [.orange, .black], startPoint: .top, endPoint: .bottom)
                }
                HStack(spacing: 14) {
                    if let logo = UIImage(named: "Logo") {
                        Image(uiImage: logo).resizable().frame(width: 90, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    VStack(alignment: .leading) {
                        Text(trip.wheelName).font(.system(size: 44, weight: .bold))
                        Text(trip.start.formatted(date: .long, time: .shortened)).font(.system(size: 28))
                    }
                }
                .foregroundStyle(.white)
                .padding(40)
                .shadow(radius: 8)
            }
            .frame(width: 1080, height: 1080)
            .clipped()

            HStack {
                stat(String(format: "%.1f", trip.distance), "km")
                stat(durationText(trip.duration), "durée")
                stat(String(format: "%.0f", trip.maxSpeed), "km/h max")
                stat(String(format: "%.0f", trip.avgSpeed), "km/h moy.")
            }
            .padding(.vertical, 40)
            .frame(width: 1080)
            .background(Color.black)
            Text("LynxDash · \(Business.website)")
                .font(.system(size: 24))
                .foregroundStyle(.gray)
                .frame(width: 1080, height: 70)
                .background(Color.black)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.system(size: 64, weight: .heavy, design: .rounded)).foregroundStyle(.orange)
            Text(label).font(.system(size: 26)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TripShareButton: View {
    let trip: Trip
    @State private var image: UIImage?
    @State private var working = false

    var body: some View {
        if let image {
            ShareLink(item: Image(uiImage: image),
                      preview: SharePreview("Trajet \(trip.wheelName)", image: Image(uiImage: image))) {
                Label("Partager l'image du trajet", systemImage: "photo")
            }
        } else {
            Button {
                working = true
                Task {
                    image = await TripImage.make(trip)
                    working = false
                }
            } label: {
                HStack {
                    Label("Créer l'image du trajet", systemImage: "photo")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working)
        }
    }
}

// MARK: - Sorties de groupe (relais ntfy.sh)

struct GroupMember: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var lat: Double
    var lon: Double
    var battery: Double
    var speed: Double
    var wheel: String
    var ts: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var lastSeen: Date { Date(timeIntervalSince1970: ts) }
}

final class GroupRide: ObservableObject {
    static let shared = GroupRide()

    @Published private(set) var active = false
    @Published private(set) var members: [GroupMember] = []
    @Published private(set) var status: String?
    @AppStorage("groupCode") var code = ""
    @AppStorage("groupName") var myName = ""

    private var timer: Timer?

    private var topic: String {
        let safe = code.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "lynxdash-group-\(safe)"
    }

    func start() {
        guard !code.isEmpty, !myName.isEmpty else {
            status = "Choisis un code de groupe et ton prénom"
            return
        }
        active = true
        status = "Connexion au groupe…"
        TripRecorder.shared.requestPermission()
        TripRecorder.shared.ensureLocation()
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        active = false
        members = []
        status = nil
    }

    private func tick() {
        publish()
        poll()
    }

    private func publish() {
        guard let loc = TripRecorder.shared.lastLocation,
              let url = URL(string: "https://ntfy.sh/\(topic)") else { return }
        let ble = BLEManager.shared
        let me = GroupMember(name: myName, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                             battery: ble.state == .connected ? ble.data.batteryPercent : -1,
                             speed: ble.state == .connected ? abs(ble.data.speed) : max(0, loc.speed * 3.6),
                             wheel: ble.connectedName ?? "", ts: Date().timeIntervalSince1970)
        guard let body = try? JSONEncoder().encode(me) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    private func poll() {
        guard let url = URL(string: "https://ntfy.sh/\(topic)/json?poll=1&since=5m") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            var latest: [String: GroupMember] = [:]
            if let data, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let msg = obj["message"] as? String,
                          let member = try? JSONDecoder().decode(GroupMember.self, from: Data(msg.utf8)) else { continue }
                    if member.name == self.myName { continue }
                    if let prev = latest[member.name], prev.ts > member.ts { continue }
                    latest[member.name] = member
                }
            }
            DispatchQueue.main.async {
                self.members = latest.values.sorted { $0.name < $1.name }
                self.status = error != nil ? "Pas de réseau" : "\(self.members.count) ami(s) visible(s)"
            }
        }.resume()
    }
}

struct GroupRideView: View {
    @ObservedObject private var group = GroupRide.shared
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(group.members) { m in
                    Annotation(m.name, coordinate: m.coordinate) {
                        VStack(spacing: 2) {
                            Image(systemName: "person.fill").padding(6).background(.orange, in: Circle())
                            Text(m.battery >= 0 ? "\(Int(m.battery)) %" : "").font(.caption2.bold())
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Form {
                if group.active {
                    Section {
                        if let s = group.status { Text(s).foregroundStyle(.secondary) }
                        ForEach(group.members) { m in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(m.name).font(.headline)
                                    Text(m.wheel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "%.0f km/h", m.speed))
                                    Text(m.battery >= 0 ? String(format: "%.0f %%", m.battery) : "—").font(.caption)
                                    Text(m.lastSeen.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Quitter la sortie", role: .destructive) { group.stop() }
                    }
                } else {
                    Section {
                        TextField("Ton prénom", text: group.$myName)
                        TextField("Code du groupe (le même pour tous)", text: group.$code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Rejoindre la sortie") { group.start() }
                        if let s = group.status { Text(s).font(.caption).foregroundStyle(.red) }
                    } footer: {
                        Text("Chaque participant entre le même code (ex. ride-bruxelles-0612). La position, la vitesse et la batterie sont partagées toutes les 10 s via le service gratuit ntfy.sh, tant que la sortie est active. Choisis un code difficile à deviner.")
                    }
                }
            }
            .frame(height: 300)
        }
        .navigationTitle("Sortie de groupe")
        .navigationBarTitleDisplayMode(.inline)
    }
}
