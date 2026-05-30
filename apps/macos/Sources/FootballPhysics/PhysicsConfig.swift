import CoreGraphics

/// Tunable physics constants for the desktop football.
///
/// All quantities are expressed in screen points and points-per-second, in the
/// **macOS screen coordinate space** (origin bottom-left, +Y points up). This is
/// the same convention `HUDPanel` integrates in, so the model maps directly onto
/// `NSWindow.setFrameOrigin`.
///
/// The struct is immutable; tweak a copy with the `with(...)` helpers rather than
/// mutating an existing config.
public struct PhysicsConfig: Equatable, Sendable {

    /// The real-world gravity baseline (pt/s², negative because +Y is up). Shared
    /// so `GravityMode.normal` and the default config never drift apart.
    public static let normalGravity: CGFloat = -2000

    // MARK: Geometry

    /// Ball radius in points. The visible diameter is `2 * radius`.
    public var radius: CGFloat

    // MARK: Gravity & damping

    /// Vertical acceleration in pt/s². Negative falls down, positive floats up
    /// (balloon mode), zero is weightless. Driven by the active `GravityMode`.
    ///
    /// The PRD lists -980 ("close to real gravity") but that reads as floaty at
    /// screen scale where 1pt is tiny; we use a livelier default and keep it
    /// configurable. See `docs/adr/0001-rendering-and-physics-architecture.md`.
    public var gravityY: CGFloat

    /// Air drag as a velocity multiplier applied per 1/60 s (rate-independent via
    /// `pow`). `1.0` = no drag; `< 1` bleeds speed while airborne.
    public var airDamping60: CGFloat

    /// Rolling resistance multiplier per 1/60 s while the ball touches the surface
    /// it rests against. Lower = the ball stops sooner. Horizontal component only.
    public var rollingResistance60: CGFloat

    // MARK: Collisions

    /// Fraction of normal-velocity kept after a wall/ground bounce (0…1).
    public var restitution: CGFloat

    /// Below this speed at surface contact the bounce is cancelled and the ball is
    /// considered resting (prevents infinite micro-bounces on floor or ceiling).
    public var bounceCutoff: CGFloat

    /// Below this total speed while resting the ball is put to sleep (vel = 0),
    /// so it can settle to a clean stop and start the idle breathing animation.
    public var sleepSpeed: CGFloat

    /// Hard cap on speed (pt/s) to keep the integrator stable under rapid kicks.
    public var maxSpeed: CGFloat

    // MARK: Mouse interaction

    /// Radius (pt) of the mouse force field, measured from the ball centre.
    public var kickRadius: CGFloat

    /// Impulse gain for a fast swipe across the ball: the harder the cursor is
    /// moving *toward* the ball, the stronger the kick. Mirrors `HUDPanel.dynamicK`.
    public var kickGain: CGFloat

    /// Gentle "airflow" acceleration (pt/s²) felt when the cursor lingers near the
    /// ball at low speed — nudges it away like a breeze. Mirrors `HUDPanel.staticK`
    /// but an order of magnitude softer so the ball drifts rather than flees.
    public var hoverForce: CGFloat

    /// Upward velocity kick (pt/s) added when the ball is clicked ("dribble").
    public var clickImpulse: CGFloat

    /// Speed of an incoming swipe (pt/s) above which a kick is allowed to play its
    /// sound / particles — distinguishes a deliberate swipe from idle drift.
    public var swipeSoundThreshold: CGFloat

    // MARK: Snap-to-cursor (right Option)

    /// Spring stiffness (1/s²) pulling the ball toward the point below the cursor
    /// while right Option is held. Higher = the ball tracks the cursor more tightly.
    public var snapStiffness: CGFloat

    /// Velocity damping multiplier per 1/60 s applied during snap, tuned near
    /// critical so the ball settles under the cursor without ringing.
    public var snapDamping60: CGFloat

    /// How far (pt) the ball centre sits *below* the cursor when snapped, so the
    /// cursor stays visible just above the ball.
    public var snapCursorOffset: CGFloat

    /// Distance (pt) between the ball and its target below the cursor beyond which
    /// the snap breaks and the ball falls back into collision mode — whether the
    /// cursor moved away too fast or gravity dragged the ball off.
    public var snapBreakDistance: CGFloat

    /// While right Option stays held after a break, the ball re-snaps once the
    /// cursor comes back within this distance (pt) of it. Kept below
    /// `snapBreakDistance` so there is hysteresis: a flick still throws the ball
    /// clear, but deliberately moving the cursor back onto it re-grabs it.
    public var snapCaptureDistance: CGFloat

    // MARK: Deformation

    /// Maximum squash amount (0…1) at the hardest landing. `0.4` ≈ 40% flatter.
    public var maxSquash: CGFloat

    /// Impact speed (pt/s) that produces `maxSquash`. Faster impacts are clamped.
    public var squashReference: CGFloat

    /// Squash recovery multiplier per 1/60 s — how fast the ball springs back to
    /// round after a bounce.
    public var squashRecovery60: CGFloat

    public init(
        radius: CGFloat = 30,
        gravityY: CGFloat = PhysicsConfig.normalGravity,
        airDamping60: CGFloat = 0.999,
        rollingResistance60: CGFloat = 0.95,
        restitution: CGFloat = 0.58,
        bounceCutoff: CGFloat = 90,
        sleepSpeed: CGFloat = 14,
        maxSpeed: CGFloat = 6000,
        kickRadius: CGFloat = 95,
        kickGain: CGFloat = 130,
        hoverForce: CGFloat = 220,
        clickImpulse: CGFloat = 950,
        swipeSoundThreshold: CGFloat = 600,
        snapStiffness: CGFloat = 200,
        snapDamping60: CGFloat = 0.72,
        snapCursorOffset: CGFloat = 42,
        snapBreakDistance: CGFloat = 85,
        snapCaptureDistance: CGFloat = 55,
        maxSquash: CGFloat = 0.55,
        squashReference: CGFloat = 1700,
        squashRecovery60: CGFloat = 0.82
    ) {
        self.radius = radius
        self.gravityY = gravityY
        self.airDamping60 = airDamping60
        self.rollingResistance60 = rollingResistance60
        self.restitution = restitution
        self.bounceCutoff = bounceCutoff
        self.sleepSpeed = sleepSpeed
        self.maxSpeed = maxSpeed
        self.kickRadius = kickRadius
        self.kickGain = kickGain
        self.hoverForce = hoverForce
        self.clickImpulse = clickImpulse
        self.swipeSoundThreshold = swipeSoundThreshold
        self.snapStiffness = snapStiffness
        self.snapDamping60 = snapDamping60
        self.snapCursorOffset = snapCursorOffset
        self.snapBreakDistance = snapBreakDistance
        self.snapCaptureDistance = snapCaptureDistance
        self.maxSquash = maxSquash
        self.squashReference = squashReference
        self.squashRecovery60 = squashRecovery60
    }

    /// The canonical desktop-football tuning.
    public static let standard = PhysicsConfig()
}
