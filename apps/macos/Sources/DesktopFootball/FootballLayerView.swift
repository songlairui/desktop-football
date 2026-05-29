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
    }

    /// Push one physics frame into the layers.
    /// - Parameters:
    ///   - angle: texture rotation (radians, CALayer CCW-positive).
    ///   - squash: 0…1 vertical compression.
    ///   - liftFactor: 0 (grounded) … 1 (high above the floor).
    ///   - motionState: drives the idle breathing pulse.
    func render(angle: CGFloat, squash: CGFloat, liftFactor: CGFloat, motionState: MotionState) {
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

        let sx = (1 + squash * 0.55) * perspective * breathe
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

        CATransaction.commit()
    }
}
