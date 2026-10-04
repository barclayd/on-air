import AppKit
import SwiftUI
import AVFoundation

private enum SetupStyle {
    static let background = Color(red: 29 / 255, green: 28 / 255, blue: 27 / 255)
    static let card = Color(red: 22 / 255, green: 21 / 255, blue: 20 / 255)
    static let field = Color(red: 20 / 255, green: 19 / 255, blue: 18 / 255)
    static let text = Color(red: 236 / 255, green: 233 / 255, blue: 229 / 255)
    static let secondary = Color(red: 143 / 255, green: 138 / 255, blue: 132 / 255)
    static let muted = Color(red: 111 / 255, green: 107 / 255, blue: 103 / 255)
    static let red = Color(red: 1, green: 74 / 255, blue: 58 / 255)
    static let error = Color(red: 1, green: 122 / 255, blue: 104 / 255)
    static let green = Color(red: 127 / 255, green: 207 / 255, blue: 154 / 255)
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .top) {
            SetupStyle.background
            if model.step == .ready {
                SetupCompletionView(reducedMotion: reduceMotion, onDone: onDone)
            }
            VStack(spacing: 28) {
                if model.step != .ready {
                    header.transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -10)))
                }
                ZStack(alignment: .top) {
                    if model.step == .permissions {
                        permissions.transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -10)))
                    }
                    if model.step == .connection {
                        connection.transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 12)),
                            removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -10))))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 44).padding(.top, 60).padding(.bottom, 32)
            .allowsHitTesting(model.step != .ready)
            .accessibilityHidden(model.step == .ready)
        }
        // The HTML's 540 × 500 includes its 52-point title-bar region.
        .frame(width: 540, height: 500)
        .ignoresSafeArea()
        .foregroundStyle(SetupStyle.text)
        .preferredColorScheme(.dark)
        .onChange(of: model.settings.verified) { _, _ in model.reconcile() }
        .onChange(of: model.settings.verifying) { _, _ in model.reconcile() }
        .onChange(of: model.settings.notesError) { _, _ in model.reconcile() }
        .animation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.5), value: model.step)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(SetupStyle.red).frame(width: 11, height: 11)
                    .opacity(reduceMotion || pulse ? 1 : 0.82)
                    .shadow(color: SetupStyle.red.opacity(pulse ? 0.8 : 0.45), radius: reduceMotion ? 6 : pulse ? 12 : 4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = !reduceMotion }
                    .onChange(of: reduceMotion) { _, reduced in pulse = !reduced }
                    .accessibilityHidden(true)
                Text("On Air").font(.system(size: 26, weight: .semibold)).tracking(-0.52)
            }
            .frame(height: 31)
            ZStack {
                if model.step == .permissions {
                    Text("Turn these on and you’re ready to talk.").transition(.opacity)
                } else {
                    Text("Add your OpenAI key to start transcribing.").transition(.opacity)
                }
            }
            .font(.system(size: 14)).foregroundStyle(SetupStyle.secondary).frame(height: 17)
        }
    }

    private var permissions: some View {
        VStack(spacing: 24) {
            VStack(spacing: 0) {
                permissionRow("Microphone", icon: .microphone, detail: microphoneDetail,
                              enabled: model.microphone == .authorized, id: "microphone",
                              disabled: model.requestingMicrophone || model.microphone == .restricted,
                              perform: model.enableMicrophone)
                divider
                permissionRow("Accessibility", icon: .clipboard,
                              detail: "Paste your words wherever you’re typing.",
                              enabled: model.accessibility, id: "accessibility", perform: model.enableAccessibility)
            }
            .background(SetupStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
            Text("You can change these any time in System Settings.")
                .font(.system(size: 12)).foregroundStyle(SetupStyle.muted)
            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(SetupStyle.error)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("setup.notice")
            } else if model.showsAccessibilityInstructions && !model.accessibility {
                Text("In Privacy & Security → \(SetupPane.accessibility.settingsTitle), turn on On Air. This screen updates automatically.")
                    .font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var microphoneDetail: String {
        switch model.microphone {
        case .denied: "Enable On Air in Microphone settings."
        case .restricted: "Restricted on this Mac. Ask your administrator."
        default: model.requestingMicrophone ? "Waiting for permission…" : "Hear you while you hold fn."
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 22) {
            DictationNotesSettingsSection(model: model.settings, compact: true, onFocusChange: model.notesFocusChanged)
            SetupKeySection(model: model)
        }
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func permissionRow(_ title: String, icon: SetupPermissionIcon.Kind, detail: String, enabled: Bool,
                               id: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { enabled }, set: { _ in perform() })) {
            HStack(spacing: 14) {
                SetupPermissionIcon(kind: icon)
                    .stroke(style: StrokeStyle(lineWidth: 1.275, lineCap: .round, lineJoin: .round))
                    .frame(width: 17, height: 17)
                    .foregroundStyle(enabled ? Color(red: 1, green: 122 / 255, blue: 102 / 255) : Color(red: 163 / 255, green: 158 / 255, blue: 152 / 255))
                    .frame(width: 34, height: 34)
                    .background(enabled ? SetupStyle.red.opacity(0.14) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).frame(minHeight: 17, alignment: .leading)
                    Text(detail).font(.system(size: 12.5)).lineSpacing(2)
                        .foregroundStyle(SetupStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 17.5, alignment: .leading)
                }
            }
        }
        .toggleStyle(SetupPermissionSwitch()).disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityHint("Open System Settings to change this permission.")
        .accessibilityIdentifier("setup.\(id)")
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 16)
    }
}

