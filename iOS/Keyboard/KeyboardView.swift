import SwiftUI
import OnAirSession

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @State private var uppercase = false
    @State private var symbols = false
    @State private var showTyping = false
    private var active: Bool { [.starting, .recording, .finishing].contains(model.state.phase) && !showTyping }
    private var rows: [String] {
        symbols ? ["1234567890", "-/:;()£&@", ".,?!'\""] : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    }
    var body: some View {
        VStack(spacing: 0) {
            if active {
                DictationPanel(phase: model.state.phase, level: model.state.level, startedAt: model.state.startedAt,
                    cancel: { model.send(.cancel) }, finish: { model.send(.finish) })
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("On Air").font(.headline)
                        Spacer()
                        if model.state.phase == .ready {
                            Text("Ready").font(.caption).foregroundStyle(.secondary)
                            Button { model.send(.turnOff) } label: { Image(systemName: "power").frame(width: 36, height: 36) }
                                .accessibilityLabel("Turn microphone off")
                        }
                        Button { showTyping = false; model.send(.start) } label: {
                            Label(model.pending ? "Starting" : "Dictate", systemImage: "mic.fill")
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(height: 38)
                        }.buttonStyle(.borderedProminent).tint(.primary).disabled(model.pending)
                    }.padding(.horizontal, 10)
                    if let result = model.result {
                        Button(action: model.insert) {
                            Label(model.uncertainDelivery ? "Insert again if missing" : "Insert transcript", systemImage: "text.badge.plus")
                                .font(.subheadline).frame(maxWidth: .infinity)
                        }.accessibilityHint("Inserts the completed dictation into the current field")
                            .id(result.turnID)
                    }
                    if let issue = model.issue ?? model.state.issue {
                        Text(issue).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal, 12)
                    }
                    if model.state.canRetry { Button("Retry transcription") { model.send(.retry) }.font(.caption) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { row, characters in
                        HStack(spacing: 5) {
                            if row == 2 {
                                keyButton(uppercase ? "⇧" : "shift", symbol: "shift", width: 40) { uppercase.toggle() }
                            }
                            ForEach(Array(characters).map(String.init), id: \.self) { character in
                                let label = uppercase && !symbols ? character.uppercased() : character
                                keyButton(label) { model.type(label); uppercase = false }
                            }
                            if row == 2 { keyButton("Delete", symbol: "delete.left", width: 40, action: model.delete) }
                        }.padding(.horizontal, row == 1 ? 18 : 4)
                    }
                }.padding(.top, 6)
                Spacer(minLength: 3)
            }
            HStack(spacing: 8) {
                if model.needsGlobe {
                    Button(action: model.nextKeyboard) { Image(systemName: "globe").font(.title2).frame(width: 44, height: 44) }
                        .accessibilityLabel("Next keyboard")
                }
                if active {
                    Spacer()
                    Button("Show keys") { showTyping = true }.font(.subheadline).frame(minHeight: 44)
                } else {
                    Button(symbols ? "ABC" : "123") { symbols.toggle() }.frame(width: 44, height: 44)
                    keyButton("space") { model.type(" ") }
                    keyButton("return", width: 70) { model.type("\n") }
                }
            }.padding(.horizontal, 8).padding(.bottom, 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .foregroundStyle(.primary)
        .onChange(of: model.state.phase) { _, phase in
            if phase == .recording || phase == .starting { showTyping = false }
        }
    }
    private func keyButton(_ title: String, symbol: String? = nil, width: CGFloat? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.body) }
                else { Text(title).font(title.count == 1 ? .system(size: 22) : .subheadline) }
            }.frame(maxWidth: width == nil ? .infinity : nil).frame(width: width, height: 40)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel(title == " " ? "Space" : title)
    }
}
