import SwiftUI
import AVFoundation

private enum SetupStyle {
    static let background = Color(red: 29 / 255, green: 28 / 255, blue: 27 / 255)
    static let card = Color(red: 22 / 255, green: 21 / 255, blue: 20 / 255)
    static let text = Color(red: 236 / 255, green: 233 / 255, blue: 229 / 255)
    static let secondary = Color(red: 161 / 255, green: 155 / 255, blue: 149 / 255)
    static let red = Color(red: 1, green: 74 / 255, blue: 58 / 255)
    static let blue = Color(red: 0.48, green: 0.74, blue: 1)
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SetupStyle.background
            if model.step == .ready {
                ready
            } else {
                VStack(spacing: 24) {
                    header
                    ScrollView {
                        VStack(spacing: 14) {
                            if model.step == .permissions { permissions }
                            else { connection }
                            if let notice = model.notice {
                                Text(notice).font(.system(size: 12)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("setup.notice")
                            }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 40).padding(.top, 58).padding(.bottom, 28)
            }
        }
        .frame(width: 540, height: 540)
        .foregroundStyle(SetupStyle.text)
        .preferredColorScheme(.dark)
        .onChange(of: model.settings.verified) { _, _ in model.reconcile() }
        .onChange(of: model.settings.verifying) { _, _ in model.reconcile() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.step)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(SetupStyle.red).frame(width: 11, height: 11)
                    .shadow(color: SetupStyle.red.opacity(0.65), radius: 8)
                    .accessibilityHidden(true)
                Text("On Air").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
            }
            Text(model.step == .permissions ? "Turn these on and you’re ready to talk." : "One last thing. Connect your OpenAI key.")
                .font(.system(size: 14)).foregroundStyle(SetupStyle.secondary)
        }
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                permissionRow("Microphone", icon: "mic", detail: microphoneDetail,
                              enabled: model.microphone == .authorized,
                              action: model.requestingMicrophone ? "Waiting…" : model.microphone == .notDetermined ? "Allow" : "Open Settings",
                              id: "microphone", disabled: model.requestingMicrophone || model.microphone == .restricted,
                              perform: model.enableMicrophone)
                divider
                permissionRow("Accessibility", icon: "document.on.clipboard", detail: model.accessibility
                              ? "Paste your words wherever you’re typing."
                              : "Notice fn and paste your words.",
                              enabled: model.accessibility, action: "Enable", id: "accessibility", perform: model.enableAccessibility)
                divider
                permissionRow("fn / Globe key", icon: "globe", detail: model.globeConfirmed
                              ? "“Do Nothing” — confirmed by you."
                              : "Keep macOS shortcuts out of the way.",
                              enabled: model.globeConfirmed, action: "Set up", id: "keyboard", perform: model.configureKeyboard)
            }
            .background(SetupStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))

            if model.showsAccessibilityInstructions && !model.accessibility {
                Text("In Privacy & Security → \(SetupPane.accessibility.settingsTitle), turn on On Air. This screen updates automatically when access is granted.")
                    .font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showsKeyboardInstructions {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Keyboard settings, set “Press fn key to” (or “Press Globe key to”) to “Do Nothing”.")
                        .font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
                    Toggle("I’ve set the fn / Globe key to Do Nothing", isOn: Binding(
                        get: { model.globeConfirmed }, set: { model.confirmGlobeSetting($0) }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .accessibilityIdentifier("setup.confirm-keyboard")
                    Text("macOS doesn’t let apps verify this setting automatically.")
                        .font(.system(size: 11)).foregroundStyle(SetupStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("You can change these any time in System Settings.")
                .font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var microphoneDetail: String {
        switch model.microphone {
        case .denied: "Access is off. Enable On Air in Privacy & Security → Microphone."
        case .restricted: "Restricted on this Mac. Ask your administrator for access."
        default: "Hear you only while you hold fn."
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            APIKeySettingsSection(model: model.settings)
            Text("While you hold fn, your audio is sent to OpenAI for transcription. On Air keeps no recording history.")
                .font(.system(size: 12)).lineSpacing(3).foregroundStyle(SetupStyle.secondary)
            Link("Create an OpenAI API key ↗", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.system(size: 13)).tint(SetupStyle.text)
            Text("An OpenAI API account with billing enabled is required. A ChatGPT subscription doesn’t include API usage.")
                .font(.system(size: 12)).lineSpacing(3).foregroundStyle(SetupStyle.secondary)
        }
        .padding(20)
        .background(SetupStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }

    private var footer: some View {
        HStack {
            if model.step == .connection {
                Button("Back", action: model.back).buttonStyle(.plain)
                    .font(.system(size: 13)).accessibilityIdentifier("setup.back")
            } else {
                Text("1 of 2").font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
            }
            Spacer()
            if model.step == .permissions {
                Button("Continue", action: model.continueSetup)
                    .buttonStyle(SetupPrimaryButton()).disabled(!model.permissionsReady)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup.continue")
            } else {
                Text("2 of 2").font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
            }
        }
    }

    private var ready: some View {
        ZStack {
            SetupReadyAnimation(reducedMotion: reduceMotion).accessibilityHidden(true).allowsHitTesting(false)
            VStack(spacing: 14) {
                Text("You’re On Air.").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                HStack(spacing: 10) {
                    Text("Hold")
                    keycap
                    Text("anywhere and start talking.")
                }
                .font(.system(size: 14)).foregroundStyle(SetupStyle.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold the fn or Globe key anywhere and start talking. Release to paste.")
                Text("Release to paste. Find On Air in your menu bar.")
                    .font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
                Button("Done", action: onDone).buttonStyle(SetupPrimaryButton())
                    .keyboardShortcut(.defaultAction).padding(.top, 12)
                    .accessibilityIdentifier("setup.done")
            }
            .offset(y: 48)
        }
    }

    private var keycap: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.83))
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11)).padding(3)
            Text("fn").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(7)
            Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.white).offset(x: -20, y: 23)
        }.frame(width: 40, height: 40).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func permissionRow(_ title: String, icon: String, detail: String, enabled: Bool,
                               action: String, id: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17))
                .foregroundStyle(enabled ? SetupStyle.red : SetupStyle.secondary)
                .frame(width: 34, height: 34)
                .background(enabled ? SetupStyle.red.opacity(0.1) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).lineSpacing(2)
                    .foregroundStyle(SetupStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: perform) {
                if enabled {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SetupStyle.red).frame(width: 40, height: 28)
                        .background(SetupStyle.red.opacity(0.12), in: Capsule())
                } else {
                    Text(action).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).frame(minHeight: 28)
                        .background(.white.opacity(0.075), in: Capsule())
                }
            }
            .buttonStyle(.plain).disabled(disabled)
            .accessibilityLabel(enabled ? "\(title), \(id == "keyboard" ? "confirmed" : "enabled"). Open settings" : "\(action) \(title)")
            .accessibilityIdentifier("setup.\(id)")
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
    }
}