/// The reference's 24-unit SVG strokes, kept as resolution-independent paths.
private struct SetupPermissionIcon: Shape {
    enum Kind { case microphone, clipboard }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .microphone:
            path.addRoundedRect(in: CGRect(x: 9, y: 3, width: 6, height: 11), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 5, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 18), control1: CGPoint(x: 5, y: 14.866), control2: CGPoint(x: 8.134, y: 18))
            path.addCurve(to: CGPoint(x: 19, y: 11), control1: CGPoint(x: 15.866, y: 18), control2: CGPoint(x: 19, y: 14.866))
            path.move(to: CGPoint(x: 12, y: 18)); path.addLine(to: CGPoint(x: 12, y: 21))
        case .clipboard:
            path.addRoundedRect(in: CGRect(x: 8, y: 3, width: 8, height: 4), cornerSize: CGSize(width: 1.2, height: 1.2))
            path.move(to: CGPoint(x: 16, y: 5)); path.addLine(to: CGPoint(x: 17.5, y: 5))
            path.addQuadCurve(to: CGPoint(x: 19, y: 6.5), control: CGPoint(x: 19, y: 5))
            path.addLine(to: CGPoint(x: 19, y: 19.5))
            path.addQuadCurve(to: CGPoint(x: 17.5, y: 21), control: CGPoint(x: 19, y: 21))
            path.addLine(to: CGPoint(x: 6.5, y: 21))
            path.addQuadCurve(to: CGPoint(x: 5, y: 19.5), control: CGPoint(x: 5, y: 21))
            path.addLine(to: CGPoint(x: 5, y: 6.5))
            path.addQuadCurve(to: CGPoint(x: 6.5, y: 5), control: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 8, y: 5))
            path.move(to: CGPoint(x: 9, y: 12)); path.addLine(to: CGPoint(x: 15, y: 12))
            path.move(to: CGPoint(x: 9, y: 16)); path.addLine(to: CGPoint(x: 13, y: 16))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

