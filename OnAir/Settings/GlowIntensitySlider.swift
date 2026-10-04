import AppKit
import SwiftUI

/// The reference's track and thumb, with AppKit pointer events, keyboard
/// navigation and accessibility. Keep the existing eleven calibrated levels.
struct GlowIntensityControl: NSViewRepresentable {
    let preferences: GlowPreferences

    func makeNSView(context: Context) -> GlowIntensitySlider {
        let slider = GlowIntensitySlider()
        slider.changed = { preferences.updateIntensity($0) }
        return slider
    }

    func updateNSView(_ slider: GlowIntensitySlider, context: Context) {
        slider.changed = { preferences.updateIntensity($0) }
        slider.doubleValue = preferences.intensity
        slider.setAccessibilityValueDescription("\(Int((preferences.intensity * 100).rounded()))%")
        slider.needsDisplay = true
    }
}

final class GlowIntensitySlider: NSSlider {
    var changed: (Double) -> Void = { _ in }
    fileprivate var tracking = false
    private var dragOffset: CGFloat = 0

    init() {
        super.init(frame: .zero)
        cell = GlowIntensitySliderCell()
        minValue = 0
        maxValue = 1
        numberOfTickMarks = Int(GlowIntensity.steps) + 1
        allowsTickMarkValuesOnly = true
        isContinuous = true
        clipsToBounds = false
        focusRingType = .none
        target = self
        action = #selector(valueChanged)
        identifier = NSUserInterfaceItemIdentifier("settings.recording-glow")
        setAccessibilityIdentifier("settings.recording-glow")
        setAccessibilityLabel("Glow intensity")
        setAccessibilityHelp("Adjusts the red glow’s brightness, height and movement. Zero percent keeps a faint glow.")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    @objc private func valueChanged() {
        doubleValue = GlowIntensity.snapped(doubleValue)
        setAccessibilityValueDescription("\(Int((doubleValue * 100).rounded()))%")
        changed(doubleValue)
        needsDisplay = true
    }

    // Route AppKit pointer events against the custom thumb geometry. Keep
    // NSSlider’s keyboard and accessibility actions on its native value path.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let cell = cell as? NSSliderCell else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let knob = cell.knobRect(flipped: isFlipped)
        // Keep the grabbed point under the pointer; clicking the track jumps there.
        dragOffset = knob.contains(point) ? point.x - knob.midX : 0
        tracking = true
        updatePointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        updatePointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        updatePointer(event)
        tracking = false
        needsDisplay = true
    }

    private func updatePointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let travel = max(bounds.width - 18, 1)
        doubleValue = GlowIntensity.snapped(Double((point.x - dragOffset - 9) / travel))
        sendAction(action, to: target)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { tracking = false }
        needsDisplay = true
        return accepted
    }
}

private final class GlowIntensitySliderCell: NSSliderCell {
    override var knobThickness: CGFloat { 18 }

    override func knobRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return .zero }
        let bounds = view.bounds
        let center = 9 + (bounds.width - 18) * CGFloat(GlowIntensity(doubleValue).value)
        return NSRect(x: center - 9, y: bounds.midY - 9, width: 18, height: 18)
    }

    override func drawTickMarks() {}

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let bounds = view.bounds
        let intensity = GlowIntensity(doubleValue).value
        let red = NSColor(calibratedRed: 1, green: 74 / 255, blue: 58 / 255, alpha: 1)
        let center = knobRect(flipped: flipped).midX
        let track = NSRect(x: 0, y: knobRect(flipped: flipped).midY - 2, width: bounds.width, height: 4)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = red.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 2 + 10 * intensity
        glow.shadowOffset = .zero
        glow.set()
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: center, height: 4), xRadius: 2, yRadius: 2)
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGradient(starting: red.withAlphaComponent(0.25), ending: red.withAlphaComponent(0.35 + 0.65 * intensity))?.draw(in: fill, angle: 0)
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob(_ nativeKnob: NSRect) {
        let knob = NSRect(x: nativeKnob.midX - 9, y: nativeKnob.midY - 9, width: 18, height: 18)
        guard let view = controlView as? GlowIntensitySlider else { return }
        let red = NSColor(calibratedRed: 1, green: 74 / 255, blue: 58 / 255, alpha: 1)
        if view.tracking || view.window?.firstResponder === view {
            red.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: knob.insetBy(dx: -6, dy: -6)).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        shadow.set()
        NSColor(calibratedRed: 244 / 255, green: 242 / 255, blue: 239 / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
