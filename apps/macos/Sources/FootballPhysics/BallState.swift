import CoreGraphics

/// The complete physical state of the ball plus the integrator that advances it.
///
/// Coordinates are **ball centres** in screen space (+Y up). The renderer turns
/// `angle` / `squash` / `velocity` into a CALayer transform; the window's origin
/// is simply `center - windowSize/2`.
///
/// Rotation convention matches Core Animation's layer space (counter-clockwise
/// positive). A ball rolling to the right (`velocity.x > 0`) spins **clockwise**,
/// i.e. `angularVelocity = -velocity.x / radius`, which decreases `angle`.
public struct BallState: Equatable, Sendable {

    /// Ball centre in screen coordinates.
    public var center: CGPoint
    /// Linear velocity, pt/s.
    public var velocity: CGPoint
    /// Texture rotation, radians (CALayer convention: CCW positive).
    public var angle: CGFloat
    /// Spin rate, rad/s. Derived from horizontal speed each frame (`-vx / r`).
    public var angularVelocity: CGFloat
    /// Vertical compression, 0…1. `0` = perfectly round, `0.4` = 40% squashed.
    public var squash: CGFloat
    /// True while the cursor is dragging the ball (gravity suspended).
    public var isGrabbed: Bool

    public init(
        center: CGPoint,
        velocity: CGPoint = .zero,
        angle: CGFloat = 0,
        angularVelocity: CGFloat = 0,
        squash: CGFloat = 0,
        isGrabbed: Bool = false
    ) {
        self.center = center
        self.velocity = velocity
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.squash = squash
        self.isGrabbed = isGrabbed
    }

    /// A ball sitting still on the ground at horizontal position `x`.
    public static func resting(atX x: CGFloat, bounds: Bounds, config: PhysicsConfig) -> BallState {
        BallState(center: CGPoint(x: x, y: bounds.floorY(radius: config.radius)))
    }

    // MARK: - Derived

    private static let groundTolerance: CGFloat = 0.5

    /// Whether the ball is resting on (or pressed against) the floor.
    public func isGrounded(config: PhysicsConfig, bounds: Bounds) -> Bool {
        center.y <= bounds.floorY(radius: config.radius) + Self.groundTolerance
    }

    /// Coarse motion classification for the renderer / sound layer.
    public func motionState(config: PhysicsConfig, bounds: Bounds) -> MotionState {
        if isGrabbed { return .grabbed }
        if !isGrounded(config: config, bounds: bounds) || abs(velocity.y) > config.bounceCutoff {
            return .flying
        }
        let rollThreshold = config.sleepSpeed * 1.5
        if abs(velocity.x) > rollThreshold { return .rolling }
        return .idle
    }

    // MARK: - Integration

    /// Advance the free (non-grabbed) ball by `dt` seconds under gravity plus the
    /// mouse field force. Returns the discrete events that fired this frame.
    @discardableResult
    public mutating func step(
        dt: CGFloat,
        fieldForce: CGPoint,
        bounds: Bounds,
        config: PhysicsConfig
    ) -> PhysicsEvents {
        guard dt > 0 else { return .none }
        var events = PhysicsEvents.none

        // Last frame's squash relaxes toward round; a fresh impact below overrides.
        squash *= pow(config.squashRecovery60, dt * 60.0)

        let groundedAtStart = isGrounded(config: config, bounds: bounds)

        // 1. Accelerate: gravity (vertical) + mouse field (both axes).
        velocity.x += fieldForce.x * dt
        velocity.y += (config.gravityY + fieldForce.y) * dt

        // 2. Damping. Air drag always; rolling resistance only while grounded.
        let airDecay = pow(config.airDamping60, dt * 60.0)
        velocity.x *= airDecay
        velocity.y *= airDecay
        if groundedAtStart {
            velocity.x *= pow(config.rollingResistance60, dt * 60.0)
        }

        clampSpeed(to: config.maxSpeed)

        // 3. Integrate position.
        center.x += velocity.x * dt
        center.y += velocity.y * dt

        // 4. Resolve collisions with the four walls + floor.
        resolveCollisions(bounds: bounds, config: config, events: &events)

        // 5. Settle: a slow grounded ball is put fully to sleep for a clean stop.
        if isGrounded(config: config, bounds: bounds),
           hypot(velocity.x, velocity.y) < config.sleepSpeed {
            velocity = .zero
        }

        // 6. Spin tracks horizontal speed (pure-rolling assumption).
        updateSpin(dt: dt, config: config)

        return events
    }

    /// Drive the ball while it is being dragged: snap the centre to `target` and
    /// derive a velocity from the motion so releasing throws it naturally.
    public mutating func follow(
        target: CGPoint,
        dt: CGFloat,
        bounds: Bounds,
        config: PhysicsConfig
    ) {
        let clamped = bounds.clampCenter(target, radius: config.radius)
        if dt > 0 {
            velocity = CGPoint(x: (clamped.x - center.x) / dt,
                               y: (clamped.y - center.y) / dt)
            clampSpeed(to: config.maxSpeed)
        }
        center = clamped
        squash *= pow(config.squashRecovery60, dt * 60.0)
        updateSpin(dt: dt, config: config)
    }

    /// A click "dribble": pop the ball straight up.
    public mutating func applyClick(config: PhysicsConfig) {
        velocity.y += config.clickImpulse
        clampSpeed(to: config.maxSpeed)
    }

    // MARK: - Helpers

    private mutating func updateSpin(dt: CGFloat, config: PhysicsConfig) {
        angularVelocity = -velocity.x / max(config.radius, 1)
        angle += angularVelocity * dt
    }

    private mutating func clampSpeed(to maxSpeed: CGFloat) {
        let speed = hypot(velocity.x, velocity.y)
        guard speed > maxSpeed, speed > 0 else { return }
        let k = maxSpeed / speed
        velocity.x *= k
        velocity.y *= k
    }

    private mutating func resolveCollisions(
        bounds: Bounds,
        config: PhysicsConfig,
        events: inout PhysicsEvents
    ) {
        let floorY = bounds.floorY(radius: config.radius)
        let ceilY = bounds.ceilingY(radius: config.radius)
        let minX = bounds.minX(radius: config.radius)
        let maxX = bounds.maxX(radius: config.radius)

        // Floor — the only surface that triggers landing squash + landing sound.
        if center.y < floorY {
            let impact = abs(velocity.y)
            center.y = floorY
            if impact > config.bounceCutoff {
                velocity.y = impact * config.restitution
                events.landed = impact
                let amount = config.maxSquash * min(1, impact / config.squashReference)
                squash = max(squash, amount)
            } else {
                velocity.y = 0
            }
        }

        // Ceiling.
        if center.y > ceilY {
            let impact = abs(velocity.y)
            center.y = ceilY
            velocity.y = -impact * config.restitution
            if impact > config.bounceCutoff { events.hitWall = max(events.hitWall ?? 0, impact) }
        }

        // Left / right walls.
        if center.x < minX {
            let impact = abs(velocity.x)
            center.x = minX
            velocity.x = impact * config.restitution
            if impact > config.bounceCutoff { events.hitWall = max(events.hitWall ?? 0, impact) }
        }
        if center.x > maxX {
            let impact = abs(velocity.x)
            center.x = maxX
            velocity.x = -impact * config.restitution
            if impact > config.bounceCutoff { events.hitWall = max(events.hitWall ?? 0, impact) }
        }
    }
}
