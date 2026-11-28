import MapKit
import SwiftUI

// MARK: - « Est-ce que j'y arrive ? »

final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { completer.queryFragment = query } }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let loc = TripRecorder.shared.lastLocation {
            completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = Array(completer.results.prefix(8)) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }
}

struct RangeCheckView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var search = PlaceSearch()
    @State private var destination: MKMapItem?
    @State private var route: MKRoute?
    @State private var error: String?
    @State private var loading = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    private var consumption: Double? {
        RangePredictor.estimate(battery: 100, wheelName: ble.connectedName)?.consumption
            ?? TripStore.shared.averageConsumption
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                UserAnnotation()
                if let route { MapPolyline(route.polyline).stroke(Theme.accent, lineWidth: 5) }
                if let destination { Marker(destination.name ?? "Arrivée", coordinate: destination.placemark.coordinate).tint(Theme.ember) }
            }
            .frame(height: route == nil ? 220 : 300)

            List {
                Section {
                    TextField("Adresse ou lieu", text: $search.query)
                        .autocorrectionDisabled()
                    if destination == nil {
                        ForEach(search.results, id: \.self) { r in
                            Button {
                                choose(r)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(r.title).foregroundStyle(.white)
                                    if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                if loading { Section { ProgressView("Calcul de l'itinéraire…") } }
                if let error { Section { Text(error).foregroundStyle(Theme.ember) } }
                if let route { verdictSection(route) }
            }
            .themedList()
        }
        .navigationTitle("Est-ce que j'y arrive ?")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: search.query) { _, _ in if destination != nil { destination = nil; route = nil } }
    }

    @ViewBuilder
    private func verdictSection(_ route: MKRoute) -> some View {
        let km = route.distance / 1000
        let battery = ble.state == .connected ? ble.data.batteryPercent : nil
        Section {
            LabeledContent("Distance", value: String(format: "%.1f km", km))
            if let c = consumption {
                let need = km * c
                LabeledContent("Batterie nécessaire (aller)", value: String(format: "%.0f %%", need))
                if let b = battery {
                    let arrive = b - need
                    let back = b - 2 * need
                    verdictRow(arrive >= 10 ? "Tu y arrives avec ≈ \(Int(arrive)) %" : (arrive > 0 ? "Juste : ≈ \(Int(arrive)) % à l'arrivée" : "Batterie insuffisante pour l'aller"),
                               ok: arrive >= 10, warn: arrive > 0 && arrive < 10)
                    verdictRow(back >= 10 ? "Aller-retour possible (≈ \(Int(back)) % au retour)" : (back > 0 ? "Aller-retour très juste (≈ \(Int(back)) %)" : "Aller-retour impossible sans recharger"),
                               ok: back >= 10, warn: back > 0 && back < 10)
                } else {
                    Text("Connecte ta roue pour comparer avec ta batterie actuelle.").font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "Basé sur ta consommation réelle : %.2f %% par km. Vent, froid et dénivelé peuvent la faire varier.", c))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Fais quelques trajets pour que l'appli connaisse ta consommation.").foregroundStyle(.secondary)
            }
            if let destination {
                Button {
                    destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                } label: { Label("Ouvrir l'itinéraire dans Plans", systemImage: "map") }
            }
        } header: {
            Text(destination?.name ?? "Arrivée")
        }
    }

    private func verdictRow(_ text: String, ok: Bool, warn: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : (warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
            .foregroundStyle(ok ? .green : (warn ? Theme.gold : Theme.ember))
            .font(.headline)
    }

    private func choose(_ completion: MKLocalSearchCompletion) {
        loading = true; error = nil; route = nil
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, _ in
            guard let item = response?.mapItems.first else {
                loading = false; error = "Lieu introuvable"; return
            }
            destination = item
            let req = MKDirections.Request()
            req.source = .forCurrentLocation()
            req.destination = item
            // Itinéraire piéton : le plus proche des pistes cyclables et rues accessibles à une gyroroue
            req.transportType = .walking
            MKDirections(request: req).calculate { resp, err in
                loading = false
                guard let r = resp?.routes.first else {
                    error = "Itinéraire indisponible" + (err.map { " (\($0.localizedDescription))" } ?? "")
                    return
                }
                route = r
                position = .rect(r.polyline.boundingMapRect.insetBy(dx: -800, dy: -800))
            }
        }
    }
}
