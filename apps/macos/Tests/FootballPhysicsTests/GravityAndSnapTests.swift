import CoreGraphics
import XCTest
@testable import FootballPhysics

/// Covers the gravity-mode (zero / balloon) and right-Option snap behaviour added
/// on top of the original drop-and-roll physics.
final class GravityAndSnapTests: XCTestCase {

    private let bounds = Bounds(rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private let dt: CGFloat = 1.0 / 60.0

    private func balloonConfig() -> PhysicsConfig {
        var c = PhysicsConfig.standard
        c.gravityY = GravityMode.balloon.gravityY
        return c
    }

    private func zeroGravityConfig() -> PhysicsConfig {
        var c = PhysicsConfig.standard
        c.gravityY = 0
        return c
    }

    // MARK: - Gravity mode mapping

    func testGravityModeValues() {
        XCTAssertEqual(GravityMode.normal.gravityY, PhysicsConfig.normalGravity)
        XCTAssertEqual(GravityMode.zero.gravityY, 0)
        XCTAssertGreaterThan(GravityMode.balloon.gravityY, 0, "balloon mode floats up")
        XCTAssertEqual(GravityMode.allCases.count, 3)
    }

    // MARK: - Balloon (anti-gravity) mode

    func testBalloonRisesAndRestsAtCeiling() {
        let config = balloonConfig()
        var ball = BallState.resting(atX: 700, bounds: bounds, config: config)

        for _ in 0..<1200 {   // 20 s — plenty to float up and settle
            ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
        }

        XCTAssertEqual(ball.center.y, bounds.ceilingY(radius: config.radius), accuracy: 1,
                       "an anti-gravity ball should float up and settle on the ceiling")
        XCTAssertEqual(hypot(ball.velocity.x, ball.velocity.y), 0, accuracy: 0.001,
                       "and come fully to rest there")
    }

    func testCeilingBounceReversesVerticalVelocity() {
        let config = PhysicsConfig.standard
        var ball = BallState(center: CGPoint(x: 700, y: bounds.ceilingY(radius: config.radius) - 4),
                             velocity: CGPoint(x: 0, y: 3000))
        let events = ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)

        XCTAssertLessThan(ball.velocity.y, 0, "should rebound downward off the ceiling")
        XCTAssertNotNil(events.hitWall, "a hard ceiling hit fires a wall event")
    }

    // MARK: - Zero gravity

    func testZeroGravityHasNoVerticalDrift() {
        let config = zeroGravityConfig()
        var ball = BallState(center: CGPoint(x: 700, y: 500), velocity: CGPoint(x: 300, y: 0))
        let startY = ball.center.y

        for _ in 0..<120 {
            ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
        }

        XCTAssertEqual(ball.center.y, startY, accuracy: 0.001, "no gravity → the ball never falls")
        XCTAssertGreaterThan(ball.center.x, 700, "horizontal momentum carries it sideways")
    }

    // MARK: - isResting tracks gravity direction

    func testIsRestingFollowsGravityDirection() {
        let normal = PhysicsConfig.standard           // gravity down
        let balloon = balloonConfig()                 // gravity up
        var ball = BallState.resting(atX: 700, bounds: bounds, config: normal)

        XCTAssertTrue(ball.isResting(config: normal, bounds: bounds),
                      "on the floor counts as resting under normal gravity")
        XCTAssertFalse(ball.isResting(config: balloon, bounds: bounds),
                       "the floor is not the resting surface in balloon mode")

        ball.center.y = bounds.ceilingY(radius: balloon.radius)
        XCTAssertTrue(ball.isResting(config: balloon, bounds: bounds),
                      "the ceiling is the resting surface in balloon mode")
    }

    // MARK: - Snap to cursor (right Option)