/// A controlled switch: its value always comes from macOS, never from the click.
private struct SetupPermissionSwitch: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 14) {
                configuration.label
                Spacer(minLength: 0)
                Capsule().fill(configuration.isOn ? SetupStyle.red : .white.opacity(0.12))
                    .frame(width: 40, height: 24)
                    .shadow(color: configuration.isOn ? SetupStyle.red.opacity(0.45) : .clear, radius: 7)
                    .overlay(alignment: .leading) {
                        Circle().fill(Color(red: 244 / 255, green: 242 / 255, blue: 239 / 255))
                            .frame(width: 20, height: 20).shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .offset(x: configuration.isOn ? 18 : 2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .timingCurve(0.3, 0.7, 0.4, 1, duration: 0.25), value: configuration.isOn)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
}

private struct SetupKeySection: View {
    @Bindable var model: OnboardingModel
    @FocusState private var keyFocused: Bool
    @State private var showsHelp = false
    private var settings: SettingsModel { model.settings }
    private var accepted: Bool { settings.verified && settings.maskedKey != nil }
    private var advancing: Bool { model.ready && model.verificationRequested && !model.editingNotes }
    private var buttonTitle: String {
        if settings.verifying { return "Verifying" }
        if advancing { return "Verified" }
        if accepted { return "Continue" }
        return settings.maskedKey == nil ? "Verify" : "Try again"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("OpenAI API key") { showsHelp = true }
                .font(.system(size: 14, weight: .semibold)).buttonStyle(.plain)
                .help("About API keys and billing")
                .popover(isPresented: $showsHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect your OpenAI account").font(.headline)
                        Text("Your key stays in Keychain. Audio is sent to OpenAI for transcription. API usage is billed separately from ChatGPT.")
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Create an OpenAI API key ↗", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    }.font(.system(size: 12)).padding(20).frame(width: 310)
                }
            HStack(spacing: 10) {
                keyField
                Button(action: verify) {
                    HStack(spacing: 8) {
                        if settings.verifying { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                        Text(buttonTitle)
                    }
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 22).frame(height: 40)
                }
                .buttonStyle(SetupKeyButton(verified: advancing))
                .disabled(settings.verifying || advancing || (accepted ? settings.notesError != nil : settings.maskedKey == nil && !settings.canVerify))
                .accessibilityIdentifier("settings.verify")
            }
            Text(settings.keyError ?? "Stored in your Mac’s Keychain. Used only to transcribe your voice.")
                .font(.system(size: 12)).foregroundStyle(settings.keyError == nil ? SetupStyle.muted : SetupStyle.error)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings.key-status")
        }
    }

    private func verify() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.notesFocusChanged(false)
        model.verifyConnection()
    }

    private var keyField: some View {
        HStack(spacing: 0) {
            if let maskedKey = settings.maskedKey {
                Text(maskedKey).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                    .accessibilityLabel("Stored API key ending in \(maskedKey.suffix(4))")
                    .padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove", action: settings.removeKey)
                    .accessibilityIdentifier("settings.remove-key")
            } else {
                Group {
                    if settings.showsKey {
                        TextField("OpenAI API key", text: Binding(get: { settings.keyDraft }, set: { settings.updateKey($0) }), prompt: Text("sk-…").foregroundStyle(SetupStyle.muted))
                    } else {
                        SecureField("OpenAI API key", text: Binding(get: { settings.keyDraft }, set: { settings.updateKey($0) }), prompt: Text("sk-…").foregroundStyle(SetupStyle.muted))
                    }
                }
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).padding(.leading, 14)
                .focused($keyFocused).disabled(settings.verifying).privacySensitive()
                .onSubmit(verify).accessibilityIdentifier("settings.api-key")
                Button(settings.showsKey ? "Hide" : "Show") { settings.showsKey.toggle(); keyFocused = true }
                    .accessibilityLabel(settings.showsKey ? "Hide API key" : "Show API key")
            }
        }
        .buttonStyle(SetupFieldButton())
        .frame(height: 42)
        .background(SetupStyle.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
        .background(RoundedRectangle(cornerRadius: 14).stroke(settings.keyError != nil ? SetupStyle.error.opacity(0.1) : .white.opacity(keyFocused && !accepted ? 0.05 : 0), lineWidth: 8))
    }

    private var border: Color {
        if settings.keyError != nil { return SetupStyle.error.opacity(0.6) }
        if accepted { return SetupStyle.green.opacity(0.45) }
        return .white.opacity(keyFocused ? 0.22 : 0.08)
    }
}

