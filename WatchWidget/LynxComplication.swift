import SwiftUI
import WidgetKit

/// Complications Apple Watch : batterie et vitesse de la roue sur le cadran.
@main
struct LynxComplicationBundle: WidgetBundle {
    var body: some Widget {
        LynxComplication()
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        var s = WidgetSnapshot()
        s.battery = 76; s.speed = 24; s.wheelName = "Lynx S"; s.connected = true
        return ComplicationEntry(date: Date(), snapshot: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : ComplicationEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = ComplicationEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct LynxComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LynxComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("LynxDash")
        .description("Batterie et vitesse de ta gyroroue.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        let s = entry.snapshot
        switch family {
        case .accessoryCircular:
            Gauge(value: s.battery, in: 0...100) {
                Image(systemName: "bolt.fill")
            } currentValueLabel: {
                Text("\(Int(s.battery))")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(s.battery < 20 ? .red : .green)
        case .accessoryCorner:
            Text("\(Int(s.battery))%")
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: s.battery, in: 0...100) { Text("") }
                        .tint(s.battery < 20 ? .red : .green)
                }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(s.wheelName).font(.headline).lineLimit(1)
                Text(s.connected ? String(format: "%.0f km/h · %.0f %%", s.speed, s.battery)
                                 : String(format: "%.0f %% · %.1f V", s.battery, s.voltage))
                Text(s.ageText).font(.caption2).foregroundStyle(.secondary)
            }
        default:
            Text("\(s.wheelName) \(Int(s.battery)) %")
        }
    }
}
