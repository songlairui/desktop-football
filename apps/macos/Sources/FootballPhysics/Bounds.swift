import CoreGraphics

/// The rectangular play area the ball is confined to, expressed in screen
/// coordinates (the screen's `visibleFrame`, so the ball never slides under the
/// menu bar or behind the Dock).
///
/// Positions tracked by the physics engine are **ball centres**, so the usable
/// span for a centre is the frame inset by the ball radius on every side.
public struct Bounds: Equatable, Sendable {
    public var rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }

    /// Lowest the ball centre may sit (resting on the ground).
    public func floorY(radius: CGFloat) -> CGFloat { rect.minY + radius }
    /// Highest the ball centre may rise before hitting the top wall.
    public func ceilingY(radius: CGFloat) -> CGFloat { rect.maxY - radius }
    /// Leftmost centre position.
    public func minX(radius: CGFloat) -> CGFloat { rect.minX + radius }
    /// Rightmost centre position.
    public func maxX(radius: CGFloat) -> CGFloat { rect.maxX - radius }

    /// Clamp a centre point into the legal span (used when the screen resizes or
    /// the ball is dropped out of bounds after a grab).
    public func clampCenter(_ p: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(p.x, minX(radius: radius)), maxX(radius: radius)),
            y: min(max(p.y, floorY(radius: radius)), ceilingY(radius: radius))
        )
    }
}