private struct SetupFieldButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(SetupStyle.secondary)
            .padding(.horizontal, 12).frame(height: 40)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct SetupKeyButton: ButtonStyle {
    var verified = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(verified ? SetupStyle.green : enabled ? SetupStyle.field : SetupStyle.muted)
            .background(verified ? SetupStyle.green.opacity(0.16) : enabled ? SetupStyle.text.opacity(configuration.isPressed ? 0.8 : 1) : .white.opacity(0.06), in: Capsule())
    }
}

private struct SetupCompletionView: View {
    let reducedMotion: Bool
    let onDone: () -> Void
    @State private var start = Date()
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: finished || reducedMotion)) { timeline in
            let time = reducedMotion || finished ? 6 : max(0, timeline.date.timeIntervalSince(start))
            let reveal = SetupCompletionRenderer.progress(time, 4.8, 5.5)
            ZStack(alignment: .top) {
                Canvas { context, size in SetupCompletionRenderer.draw(in: &context, size: size, time: time) }
                    .accessibilityHidden(true).allowsHitTesting(false)
                VStack(spacing: 10) {
                    Text("You’re On Air.").font(.system(size: 26, weight: .semibold)).tracking(-0.52).frame(height: 31)
                    HStack(spacing: 10) {
                        Text("Hold")
                        keycap
                        Text("anywhere and start talking.")
                    }
                    .font(.system(size: 14)).foregroundStyle(SetupStyle.secondary).padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Hold the fn or Globe key anywhere and start talking. Release to paste.")
                    Button(action: onDone) {
                        Text("Done").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 22).padding(.vertical, 9)
                    }
                        .buttonStyle(SetupKeyButton()).padding(.top, 18)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup.done")
                }
                .padding(.top, 262 + (reducedMotion ? 0 : 10 * (1 - reveal)))
                .opacity(reveal).allowsHitTesting(reveal > 0.99).accessibilityHidden(reveal < 0.99)
            }
        }
        .task {
            start = Date()
            do { try await Task.sleep(for: .seconds(5.6)) } catch { return }
            finished = true
        }
    }

    private var keycap: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 9).fill(Color(red: 217 / 255, green: 214 / 255, blue: 207 / 255))
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)).padding(3)
            Text("fn").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.top, 6).padding(.trailing, 8)
            Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.white).offset(x: -22, y: 22)
        }.frame(width: 40, height: 40).shadow(color: .black.opacity(0.45), radius: 6, y: 4)
    }
}

