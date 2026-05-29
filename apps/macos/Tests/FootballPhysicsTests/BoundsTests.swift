import CoreGraphics
import XCTest
@testable import FootballPhysics

final class BoundsTests: XCTestCase {

    private let bounds = Bounds(rect: CGRect(x: 100, y: 50, width: 800, height: 600))
    private let radius: CGFloat = 30

    func testCentreSpanIsInsetByRadius() {
        XCTAssertEqual(bounds.minX(radius: radius), 130)
        XCTAssertEqual(bounds.maxX(radius: radius), 870)
        XCTAssertEqual(bounds.floorY(radius: radius), 80)
        XCTAssertEqual(bounds.ceilingY(radius: radius), 620)
    }

    func testClampPullsOutOfBoundsPointBack() {
        let clamped = bounds.clampCenter(CGPoint(x: -1000, y: 100_000), radius: radius)
        XCTAssertEqual(clamped.x, bounds.minX(radius: radius))
        XCTAssertEqual(clamped.y, bounds.ceilingY(radius: radius))
    }

    func testClampLeavesInteriorPointUnchanged() {
        let p = CGPoint(x: 500, y: 300)
        XCTAssertEqual(bounds.clampCenter(p, radius: radius), p)
    }
}
