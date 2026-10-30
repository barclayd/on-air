import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OnAirWidgets: WidgetBundle {
    var body: some Widget { OnAirLiveActivity(); OnAirControl() }
}

struct OnAirControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.danbarclay.onair.ios.dictate") {
            ControlWidgetButton(action: DictateWithOnAir()) { Label("Dictate", systemImage: "waveform") }
        }.displayName("On Air").description("Start or finish dictation")
    }
}

struct OnAirLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnAirActivity.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("On Air", systemImage: "waveform").font(.headline)
                    Spacer()
                    if !context.isStale { timer(context.state) }
                }
                Text(context.isStale ? "Open On Air to check your session" : context.state.label)
                    .font(.subheadline)
                controls(context)
            }.padding().activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(URL(string: "onair://session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("On Air", systemImage: "waveform").font(.headline).padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale { timer(context.state).padding(.top, 8) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        Text(context.isStale ? "Open On Air to check your session" : context.state.label).font(.subheadline)
                        controls(context)
                    }.padding(.vertical, 8)
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "exclamationmark.circle" : "waveform")
                    .foregroundStyle(!context.isStale && context.state.phase == "recording" ? .red : .white)
            } compactTrailing: {
                if context.isStale { Text("Check").font(.caption) }
                else if context.state.phase == "recording", let date = context.state.startedAt {
                    Text(date, style: .timer).monospacedDigit().frame(maxWidth: 44)
                } else { Text(context.state.phase == "finishing" ? "…" : "On").font(.caption) }
            } minimal: {
                Image(systemName: context.isStale ? "exclamationmark.circle" : "waveform")
                    .foregroundStyle(!context.isStale && context.state.phase == "recording" ? .red : .white)
            }.widgetURL(URL(string: "onair://session"))
        }
    }

    @ViewBuilder private func timer(_ state: OnAirActivity.ContentState) -> some View {
        if state.phase == "recording", let date = state.startedAt {
            Text(date, style: .timer).monospacedDigit().foregroundStyle(.secondary)
        } else if state.phase == "ready", let until = state.readyUntil {
            Text(timerInterval: Date()...max(Date(), until), countsDown: true).monospacedDigit().foregroundStyle(.secondary)
        }
    }
    private func controls(_ context: ActivityViewContext<OnAirActivity>) -> some View {
        HStack {
            if context.state.phase == "recording" || context.state.phase == "finishing" {
                Button(intent: intent("cancel", context)) { Label("Cancel", systemImage: "xmark") }
                if context.state.phase == "recording" {
                    Button(intent: intent("finish", context)) { Label("Finish", systemImage: "checkmark") }
                        .tint(.red)
                }
            }
            Spacer(minLength: 0)
            Button(intent: intent("off", context)) { Label("Turn off", systemImage: "power") }
        }.buttonStyle(.bordered)
    }
    private func intent(_ action: String, _ context: ActivityViewContext<OnAirActivity>) -> OnAirSessionAction {
        OnAirSessionAction(sessionID: context.attributes.sessionID, turnID: context.state.turnID, action: action)
    }
}
