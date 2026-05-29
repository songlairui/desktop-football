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
    private let config = PhysicsConfig.standard
    private var ball: BallState
    private var bounds: Bounds

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

    /// Drop the ball back to the centre of the current screen.
    func reset() {
        bounds = currentBounds()
        ball = BallState.resting(atX: bounds.rect.midX, bounds: bounds, config: config)
        syncWindowToBall()
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
        bounds = currentBounds()
        let mouse = NSEvent.mouseLocation
        let mVel = CGPoint(x: (mouse.x - prevMouse.x) / dt, y: (mouse.y - prevMouse.y) / dt)
        prevMouse = mouse

        if ball.isGrabbed {
            ball.follow(target: CGPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y),
                        dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
        } else {
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
        if ball.isGrabbed {
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

    private func currentBounds() -> Bounds {
        let vis = (screen ?? NSScreen.main)?.visibleFrame ?? bounds.rect
        return Bounds(rect: vis)
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
