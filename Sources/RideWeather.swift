import CoreLocation
import SwiftUI

// MARK: - Météo du trajet (Open-Meteo, gratuit, sans clé)

struct RideForecast: Equatable {
    var temperature: Double
    var windGusts: Double          // km/h
    var weatherCode: Int
    var rainProbability: Int       // % maximum sur les 3 prochaines heures
    var rainMM: Double             // cumul sur les 3 prochaines heures
    var minTemperature: Double     // minimum sur les 3 prochaines heures
    var fetched: Date

    var symbol: String {
        switch weatherCode {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// Conseils pour la gyroroue, du plus important au moins important.
    var warnings: [String] {
        var w: [String] = []
        if weatherCode >= 95 { w.append("Orage annoncé : évite de rouler") }
        if minTemperature <= 2 { w.append(String(format: "Risque de verglas (%.0f °C) : sol glissant, batterie moins puissante", minTemperature)) }
        else if minTemperature <= 7 { w.append("Froid : autonomie et puissance réduites, attention au freinage sur sol froid") }
        if rainProbability >= 60 || rainMM >= 1 { w.append("Pluie probable (\(rainProbability) %) : protège la roue, freine plus tôt, attention aux marquages et plaques") }
        if windGusts >= 50 { w.append(String(format: "Rafales à %.0f km/h : prudence à haute vitesse", windGusts)) }
        return w
    }
}

final class RideWeather: ObservableObject {
    static let shared = RideWeather()

    @Published private(set) var forecast: RideForecast?
    @Published private(set) var error: String?
    private var loading = false
    private var notifiedThisConnection = false

    /// Rafraîchit si la dernière prévision a plus de 15 minutes.
    func refreshIfNeeded() {
        if let f = forecast, Date().timeIntervalSince(f.fetched) < 900 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        guard let loc = TripRecorder.shared.lastLocation else {
            TripRecorder.shared.requestOneShotLocation()
            // nouvelle tentative quand la position sera arrivée
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if TripRecorder.shared.lastLocation != nil { self?.refresh() }
            }
            return
        }
        loading = true
        let lat = String(format: "%.3f", loc.coordinate.latitude)
        let lon = String(format: "%.3f", loc.coordinate.longitude)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,wind_gusts_10m"
            + "&hourly=precipitation_probability,precipitation,temperature_2m"
            + "&forecast_hours=3&wind_speed_unit=kmh&timezone=auto"
        guard let url = URL(string: urlString) else { loading = false; return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = json["current"] as? [String: Any],
                      let hourly = json["hourly"] as? [String: Any] else {
                    self.error = err == nil ? "Météo indisponible" : "Pas de réseau pour la météo"
                    return
                }
                func nums(_ key: String) -> [Double] {
                    (hourly[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
                }
                let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue ?? 0
                let f = RideForecast(
                    temperature: temp,
                    windGusts: (current["wind_gusts_10m"] as? NSNumber)?.doubleValue ?? 0,
                    weatherCode: (current["weather_code"] as? NSNumber)?.intValue ?? 0,
                    rainProbability: Int(nums("precipitation_probability").max() ?? 0),
                    rainMM: nums("precipitation").reduce(0, +),
                    minTemperature: nums("temperature_2m").min() ?? temp,
                    fetched: Date())
                self.error = nil
                self.forecast = f
                self.notifyIfNeeded(f)
            }
        }.resume()
    }

    /// À la connexion de la roue : prévient une fois s'il y a un risque.
    func wheelConnected() {
        notifiedThisConnection = false
        refresh()
    }

    private func notifyIfNeeded(_ f: RideForecast) {
        guard Prefs.weatherAlerts, !notifiedThisConnection, BLEManager.shared.state == .connected,
              let first = f.warnings.first else { return }
        notifiedThisConnection = true
        SafetyMonitor.shared.notify(title: "Météo du trajet", body: first)
    }
}

struct WeatherCard: View {
    @ObservedObject private var weather = RideWeather.shared

    var body: some View {
        Group {
            if let f = weather.forecast {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: f.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f °C", f.temperature)).font(.title3.bold())
                            Text("Pluie \(f.rainProbability) % · rafales \(Int(f.windGusts)) km/h")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer()
                        Text("3 h").font(.caption2).foregroundStyle(.secondary)
                    }
                    if f.warnings.isEmpty {
                        Label("Conditions idéales pour rouler", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        ForEach(f.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Theme.gold)
                        }
                    }
                }
                .foregroundStyle(.white)
            } else {
                HStack {
                    Image(systemName: "cloud.sun").foregroundStyle(Theme.gold)
                    Text(weather.error ?? "Météo du trajet…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Actualiser") { weather.refresh() }.font(.caption)
                }
            }
        }
        .glassCard()
        .onAppear { weather.refreshIfNeeded() }
    }
}
