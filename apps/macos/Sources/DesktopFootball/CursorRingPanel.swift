import AppKit

/// A completely transparent, always-click-through NSPanel that draws a
/// dashed ring of radius `kickRadius` centred on the cursor. Visible only in
/// Game Mode — gives the player a visual feel for the enlarged hit zone.
///
/// The ring's appearance changes with proximity and charge level:
///   • white dashed  — cursor outside the kick radius
///   • yellow solid  — cursor inside the kick radius ("in range")
///   • blue→red arc  — charge is building (charge fraction 0 → 1)
final class CursorRingPanel: NSPanel {

    private let ringLayer = CAShapeLayer()
    private let halfSize: CGFloat

    init(kickRadius: CGFloat) {
        halfSize = kickRadius + 22
        let size = halfSize * 2
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let cv = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        cv.wantsLayer = true
        cv.layer?.masksToBounds = false
        contentView = cv

        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: halfSize - kickRadius, y: halfSize - kickRadius,
                                   width: kickRadius * 2, height: kickRadius * 2))
        ringLayer.path = path
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        ringLayer.lineWidth = 1.5
        ringLayer.lineDashPattern = [8, 5]
        ringLayer.frame = CGRect(origin: .zero, size: NSSize(width: size, height: size))
        cv.layer?.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Move the ring so it is centred on `mouse`, and update its style.
    func update(mouse: NSPoint, inRange: Bool, chargeFraction: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        setFrameOrigin(NSPoint(x: mouse.x - halfSize, y: mouse.y - halfSize))

        if chargeFraction > 0.02 {
            let hue = CGFloat(0.55) - chargeFraction * 0.55  // blue → red
            ringLayer.strokeColor = NSColor(hue: hue, saturation: 1, brightness: 1,
                                            alpha: 0.88).cgColor
            ringLayer.lineWidth = 2.2
            ringLayer.lineDashPattern = nil
        } else if inRange {
            ringLayer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
            ringLayer.lineWidth = 2.0
            ringLayer.lineDashPattern = nil
        } else {
            ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
            ringLayer.lineWidth = 1.5
            ringLayer.lineDashPattern = [8, 5]
        }

        CATransaction.commit()
    }
}
