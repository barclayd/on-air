import AppKit
import SwiftUI

private enum SettingsPalette {
    static let background = Color(red: 29 / 255, green: 28 / 255, blue: 27 / 255)
    static let field = Color(red: 20 / 255, green: 19 / 255, blue: 18 / 255)
    static let text = Color(red: 236 / 255, green: 233 / 255, blue: 229 / 255)
    static let secondary = Color(red: 143 / 255, green: 138 / 255, blue: 132 / 255)
    static let muted = Color(red: 111 / 255, green: 107 / 255, blue: 103 / 255)
    static let placeholder = Color(red: 95 / 255, green: 91 / 255, blue: 87 / 255)
    static let error = Color(red: 255 / 255, green: 122 / 255, blue: 104 / 255)
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                DictationNotesSettingsSection(model: model)

                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

                RecordingGlowSettingsSection(preferences: model.glow)

                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

                APIKeySettingsSection(model: model)
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
        }
        .frame(width: 520)
        .foregroundStyle(SettingsPalette.text)
        .background(SettingsPalette.background.ignoresSafeArea())
        .background(SettingsWindowChrome(onClose: { model.dismiss(owner: "settings") }))
        .preferredColorScheme(.dark)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { title }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { title }
            }
        }
        .toolbarBackground(SettingsPalette.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .modifier(SettingsTitleVisibility())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notesSaved)
        .onAppear {
            // An accessory app has no application menu. Expose the standard
            // Settings/Edit/Window commands only while this window is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.present(owner: "settings")
        }
        .onDisappear { model.dismiss(owner: "settings") }
    }

    private var title: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 74 / 255, blue: 58 / 255))
                .frame(width: 6, height: 6).shadow(color: .red.opacity(0.65), radius: 4)
            Text("On Air").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 189 / 255, green: 184 / 255, blue: 178 / 255))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingGlowSettingsSection: View {
    let preferences: GlowPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = ProcessInfo.processInfo.systemUptime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Glow intensity").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int((preferences.intensity * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(SettingsPalette.secondary)
                    .accessibilityHidden(true)
            }
            GlowIntensityControl(preferences: preferences).frame(height: 22)
            HStack {
                Text("Subtle")
                Spacer()
                Text("Bright")
            }
            .font(.system(size: 12)).foregroundStyle(SettingsPalette.muted)
            .accessibilityHidden(true)

            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                let time = reduceMotion ? 0 : now - startedAt
                let frame = GlowFrame(time: time, level: 0.4 + 0.2 * sin(time * 2.4),
                    presence: 1, processing: 0, wavePresence: 0, processingTime: 0,
                    reducedMotion: reduceMotion,
                    intensity: preferences.displayedIntensity(at: now, reducedMotion: reduceMotion))
                Canvas { context, size in
                    // Show the bottom of a miniature display using the actual overlay renderer.
                    let height = size.width * 0.625
                    var canvas = context
                    canvas.translateBy(x: 0, y: size.height - height)
                    GlowRenderer.draw(in: canvas, size: CGSize(width: size.width, height: height), frame: frame)
                }
            }
            .frame(height: 82)
            .background(SettingsPalette.field)
            .overlay(alignment: .topLeading) {
                Text("Preview").font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary.opacity(0.7)).padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
            .allowsHitTesting(false).accessibilityHidden(true)

        }
    }
}

