import CoreGraphics

/// The three gravity "worlds" the ball can live in, switched from the menu bar.
///
/// `gravityY` is the vertical acceleration (pt/s²) fed into `PhysicsConfig`. The
/// macOS screen space has +Y pointing up, so a *negative* value falls down and a
/// *positive* value floats up.
public enum GravityMode: String, Sendable, CaseIterable {
    /// Real-world gravity — the ball falls and settles on the floor.
    case normal
    /// Weightless — the ball drifts wherever it is kicked and slowly bleeds speed.
    case zero
    /// Anti-gravity "balloon" — the ball floats up and settles against the ceiling.
    case balloon

    /// Vertical acceleration for this mode (pt/s²; +Y is up).
    public var gravityY: CGFloat {
        switch self {
        case .normal:  return PhysicsConfig.normalGravity
        case .zero:    return 0
        case .balloon: return 760
        }
    }

    /// Air-drag multiplier per 1/60 s for this mode. Weightless mode adds noticeably
    /// more drag so a kicked ball glides to a stop instead of drifting forever;
    /// the gravity modes keep the light default so falls/floats stay lively.
    public var airDamping60: CGFloat {
        switch self {
        case .normal:  return 0.999
        case .zero:    return 0.978
        case .balloon: return 0.997
        }
    }

    /// Human-readable label for the menu item.
    public var menuTitle: String {
        switch self {
        case .normal:  return "Normal Gravity"
        case .zero:    return "Zero Gravity"
        case .balloon: return "Balloon (Anti-Gravity)"
        }
    }
}
