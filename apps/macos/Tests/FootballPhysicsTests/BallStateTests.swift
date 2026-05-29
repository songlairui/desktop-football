import CoreGraphics
import XCTest
@testable import FootballPhysics

final class BallStateTests: XCTestCase {

    private let config = PhysicsConfig.standard
    private let bounds = Bounds(rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private let dt: CGFloat = 1.0 / 60.0

    private func advance(_ ball: inout BallState, frames: Int, field: CGPoint = .zero) -> [PhysicsEvents] {
        var events: [PhysicsEvents] = []
        for _ in 0..<frames {
            events.append(ball.step(dt: dt, fieldForce: field, bounds: bounds, config: config))
        }
        return events
    }

    // MARK: US-1 basic motion

    func testGravityPullsBallDownAndItLands() {
        var ball = BallState(center: CGPoint(x: 700, y: 800))
        let events = advance(&ball, frames: 240)  // 4 s — plenty to fall 800pt

        XCTAssertEqual(ball.center.y, bounds.floorY(radius: config.radius), accuracy: 0.5,
                       "ball should come to rest on the floor")
        XCTAssertTrue(events.contains { $0.landed != nil }, "a landing event should fire")
    }

    func testBouncesDecayInHeight() {
        var ball = BallState(center: CGPoint(x: 700, y: 700))
        var peaks: [CGFloat] = []
        var prevY = ball.center.y
        var rising = false

        for _ in 0..<600 {
            ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
            let goingUp = ball.center.y > prevY
            if rising && !goingUp { peaks.append(prevY) }   // local maximum = bounce apex
            rising = goingUp
            prevY = ball.center.y
        }

        XCTAssertGreaterThanOrEqual(peaks.count, 2, "should bounce at least twice")
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1] + 0.5, "each bounce apex must be lower than the last")
        }
    }

    func testBallComesToRest() {
        var ball = BallState(center: CGPoint(x: 700, y: 700), velocity: CGPoint(x: 400, y: 0))
        advance(&ball, frames: 1200)  // 20 s
        XCTAssertEqual(hypot(ball.velocity.x, ball.velocity.y), 0, accuracy: 0.001,
                       "friction + sleep should bring the ball to a full stop")
        XCTAssertEqual(ball.center.y, bounds.floorY(radius: config.radius), accuracy: 0.5)
    }

    func testBallNeverLeavesBounds() {
        var ball = BallState(center: CGPoint(x: 700, y: 500),
                             velocity: CGPoint(x: 5000, y: 4000))
        for _ in 0..<1200 {
            ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
            XCTAssertGreaterThanOrEqual(ball.center.x, bounds.minX(radius: config.radius) - 0.5)
            XCTAssertLessThanOrEqual(ball.center.x, bounds.maxX(radius: config.radius) + 0.5)
            XCTAssertGreaterThanOrEqual(ball.center.y, bounds.floorY(radius: config.radius) - 0.5)
            XCTAssertLessThanOrEqual(ball.center.y, bounds.ceilingY(radius: config.radius) + 0.5)
        }
    }

    func testWallBounceReversesHorizontalVelocity() {
        // Launch right, into the right wall, while grounded.
        var ball = BallState(center: CGPoint(x: bounds.maxX(radius: config.radius) - 5, y: bounds.floorY(radius: config.radius)),
                             velocity: CGPoint(x: 3000, y: 0))
        let events = advance(&ball, frames: 3)
        XCTAssertLessThan(ball.velocity.x, 0, "should rebound leftward off the right wall")
        XCTAssertTrue(events.contains { $0.hitWall != nil }, "a wall-hit event should fire")
    }

    // MARK: US-3 spin

    func testRollingRightSpinsClockwise() {
        var ball = BallState(center: CGPoint(x: 700, y: bounds.floorY(radius: config.radius)),
                             velocity: CGPoint(x: 600, y: 0))
        ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
        // CALayer CCW-positive ⇒ clockwise spin is a negative angular velocity.
        XCTAssertLessThan(ball.angularVelocity, 0)
        XCTAssertEqual(ball.angularVelocity, -ball.velocity.x / config.radius, accuracy: 1e-6)
    }

    func testRollingLeftSpinsCounterClockwise() {
        var ball = BallState(center: CGPoint(x: 700, y: bounds.floorY(radius: config.radius)),
                             velocity: CGPoint(x: -600, y: 0))
        ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
        XCTAssertGreaterThan(ball.angularVelocity, 0)
    }

    // MARK: US-3 squash & stretch

    func testHardLandingProducesSquash() {
        var ball = BallState(center: CGPoint(x: 700, y: bounds.floorY(radius: config.radius) + 2),
                             velocity: CGPoint(x: 0, y: -3000))
        ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)
        XCTAssertGreaterThan(ball.squash, 0, "a hard landing should squash the ball")
        XCTAssertLessThanOrEqual(ball.squash, config.maxSquash + 1e-6)
    }

    func testSquashRelaxesBackToRound() {
        var ball = BallState(center: CGPoint(x: 700, y: bounds.floorY(radius: config.radius)),
                             squash: config.maxSquash)
        advance(&ball, frames: 120)
        XCTAssertLessThan(ball.squash, 0.02, "squash should decay back to round")
    }

    // MARK: Motion state classification

    func testMotionStateTransitions() {
        var ball = BallState.resting(atX: 700, bounds: bounds, config: config)
        XCTAssertEqual(ball.motionState(config: config, bounds: bounds), .idle)

        ball.velocity = CGPoint(x: 400, y: 0)
        XCTAssertEqual(ball.motionState(config: config, bounds: bounds), .rolling)

        ball.center.y += 200
        XCTAssertEqual(ball.motionState(config: config, bounds: bounds), .flying)

        ball.isGrabbed = true
        XCTAssertEqual(ball.motionState(config: config, bounds: bounds), .grabbed)
    }

    // MARK: Interaction helpers

    func testClickPopsBallUpward() {
        var ball = BallState.resting(atX: 700, bounds: bounds, config: config)
        ball.applyClick(config: config)
        XCTAssertEqual(ball.velocity.y, config.clickImpulse, accuracy: 1e-6)
    }

    func testFollowDerivesVelocityForThrow() {
        var ball = BallState(center: CGPoint(x: 700, y: 500))
        ball.follow(target: CGPoint(x: 760, y: 500), dt: dt, bounds: bounds, config: config)
        XCTAssertEqual(ball.velocity.x, 60 / dt, accuracy: 1.0, "release velocity = drag delta / dt")
        XCTAssertEqual(ball.center.x, 760, accuracy: 0.001)
    }

    func testFollowVelocityIsSpeedCapped() {
        var ball = BallState(center: CGPoint(x: 0, y: 500))
        ball.follow(target: CGPoint(x: 1_000_000, y: 500), dt: dt, bounds: bounds, config: config)
        XCTAssertLessThanOrEqual(hypot(ball.velocity.x, ball.velocity.y), config.maxSpeed + 1e-6)
    }
}