    func testSnapHoldsBallBelowStationaryCursor() {
        let config = PhysicsConfig.standard
        let target = CGPoint(x: 700, y: 500)
        var ball = BallState(center: target, isSnapped: true)   // panel teleports here on press

        for _ in 0..<240 {
            ball.snapStep(target: target, dt: dt, bounds: bounds, config: config)
        }

        XCTAssertTrue(ball.isSnapped, "a still cursor keeps the ball snapped")
        XCTAssertEqual(ball.center.x, target.x, accuracy: 1)
        // Spring vs. gravity equilibrium hangs the ball ~|g|/k below the cursor.
        let expectedSag = -config.gravityY / config.snapStiffness
        XCTAssertEqual(ball.center.y, target.y - expectedSag, accuracy: 6,
                       "ball hangs just below the cursor under normal gravity")
        XCTAssertLessThan(target.y - ball.center.y, config.snapBreakDistance,
                          "the gravity sag stays within the break distance")
    }

    func testSnapBreaksWhenCursorOutrunsBall() {
        let config = PhysicsConfig.standard
        var ball = BallState(center: CGPoint(x: 700, y: 500), isSnapped: true)
        let jumped = CGPoint(x: 1300, y: 500)   // cursor leaps ~600pt in one frame

        let stillSnapped = ball.snapStep(target: jumped, dt: dt, bounds: bounds, config: config)

        XCTAssertFalse(stillSnapped, "the ball can't keep up and breaks away")
        XCTAssertFalse(ball.isSnapped)
    }

    func testSnappedBallReportsGrabbedMotion() {
        let config = PhysicsConfig.standard
        var ball = BallState.resting(atX: 700, bounds: bounds, config: config)
        ball.isSnapped = true
        XCTAssertEqual(ball.motionState(config: config, bounds: bounds), .grabbed,
                       "a snapped ball renders held, not idle/rolling")
    }

    func testSnapSitsAtTargetUnderZeroGravity() {
        let config = zeroGravityConfig()
        let target = CGPoint(x: 700, y: 500)
        var ball = BallState(center: target, isSnapped: true)

        for _ in 0..<240 {
            ball.snapStep(target: target, dt: dt, bounds: bounds, config: config)
        }

        XCTAssertTrue(ball.isSnapped, "weightless snap holds with no oscillation drift")
        XCTAssertEqual(ball.center.x, target.x, accuracy: 0.5)
        XCTAssertEqual(ball.center.y, target.y, accuracy: 0.5, "zero gravity → ball sits exactly at target")
    }

    func testSnapEquilibriumTracksGravityInBalloonMode() {
        let config = balloonConfig()
        let target = CGPoint(x: 700, y: 500)
        var ball = BallState(center: target, isSnapped: true)

        for _ in 0..<240 {
            ball.snapStep(target: target, dt: dt, bounds: bounds, config: config)
        }

        XCTAssertTrue(ball.isSnapped, "the small balloon-gravity offset stays within the break distance")
        // Equilibrium sits gravityY/snapStiffness off the target (above it, since
        // balloon gravity is upward). The panel cancels this in snapTarget() so the
        // *visible* offset below the cursor stays constant across modes.
        let expected = target.y + config.gravityY / config.snapStiffness
        XCTAssertEqual(ball.center.y, expected, accuracy: 4)
        XCTAssertGreaterThan(ball.center.y, target.y, "balloon gravity lifts the ball slightly above the raw target")
    }

    // MARK: - Landing-surface audio routing

    func testBalloonCeilingCountsAsLanding() {
        let config = balloonConfig()
        var ball = BallState(center: CGPoint(x: 700, y: bounds.ceilingY(radius: config.radius) - 4),
                             velocity: CGPoint(x: 0, y: 3000))
        let events = ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)

        XCTAssertNotNil(events.landed, "the ceiling is the landing surface in balloon mode (full-volume audio)")
        XCTAssertNil(events.hitWall, "and not a reduced-volume wall hit")
    }

    func testFloorStillCountsAsLandingUnderNormalGravity() {
        let config = PhysicsConfig.standard
        var ball = BallState(center: CGPoint(x: 700, y: bounds.floorY(radius: config.radius) + 4),
                             velocity: CGPoint(x: 0, y: -3000))
        let events = ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)

        XCTAssertNotNil(events.landed, "the floor stays the landing surface under normal gravity")
    }
}
