import AppKit
import FootballPhysics

/// Renders the ball with Core Animation. Three layers:
///   • `shadowLayer`  — a soft ellipse that offsets/blurs/fades with the ball's
///                      height (the fake-3D depth cue from the PRD).
///   • `ballContainer`— carries squash/stretch + perspective + breathing scale
///                      in **screen axes** (so a landing always flattens the ball
///                      vertically, regardless of how the texture has rotated).
///   • `textureLayer` — the football image, carrying rotation only.
///
/// Every property is set inside a `CATransaction` with actions disabled, so the
/// 60 fps loop drives the layers directly with no implicit easing fighting it.
final class FootballLayerView: NSView {

    private let ballContainer = CALayer()
    private let textureLayer = CALayer()
    private let shadowLayer = CALayer()
    private let chargeRingLayer = CAShapeLayer()  // charge progress arc

    private let diameter: CGFloat
    private let ballAnchor: CGPoint
    private let liftRange: CGFloat

    private var breathePhase: CGFloat = 0

    init(windowSize: NSSize, diameter: CGFloat, ballAnchor: CGPoint, liftRange: CGFloat) {
        self.diameter = diameter
        self.ballAnchor = ballAnchor
        self.liftRange = liftRange
        super.init(frame: NSRect(origin: .zero, size: windowSize))
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override var isFlipped: Bool { false }      // keep +Y up, matching screen space
    override var mouseDownCanMoveWindow: Bool { false }

    private func buildLayers() {
        guard let root = layer else { return }
        root.contentsScale = window?.backingScaleFactor ?? 2

        // Shadow sits below the ball; its base position is just under the centre.
        shadowLayer.contents = BallTexture.softShadow()
        shadowLayer.bounds = CGRect(x: 0, y: 0, width: diameter * 1.5, height: diameter * 1.5)
        shadowLayer.position = CGPoint(x: ballAnchor.x, y: ballAnchor.y)
        shadowLayer.contentsScale = root.contentsScale
        root.addSublayer(shadowLayer)

        ballContainer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ballContainer.position = ballAnchor
        root.addSublayer(ballContainer)

        textureLayer.contents = BallTexture.football()
        textureLayer.frame = ballContainer.bounds
        textureLayer.contentsScale = root.contentsScale
        ballContainer.addSublayer(textureLayer)

        // Charge ring — a progress arc drawn just outside the ball, filled as
        // the player holds Right Command. Starts from the top (rotation −90°).
        let cr = diameter * 0.68
        let chargePath = CGMutablePath()
        chargePath.addEllipse(in: CGRect(x: ballAnchor.x - cr, y: ballAnchor.y - cr,
                                         width: cr * 2, height: cr * 2))
        chargeRingLayer.path = chargePath
        chargeRingLayer.fillColor = nil
        chargeRingLayer.lineWidth = 3.5
        chargeRingLayer.strokeStart = 0
        chargeRingLayer.strokeEnd = 0
        chargeRingLayer.lineCap = .round
        chargeRingLayer.strokeColor = NSColor.systemBlue.cgColor
        chargeRingLayer.contentsScale = root.contentsScale
        // Rotate so the fill starts from 12 o'clock.
        chargeRingLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        root.addSublayer(chargeRingLayer)
    }

    /// Push one physics frame into the layers.
    /// - Parameters:
    ///   - angle: texture rotation (radians, CALayer CCW-positive).
    ///   - squash: 0…1 vertical compression.
    ///   - liftFactor: 0 (grounded) … 1 (high above the floor).
    ///   - motionState: drives the idle breathing pulse.
    func render(angle: CGFloat, squash: CGFloat, liftFactor: CGFloat, motionState: MotionState,
                chargeFraction: CGFloat = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Texture rotation only.
        textureLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)

        // Idle breathing: a gentle ±2% pulse, advanced only while resting.
        var breathe: CGFloat = 1
        if motionState == .idle {
            breathePhase += 0.06
            breathe = 1 + 0.02 * sin(breathePhase)
        } else {
            breathePhase = 0
        }

        // Subtle perspective: a little larger when flying up ("toward the viewer").
        let perspective = 1 + 0.05 * liftFactor

        let sx = (1 + squash * 0.75) * perspective * breathe
        let sy = (1 - squash) * perspective * breathe
        ballContainer.transform = CATransform3DMakeScale(sx, sy, 1)

        // Shadow: sinks + shrinks + fades as the ball rises; widens as it squashes.
        let offset = -diameter * 0.42 - diameter * 0.62 * liftFactor
        let shadowScale = (1 - 0.45 * liftFactor)
        shadowLayer.transform = CATransform3DMakeScale(
            shadowScale * (1 + squash * 0.5),
            shadowScale * (1 - squash * 0.3), 1)
        shadowLayer.position = CGPoint(x: ballAnchor.x, y: ballAnchor.y + offset)
        shadowLayer.opacity = Float(0.34 * (1 - 0.7 * liftFactor))

        // Charge ring progress arc — hue sweeps blue → red as charge fills.
        if chargeFraction > 0.01 {
            chargeRingLayer.strokeEnd = chargeFraction
            let hue = CGFloat(0.55) - chargeFraction * 0.55
            chargeRingLayer.strokeColor = NSColor(hue: hue, saturation: 1.0, brightness: 1.0,
                                                   alpha: 0.9).cgColor
        } else {
            chargeRingLayer.strokeEnd = 0
        }

        CATransaction.commit()
    }

    /// Brief expand-fade ring at the ball position — fired on each phantom combo strike.
    func playImpactFlash() {
        guard let root = layer else { return }
        let flash = CAShapeLayer()
        let r = diameter * 0.5
        flash.path = CGPath(ellipseIn: CGRect(x: ballAnchor.x - r, y: ballAnchor.y - r,
                                              width: r * 2, height: r * 2), transform: nil)
        flash.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
        flash.strokeColor = nil
        root.addSublayer(flash)

        let group = CAAnimationGroup()
        group.duration = 0.22
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        let scale = CABasicAnimation(keyPath: "transform")
        scale.toValue = CATransform3DMakeScale(2.4, 2.4, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0; fade.toValue = 0.0
        group.animations = [scale, fade]
        flash.add(group, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { flash.removeFromSuperlayer() }
    }

    /// Burst ring that expands and fades on charge release; ring multiplier controls size.
    func playChargeRelease(multiplier: CGFloat) {
        guard let root = layer else { return }
        let burst = CAShapeLayer()
        let r = diameter * 0.55
        burst.path = CGPath(ellipseIn: CGRect(x: ballAnchor.x - r, y: ballAnchor.y - r,
                                              width: r * 2, height: r * 2), transform: nil)
        burst.fillColor = nil
        burst.strokeColor = NSColor.orange.withAlphaComponent(0.85).cgColor
        burst.lineWidth = 3
        root.addSublayer(burst)

        let group = CAAnimationGroup()
        group.duration = 0.32
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        let scale = CABasicAnimation(keyPath: "transform")
        let s = CGFloat(1 + min(multiplier, 4) * 0.6)
        scale.toValue = CATransform3DMakeScale(s, s, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0; fade.toValue = 0.0
        group.animations = [scale, fade]
        burst.add(group, forKey: "burst")

        // Reset charge ring instantly
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chargeRingLayer.strokeEnd = 0
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { burst.removeFromSuperlayer() }
    }
}
