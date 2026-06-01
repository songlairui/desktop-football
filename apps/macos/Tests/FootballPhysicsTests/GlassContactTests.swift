import CoreGraphics
import XCTest
@testable import FootballPhysics

final class GlassContactTests: XCTestCase {

    func testFastSwipeAcrossProjectedDiskProducesImpulseInSwipeDirection() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 500),
            mouse: CGPoint(x: 580, y: 500),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertTrue(result.didStrike)
        XCTAssertGreaterThan(result.impulse.x, 0)
        XCTAssertEqual(result.impulse.y, 0, accuracy: 0.001)
    }

    func testFastSwipeProducesStrongStrikeImpulse() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 500),
            mouse: CGPoint(x: 580, y: 500),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertGreaterThan(hypot(result.impulse.x, result.impulse.y), 3_000)
    }

    func testVeryFastSwipeProducesPowerStrikeImpulse() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 500),
            mouse: CGPoint(x: 580, y: 500),
            mouseVelocity: CGPoint(x: 4_200, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertGreaterThan(hypot(result.impulse.x, result.impulse.y), 7_500)
    }

    func testStrikeReportsProjectedContactOffset() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 530),
            mouse: CGPoint(x: 580, y: 530),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertTrue(result.didStrike)
        XCTAssertEqual(result.contactOffset.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.contactOffset.y, 30, accuracy: 0.001)
    }

    func testSlowSwipeDoesNotStrike() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 460, y: 500),
            mouse: CGPoint(x: 520, y: 500),
            mouseVelocity: CGPoint(x: 250, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertEqual(result, .zero)
    }

    func testPassingOutsideProjectedDiskDoesNotStrike() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 575),
            mouse: CGPoint(x: 580, y: 575),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: true
        )

        XCTAssertEqual(result, .zero)
    }

    func testCooldownSuppressesRepeatedStrike() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 420, y: 500),
            mouse: CGPoint(x: 580, y: 500),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: false,
            cooldownReady: false
        )

        XCTAssertEqual(result, .zero)
    }

    func testCursorAlreadyInsideDiskDoesNotFireUntilItCrossesOutOrReenters() {
        let result = GlassContact.evaluate(
            ballCenter: CGPoint(x: 500, y: 500),
            previousMouse: CGPoint(x: 490, y: 500),
            mouse: CGPoint(x: 510, y: 500),
            mouseVelocity: CGPoint(x: 2_400, y: 0),
            strikeRadius: 50,
            minimumSpeed: 600,
            wasInside: true,
            cooldownReady: true
        )

        XCTAssertEqual(result, .zero)
    }
}
