import Foundation
import simd

/// 3D damped-oscillator pendulum used by the "Hanging Charm" idle mode.
///
/// The ball is attached to a fixed anchor by an inextensible rope of length
/// `ropeLength` and oscillates around the rest point directly below the anchor
/// (gravity + rope tension are bundled into a single linear restoring force so
/// the integrator can be plain semi-implicit Euler). A persistent low-amplitude
/// "breeze" keeps the motion alive, and a hard rope-length cap removes any
/// radial component that would otherwise let the ball drift off the sphere.
public struct PendulumState {

    /// Anchor point in world space — the spot the rope hangs from. Typically
    /// placed above the visible viewport so the rope disappears off the top.
    public var anchor: SIMD3<Float>

    /// Rope length in world units. The ball centre is constrained to a sphere
    /// of this radius around `anchor`.
    public var ropeLength: Float

    /// Displacement of the ball from the anchor, in world space. At rest this
    /// is `(0, -ropeLength, 0)`. Tiny XY and Z deviations are what create the
    /// elliptical "3D swing" — the Z component is what gives the ball its
    /// "in-and-out" depth change that the perspective camera then turns into
    /// near/far size variation.
    public var displacement: SIMD3<Float>

    /// Time-derivative of `displacement`. Accumulated by the restoring force,
    /// decayed by damping, perturbed by the breeze.
    public var velocity: SIMD3<Float>

    /// Phase of the breeze sinusoid. Bumped every step so the wind never
    /// repeats exactly.
    public var windPhase: Float

    /// Linear restoring stiffness (1/s²). Period ≈ 2π / sqrt(stiffness).
    /// Defaults to ~5 → period ≈ 2.8 s.
    public var springStiffness: Float

    /// Per-second velocity multiplier (`< 1` = damped, `1` = no damping).
    /// Smaller = motion dies out faster. Default 0.78 lets a fresh impulse
    /// ring for ~5 s, but the breeze keeps topping it up.
    public var dampingPerSecond: Float

    /// RMS wind force in world units / s². Breeze injects energy continuously
    /// so the ball never quite comes to rest.
    public var windStrength: Float

    public init(anchor: SIMD3<Float>,
                ropeLength: Float,
                initialDisplacement: SIMD3<Float>? = nil,
                initialVelocity: SIMD3<Float> = .zero,
                springStiffness: Float = 5.0,
                dampingPerSecond: Float = 0.78,
                windStrength: Float = 1.1) {
        self.anchor = anchor
        self.ropeLength = ropeLength
        self.displacement = initialDisplacement ?? SIMD3<Float>(0, -ropeLength, 0)
        self.velocity = initialVelocity
        self.windPhase = 0
        self.springStiffness = springStiffness
        self.dampingPerSecond = dampingPerSecond
        self.windStrength = windStrength
    }

    /// World-space position of the ball centre.
    public var worldPosition: SIMD3<Float> { anchor + displacement }

    /// Breeze frequency parameters. Different per-axis so the XY and Z motions
    /// don't lock into a single plane — that's what turns the trace from a flat
    /// ellipse into a Lissajous-like 3D curve.
    public var windFrequencyX: Float { 0.7 }
    public var windFrequencyZ: Float { 0.9 }

    /// Advance the simulation by `dt` seconds.
    public mutating func step(dt: Float) {
        guard dt > 0 else { return }

        // 1. Linear restoring force around the rest point (anchor + (0, -L, 0)).
        let restDisplacement = SIMD3<Float>(0, -ropeLength, 0)
        let offset = displacement - restDisplacement
        let restoring = -springStiffness * offset

        // 2. Persistent breeze: low-frequency sinusoid + a touch of jitter, on
        //    X and Z only (Y motion would just shorten the rope).
        windPhase += dt
        let jitterX = Float.random(in: -0.35...0.35)
        let jitterZ = Float.random(in: -0.35...0.35)
        let windX = (sin(windPhase * windFrequencyX) * 0.65 + jitterX) * windStrength
        let windZ = (cos(windPhase * windFrequencyZ) * 0.65 + jitterZ) * windStrength
        let wind = SIMD3<Float>(windX, 0, windZ)

        // 3. Semi-implicit Euler with frame-rate-independent damping.
        velocity += (restoring + wind) * dt
        velocity *= pow(dampingPerSecond, dt)
        displacement += velocity * dt

        // 4. Hard rope-length constraint. Strip the radial component of velocity
        //    and snap the position back to the sphere so the ball can never
        //    drift "above" the anchor.
        let len = length(displacement)
        guard len > 0 else { return }
        if len > ropeLength {
            let n = displacement / len
            let radialV = dot(velocity, n) * n
            velocity -= radialV
            displacement = n * ropeLength
        }
    }

    /// Inject a one-shot impulse — used by the "nudge" interaction so a click
    /// gives the charm a satisfying kick.
    public mutating func nudge(impulse: SIMD3<Float>) {
        velocity += impulse
    }

    /// Reset the motion back to a clean rest position with a given initial
    /// displacement (e.g. when first entering the mode).
    public mutating func reset(displacement: SIMD3<Float>? = nil,
                               velocity: SIMD3<Float> = .zero) {
        self.displacement = displacement ?? SIMD3<Float>(0, -ropeLength, 0)
        self.velocity = velocity
        self.windPhase = 0
    }
}