/// Onboarding and Settings edit the same immediately persisted optional notes.
struct DictationNotesSettingsSection: View {
    @Bindable var model: SettingsModel
    var compact = false
    var onFocusChange: (Bool) -> Void = { _ in }
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                heading("Dictation notes")
                if compact {
                    Text("Optional").font(.system(size: 12)).foregroundStyle(Color(red: 111 / 255, green: 107 / 255, blue: 103 / 255))
                }
                Spacer()
                if !compact {
                    Text("Saved").font(.system(size: 12))
                        .foregroundStyle(SettingsPalette.secondary)
                        .opacity(model.notesSaved ? 1 : 0)
                        .accessibilityHidden(!model.notesSaved)
                }
            }
            if !compact { hint("Names, jargon or style On Air should know about.") }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { model.notes }, set: { model.updateNotes($0) }))
                    .font(.system(size: 14)).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .notes)
                    .padding(.horizontal, 9).padding(.vertical, 10)
                    .accessibilityLabel("Dictation notes")
                    .accessibilityIdentifier("settings.notes")
                if model.notes.isEmpty {
                    Text("Use British English and prefer numerals to written-out numbers. I’m a software engineer and often discuss frontend engineering.")
                        .font(.system(size: 14)).lineSpacing(5)
                        .foregroundStyle(compact ? SettingsPalette.secondary.opacity(0.65) : SettingsPalette.placeholder)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(height: compact ? 92 : 113)
            .background(fieldBackground(focused: focus == .notes, error: model.notesError != nil))
            if let error = model.notesError { errorText(error) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notesSaved)
        .onChange(of: focus) { _, value in onFocusChange(value == .notes) }
    }

    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 14, weight: .semibold)) }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 19, alignment: .leading)
    }
    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SettingsPalette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func fieldBackground(focused: Bool, error: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.field)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(error ? SettingsPalette.error.opacity(0.6) : .white.opacity(focused ? 0.22 : 0.08)))
            .background(RoundedRectangle(cornerRadius: compact ? 13 : 10).stroke(error ? SettingsPalette.error.opacity(0.1) : .white.opacity(focused ? 0.05 : 0), lineWidth: compact ? 6 : 8))
    }
}

struct APIKeySettingsSection: View {
    @Bindable var model: SettingsModel
    var compact = false
    @FocusState private var focus: Field?
    private enum Field { case key }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("OpenAI API key")
            if !compact { hint("Used only to transcribe your voice. Stored in your Mac’s Keychain.") }
            if let key = model.maskedKey {
                storedKey(key)
            } else {
                keyEntry
            }
            keyStatus
        }
    }

    private var keyEntry: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Group {
                    if model.showsKey {
                        TextField("OpenAI API key", text: Binding(get: { model.keyDraft }, set: { model.updateKey($0) }),
                                  prompt: Text("sk-…").foregroundStyle(compact ? SettingsPalette.secondary.opacity(0.65) : SettingsPalette.placeholder))
                    } else {
                        SecureField("OpenAI API key", text: Binding(get: { model.keyDraft }, set: { model.updateKey($0) }),
                                    prompt: Text("sk-…").foregroundStyle(compact ? SettingsPalette.secondary.opacity(0.65) : SettingsPalette.placeholder))
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.leading, 14)
                .focused($focus, equals: .key)
                .onSubmit { model.verifyDraft() }
                .disabled(model.verifying)
                .privacySensitive()
                .accessibilityLabel("OpenAI API key")
                .accessibilityIdentifier("settings.api-key")
                Button(model.showsKey ? "Hide" : "Show") {
                    focus = nil
                    model.showsKey.toggle()
                    DispatchQueue.main.async { focus = .key }
                }
                .buttonStyle(QuietSettingsButton())
                .accessibilityLabel(model.showsKey ? "Hide API key" : "Show API key")
            }
            .frame(height: 42)
            .background(fieldBackground(focused: focus == .key, error: model.keyError != nil))

            Button(action: model.verifyDraft) {
                HStack(spacing: 8) {
                    if model.verifying { ProgressView().controlSize(.mini).tint(SettingsPalette.field) }
                    Text(model.verifying ? "Verifying" : "Verify")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16).frame(height: 42)
            }
            .buttonStyle(VerifySettingsButton(cornerRadius: compact ? 21 : 10, verifying: model.verifying))
            .disabled(!model.canVerify)
            .accessibilityIdentifier("settings.verify")
        }
    }

    private func storedKey(_ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 13))
                .foregroundStyle(SettingsPalette.secondary).accessibilityHidden(true)
            Text(key).font(.system(size: 13, design: .monospaced)).tracking(1)
                .foregroundStyle(Color(red: 207 / 255, green: 202 / 255, blue: 196 / 255))
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Stored API key ending in \(key.suffix(4))")
            Spacer(minLength: 0)
            Button("Remove", action: model.removeKey)
                .buttonStyle(QuietSettingsButton(remove: true))
                .accessibilityLabel("Remove API key")
                .accessibilityIdentifier("settings.remove-key")
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 42)
        .background(fieldBackground(focused: false))
    }

    @ViewBuilder private var keyStatus: some View {
        if let error = model.keyError {
            HStack(alignment: .top, spacing: 8) {
                errorText(error).frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                if model.maskedKey != nil {
                    Button("Try again", action: model.retryStoredVerification).buttonStyle(QuietSettingsButton())
                }
            }
        } else {
            HStack(spacing: 7) {
                if model.maskedKey != nil {
                    if model.verifying {
                        ProgressView().controlSize(.mini)
                        Text("Verifying")
                    } else {
                        Circle().fill(model.verified ? Color(red: 95 / 255, green: 211 / 255, blue: 138 / 255) : SettingsPalette.secondary).frame(width: 6, height: 6)
                        Text(model.verified ? "Verified" : "Saved in Keychain")
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(model.verified ? Color(red: 127 / 255, green: 207 / 255, blue: 154 / 255) : SettingsPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .accessibilityIdentifier("settings.key-status")
        }
    }

    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 14, weight: .semibold)) }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 19, alignment: .leading)
    }
    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SettingsPalette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func fieldBackground(focused: Bool, error: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.field)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(error ? Color(red: 1, green: 106 / 255, blue: 88 / 255).opacity(0.6) : .white.opacity(focused ? 0.22 : 0.08)))
            .background(RoundedRectangle(cornerRadius: compact ? 13 : 10).stroke(error ? Color(red: 1, green: 90 / 255, blue: 70 / 255).opacity(0.1) : .white.opacity(focused ? 0.05 : 0), lineWidth: compact ? 6 : 8))
    }
}

