import Foundation
import CryptoKit

@MainActor
enum FocusRecoveryChecks {
    static func run() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            checks += 1
            guard value else { throw Failure(message: message) }
        }
        func fixture(_ condition: DestinationCondition = .ready) -> (FocusAccessFixture, DictationDestination) {
            let access = FocusAccessFixture()
            access.current = condition
            return (access, DictationDestination(access: access))
        }

        func digest(_ text: String) -> SHA256.Digest { SHA256.hash(data: Data(text.utf8)) }
        var selectedTextReads = 0
        let caret = DestinationSelectionSnapshot(range: CFRange(location: 10, length: 0)) {
            selectedTextReads += 1; return digest("unused")
        }
        try expect(caret.rejection(currentRange: { CFRange(location: 400, length: 0) }, selectedText: {
            selectedTextReads += 1; return digest("background output")
        }) == nil, "Background output or a document update may advance the caret in the original field")
        try expect(selectedTextReads == 0, "Caret-only dictation never reads or fingerprints mutable text")
        try expect(caret.rejection(currentRange: { CFRange(location: 10, length: 5) }, selectedText: { digest("other") }) == "selection_changed",
                   "A new selection cannot turn a caret insertion into replacement")
        try expect(caret.rejection(currentRange: { nil }, selectedText: { nil }) == "selection_unreadable",
                   "An unreadable previously captured selection is not considered verified")
        let replacement = DestinationSelectionSnapshot(range: CFRange(location: 10, length: 5), selectedText: { digest("words") })
        try expect(replacement.rejection(currentRange: { CFRange(location: 10, length: 5) }, selectedText: { digest("words") }) == nil,
                   "An unchanged original selection can still be replaced")
        try expect(replacement.rejection(currentRange: { CFRange(location: 10, length: 5) }, selectedText: { digest("other") }) == "selected_text_changed",
                   "Background changes to the selected words cannot be overwritten")
        try expect(replacement.rejection(currentRange: { CFRange(location: 11, length: 5) }, selectedText: { digest("words") }) == "selection_changed",
                   "A moved replacement selection remains disqualifying")
        try expect(replacement.rejection(currentRange: { CFRange(location: 10, length: 5) }, selectedText: { nil }) == "selected_text_unreadable",
                   "Replacement requires readable selected words")

        let (busy, temporarilyUnreadable) = fixture(.unverified)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(85))
            busy.move(.ready)
        }
        try expect(await temporarilyUnreadable.prepare(), "Temporary accessibility failures recover within the verification budget")
        try expect(busy.requests == 0, "Retrying an unreadable target does not request app activation")
        temporarilyUnreadable.invalidate()

        let (unresponsive, stillUnreadable) = fixture(.unverified)
        try expect(!(await stillUnreadable.prepare()), "A target that stays unreadable never receives a paste")
        unresponsive.move(.ready)
        try expect(await stillUnreadable.prepare(), "An inconclusive read does not permanently poison the captured destination")
        stillUnreadable.invalidate()

        let (gone, unreadableThenClosed) = fixture(.unverified)
        gone.move(.unavailable)
        gone.move(.ready)
        try expect(!(await unreadableThenClosed.prepare()), "A confirmed invalid target remains disqualified after temporary read failures")
        unreadableThenClosed.invalidate()

        let (busyRestore, restoreThroughBusy) = fixture(.interrupted)
        busyRestore.onRequest = {
            busyRestore.move(.unverified)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(85))
                busyRestore.move(.ready)
            }
        }
        try expect(await restoreThroughBusy.prepare(), "Transient reads during focus restoration can recover")
        try expect(busyRestore.requests == 1, "Transient reads do not repeatedly activate the captured app")
        restoreThroughBusy.invalidate()

        let (normal, ready) = fixture()
        try expect(await ready.prepare(), "Unchanged destination is ready")
        try expect(ready.isReadyForInsertion() && normal.requests == 0, "Normal dictation never activates another app")
        ready.invalidate()

        let (stolen, interrupted) = fixture()
        stolen.move(.interrupted)
        try expect(interrupted.needsAttention, "Focus loss is tracked while recording")
        stolen.onRequest = { stolen.current = .ready }
        try expect(await interrupted.prepare(), "External focus interruption is recoverable")
        try expect(stolen.requests == 1 && interrupted.isReadyForInsertion(), "Restore once and verify exact field")
        interrupted.invalidate()

        let (slow, delayed) = fixture()
        slow.move(.interrupted)
        slow.onRequest = {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(85))
                slow.move(.ready)
            }
        }
        try expect(await delayed.prepare(), "Wait for asynchronous activation")
        try expect(slow.requests == 1, "Polling must not repeatedly steal focus")
        delayed.invalidate()

        let (denied, timeout) = fixture()
        denied.move(.interrupted)
        try expect(!(await timeout.prepare()), "A request accepted by macOS does not prove focus was restored")
        // Hosted runners can resume a sleeping task late. Count the production
        // retry budget directly instead of asserting scheduler wall-clock speed.
        try expect(denied.focusAttempts == 10 && denied.requests == 1, "Failed recovery is bounded to ten checks and one activation")
        try expect(!timeout.isReadyForInsertion(), "Timed-out restoration cannot post events")
        timeout.invalidate()

        let (moved, deliberate) = fixture()
        moved.interaction?()
        moved.move(.interrupted)
        moved.onRequest = { moved.move(.ready) }
        try expect(await deliberate.prepare(), "Earlier navigation does not retarget the captured dictation")
        try expect(moved.requests == 1 && deliberate.isReadyForInsertion(), "The original unchanged field remains the insertion target")
        deliberate.invalidate()

        let (clicked, clickedAway) = fixture()
        clicked.interaction?()
        clicked.move(.interrupted)
        try expect(clicked.requests == 0, "Clicking away does not restore focus while recording")
        clicked.onRequest = { clicked.move(.ready) }
        try expect(await clickedAway.prepare(), "A prior click away allows restoration when the transcript is ready")
        try expect(clicked.requests == 1 && clickedAway.isReadyForInsertion(), "Click-away recovery verifies the original destination")
        clickedAway.invalidate()

        let (menuInput, stillFocused) = fixture()
        menuInput.interaction?()
        try expect(await stillFocused.prepare(), "Menu interaction does not block an unchanged, still-focused destination")
        try expect(menuInput.requests == 0, "An unchanged field needs no activation after menu interaction")
        stillFocused.invalidate()

        let (field, differentField) = fixture()
        field.interaction?()
        field.move(.interrupted)
        field.move(.ready)
        try expect(await differentField.prepare(), "Clicking away and back preserves the original destination")
        try expect(field.requests == 0, "Returning to the original field needs no activation")
        differentField.invalidate()

        let (edited, modified) = fixture()
        edited.restorable = false
        edited.move(.unavailable)
        try expect(!(await modified.prepare()) && edited.requests == 0,
                   "Edited, secure, closed or uninspectable destinations cannot be forced open")
        modified.invalidate()

        let (unsupported, unknownField) = fixture()
        unsupported.restorable = false
        try expect(await unknownField.prepare(), "An unchanged custom editor can still accept ordinary insertion")
        unsupported.move(.interrupted)
        try expect(!(await unknownField.prepare()) && unsupported.requests == 0, "Unverifiable custom editors use recovery after focus loss")
        unknownField.invalidate()

        let (racing, race) = fixture()
        racing.move(.interrupted)
        racing.onRequest = { racing.current = .ready; racing.interaction?() }
        try expect(!(await race.prepare()), "Input during restoration aborts delivery even when focus is restored")
        race.invalidate()

        let (changing, changedDuringRestore) = fixture()
        changing.move(.interrupted)
        changing.onRequest = {
            changing.move(.unavailable)
            changing.move(.ready)
        }
        try expect(!(await changedDuringRestore.prepare()), "A target edit during restoration remains disqualifying even if undone")
        changedDuringRestore.invalidate()

        let (changingAfter, changedAfterPrepare) = fixture()
        try expect(await changedAfterPrepare.prepare(), "Prepare before a later field change")
        changingAfter.move(.unavailable)
        changingAfter.move(.ready)
        try expect(!changedAfterPrepare.isReadyForInsertion(), "A target edit after preparation cannot be erased by undoing it")
        changedAfterPrepare.invalidate()

        let (late, recheck) = fixture()
        try expect(await recheck.prepare(), "Prepare insertion")
        late.current = .interrupted // No notification: final synchronous validation still catches it.
        try expect(!recheck.isReadyForInsertion(), "Focus loss after preparation prevents event delivery")
        late.current = .ready
        late.interaction?()
        try expect(!recheck.isReadyForInsertion(), "Late input invalidates a prepared insertion")
        recheck.invalidate()

        let (cancelAccess, cancelled) = fixture()
        cancelAccess.move(.interrupted)
        let task = Task { @MainActor in await cancelled.prepare() }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        try expect(!(await task.value) && !cancelled.isReadyForInsertion(), "Task cancellation stops a pending restoration")
        cancelled.invalidate()

        let (lockAccess, locked) = fixture()
        lockAccess.move(.interrupted)
        let lockTask = Task { @MainActor in await locked.prepare() }
        try await Task.sleep(for: .milliseconds(60))
        locked.invalidate()
        lockAccess.current = .ready
        try expect(!(await lockTask.value), "Lock or shutdown invalidation prevents a late paste")
        try expect(lockAccess.changed == nil && lockAccess.interaction == nil, "Invalidation tears down observers")

        let (retainedAccess, retained) = fixture()
        retainedAccess.move(.unavailable)
        retained.stopMonitoring()
        try expect(retainedAccess.changed == nil, "Retained results do not keep global observers alive")
        try expect(!(await retained.prepare()), "Retention does not silently re-enable a changed destination")
        retained.invalidate()

        print("PASS: \(checks) focus recovery checks (production policy, controlled OS boundaries; no events posted)")
    }
    struct Failure: Error { let message: String }
}

@MainActor
private final class FocusAccessFixture: DestinationAccess {
    let processIdentifier: Int32 = 321
    var current: DestinationCondition = .ready
    var restorable = true
    var requests = 0
    var focusAttempts = 0
    var changed: (() -> Void)?
    var interaction: (() -> Void)?
    var onRequest: (() -> Void)?
    var canRestore: Bool { restorable }
    func condition() -> DestinationCondition { current }
    func requestFocus() -> Bool { requests += 1; onRequest?(); return true }
    func move(_ value: DestinationCondition) { current = value; changed?() }
    func focusOriginalField() { focusAttempts += 1 }
    func observe(change: @escaping () -> Void, interaction: @escaping () -> Void) { changed = change; self.interaction = interaction }
    func stopObserving() { changed = nil; interaction = nil }
}
