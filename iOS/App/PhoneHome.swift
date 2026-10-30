import AVFAudio
import SwiftUI
import OnAirCore
import OnAirSession

struct PhoneHome: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var showSetup = false
    @AppStorage("keepReady") private var keepReady = false
    @State private var practice = ""
    @State private var hasKey = false
    private var active: Bool { [.starting, .recording, .finishing].contains(coordinator.state.phase) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 8) {
                        Circle().fill(coordinator.state.phase == .recording ? .red : .secondary).frame(width: 7, height: 7)
                        Text("IPHONE BETA").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A little less typing.").font(.system(size: 37, weight: .semibold, design: .serif))
                        Text("Your voice, wherever you write.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    if active {
                        DictationPanel(phase: coordinator.state.phase, level: coordinator.state.level,
                            startedAt: coordinator.state.startedAt,
                            cancel: { coordinator.cancel() }, finish: { coordinator.finish() })
                            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 26))
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Label(coordinator.state.phase.label, systemImage: "waveform")
                                .font(.headline)
                            Text(coordinator.state.phase == .ready
                                 ? "Return to your app, switch to the On Air keyboard and tap the microphone."
                                 : "Start here, or enable a five-minute keyboard session to dictate across your apps.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button {
                                if hasKey { Task { await coordinator.startDictation() } } else { showSetup = true }
                            } label: {
                                Label(hasKey ? "Start dictation" : "Set up On Air", systemImage: "mic.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).tint(.primary)
                            if hasKey {
                                if coordinator.state.phase == .ready {
                                    Button("Turn microphone off", role: .destructive) { coordinator.turnOff() }
                                } else {
                                    Button("Enable keyboard for 5 minutes") { Task { await coordinator.activateReady() } }
                                        .accessibilityHint("Keeps the microphone active and discards audio between dictations")
                                }
                            }
                        }.padding(22).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 26))
                    }
                    if let issue = coordinator.state.issue {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                            if coordinator.state.canRetry { Button("Retry transcription") { coordinator.retry() } }
                        }.font(.subheadline)
                    }
                    if let result = coordinator.transcript {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your words").font(.headline)
                            Text(result.text).textSelection(.enabled)
                            Button("Copy transcript", systemImage: "doc.on.doc") { coordinator.copyTranscript() }
                            Text("Available for five minutes. Copy only when you want it on your clipboard.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Try your keyboard").font(.headline)
                        TextField("Tap here, then hold the globe key", text: $practice, axis: .vertical)
                            .lineLimit(3...6).padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("practiceField")
                        Text("Choose On Air from the keyboard list. Secure fields and some apps use Apple’s keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
            .navigationTitle("On Air").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Setup", systemImage: "slider.horizontal.3") { showSetup = true } } }
            .sheet(isPresented: $showSetup, onDismiss: refreshKey) { PhoneSetup(coordinator: coordinator) }
            .onAppear(perform: refreshKey)
        }
    }
    private func refreshKey() { hasKey = (try? IPhoneKeychain.load()) != nil }
}

struct PhoneSetup: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage("keepReady") private var keepReady = false
    @AppStorage(DictationPreferences.notesKey) private var notes = ""
    @State private var key = ""
    @State private var saved = false
    @State private var status: String?
    @State private var verification: Task<Void, Never>?
    @State private var verifying = false
    @State private var verificationID = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(saved ? "Replace OpenAI key" : "OpenAI API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("apiKeyField")
                    Button(verifying ? "Checking connection…" : "Verify and save key", action: verify)
                        .disabled(verifying || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    if saved {
                        Button("Remove saved key", role: .destructive) {
                            verificationID = UUID(); verification?.cancel(); verifying = false
                            coordinator.turnOff()
                            do { try IPhoneKeychain.remove(); saved = false; status = "Key removed" }
                            catch { status = "Could not remove the key. Try again." }
                        }
                    }
                } header: { Text("1 · Your OpenAI key") } footer: {
                    Text("Stored in this iPhone’s Keychain. Only the On Air app reads it; the keyboard never receives your key. Dictation uses your OpenAI account and API billing.")
                }
                Section {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → On Air")
                    Text("Then select On Air and enable Allow Full Access.")
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                } header: { Text("2 · Enable the keyboard") } footer: {
                    Text("Full Access lets the keyboard send recording commands to On Air. Ordinary typing works without it. Typed text and surrounding field content are never sent to OpenAI.")
                }
                Section {
                    Toggle("Stay ready after dictation", isOn: $keepReady)
                    TextField("Names, vocabulary and spelling preferences", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: notes) { _, value in if value.count > DictationPreferences.notesLimit { notes = String(value.prefix(DictationPreferences.notesLimit)) } }
                } header: { Text("3 · Make it yours") } footer: {
                    Text("Ready mode keeps the microphone active for up to five minutes. Audio between dictations is discarded. Turn it off in On Air or its Live Activity. Changes apply to the next session.")
                }
                Section("Shortcuts and Control Centre") {
                    Text("Add On Air’s Dictate control in Control Centre, or choose “Dictate with On Air” in Shortcuts or your Action Button settings. Tap again to finish. Allow Live Activities in Settings for background recording.")
                }
                Section("Privacy") {
                    Text("Audio from active dictations is sent directly to OpenAI for transcription. Failed audio stays only in memory for up to five minutes so you can retry. Completed text is briefly saved in a protected, backup-excluded shared file for keyboard delivery; it expires after five minutes and is deleted when consumed or when the app next runs after expiry. No audio files or dictation history are saved. No analytics are collected.")
                    Link("OpenAI data controls", destination: URL(string: "https://platform.openai.com/docs/guides/your-data")!)
                }
            }.navigationTitle("Set up On Air").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { saved = (try? IPhoneKeychain.load()) != nil }
                .onDisappear { verificationID = UUID(); verification?.cancel(); key = "" }
        }
    }
    private func verify() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-") else { status = "Enter an OpenAI API key"; return }
        coordinator.turnOff()
        verification?.cancel(); let id = UUID(); verificationID = id; verifying = true; status = nil
        verification = Task {
            let client = OpenAITranscriber(key: { value })
            defer { client.shutdown(); if verificationID == id { verifying = false } }
            do {
                try await client.verifyConnection()
                guard !Task.isCancelled, verificationID == id else { return }
                try IPhoneKeychain.save(value)
                saved = true; key = ""; status = "Key verified and saved"
            } catch {
                guard !Task.isCancelled, verificationID == id else { return }
                status = (error as? TranscriptionError)?.localizedDescription ?? "Could not save the key. Try again."
            }
        }
    }
}
