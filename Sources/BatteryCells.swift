import Charts
import SwiftUI

// MARK: - Batterie cellule par cellule (BMS intelligent Leaperkim)

struct CellStats {
    var cells: [Double]          // cellules valides (> 0)
    var min: Double, max: Double, avg: Double
    var minIndex: Int, maxIndex: Int
    var diff: Double { max - min }

    init?(_ raw: [Double], count: Int) {
        let valid = Array(raw.prefix(count))
        guard valid.contains(where: { $0 > 0.5 }) else { return nil }
        cells = valid
        let live = valid.enumerated().filter { $0.element > 0.5 }
        let mn = live.min { $0.element < $1.element }!, mx = live.max { $0.element < $1.element }!
        min = mn.element; max = mx.element; minIndex = mn.offset + 1; maxIndex = mx.offset + 1
        avg = live.map(\.element).reduce(0, +) / Double(live.count)
    }

    /// Écart entre cellules : < 30 mV très bon, < 80 mV correct, au-delà à contrôler.
    var verdict: (String, Color) {
        if diff < 0.03 { return ("Équilibrée", .green) }
        if diff < 0.08 { return ("Correcte", Theme.gold) }
        return ("Déséquilibrée — à contrôler", Theme.ember)
    }
}

struct BatteryCellsView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        List {
            if let packs = ble.data.bmsCells {
                ForEach(Array(packs.enumerated()), id: \.offset) { i, raw in
                    if let s = CellStats(raw, count: ble.cellCount) {
                        packSection(index: i, stats: s, temps: ble.data.bmsTemps?[safe: i] ?? [])
                    }
                }
            } else {
                Section {
                    Text(ble.state == .connected
                         ? "Cette roue n'envoie pas le détail de ses cellules. Il est disponible sur les Leaperkim à BMS intelligent (Lynx, Lynx S, Sherman L…)."
                         : "Connecte la roue pour voir ses cellules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .themedList()
        .navigationTitle("Cellules")
    }

    @ViewBuilder
    private func packSection(index: Int, stats s: CellStats, temps: [Double]) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.verdict.0).font(.headline).foregroundStyle(s.verdict.1)
                    Text(String(format: "Écart %.0f mV · moyenne %.3f V", s.diff * 1000, s.avg))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(String(format: "max %.3f V (n° %d)", s.max, s.maxIndex)).font(.caption.monospacedDigit())
                    Text(String(format: "min %.3f V (n° %d)", s.min, s.minIndex)).font(.caption.monospacedDigit())
                        .foregroundStyle(s.diff >= 0.08 ? Theme.ember : .secondary)
                }
            }
            Chart {
                ForEach(Array(s.cells.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("Cellule", i + 1), y: .value("V", v))
                        .foregroundStyle(i + 1 == s.minIndex && s.diff >= 0.03 ? Theme.ember : Theme.accent)
                }
                RuleMark(y: .value("Moyenne", s.avg)).foregroundStyle(.white.opacity(0.6))
            }
            .chartYScale(domain: max(2.8, s.min - 0.05)...min(4.3, s.max + 0.05))
            .frame(height: 180)
            if temps.contains(where: { $0 != 0 }) {
                Text("Températures : " + temps.filter { $0 != 0 }.map { String(format: "%.0f °C", $0) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Pack \(index + 1)")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
