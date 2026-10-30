import Combine
import SwiftUI
import UIKit
import OnAirSession

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var state = SessionSnapshot()
    @Published var fullAccess = false
    @Published var result: TranscriptRecord?
    @Published var issue: String?
    @Published var pending = false
    @Published var needsGlobe = true
    @Published var uncertainDelivery = false
    var send: (SessionAction) -> Void = { _ in }
    var type: (String) -> Void = { _ in }
    var delete: () -> Void = {}
    var nextKeyboard: () -> Void = {}
    var insert: () -> Void = {}
    var settings: () -> Void = {}
}

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var store: SessionStore?
    private var hosting: UIHostingController<KeyboardView>?
    private var poll: Task<Void, Never>?
    private var visible = false
    private var insertion = InsertionGuard()
    private var inserting = false
    private var pendingCommand: SessionCommand?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.type = { [weak self] text in
            guard let self else { return }
            self.insertion.invalidate(); self.textDocumentProxy.insertText(text)
        }
        model.delete = { [weak self] in self?.insertion.invalidate(); self?.textDocumentProxy.deleteBackward() }
        model.nextKeyboard = { [weak self] in self?.insertion.invalidate(); self?.advanceToNextInputMode() }
        model.send = { [weak self] action in self?.send(action) }
        model.insert = { [weak self] in self?.deliver(explicit: true) }
        model.settings = { [weak self] in
            // Public settings route only. Cold activation uses an explicit visit
            // to the containing app; no responder-chain/private launch workaround.
            self?.extensionContext?.open(URL(string: UIApplication.openSettingsURLString)!)
        }
        let hosting = UIHostingController(rootView: KeyboardView(model: model))
        hosting.view.backgroundColor = .clear
        addChild(hosting); view.addSubview(hosting.view); hosting.didMove(toParent: self)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.hosting = hosting
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true; model.fullAccess = hasFullAccess; model.needsGlobe = needsInputModeSwitchKey
        if hasFullAccess { store = try? SessionStore.appGroup(); try? store?.purge() }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height: CGFloat = view.bounds.width > 600 ? 250 : 316
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
            heightConstraint?.priority = .init(999); heightConstraint?.isActive = true
        } else { heightConstraint?.constant = height }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false; insertion.invalidate(); poll?.cancel(); poll = nil
        pendingCommand = nil; model.pending = false
    }
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        if !inserting { insertion.invalidate() }
    }
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        if !inserting { insertion.invalidate() }
    }
    private func refresh() {
        guard visible else { return }
        model.fullAccess = hasFullAccess
        guard hasFullAccess else { store = nil; model.result = nil; return }
        if store == nil { store = try? SessionStore.appGroup() }
        if let snapshot = store?.snapshot() {
            if snapshot.isLive() {
                let oldPhase = model.state.phase
                model.state = snapshot
                if oldPhase != snapshot.phase {
                    UIAccessibility.post(notification: .announcement, argument: snapshot.phase.label)
                }
                if let pendingCommand, snapshot.acknowledgedCommand == pendingCommand.id {
                    self.pendingCommand = nil; model.pending = false; model.issue = nil
                }
            } else {
                if model.state.phase != .off { insertion.invalidate() }
                model.state = SessionSnapshot()
            }
        }
        if let pendingCommand, pendingCommand.expiresAt <= Date() {
            self.pendingCommand = nil; model.pending = false; insertion.invalidate()
            model.issue = "Open On Air and enable a keyboard session, then return here."
        }
        model.result = store?.result()
        if let result = model.result {
            model.uncertainDelivery = store?.wasClaimed(result.turnID) == true
            if insertion.permits(result, documentID: textDocumentProxy.documentIdentifier, visible: visible) {
                deliver(explicit: false)
            }
        }
    }
    private func send(_ action: SessionAction) {
        guard hasFullAccess else { model.issue = "Enable Allow Full Access in Settings for dictation."; return }
        guard let store, let state = store.snapshot(), state.isLive() else {
            model.issue = "Open On Air, tap Enable keyboard for 5 minutes, then return here."; return
        }
        if action == .start, state.phase != .ready {
            model.issue = "Open On Air, tap Enable keyboard for 5 minutes, then return here."; return
        }
        let destination = action == .start ? insertion.capture(documentID: textDocumentProxy.documentIdentifier) : nil
        if action == .cancel || action == .turnOff { insertion.invalidate() }
        let command = SessionCommand(action: action, snapshot: state, destinationID: destination)
        do {
            try store.enqueue(command); pendingCommand = command; model.pending = true; model.issue = nil
        } catch { insertion.invalidate(); model.issue = "Could not contact On Air. Try again." }
    }
    private func deliver(explicit: Bool) {
        guard visible, hasFullAccess, let store, let result = store.result() else { return }
        if !explicit {
            guard insertion.permits(result, documentID: textDocumentProxy.documentIdentifier, visible: visible) else { return }
        }
        do {
            guard let claimed = try store.claim(result.turnID, explicit: explicit) else { return }
            // No async suspension between the destination check, claim and insertion.
            inserting = true
            textDocumentProxy.insertText(claimed.text)
            inserting = false; insertion.invalidate()
            try store.consume(claimed.turnID); model.result = nil
            UIAccessibility.post(notification: .announcement, argument: "Transcript inserted")
        } catch {
            inserting = false; insertion.invalidate()
            model.issue = "Delivery needs checking. Use Insert only if the text is missing."
        }
    }
}
