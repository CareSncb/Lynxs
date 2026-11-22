import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LynxWidgetBundle: WidgetBundle {
    var body: some Widget {
        LynxLiveActivity()
        LynxHomeWidget()
    }
}

struct LynxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LynxActivityAttributes.self) { context in
            LockScreenView(state: context.state, name: context.attributes.wheelName)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text("\(context.state.speed)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(pwmColor(context.state))
                        Text("km/h").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("\(context.state.battery) %", systemImage: "battery.75")
                        if context.state.hasPWM {
                            Text("PWM \(context.state.pwm) %").foregroundStyle(pwmColor(context.state))
                        }
                    }
                    .font(.callout)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.wheelName).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f km", context.state.tripKm))
                        Text("\(context.state.temperature) °C")
                        if context.state.limited || context.state.pending {
                            Image(systemName: context.state.pending ? "hourglass" : "lock.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text("\(context.state.speed)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(pwmColor(context.state))
            } compactTrailing: {
                Text("\(context.state.battery)%")
                    .font(.caption.monospacedDigit())
            } minimal: {
                Text("\(context.state.speed)")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}

private func pwmColor(_ s: LynxActivityAttributes.ContentState) -> Color {
    guard s.hasPWM else { return .white }
    if s.pwm >= 80 { return .red }
    if s.pwm >= 60 { return .orange }
    return .green
}

struct LockScreenView: View {
    let state: LynxActivityAttributes.ContentState
    let name: String

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(state.connected ? "\(state.speed)" : "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pwmColor(state))
                Text("km/h").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.headline).lineLimit(1)
                    if state.limited || state.pending {
                        Image(systemName: state.pending ? "hourglass" : "lock.fill").foregroundStyle(.orange)
                    }
                }
                ProgressView(value: Double(state.battery), total: 100)
                    .tint(state.battery < 20 ? .red : (state.battery < 40 ? .orange : .green))
                HStack {
                    Text("\(state.battery) %")
                    if state.hasPWM { Text("PWM \(state.pwm) %") }
                    Text("\(state.temperature) °C")
                    Spacer()
                    Text(String(format: "%.1f km", state.tripKm))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !state.connected {
                    Text("Roue déconnectée").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding()
        .foregroundStyle(.white)
    }
}

// MARK: - Widget écran d'accueil / écran verrouillé

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        var s = WidgetSnapshot()
        s.wheelName = "Lynx S"; s.battery = 76; s.weekKm = 84; s.todayKm = 12
        return SnapshotEntry(date: Date(), snapshot: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct LynxHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LynxHomeWidget", provider: SnapshotProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Ma roue")
        .description("Batterie de ta dernière roue et kilomètres de la semaine.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

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
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(s.wheelName).font(.headline).lineLimit(1)
                Text("\(Int(s.battery)) % · \(String(format: "%.1f V", s.voltage))")
                Text(String(format: "%.0f km cette semaine", s.weekKm)).font(.caption)
            }
        case .accessoryInline:
            Text("\(s.wheelName) \(Int(s.battery)) %")
        case .systemMedium:
            HStack(spacing: 16) {
                batteryRing(s)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.wheelName).font(.headline).lineLimit(1)
                    Text(String(format: "%.1f V", s.voltage)).foregroundStyle(.secondary)
                    Text(String(format: "Aujourd'hui : %.1f km", s.todayKm)).font(.caption)
                    Text(String(format: "7 jours : %.0f km", s.weekKm)).font(.caption)
                    Text(s.ageText).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .foregroundStyle(.white)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.wheelName).font(.caption.bold()).lineLimit(1)
                    if s.limited { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                }
                batteryRing(s)
                Text(String(format: "%.0f km / 7 j", s.weekKm)).font(.caption2)
                Text(s.ageText).font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }

    private func batteryRing(_ s: WidgetSnapshot) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: s.battery / 100)
                .stroke(s.battery < 20 ? Color.red : (s.battery < 40 ? .orange : .green),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(s.battery))%").font(.headline.monospacedDigit())
        }
        .frame(width: 64, height: 64)
    }
}
