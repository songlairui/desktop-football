import CoreGraphics

/// The complete physical state of the ball plus the integrator that advances it.
///
/// Coordinates are **ball centres** in screen space (+Y up). The renderer turns
/// `angle` / `squash` / `velocity` into the visible ball transform.
///
/// Rotation convention matches Core Animation's layer space (counter-clockwise
/// positive). A ball rolling to the right (`velocity.x > 0`) spins **clockwise**,
/// i.e. `angularVelocity = -velocity.x / radius`, which decreases `angle`. The
/// current 3D renderer maps this legacy screen-space spin onto the camera-facing
/// Z axis; future true-depth modes should use a dedicated 3D orientation state.
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
    /// True while the ball is snapped below the cursor (right Option). A soft
    /// spring holds it under the cursor while gravity still tugs; it breaks back
    /// into free physics once it strays past `snapBreakDistance`.
    public var isSnapped: Bool

    public init(
        center: CGPoint,
        velocity: CGPoint = .zero,
        angle: CGFloat = 0,
        angularVelocity: CGFloat = 0,
        squash: CGFloat = 0,
        isGrabbed: Bool = false,
        isSnapped: Bool = false
    ) {
        self.center = center
        self.velocity = velocity
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.squash = squash
        self.isGrabbed = isGrabbed
        self.isSnapped = isSnapped
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

    /// Whether the ball is pressed against the ceiling (the resting surface in
    /// balloon / anti-gravity mode).
    public func isCeiled(config: PhysicsConfig, bounds: Bounds) -> Bool {
        center.y >= bounds.ceilingY(radius: config.radius) - Self.groundTolerance
    }

    /// Whether the ball is settled against the surface gravity pulls it toward —
    /// the floor under normal gravity, the ceiling in balloon mode, or either when
    /// weightless. Drives sleeping, rolling resistance and the idle animation so
    /// they work the same in every gravity world.
    public func isResting(config: PhysicsConfig, bounds: Bounds) -> Bool {
        if config.gravityY < 0 { return isGrounded(config: config, bounds: bounds) }
        if config.gravityY > 0 { return isCeiled(config: config, bounds: bounds) }
        return isGrounded(config: config, bounds: bounds) || isCeiled(config: config, bounds: bounds)
    }

    /// Coarse motion classification for the renderer / sound layer.
    public func motionState(config: PhysicsConfig, bounds: Bounds) -> MotionState {
        if isGrabbed || isSnapped { return .grabbed }
        if !isResting(config: config, bounds: bounds) || abs(velocity.y) > config.bounceCutoff {
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

        squash = 0

        let restingAtStart = isResting(config: config, bounds: bounds)

        // 1. Accelerate: gravity (vertical) + mouse field (both axes).
        velocity.x += fieldForce.x * dt
        velocity.y += (config.gravityY + fieldForce.y) * dt

        // 2. Damping. Air drag always; rolling resistance only while resting on a
        //    surface (floor under gravity, ceiling under balloon mode).
        let airDecay = pow(config.airDamping60, dt * 60.0)
        velocity.x *= airDecay
        velocity.y *= airDecay
        if restingAtStart {
            velocity.x *= pow(config.rollingResistance60, dt * 60.0)
        }

        clampSpeed(to: config.maxSpeed)

        // 3. Integrate position.
        center.x += velocity.x * dt
        center.y += velocity.y * dt

        // 4. Resolve collisions with the four walls + floor.
        resolveCollisions(bounds: bounds, config: config, events: &events)

        // 5. Settle: a slow ball resting against its surface is put fully to sleep
        //    for a clean stop (floor under gravity, ceiling under balloon mode).
        if isResting(config: config, bounds: bounds),
           hypot(velocity.x, velocity.y) < config.sleepSpeed {
            velocity = .zero
        }

        // 6. Spin is coupled to horizontal speed by surface friction. In the air,
        // or immediately after a bounce, existing spin carries through instead of
        // snapping to the new travel direction.
        updateSpin(dt: dt, config: config, bounds: bounds)

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
        squash = 0
        updateSpin(dt: dt, config: config)
    }

    /// Hold the ball below the cursor while right Option is pressed.
    ///
    /// A spring pulls the ball toward `target` (the point below the cursor) while
    /// gravity keeps tugging, so the ball hangs just under the cursor and follows
    /// it. The attachment is *soft*: if the cursor outruns the spring, or gravity
    /// drags the ball off, the ball strays past `snapBreakDistance`, `isSnapped`
    /// flips to `false`, and the caller hands it back to free physics with the
    /// velocity it had built up.
    ///
    /// - Returns: whether the ball is still snapped after this step.
    @discardableResult
    public mutating func snapStep(
        target: CGPoint,
        dt: CGFloat,
        bounds: Bounds,
        config: PhysicsConfig
    ) -> Bool {
        guard dt > 0 else { return isSnapped }

        let dx = target.x - center.x
        let dy = target.y - center.y

        // Spring toward the cursor + the ambient gravity of the active mode.
        velocity.x += dx * config.snapStiffness * dt
        velocity.y += (dy * config.snapStiffness + config.gravityY) * dt

        let decay = pow(config.snapDamping60, dt * 60.0)
        velocity.x *= decay
        velocity.y *= decay
        clampSpeed(to: config.maxSpeed)

        center.x += velocity.x * dt
        center.y += velocity.y * dt
        center = bounds.clampCenter(center, radius: config.radius)

        squash = 0
        updateSpin(dt: dt, config: config)

        if hypot(target.x - center.x, target.y - center.y) > config.snapBreakDistance {
            isSnapped = false
        }
        return isSnapped
    }

    /// A click "dribble": pop the ball straight up.
    public mutating func applyClick(config: PhysicsConfig) {
        velocity.y += config.clickImpulse
        clampSpeed(to: config.maxSpeed)
    }

    // MARK: - Helpers

    private mutating func updateSpin(dt: CGFloat, config: PhysicsConfig, bounds: Bounds? = nil) {
        let rollingTarget = -velocity.x / max(config.radius, 1)
        if let bounds {
            if isResting(config: config, bounds: bounds) {
                let grip = 1 - pow(0.72, dt * 60.0)
                angularVelocity += (rollingTarget - angularVelocity) * grip
            } else {
                angularVelocity *= pow(0.992, dt * 60.0)
            }
        } else {
            angularVelocity = rollingTarget
        }
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

        // The surface gravity pulls the ball onto is the "landing" surface
        // for sound/events; the opposite is just a wall bounce. Under
        // normal/zero gravity that's the floor; in balloon mode it's the ceiling.
        let floorIsLanding = config.gravityY <= 0

        // Floor.
        if center.y < floorY {
            let impact = abs(velocity.y)
            center.y = floorY
            if impact > config.bounceCutoff {
                velocity.y = impact * (floorIsLanding ? config.restitution : config.wallRestitution)
                if floorIsLanding { events.landed = max(events.landed ?? 0, impact) }
                else { events.hitWall = max(events.hitWall ?? 0, impact) }
            } else {
                velocity.y = 0
            }
        }

        // Ceiling — mirrors the floor so balloon mode can settle against the top
        // instead of jittering: a soft touch is cancelled, a hard one bounces.
        // In balloon mode this is the landing surface.
        if center.y > ceilY {
            let impact = abs(velocity.y)
            center.y = ceilY
            if impact > config.bounceCutoff {
                velocity.y = -impact * (floorIsLanding ? config.wallRestitution : config.restitution)
                if floorIsLanding { events.hitWall = max(events.hitWall ?? 0, impact) }
                else { events.landed = max(events.landed ?? 0, impact) }
            } else {
                velocity.y = 0
            }
        }

        // Left / right walls.
        if center.x < minX {
            let impact = abs(velocity.x)
            center.x = minX
            velocity.x = impact * config.wallRestitution
            if impact > config.bounceCutoff { events.hitWall = max(events.hitWall ?? 0, impact) }
        }
        if center.x > maxX {
            let impact = abs(velocity.x)
            center.x = maxX
            velocity.x = -impact * config.wallRestitution
            if impact > config.bounceCutoff { events.hitWall = max(events.hitWall ?? 0, impact) }
        }
    }
}
