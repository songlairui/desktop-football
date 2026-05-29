import CoreGraphics
import XCTest
@testable import FootballPhysics

final class KickFieldTests: XCTestCase {

    private let config = PhysicsConfig.standard

    func testCursorOutsideRadiusProducesNoForce() {
        let result = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 500 + config.kickRadius + 10, y: 500),
            mouseVelocity: CGPoint(x: -2000, y: 0),
            config: config
        )
        XCTAssertEqual(result, .zero)
    }

    func testSwipeTowardBallKicksItAway() {
        // Cursor to the left of the ball, swiping right (toward it) ⇒ ball pushed right.
        let result = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 460, y: 500),
            mouseVelocity: CGPoint(x: 3000, y: 0),
            config: config
        )
        XCTAssertGreaterThan(result.force.x, 0, "ball should be pushed away from the cursor")
        XCTAssertGreaterThan(result.approachSpeed, 0)
    }

    func testRecedingCursorAddsNoKickButStillHovers() {
        // Cursor inside the field but swiping away ⇒ no dynamic kick, only static hover.
        let receding = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 460, y: 500),
            mouseVelocity: CGPoint(x: -3000, y: 0),
            config: config
        )
        XCTAssertEqual(receding.approachSpeed, 0, "approach speed clamps to zero when receding")
        XCTAssertGreaterThan(receding.force.x, 0, "static airflow still nudges the ball away")

        // The hover-only push must be far weaker than a real kick.
        let kicking = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 460, y: 500),
            mouseVelocity: CGPoint(x: 3000, y: 0),
            config: config
        )
        XCTAssertGreaterThan(kicking.force.x, receding.force.x * 3)
    }

    func testForcePointsAwayAlongCursorToBallAxis() {
        // Cursor below-left of the ball ⇒ push is up-right.
        let result = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 470, y: 470),
            mouseVelocity: CGPoint(x: 1500, y: 1500),
            config: config
        )
        XCTAssertGreaterThan(result.force.x, 0)
        XCTAssertGreaterThan(result.force.y, 0)
    }

    func testStrengthFallsOffWithDistance() {
        let near = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 490, y: 500),
            mouseVelocity: .zero,
            config: config
        )
        let far = KickField.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            mouse: CGPoint(x: 500 - config.kickRadius + 5, y: 500),
            mouseVelocity: .zero,
            config: config
        )
        XCTAssertGreaterThan(abs(near.force.x), abs(far.force.x),
                             "hover force is stronger nearer the centre")
    }
}
