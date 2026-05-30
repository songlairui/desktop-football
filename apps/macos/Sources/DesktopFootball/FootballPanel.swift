import AppKit
import CoreVideo
import FootballPhysics

/// The desktop football window. The **window itself is the ball**: a small
/// transparent panel that the physics engine walks around the screen by moving
/// its origin every frame (the same CVDisplayLink + `setFrameOrigin` model
/// `HUDPanel` proved out). The ball graphic, shadow and deformation live inside
/// the window via `FootballLayerView`.
///
/// Mouse model:
///   • A global cursor poll each frame drives the kick/airflow field — this works
///     even while the window ignores mouse events, so swiping *near* the ball
///     kicks it without the transparent window stealing desktop clicks.
///   • `ignoresMouseEvents` is toggled each frame: the window only captures
///     clicks when the cursor is actually over the ball, so clicking / dragging
///     it works while the rest of the transparent area stays click-through.
final class FootballPanel: NSPanel {

    // MARK: Geometry
    private let windowSize = NSSize(width: 170, height: 170)
    private let ballAnchor = CGPoint(x: 85, y: 100)
    private let liftRange: CGFloat = 380

    // MARK: Model
    private var config = PhysicsConfig.standard
    private var ball: BallState
    private var bounds: Bounds
    private(set) var gravityMode: GravityMode = .normal

    // MARK: Infra
    private let ballView: FootballLayerView
    private let sound = SoundEngine()

    private var displayLink: CVDisplayLink?
    private var lastStepTime: CFTimeInterval = 0
    private var prevMouse = NSEvent.mouseLocation
    private var lastKickAt: CFTimeInterval = 0

    // MARK: Interaction state
    private var didDrag = false
    private var grabOffset = CGPoint.zero
    private var interactive = false

    /// kVK_RightOption — the modifier that snaps the ball to the cursor.
    private let rightOptionKeyCode: CGKeyCode = 61
    /// Rising-edge tracker so the snap only re-arms after the key is released, not
    /// every frame the key stays held once the ball has broken away.
    private var wasSnapHeld = false

    // MARK: - Init

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        bounds = Bounds(rect: vis)
        ball = BallState.resting(atX: vis.midX, bounds: bounds, config: config)

        ballView = FootballLayerView(windowSize: windowSize, diameter: config.radius * 2,
                                     ballAnchor: ballAnchor, liftRange: liftRange)

        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        contentView = ballView

        syncWindowToBall()
        sound.start()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var soundEnabled: Bool {
        get { sound.isEnabled }
        set { sound.isEnabled = newValue }
    }

    /// Drop the ball back to the centre of the screen it is currently on.
    func reset() {
        bounds = screenBounds(containing: ball.center)
        ball = BallState.resting(atX: bounds.rect.midX, bounds: bounds, config: config)
        syncWindowToBall()
    }

    /// Switch the gravity world (normal / zero / balloon). The ball wakes up so it
    /// immediately responds to the new gravity instead of staying asleep.
    func setGravityMode(_ mode: GravityMode) {
        gravityMode = mode
        config.gravityY = mode.gravityY
        config.airDamping60 = mode.airDamping60   // weightless mode drags harder
        ball.isSnapped = false
        sound.setRollSpeed(0)                     // silence rolling audio across the transition
    }

