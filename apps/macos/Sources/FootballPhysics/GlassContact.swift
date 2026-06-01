import CoreGraphics

/// Predictable "front glass" interaction for the 3D presentation.
///
/// The cursor lives on the screen plane. A strike happens only when the cursor
/// path crosses the ball's projected contact disk, then the ball receives one
/// velocity impulse in the cursor's travel direction.
public enum GlassContact {

    public struct Result: Equatable, Sendable {
        public var impulse: CGPoint
        public var strength: CGFloat
        /// Projected contact point relative to the ball centre, in screen points.
        /// This lets the renderer derive billiards-style side spin from
        /// `contactOffset × impulse` without changing the 2D position physics.
        public var contactOffset: CGPoint

        public var didStrike: Bool {
            impulse.x != 0 || impulse.y != 0
        }

        public init(impulse: CGPoint, strength: CGFloat, contactOffset: CGPoint = .zero) {
            self.impulse = impulse
            self.strength = strength
            self.contactOffset = contactOffset
        }

        public static let zero = Result(impulse: .zero, strength: 0, contactOffset: .zero)
    }

    public static func evaluate(
        ballCenter: CGPoint,
        previousMouse: CGPoint,
        mouse: CGPoint,
        mouseVelocity: CGPoint,
        strikeRadius: CGFloat,
        minimumSpeed: CGFloat,
        wasInside: Bool,
        cooldownReady: Bool
    ) -> Result {
        guard cooldownReady, strikeRadius > 0 else { return .zero }

        let speed = hypot(mouseVelocity.x, mouseVelocity.y)
        guard speed >= minimumSpeed else { return .zero }

        let nowInside = distance(mouse, ballCenter) <= strikeRadius
        let contact = closestPoint(to: ballCenter, onSegmentFrom: previousMouse, to: mouse)
        let contactDistance = distance(contact, ballCenter)
        let crossedDisk = contactDistance <= strikeRadius
        guard crossedDisk, !wasInside || !nowInside else { return .zero }

        let ux = mouseVelocity.x / speed
        let uy = mouseVelocity.y / speed
        let t = min(1, max(0, (speed - minimumSpeed) / 2_800))
        let burst = pow(t, 0.75)
        let magnitude: CGFloat = 1_400 + 6_600 * burst
        let contactOffset = CGPoint(x: contact.x - ballCenter.x,
                                    y: contact.y - ballCenter.y)
        return Result(impulse: CGPoint(x: ux * magnitude, y: uy * magnitude),
                      strength: t,
                      contactOffset: contactOffset)
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    public static func segmentDistance(from point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        distance(point, closestPoint(to: point, onSegmentFrom: a, to: b))
    }

    public static func closestPoint(to point: CGPoint, onSegmentFrom a: CGPoint, to b: CGPoint) -> CGPoint {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        guard len2 > 0 else { return a }

        let wx = point.x - a.x
        let wy = point.y - a.y
        let t = max(0, min(1, (wx * vx + wy * vy) / len2))
        return CGPoint(x: a.x + vx * t, y: a.y + vy * t)
    }
}
