import AppKit
import SwiftUI

private enum SettingsPalette {
    static let background = Color(red: 29 / 255, green: 28 / 255, blue: 27 / 255)
    static let field = Color(red: 20 / 255, green: 19 / 255, blue: 18 / 255)
    static let text = Color(red: 236 / 255, green: 233 / 255, blue: 229 / 255)
    static let secondary = Color(red: 143 / 255, green: 138 / 255, blue: 132 / 255)
    static let error = Color(red: 255 / 255, green: 122 / 255, blue: 104 / 255)
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    var openSetup: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                DictationNotesSettingsSection(model: model)

                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

                APIKeySettingsSection(model: model)
                Button("Set up permissions and fn key…", action: openSetup)
                    .buttonStyle(.link).font(.system(size: 12))
            }
            .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 32)
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

/// Both onboarding and Settings edit the same immediately persisted preference.
struct DictationNotesSettingsSection: View {
    @Bindable var model: SettingsModel
    var compact = false
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                heading("Dictation notes")
                if compact {
                    Text("Optional").font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
                }
                Spacer()
                Text("Saved").font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondary)
                    .opacity(model.notesSaved ? 1 : 0)
                    .accessibilityHidden(!model.notesSaved)
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
                    Text("Use British spelling. Write HubSpot, not Hubspot.")
                        .font(.system(size: 14)).lineSpacing(5)
                        .foregroundStyle(SettingsPalette.secondary.opacity(0.65))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(height: compact ? 90 : 112)
            .background(fieldBackground(focused: focus == .notes, error: model.notesError != nil))
            if let error = model.notesError { errorText(error) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notesSaved)
    }

    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 14, weight: .semibold)) }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SettingsPalette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func fieldBackground(focused: Bool, error: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.field)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(error ? SettingsPalette.error.opacity(0.6) : .white.opacity(focused ? 0.22 : 0.08)))
            .background(RoundedRectangle(cornerRadius: 13).stroke(error ? SettingsPalette.error.opacity(0.1) : .white.opacity(focused ? 0.05 : 0), lineWidth: 6))
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
                                  prompt: Text("sk-…").foregroundStyle(SettingsPalette.secondary.opacity(0.65)))
                    } else {
                        SecureField("OpenAI API key", text: Binding(get: { model.keyDraft }, set: { model.updateKey($0) }),
                                    prompt: Text("sk-…").foregroundStyle(SettingsPalette.secondary.opacity(0.65)))
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
                HStack(spacing: 7) {
                    if model.verifying { ProgressView().controlSize(.mini).tint(SettingsPalette.field) }
                    Text(model.verifying ? "Verifying" : "Verify")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16).frame(height: 42)
            }
            .buttonStyle(VerifySettingsButton(cornerRadius: compact ? 21 : 10))
            .disabled(!model.canVerify)
            .accessibilityIdentifier("settings.verify")
        }
    }

    private func storedKey(_ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 13))
                .foregroundStyle(SettingsPalette.secondary).accessibilityHidden(true)
            Text(key).font(.system(size: 13, design: .monospaced)).tracking(1)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Stored API key ending in \(key.suffix(4))")
            Spacer(minLength: 0)
            Button("Remove", action: model.removeKey)
                .buttonStyle(QuietSettingsButton())
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
                        Circle().fill(model.verified ? Color.green : SettingsPalette.secondary).frame(width: 6, height: 6)
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
    }
    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SettingsPalette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func fieldBackground(focused: Bool, error: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.field)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(error ? SettingsPalette.error.opacity(0.6) : .white.opacity(focused ? 0.22 : 0.08)))
            .background(RoundedRectangle(cornerRadius: 13).stroke(error ? SettingsPalette.error.opacity(0.1) : .white.opacity(focused ? 0.05 : 0), lineWidth: 6))
    }
}

private struct QuietSettingsButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private struct VerifySettingsButton: ButtonStyle {
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? SettingsPalette.field : SettingsPalette.secondary.opacity(0.7))
            .background(enabled ? SettingsPalette.text.opacity(configuration.isPressed ? 0.8 : 1) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }
        func configureWindow() {
            guard let window else { return }
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
