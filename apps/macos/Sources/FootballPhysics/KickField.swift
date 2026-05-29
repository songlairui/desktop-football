import CoreGraphics

/// The mouse force field around the ball. This is the football inverse of
/// `HUDPanel.repulseForce`: the same static-repulsion + approach-speed-impulse
/// model, applied to the ball so the cursor can nudge and kick it.
///
/// Pure and side-effect free, so the interaction feel can be unit-tested without
/// AppKit.
public enum KickField {

    /// The result of evaluating the field for one frame.
    public struct Result: Equatable, Sendable {
        /// Acceleration to add to the ball this frame (pt/s²), already aimed away
        /// from the cursor.
        public var force: CGPoint
        /// Cursor speed projected toward the ball (pt/s); `0` when the cursor is
        /// receding. Used to decide whether a swipe is forceful enough to count
        /// as a "kick" for sound/particles.
        public var approachSpeed: CGFloat

        public init(force: CGPoint, approachSpeed: CGFloat) {
            self.force = force
            self.approachSpeed = approachSpeed
        }

        public static let zero = Result(force: .zero, approachSpeed: 0)
    }

    /// Evaluate the field.
    ///
    /// - Parameters:
    ///   - ballCenter: ball centre in screen coordinates.
    ///   - mouse: cursor position in screen coordinates.
    ///   - mouseVelocity: cursor velocity this frame (pt/s).
    ///   - config: physics tuning.
    public static func evaluate(
        ballCenter: CGPoint,
        mouse: CGPoint,
        mouseVelocity: CGPoint,
        config: PhysicsConfig
    ) -> Result {
        let dx = ballCenter.x - mouse.x
        let dy = ballCenter.y - mouse.y
        let dist = hypot(dx, dy)

        guard dist < config.kickRadius else { return .zero }

        // Push direction: cursor → ball centre. When the cursor sits exactly on
        // the centre, default to straight up so a dead-centre click still lifts.
        let (ux, uy): (CGFloat, CGFloat) = dist > 1 ? (dx / dist, dy / dist) : (0, 1)

        // Strength falloff: 1 at the centre, 0 at the field edge.
        let t = 1.0 - dist / config.kickRadius

        // Static airflow — always-on gentle drift, quadratic falloff.
        let hoverMag = config.hoverForce * t * t

        // Dynamic kick — only the part of the cursor's motion heading into the
        // ball contributes (a swipe *away* should not suck the ball along).
        let approachSpeed = max(0, mouseVelocity.x * ux + mouseVelocity.y * uy)
        let kickMag = config.kickGain * approachSpeed * t

        let mag = hoverMag + kickMag
        return Result(force: CGPoint(x: ux * mag, y: uy * mag),
                      approachSpeed: approachSpeed)
    }
}
