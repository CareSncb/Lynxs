import Foundation

// MARK: - Autonomie restante apprise sur tes trajets

/// Modèle : consommation (% batterie / km) = a + b × vitesse moyenne + c × froid,
/// ajusté par moindres carrés sur tes derniers trajets, puis mélangé avec la consommation
/// mesurée sur le trajet en cours (de plus en plus fiable à mesure qu'il s'allonge).
enum RangePredictor {
    struct Estimate { var km: Double; var consumption: Double; var basedOn: Int }

    /// Coefficients du modèle (a, b, c) ; nil si pas assez de trajets.
    static func model(wheelName: String?) -> (a: Double, b: Double, c: Double, n: Int)? {
        var trips = TripStore.shared.trips.filter { $0.consumption != nil && $0.distance >= 2 }
        if let w = wheelName {
            let same = trips.filter { $0.wheelName == w }
            if same.count >= 3 { trips = same }
        }
        trips = Array(trips.prefix(40))
        guard trips.count >= 3 else { return nil }

        let rows: [(x1: Double, x2: Double, y: Double)] = trips.map {
            (x1: $0.avgSpeed, x2: max(0, 15 - ($0.ambientTemp ?? 15)), y: $0.consumption ?? 0)
        }
        let useCold = rows.filter { $0.x2 > 0 }.count >= 3
        // Moindres carrés (2 ou 3 paramètres) par équations normales
        if useCold, let s = solve3(rows) { return (s.0, s.1, s.2, trips.count) }
        let n = Double(rows.count)
        let mx = rows.reduce(0) { $0 + $1.x1 } / n
        let my = rows.reduce(0) { $0 + $1.y } / n
        var sxy = 0.0, sxx = 0.0
        for r in rows { sxy += (r.x1 - mx) * (r.y - my); sxx += (r.x1 - mx) * (r.x1 - mx) }
        let b = sxx > 1 ? max(0, sxy / sxx) : 0          // la consommation ne baisse pas avec la vitesse
        return (my - b * mx, b, 0, trips.count)
    }

    private static func solve3(_ rows: [(x1: Double, x2: Double, y: Double)]) -> (Double, Double, Double)? {
        // matrice X'X et X'y avec colonne de 1
        var m = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        for r in rows {
            let x = [1, r.x1, r.x2]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += x[i] * x[j] }
                m[i][3] += x[i] * r.y
            }
        }
        // élimination de Gauss
        for col in 0..<3 {
            guard let pivot = (col..<3).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-9 else { return nil }
            m.swapAt(col, pivot)
            for r in 0..<3 where r != col {
                let f = m[r][col] / m[col][col]
                for k in col..<4 { m[r][k] -= f * m[col][k] }
            }
        }
        let a = m[0][3] / m[0][0], b = m[1][3] / m[1][1], c = m[2][3] / m[2][2]
        guard b >= 0, c >= -0.05 else { return nil }
        return (a, b, max(0, c))
    }

    /// Estimation de l'autonomie restante (en gardant 5 % de réserve).
    static func estimate(battery: Double, wheelName: String?) -> Estimate? {
        let recorder = TripRecorder.shared
        let speed = recorder.averageSpeed > 3 ? recorder.averageSpeed : nil
        let ambient = RideWeather.shared.forecast?.temperature
        var predicted: Double?
        var n = 0
        if let m = model(wheelName: wheelName) {
            let v = speed ?? TripStore.shared.trips.prefix(10).map(\.avgSpeed).reduce(0, +) / Double(max(1, min(10, TripStore.shared.trips.count)))
            predicted = max(0.2, m.a + m.b * v + m.c * max(0, 15 - (ambient ?? 15)))
            n = m.n
        } else if let avg = TripStore.shared.averageConsumption {
            predicted = avg
        }
        // Trajet en cours : poids croissant jusqu'à 100 % à 15 km
        if let live = recorder.liveConsumption, recorder.currentDistance >= 1 {
            let w = min(1, recorder.currentDistance / 15)
            predicted = predicted.map { $0 * (1 - w) + live * w } ?? live
        }
        guard let c = predicted, c > 0 else { return nil }
        return Estimate(km: max(0, battery - 5) / c, consumption: c, basedOn: n)
    }
}
