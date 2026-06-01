import AppKit

/// A small, always-click-through, transparent NSPanel that renders combo strike
/// "shockwave" ripples near the impact point.
///
/// Effects are drawn at the ball's **global screen coordinates** (same space as
/// `NSEvent.mouseLocation`). Older versions covered the union of all displays,
/// which made a transparent overlay participate in composition on secondary
/// monitors. Keep this panel tightly bounded around the effect instead.
final class EffectsOverlayPanel: NSPanel {

    static let shared = EffectsOverlayPanel()

    private let panelSize: CGFloat = 420
    private var halfSize: CGFloat { panelSize / 2 }

    private init() {
        super.init(
            contentRect: NSRect(x: -10_000, y: -10_000, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        cv.wantsLayer = true
        cv.layer?.masksToBounds = false
        contentView = cv
    }

    required init?(coder: NSCoder) { fatalError() }

    private func prepareEffect(at screenPos: CGPoint) -> CGPoint {
        setFrameOrigin(NSPoint(x: screenPos.x - halfSize, y: screenPos.y - halfSize))
        orderFrontRegardless()
        return CGPoint(x: halfSize, y: halfSize)
    }

    /// Fruit-Ninja–style slash mark at `screenPos`, oriented perpendicular to the
    /// strike impulse direction. Two layers: a wide soft glow + a razor-thin bright
    /// core, both fading in ~0.22 s.
    func showSlashEffect(at screenPos: CGPoint, angle: CGFloat, power: CGFloat = 1.0) {
        guard let root = contentView?.layer else { return }
        let localPos = prepareEffect(at: screenPos)

        // The blade cuts ACROSS the motion, not along it (perpendicular + small jitter).
        let slashAngle = angle + .pi / 2 + CGFloat.random(in: -0.25...0.25)
        let halfLen: CGFloat = 55 + 35 * min(power, 1.3)

        let s = CGPoint(x: localPos.x - cos(slashAngle) * halfLen,
                        y: localPos.y - sin(slashAngle) * halfLen)
        let e = CGPoint(x: localPos.x + cos(slashAngle) * halfLen,
                        y: localPos.y + sin(slashAngle) * halfLen)

        func makeLine(width: CGFloat, color: NSColor) -> CAShapeLayer {
            let layer = CAShapeLayer()
            let path = CGMutablePath(); path.move(to: s); path.addLine(to: e)
            layer.path = path
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.fillColor = nil
            root.addSublayer(layer)
            return layer
        }

        let glow = makeLine(width: 9, color: .white.withAlphaComponent(0.22))
        let core = makeLine(width: 2.0,
                            color: NSColor(hue: 0.14, saturation: 0.15, brightness: 1, alpha: 0.92))

        let dur = 0.22
        for lyr in [glow, core] {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0; anim.toValue = 0.0
            anim.duration = dur; anim.fillMode = .forwards; anim.isRemovedOnCompletion = false
            lyr.add(anim, forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.04) {
            glow.removeFromSuperlayer(); core.removeFromSuperlayer()
        }
    }

    /// Play a ripple-wave effect centred at `screenPos`.
    ///
    /// `power` (0 … 1+) scales ring count, size and opacity so later combo
    /// strikes look progressively more dramatic:
    ///   • power ≤ 0.80 → 2 rings, max radius ~90pt
    ///   • power ≤ 1.00 → 3 rings, max radius ~110pt
    ///   • power  > 1.00 → 4 rings, max radius ~140pt  (mega-combo finale)
    func showStrikeEffect(at screenPos: CGPoint, power: CGFloat = 1.0) {
        guard let root = contentView?.layer else { return }
        let localPos = prepareEffect(at: screenPos)

        let numRings = power > 1.0 ? 4 : (power > 0.85 ? 3 : 2)
        let maxRadius: CGFloat = 55 + 85 * power   // 55→140pt as power rises
        let baseRadius: CGFloat = 26

        let palette: [NSColor] = [
            .white,
            NSColor(hue: 0.13, saturation: 0.9, brightness: 1.0, alpha: 1),  // amber
            NSColor(hue: 0.05, saturation: 1.0, brightness: 1.0, alpha: 1),  // orange
            NSColor(hue: 0.00, saturation: 1.0, brightness: 1.0, alpha: 1),  // red (finale ring)
        ]

        for i in 0..<numRings {
            let delay = Double(i) * 0.05
            let color = palette[min(i, palette.count - 1)]
            let lineWidth: CGFloat = 2.8 - CGFloat(i) * 0.4
            let alphaMult: CGFloat = 0.80 - CGFloat(i) * 0.12

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let ring = CAShapeLayer()
                let path = CGMutablePath()
                path.addEllipse(in: CGRect(x: localPos.x - baseRadius,
                                           y: localPos.y - baseRadius,
                                           width: baseRadius * 2,
                                           height: baseRadius * 2))
                ring.path = path
                ring.fillColor = nil
                ring.strokeColor = color.withAlphaComponent(alphaMult).cgColor
                ring.lineWidth = lineWidth
                root.addSublayer(ring)

                let group = CAAnimationGroup()
                group.duration = 0.32
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false

                let sc = maxRadius / baseRadius
                let scale = CABasicAnimation(keyPath: "transform")
                scale.fromValue = CATransform3DIdentity
                scale.toValue = CATransform3DMakeScale(sc, sc, 1)

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.0

                group.animations = [scale, fade]
                ring.add(group, forKey: "ripple")
                root.addSublayer(ring)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    ring.removeFromSuperlayer()
                }
            }
        }
    }
}