    // MARK: - Lifecycle

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        prevMouse = NSEvent.mouseLocation
        startLoop()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        stopLoop()
        sound.stop()
    }

    private func startLoop() {
        stopLoop()
        lastStepTime = 0
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }

        // The output handler runs on CVDisplayLink's own real-time thread. To avoid
        // a data race on stepPending/lastStepTime (accessed only from main), we
        // immediately hop to main and do all bookkeeping there.
        CVDisplayLinkSetOutputHandler(dl) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async { self?.onDisplayTick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(dl)
    }

    /// Runs on main. Uses the dispatch-queue coalescing inherent in
    /// `DispatchQueue.main.async` to skip redundant frames — if the previous async
    /// block hasn't executed yet (i.e. main is busy), the queue merges them by
    /// virtue of us just enqueueing another block. The `CACurrentMediaTime()` snapshot
    /// taken here is always fresh when the block actually runs.
    private func onDisplayTick() {
        let now = CACurrentMediaTime()
        let dt: CGFloat = lastStepTime == 0 ? 1.0 / 60.0 : CGFloat(now - lastStepTime)
        lastStepTime = now
        tick(dt: min(dt, 0.1), now: now)
    }

    private func stopLoop() {
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
    }

    // MARK: - Per-frame update

    private func tick(dt: CGFloat, now: CFTimeInterval) {
        let mouse = NSEvent.mouseLocation
        let mVel = CGPoint(x: (mouse.x - prevMouse.x) / dt, y: (mouse.y - prevMouse.y) / dt)
        prevMouse = mouse

        let snapHeld = isRightOptionDown()
        let snapPressed = snapHeld && !wasSnapHeld
        wasSnapHeld = snapHeld

        // Bounds policy: while the ball is being carried — dragged, or shepherded
        // with right Option held — it may cross between displays (union of all
        // screens). Once let go it is confined to whichever screen it now sits on,
        // so each display keeps its own edges and the boundary bites immediately.
        let roaming = ball.isGrabbed || snapHeld
        bounds = roaming ? roamingBounds() : screenBounds(containing: ball.center)

        // Decide whether the ball should be snapped this frame. A fresh press
        // (rising edge) always summons the ball, however far away it is. While the
        // key stays held it keeps following; if it broke away, it re-snaps only
        // once the cursor comes back within the (smaller) capture distance — so a
        // flick throws it clear but deliberately returning the cursor re-grabs it.
        let snapPoint = snapTarget(mouse: mouse)
        let withinCapture = hypot(snapPoint.x - ball.center.x, snapPoint.y - ball.center.y) <= config.snapCaptureDistance
        let doSnap = !ball.isGrabbed && snapHeld && (snapPressed || ball.isSnapped || withinCapture)

        if ball.isGrabbed {
            ball.isSnapped = false                   // an active mouse-drag wins over snap
            ball.follow(target: CGPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y),
                        dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
        } else if doSnap {
            if !ball.isSnapped {
                ball.center = snapPoint              // jump straight under the cursor…
                ball.velocity = .zero                // …and stop there ("snap & stop")
                ball.isSnapped = true
            }
            // Soft spring holds it under the cursor; breaks away on its own if the
            // cursor outruns it or gravity drags it past snapBreakDistance.
            ball.snapStep(target: snapPoint, dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
        } else {
            ball.isSnapped = false                   // key up or broke away → free physics
            let field = KickField.evaluate(ballCenter: ball.center, mouse: mouse,
                                           mouseVelocity: mVel, config: config)
            let events = ball.step(dt: dt, fieldForce: field.force, bounds: bounds, config: config)

            if let impact = events.landed { sound.playBounce(impact: impact) }
            if let impact = events.hitWall { sound.playBounce(impact: impact * 0.6) }

            if field.approachSpeed > config.swipeSoundThreshold, now - lastKickAt > 0.12 {
                sound.playKick(strength: field.approachSpeed)
                lastKickAt = now
            }

            let state = ball.motionState(config: config, bounds: bounds)
            sound.setRollSpeed(state == .rolling ? abs(ball.velocity.x) : 0)
        }

        syncWindowToBall()
        updateInteractivity(mouse: mouse)
    }

    /// The point the snapped ball is pulled toward, clamped into the play area so
    /// it stays reachable even at a screen edge.
    ///
    /// The target is offset so the spring↔gravity *equilibrium* lands the ball a
    /// consistent `snapCursorOffset` **below the cursor in every gravity mode**
    /// (the user asked for "下方" — below). The ball settles `gravityY/snapStiffness`
    /// off the target, so we pre-subtract that to cancel it out.
    private func snapTarget(mouse: NSPoint) -> CGPoint {
        let gravitySag = config.gravityY / config.snapStiffness
        let raw = CGPoint(x: mouse.x, y: mouse.y - config.snapCursorOffset - gravitySag)
        return bounds.clampCenter(raw, radius: config.radius)
    }

    /// Move the window so the ball graphic lands on `ball.center`, then render.
    private func syncWindowToBall() {
        setFrameOrigin(NSPoint(x: ball.center.x - ballAnchor.x,
                               y: ball.center.y - ballAnchor.y))
        let floorY = bounds.floorY(radius: config.radius)
        let lift = max(0, min(1, (ball.center.y - floorY) / liftRange))
        ballView.render(angle: ball.angle, squash: ball.squash,
                        liftFactor: lift,
                        motionState: ball.motionState(config: config, bounds: bounds))
    }

    /// Capture clicks only while the cursor is over the ball; otherwise let the
    /// transparent window pass clicks through to whatever is behind it.
    ///
    /// Uses hysteresis to prevent flickering: the window enters interactive mode at
    /// a smaller radius than it exits, so a fast cursor that grazes the boundary
    /// doesn't rapidly toggle `ignoresMouseEvents` and lose a mouseDown.
    private func updateInteractivity(mouse: NSPoint) {
        let d = hypot(mouse.x - ball.center.x, mouse.y - ball.center.y)
        let nowInteractive: Bool
        if ball.isGrabbed || ball.isSnapped {
            nowInteractive = true
        } else if interactive {
            nowInteractive = d <= config.radius * 1.5   // exit radius (larger)
        } else {
            nowInteractive = d <= config.radius * 1.15  // enter radius (smaller)
        }
        if nowInteractive != interactive {
            interactive = nowInteractive
            ignoresMouseEvents = !nowInteractive
        }
    }

    /// The union of every screen's visible frame — used only while the ball is
    /// being carried, so it can travel between displays. Offset/odd-sized displays
    /// leave "void" gaps inside the bounding box the ball can pass through.
    private func roamingBounds() -> Bounds {
        let screens = NSScreen.screens
        guard let first = screens.first else { return bounds }
        let union = screens.dropFirst().reduce(first.visibleFrame) { $0.union($1.visibleFrame) }
        return Bounds(rect: union)
    }

    /// The visible frame of the screen the given point sits on — the play area when
    /// the ball is free, so each display keeps its own edges. If the point is in a
    /// gap between displays (or off them all) we fall back to the nearest screen so
    /// the ball is pulled back onto a real display rather than lost in the void.
    private func screenBounds(containing point: CGPoint) -> Bounds {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return bounds }
        if let onScreen = screens.first(where: { $0.frame.contains(point) }) {
            return Bounds(rect: onScreen.visibleFrame)
        }
        let nearest = screens.min { Self.squaredDistance(from: point, to: $0.frame)
                                  < Self.squaredDistance(from: point, to: $1.frame) }
        return Bounds(rect: (nearest ?? screens[0]).visibleFrame)
    }

    /// Squared distance from a point to the nearest edge/inside of a rect.
    private static func squaredDistance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Whether the **right** Option key is physically down. Uses the permission-free
    /// CoreGraphics state APIs (no event tap / Input-Monitoring prompt).
    ///
    /// `.hidSystemState` is checked first and matters most: this app is a
    /// non-activating accessory, so it never becomes key and the session-level
    /// event state can miss the press — but the HID state reads the hardware
    /// directly regardless of focus. The session keystate and the device-dependent
    /// right-Option flag bit are kept as belt-and-suspenders fallbacks.
    private func isRightOptionDown() -> Bool {
        if CGEventSource.keyState(.hidSystemState, key: rightOptionKeyCode) { return true }
        if CGEventSource.keyState(.combinedSessionState, key: rightOptionKeyCode) { return true }
        let rightOptionMask: UInt64 = 0x40   // NX_DEVICERALTKEYMASK
        if CGEventSource.flagsState(.hidSystemState).rawValue & rightOptionMask != 0 { return true }
        return false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        ball.velocity = .zero                       // "catch" the ball
        let m = NSEvent.mouseLocation
        grabOffset = CGPoint(x: ball.center.x - m.x, y: ball.center.y - m.y)
    }

    override func mouseDragged(with event: NSEvent) {
        if !didDrag {
            didDrag = true
            ball.isGrabbed = true                    // hand off to follow() in tick
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            ball.isGrabbed = false                   // release → tick throws with carried velocity
        } else {
            ball.applyClick(config: config)          // tap → dribble pop
            sound.playKick(strength: 420)
        }
        didDrag = false
    }
}