private struct SetupPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? SetupStyle.card : SetupStyle.secondary)
            .padding(.horizontal, 23).padding(.vertical, 10)
            .background(enabled ? SetupStyle.text.opacity(configuration.isPressed ? 0.8 : 1) : .white.opacity(0.06), in: Capsule())
    }
}

/// A short, purely decorative echo of the supplied red → blue → checkmark film.
/// No input monitor, audio engine, or network request participates in the animation.
private struct SetupReadyAnimation: View {
    let reducedMotion: Bool
    @State private var start = Date()
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: finished || reducedMotion)) { timeline in
            Canvas { context, size in
                let time = reducedMotion || finished ? 3 : max(0, timeline.date.timeIntervalSince(start))
                let lift = min(1, max(0, (time - 0.8) / 0.9))
                let check = min(1, max(0, (time - 1.55) / 0.45))
                let tint = time < 0.65 ? SetupStyle.red : SetupStyle.blue
                if time < 1.8 {
                    var glow = context
                    glow.addFilter(.blur(radius: 32))
                    glow.opacity = (1 - lift) * 0.6
                    glow.fill(Path(ellipseIn: CGRect(x: -30, y: size.height - 32, width: size.width + 60, height: 100)), with: .color(tint))
                }
                let y = (size.height - 20) * (1 - lift) + 156 * lift
                let width = size.width * (1 - lift) + 64 * lift
                var line = Path()
                for index in 0...120 {
                    let u = Double(index) / 120
                    let point = CGPoint(x: (size.width - width) / 2 + u * width,
                                        y: y + sin(u * .pi * 8 + time * 8) * pow(sin(u * .pi), 2) * 7 * (1 - check))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var wave = context
                wave.opacity = time < 0.5 ? 0 : 1 - check
                wave.stroke(line, with: .color(SetupStyle.blue), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                var tick = Path()
                tick.move(to: CGPoint(x: size.width / 2 - 22, y: 155))
                tick.addLine(to: CGPoint(x: size.width / 2 - 5, y: 172))
                tick.addLine(to: CGPoint(x: size.width / 2 + 25, y: 138))
                context.opacity = check
                var halo = context
                halo.addFilter(.blur(radius: 12))
                halo.stroke(tick, with: .color(SetupStyle.blue.opacity(0.8)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                context.stroke(tick, with: .color(SetupStyle.blue), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .task {
            start = Date()
            do { try await Task.sleep(for: .seconds(2.2)) } catch { return }
            finished = true
        }
    }
}
