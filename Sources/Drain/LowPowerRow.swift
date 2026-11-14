import AppKit

/// The "Low Power" row from macOS's own battery menu: a round button that fills
/// yellow when on, the label beside it, and a soft highlight
/// across the row on hover. Clicking anywhere on the row toggles it and leaves
/// the menu open, like the system's.
final class LowPowerRowView: NSView {
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var onToggle: (() -> Void)?

    private let label = NSTextField(labelWithString: "Low Power")
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    private let circleSize: CGFloat = 26
    private let inset: CGFloat = 14

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        autoresizingMask = [.width]

        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + circleSize + 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Low Power")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    // Without this VoiceOver sees a checkbox it cannot press.
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseMoved(with event: NSEvent) { hovering = isMouseInside }

    /// Checked against the real pointer, so the highlight can't get stuck on.
    private var isMouseInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func viewDidMoveToWindow() { hovering = false }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isMouseInside {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 9, yRadius: 9).fill()
        }

        let circle = NSRect(x: inset, y: (bounds.height - circleSize) / 2, width: circleSize, height: circleSize)
        (isOn ? NSColor.systemYellow : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let tint: NSColor = isOn ? .black : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(hierarchicalColor: tint))
        if let glyph = NSImage(systemSymbolName: "battery.50percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = glyph.size
            glyph.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }
}
