import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LynxWidgetBundle: WidgetBundle {
    var body: some Widget {
        LynxLiveActivity()
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
