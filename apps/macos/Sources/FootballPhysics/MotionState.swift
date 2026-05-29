import CoreGraphics

/// A coarse classification of what the ball is doing this frame. The renderer
/// and sound engine subscribe to this rather than re-deriving thresholds, so the
/// visual/audio language stays in one place.
public enum MotionState: String, Equatable, Sendable {
    /// Resting on the ground, essentially still — drives the breathing animation.
    case idle
    /// Rolling along the ground with meaningful horizontal speed.
    case rolling
    /// Airborne (gravity acting, not grounded).
    case flying
    /// Held by the cursor (gravity suspended, follows the mouse).
    case grabbed
}

/// Discrete physical events emitted by a single integration step. They are
/// one-shot (true only on the frame they happen) so the app layer can fire
/// sounds / particles without tracking edges itself.
public struct PhysicsEvents: Equatable, Sendable {
    /// The ball touched the ground this frame with a real downward speed.
    /// Carries the impact speed (pt/s) so volume/pitch can scale with it.
    public var landed: CGFloat?
    /// The ball bounced off a side or top wall this frame (impact speed, pt/s).
    public var hitWall: CGFloat?

    public init(landed: CGFloat? = nil, hitWall: CGFloat? = nil) {
        self.landed = landed
        self.hitWall = hitWall
    }

    public static let none = PhysicsEvents()
}