private struct QuietSettingsButton: ButtonStyle {
    var remove = false
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: remove ? 13 : 12))
            .foregroundStyle(hovered ? SettingsPalette.text : remove ? Color(red: 163 / 255, green: 158 / 255, blue: 152 / 255) : SettingsPalette.secondary)
            .padding(.horizontal, remove ? 10 : 12).padding(.vertical, remove ? 7 : 8)
            .background(.white.opacity(configuration.isPressed ? 0.08 : remove && hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct VerifySettingsButton: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var verifying = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled || verifying ? SettingsPalette.field : SettingsPalette.muted)
            .background(enabled || verifying ? SettingsPalette.text.opacity(configuration.isPressed ? 0.8 : 1) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct SettingsTitleVisibility: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) }
        else { content }
    }
}

/// Use the native Settings window lifecycle and return to accessory mode on close.
private struct SettingsWindowChrome: NSViewRepresentable {
    let onClose: () -> Void
    func makeNSView(context: Context) -> ChromeView { let view = ChromeView(); view.onClose = onClose; return view }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.onClose = onClose
        // Settings applies its own title after attaching the hosting view.
        DispatchQueue.main.async { [weak view] in view?.configureWindow() }
    }

    final class ChromeView: NSView {
        var onClose: () -> Void = {}
        private weak var configuredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }
        func configureWindow() {
            guard let window else { return }
            if configuredWindow !== window {
                configuredWindow = window
                // Start with the reference's neutral field state. Tab still enters
                // the normal key-view loop; reopening preserves the user's focus.
                DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
            }
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(willClose), name: NSWindow.willCloseNotification, object: window)
            window.identifier = NSUserInterfaceItemIdentifier("on-air.settings")
            window.title = "On Air"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(calibratedRed: 29 / 255, green: 28 / 255, blue: 27 / 255, alpha: 1)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        @objc private func willClose(_ notification: Notification) {
            onClose()
            AppWindowLifecycle.didClose(window)
        }
    }
}