/// Port of the supplied HTML canvas: red glow → travelling blue line → rising tick.
/// Uses elapsed time rather than synthetic voice input; stops drawing when settled.
private enum SetupCompletionRenderer {
    static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(1, max(0, (t - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let width = size.width, height = size.height
        let mix = progress(t, 1.9, 2.7)
        let alpha = progress(t, 0.3, 0.9) * (1 - progress(t, 2.6, 3.5))
        let syllable = pow(max(0, sin(t * 8.5 + 2 * sin(t * 1.7))), 0.6)
        let dynamics = 0.55 + 0.45 * sin(t * 1.9 + sin(t * 0.7) * 3)
        let level = min(1, syllable * dynamics * 0.9) * (1 - progress(t, 1.7, 2)) * progress(t, 0.5, 0.9)
        let center = 0.5 + 0.3 * sin(max(0, t - 1.9) * 1.8) * (1 - progress(t, 3.3, 4))
        if alpha > 0.003 {
            let pulse = 0.5 + 0.5 * sin(t * 1.7)
            let h = ((0.16 + level * 0.18) * (1 - mix) + 0.09 * mix) * height * (0.94 + 0.08 * pulse * (1 - mix))
            let strength = alpha * (0.7 + 0.3 * pulse) * (0.8 + 0.2 * level)
            let color = Color(red: (240 - 170 * mix) / 255, green: (40 + 100 * mix) / 255, blue: (34 + 221 * mix) / 255)
            let warm = Color(red: (255 - 125 * mix) / 255, green: (104 + 76 * mix) / 255, blue: (72 + 183 * mix) / 255)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: height))
            for i in 0...40 {
                let u = Double(i) / 40
                let hump = exp(-pow(u - 0.5, 2) / 0.09)
                let variation = sin(u * 6 + t * 1.3) * 0.6 + sin(u * 11 - t * 2.1) * 0.4
                let red = h * (0.55 + 0.45 * hump) + h * 0.16 * (0.3 + level) * variation
                let envelope = exp(-pow((u - center) / 0.2, 2))
                path.addLine(to: CGPoint(x: u * width, y: height - (red * (1 - mix) + h * (0.6 + 0.9 * envelope) * mix)))
            }
            path.addLine(to: CGPoint(x: width, y: height)); path.closeSubpath()
            var glow = context
            glow.addFilter(.blur(radius: 40))
            let gradient = Gradient(stops: [.init(color: warm.opacity(0.7 * strength), location: 0),
                .init(color: color.opacity(0.42 * strength), location: 0.3),
                .init(color: color.opacity(0.12 * strength), location: 0.7), .init(color: .clear, location: 1)])
            glow.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: height), endPoint: CGPoint(x: 0, y: height - h * 2.2)))
            glow.fill(Path(CGRect(x: 0, y: height - 8, width: width, height: 8)), with: .color(warm.opacity(0.45 * strength)))
        }
        let lineAlpha = progress(t, 2.2, 2.8)
        guard lineAlpha >= 0.01 else { return }
        let move = progress(t, 3.3, 4.3), morph = progress(t, 4.25, 4.95)
        let yCenter = 52 + (height - 52) * 0.42 - 40
        let y = height * 0.94 + (yCenter - height * 0.94) * move
        let span = width + (64 - width) * move
        let waveCenter = width * center
        let lineCenter = waveCenter + (width / 2 - waveCenter) * move
        let amplitude = 14 * (1 - move), spread = 0.18 * width * (1 - 0.7 * move)
        let tick = [CGPoint(x: width / 2 - 27, y: yCenter + 1), CGPoint(x: width / 2 - 9, y: yCenter + 19), CGPoint(x: width / 2 + 27, y: yCenter - 19)]
        let first = hypot(18.0, 18.0), second = hypot(36.0, 38.0)
        var line = Path()
        for i in 0..<140 {
            let u = Double(i) / 139
            let x = lineCenter + (u - 0.5) * span
            let envelope = exp(-pow((x - waveCenter) / spread, 2))
            let waveY = y + envelope * amplitude * (sin(x * 0.032 - t * 9) * 0.7 + sin(x * 0.032 * 1.7 - t * 12) * 0.3)
            let distance = u * (first + second)
            let segment = distance <= first ? 0 : 1
            let f = distance <= first ? distance / first : (distance - first) / second
            let tx = tick[segment].x + (tick[segment + 1].x - tick[segment].x) * f
            let ty = tick[segment].y + (tick[segment + 1].y - tick[segment].y) * f
            let point = CGPoint(x: x + (tx - x) * morph, y: waveY + (ty - waveY) * morph)
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        let opacity = (0.12 + 0.88 * move) * lineAlpha
        let position = center + (0.5 - center) * move
        let blue = Color(red: 190 / 255, green: 215 / 255, blue: 1)
        let light = Color(red: 225 / 255, green: 238 / 255, blue: 1)
        let gradient = Gradient(stops: [.init(color: blue.opacity(opacity), location: 0),
            .init(color: blue.opacity(opacity), location: max(0, position - 0.28)),
            .init(color: light.opacity(0.95 * lineAlpha), location: position),
            .init(color: blue.opacity(opacity), location: min(1, position + 0.28)), .init(color: blue.opacity(opacity), location: 1)])
        context.addFilter(.shadow(color: Color(red: 90 / 255, green: 150 / 255, blue: 1).opacity(0.9 * lineAlpha), radius: 12 + 10 * morph))
        let shading: GraphicsContext.Shading = move > 0.98 ? .color(light.opacity(lineAlpha)) : .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: width, y: 0))
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.6 + 1.6 * morph, lineCap: .round, lineJoin: .round))
    }
}
