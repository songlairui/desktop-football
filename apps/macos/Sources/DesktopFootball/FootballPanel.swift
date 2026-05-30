import AppKit
import CoreVideo
import FootballPhysics

/// The desktop football window. A full-screen transparent panel hosts the Metal
/// scene while the physics engine still tracks the ball in screen coordinates.
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
    /// The screen-sized frame currently occupied by the transparent Metal overlay.
    private var overlayFrame: NSRect

    // MARK: Model
    private var config = PhysicsConfig.standard
    private var ball: BallState
    private var bounds: Bounds
    private(set) var gravityMode: GravityMode = .normal

    // MARK: Infra
    private let ballView: FootballMetalView   // changed from FootballLayerView
    private let sound = SoundEngine()

    private var displayLink: CVDisplayLink?
    private let framePermit = DispatchSemaphore(value: 1)
    private var lastStepTime: CFTimeInterval = 0
    private var prevMouse = NSEvent.mouseLocation
    private var lastKickAt: CFTimeInterval = 0

    // MARK: Interaction state
    private var didDrag = false
    private var grabOffset = CGPoint.zero
    private var interactive = false

    /// kVK_RightOption — snaps the ball under the cursor.
    private let rightOptionKeyCode: CGKeyCode = 61
    private var wasSnapHeld = false

    // MARK: Game mode
    private(set) var isGameMode = false
    private var cursorRingPanel: CursorRingPanel?
    var comboStrikeCount = 2    // 0=off, 2, or 3 — set from menu
    private var chargeFraction: CGFloat = 0

    // MARK: Combo detection (3 zone-entries / 0.5 s → standard combo)
    private var comboEntryTimes: [CFTimeInterval] = []
    private var wasInKickRadius = false

    // MARK: Zigzag mega-combo (4 horizontal reversals / 0.8 s → 5-hit secret)
    private var zigzagTimes: [CFTimeInterval] = []
    private var prevDxSign: Int = 0   // +1 right, -1 left, 0 neutral
    private var comboLockedUntil: CFTimeInterval = 0  // prevents re-trigger during animation

    // MARK: Cruise mode (菜单开关 — 定时风吹让球保持运动)
    private(set) var isCruiseMode = false
    private var cruiseWorkItem: DispatchWorkItem?

    // MARK: Charge (Right Command, game mode only)
    private let chargeKeyCode: CGKeyCode = 54   // kVK_RightCommand
    private var chargeStartTime: CFTimeInterval? = nil
    private var wasChargeHeld = false

    // MARK: - Init

    init() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let initialFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let vis = screen?.visibleFrame ?? initialFrame
        bounds = Bounds(rect: vis)
        ball = BallState.resting(atX: vis.midX, bounds: bounds, config: config)
        overlayFrame = initialFrame

        guard let scene = MetalScene() else { fatalError("Metal not available") }
        ballView = FootballMetalView(frame: NSRect(origin: .zero, size: initialFrame.size), scene: scene)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        ballView.autoresizingMask = [.width, .height]
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
    func setGameMode(_ on: Bool) {
        isGameMode = on
        config.kickRadius = on ? 160 : PhysicsConfig.normalKickRadius
        config.kickGain   = on ? 165 : PhysicsConfig.normalKickGain
        if on {
            let ring = CursorRingPanel(kickRadius: config.kickRadius)
            ring.orderFrontRegardless()
            cursorRingPanel = ring
        } else {
            cursorRingPanel?.orderOut(nil)
            cursorRingPanel = nil
            chargeFraction = 0
            chargeStartTime = nil
        }
    }

    func setCruiseMode(_ on: Bool) {
        isCruiseMode = on
        cruiseWorkItem?.cancel(); cruiseWorkItem = nil
        if on { scheduleCruiseGust() }
    }

    private func scheduleCruiseGust() {
        guard isCruiseMode else { return }
        let interval = Double.random(in: 3.5...7.5)
        let item = DispatchWorkItem { [weak self] in
            self?.applyCruiseGust()
            self?.scheduleCruiseGust()
        }
        cruiseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func applyCruiseGust() {
        guard isCruiseMode else { return }
        let speed = hypot(ball.velocity.x, ball.velocity.y)
        guard speed < config.maxSpeed * 0.30 else { return }  // don't push an already-fast ball

        // 65% chance of a strong horizontal shot (left or right) for the cross-screen arc feel.
        let angle: CGFloat
        if Double.random(in: 0...1) < 0.65 {
            let dir: CGFloat = Bool.random() ? 0 : .pi   // right or left
            angle = dir + CGFloat.random(in: -0.25...0.25)  // slight upward/downward tilt
        } else {
            angle = CGFloat.random(in: 0...(.pi * 2))
        }
        let gustStrength = CGFloat.random(in: 2000...3200)
        ball.velocity.x += cos(angle) * gustStrength
        ball.velocity.y += sin(angle) * gustStrength
        let spd = hypot(ball.velocity.x, ball.velocity.y)
        if spd > config.maxSpeed { ball.velocity.x *= config.maxSpeed / spd; ball.velocity.y *= config.maxSpeed / spd }
        EffectsOverlayPanel.shared.showStrikeEffect(at: ball.center, power: 0.35)
        sound.playKick(strength: gustStrength * 0.25)
    }

    func setGravityMode(_ mode: GravityMode) {
        gravityMode = mode
        config.gravityY = mode.gravityY
        config.airDamping60 = mode.airDamping60   // weightless mode drags harder
        ball.isSnapped = false
        sound.setRollSpeed(0)                     // silence rolling audio across the transition
    }

    // MARK: - Lifecycle

    override func orderFrontRegardless() {
        ignoresMouseEvents = true
        interactive = false
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

        // The output handler runs on CVDisplayLink's own real-time thread. Keep
        // at most one pending main-thread frame; otherwise menu tracking can be
        // starved by queued render ticks, and CAMetalLayer.nextDrawable can beachball.
        CVDisplayLinkSetOutputHandler(dl) { [weak self, framePermit] _, _, _, _, _ in
            guard framePermit.wait(timeout: .now()) == .success else {
                return kCVReturnSuccess
            }
            DispatchQueue.main.async { [weak self, framePermit] in
                defer { framePermit.signal() }
                self?.onDisplayTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(dl)
    }

    /// Runs on main. Skips menu tracking loops so status bar menus remain responsive.
    private func onDisplayTick() {
        if RunLoop.current.currentMode == .eventTracking {
            return
        }
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

        // ── Snap (Right Option) ──────────────────────────────────────────────────
        let snapHeld = isRightOptionDown()
        let snapPressed = snapHeld && !wasSnapHeld
        wasSnapHeld = snapHeld
        let roaming = ball.isGrabbed || snapHeld
        bounds = roaming ? roamingBounds() : screenBounds(containing: ball.center)
        let snapPoint = snapTarget(mouse: mouse)
        let withinCapture = hypot(snapPoint.x - ball.center.x, snapPoint.y - ball.center.y)
            <= config.snapCaptureDistance
        let doSnap = !ball.isGrabbed && snapHeld && (snapPressed || ball.isSnapped || withinCapture)

        // ── Charge (Right Command, game mode only) ───────────────────────────────
        let chargeHeld = isGameMode && isRightCommandDown()
        let chargeReleased = !chargeHeld && wasChargeHeld
        wasChargeHeld = chargeHeld
        if chargeHeld, chargeStartTime == nil { chargeStartTime = now }
        if chargeReleased, let start = chargeStartTime {
            chargeStartTime = nil
            let elapsed = now - start
            chargeFraction = 0
            if elapsed > 0.08 { applyChargeKick(elapsed: elapsed, mouse: mouse) }
        }
        chargeFraction = chargeStartTime.map { CGFloat(min(1.0, (now - $0) / 1.5)) } ?? 0

        // ── Ball physics ─────────────────────────────────────────────────────────
        if ball.isGrabbed {
            ball.isSnapped = false
            ball.follow(target: CGPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y),
                        dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
        } else if doSnap {
            if !ball.isSnapped {
                ball.center = snapPoint; ball.velocity = .zero; ball.isSnapped = true
            }
            ball.snapStep(target: snapPoint, dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
        } else {
            ball.isSnapped = false
            // During charge: suppress the dynamic kick so the player can aim without
            // accidentally poking the ball; hover force still applies.
            let evalConfig = chargeHeld ? config.withKickGain(0) : config
            let field = KickField.evaluate(ballCenter: ball.center, mouse: mouse,
                                           mouseVelocity: mVel, config: evalConfig)
            let events = ball.step(dt: dt, fieldForce: field.force, bounds: bounds, config: config)

            if let impact = events.landed { sound.playBounce(impact: impact) }
            if let impact = events.hitWall { sound.playBounce(impact: impact * 0.6) }

            if !chargeHeld && field.approachSpeed > config.swipeSoundThreshold,
               now - lastKickAt > 0.12 {
                sound.playKick(strength: field.approachSpeed)
                lastKickAt = now
            }

            let state = ball.motionState(config: config, bounds: bounds)
            sound.setRollSpeed(state == .rolling ? abs(ball.velocity.x) : 0)

            // ── Combo detection (only when free-rolling, not grabbing/snapping) ──
            if !chargeHeld { detectCombos(mouse: mouse, mVel: mVel, now: now) }
        }

        // ── Cursor ring (game mode) ──────────────────────────────────────────────
        if let ring = cursorRingPanel {
            let d = hypot(mouse.x - ball.center.x, mouse.y - ball.center.y)
            ring.update(mouse: mouse, inRange: d < config.kickRadius, chargeFraction: chargeFraction)
        }

        syncWindowToBall()
        updateInteractivity(mouse: mouse)
    }

    /// Zone-entry combo and zigzag mega-combo detection. Call each free-physics frame.
    private func detectCombos(mouse: NSPoint, mVel: CGPoint, now: CFTimeInterval) {
        guard now > comboLockedUntil else { return }   // combo animation in progress

        let dist = hypot(mouse.x - ball.center.x, mouse.y - ball.center.y)
        let nowIn = dist < config.kickRadius
        let entered = nowIn && !wasInKickRadius
        wasInKickRadius = nowIn

        // ── Zigzag mega-combo (PRIORITY): 4 L/R reversals in 0.8 s ──────────────
        let dxSign = mVel.x > 180 ? 1 : (mVel.x < -180 ? -1 : 0)
        var firedMega = false
        if dxSign != 0 && prevDxSign != 0 && dxSign != prevDxSign
           && dist < config.kickRadius * 2.5 {
            zigzagTimes.append(now)
            zigzagTimes = zigzagTimes.filter { now - $0 < 0.8 }
            if zigzagTimes.count >= 4 {
                zigzagTimes.removeAll()
                comboEntryTimes.removeAll()
                triggerComboStrikes(count: 5, baseVelocity: ball.velocity, now: now)
                firedMega = true
            }
        }
        if dxSign != 0 { prevDxSign = dxSign }

        // ── Standard combo: 3 zone-entries in 0.5 s (only if mega didn't fire) ──
        if !firedMega && entered {
            let cursorSpeed = hypot(mVel.x, mVel.y)
            if cursorSpeed > config.swipeSoundThreshold * 0.6 {
                comboEntryTimes.append(now)
                comboEntryTimes = comboEntryTimes.filter { now - $0 < 0.5 }
                if comboEntryTimes.count >= 3 {
                    comboEntryTimes.removeAll()
                    triggerComboStrikes(count: comboStrikeCount, baseVelocity: ball.velocity, now: now)
                }
            }
        }
    }

    /// The point the snapped ball is pulled toward, clamped into the play area so
    /// it stays reachable even at a screen edge.
    ///
    /// The target is offset so the spring↔gravity *equilibrium* lands the ball a
    /// consistent `snapCursorOffset` **below the cursor in every gravity mode**
    /// (the user asked for "下方" — below). The ball settles `gravityY/snapStiffness`
    /// off the target, so we pre-subtract that to cancel it out.
    /// The spring-gravity equilibrium offset: at rest the ball sits
    /// `-gravityY / stiffness` ABOVE the target. To make the VISIBLE ball centre
    /// appear `snapCursorOffset` below the cursor we must add this sag INTO the
    /// target (push target down further so ball floats back up to desired position).
    private func snapTarget(mouse: NSPoint) -> CGPoint {
        let sag = config.gravityY / config.snapStiffness  // e.g. -10 pt under normal gravity
        let raw = CGPoint(x: mouse.x, y: mouse.y - config.snapCursorOffset + sag)
        return bounds.clampCenter(raw, radius: config.radius)
    }

    /// Push the current ball state to the Metal scene. The window no longer moves —
    /// the 3D camera and projection handle positioning.
    private func syncWindowToBall() {
        syncOverlayFrameToBall()
        ballView.render(ballState: ball, config: config, bounds: bounds)
    }

    private func syncOverlayFrameToBall() {
        let target = overlayWindowFrame(containing: ball.center)
        guard target != overlayFrame else { return }
        overlayFrame = target
        setFrame(target, display: true)
        ballView.frame = NSRect(origin: .zero, size: target.size)
    }

    private func overlayWindowFrame(containing point: CGPoint) -> NSRect {
        screen(containing: point)?.frame ?? overlayFrame
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
        interactive = nowInteractive
        ignoresMouseEvents = !nowInteractive
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
        guard let screen = screen(containing: point) else { return bounds }
        return Bounds(rect: screen.visibleFrame)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let onScreen = screens.first(where: { $0.frame.contains(point) }) {
            return onScreen
        }
        let nearest = screens.min { Self.squaredDistance(from: point, to: $0.frame)
                                  < Self.squaredDistance(from: point, to: $1.frame) }
        return nearest ?? screens[0]
    }

    /// Squared distance from a point to the nearest edge/inside of a rect.
    private static func squaredDistance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Deliver `count` phantom combo strikes with a "水果忍者" cinematic rhythm.
    ///
    /// Design principles:
    ///   • Long gaps (0.7–0.9 s) so the ball visibly travels across the screen
    ///     between hits — each blow sends it from one edge toward the other.
    ///   • Impulse ESCALATES (2 200 → 2 750 pt/s) so the sequence builds to a peak.
    ///   • Each hit squash-spikes the ball deformation for a crisp impact feel.
    ///   • Every hit spawns a ripple ring (overlay) + a blade slash mark.
    ///   • Combo lock prevents re-triggering until the last hit has played.
    ///
    /// 5-hit mega-combo total duration ≈ 3 s — during which the ball bounces
    /// wall-to-wall several times before each successive strike.
    private func triggerComboStrikes(count: Int, baseVelocity: CGPoint, now: CFTimeInterval) {
        guard count > 0 else { return }
        let baseAngle = atan2(baseVelocity.y, baseVelocity.x)

        // (delay s, impulse pt/s, spread rad)
        // Impulse and spread escalate — first hit is a crisp confirm, finale is maximum chaos.
        let allStrikes: [(Double, CGFloat, CGFloat)] = [
            (0.30, 2200, 0.30),   // hit 1 — confirm, tightly follows ball direction
            (0.95, 2400, 0.90),   // hit 2 — deflect, ball has time to reach far wall
            (1.70, 2550, 1.60),   // hit 3 — strong, wider random arc
            (2.55, 2700, 2.20),   // hit 4 — very wild
            (3.45, 2800,  .pi),   // hit 5 FINALE — full 360°, maximum impulse
        ]
        let profile = Array(allStrikes.prefix(min(count, allStrikes.count)))
        comboLockedUntil = now + (profile.last?.0 ?? 0) + 1.0

        for (delay, impulse, spread) in profile {
            let angle = baseAngle + CGFloat.random(in: -spread...spread)
            let capturedImpulse = impulse
            let capturedPower = impulse / 2800   // 0.79 … 1.0 for overlay scaling
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.ball.isGrabbed, !self.ball.isSnapped else { return }
                self.ball.velocity.x += cos(angle) * capturedImpulse
                self.ball.velocity.y += sin(angle) * capturedImpulse
                // Allow up to 1.35× maxSpeed during combos for the "rocket" feel.
                let spd = hypot(self.ball.velocity.x, self.ball.velocity.y)
                let cap = self.config.maxSpeed * 1.35
                if spd > cap {
                    self.ball.velocity.x *= cap / spd
                    self.ball.velocity.y *= cap / spd
                }
                // Dramatic squash spike on each hit.
                self.ball.squash = min(self.config.maxSquash * 1.3, self.ball.squash + 0.38)
                // Visual: ripple + blade slash.
                EffectsOverlayPanel.shared.showStrikeEffect(at: self.ball.center, power: capturedPower)
                EffectsOverlayPanel.shared.showSlashEffect(at: self.ball.center, angle: angle, power: capturedPower)
                self.sound.playKick(strength: capturedImpulse * 0.65)
            }
        }
    }

    /// Apply a charged kick on Right Command release.
    private func applyChargeKick(elapsed: CFTimeInterval, mouse: NSPoint) {
        let dx = ball.center.x - mouse.x
        let dy = ball.center.y - mouse.y
        let dist = hypot(dx, dy)
        guard dist < config.kickRadius * 2.8 else { return }
        let (ux, uy): (CGFloat, CGFloat) = dist > 1 ? (dx / dist, dy / dist) : (0, 1)
        let multiplier = min(4.0, 1.0 + CGFloat(elapsed) * 2.0)
        let impulse = 1500 * multiplier
        ball.velocity.x += ux * impulse
        ball.velocity.y += uy * impulse
        let spd = hypot(ball.velocity.x, ball.velocity.y)
        let cap = config.maxSpeed * min(1.5, 0.9 + multiplier * 0.15)
        if spd > cap {
            ball.velocity.x *= cap / spd
            ball.velocity.y *= cap / spd
        }
        ball.squash = min(config.maxSquash, ball.squash + 0.25 * multiplier / 4.0)
        sound.playKick(strength: impulse * 0.75)
        EffectsOverlayPanel.shared.showStrikeEffect(at: ball.center, power: multiplier / 4.0 * 1.5)
    }

    /// Permission-free key-state poll via HID (works for non-activating accessory apps).
    private func isKeyDown(_ keyCode: CGKeyCode) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keyCode) ||
        CGEventSource.keyState(.combinedSessionState, key: keyCode)
    }

    /// Device-independent modifier flag check. More reliable than keyCode for
    /// right-side modifiers on keyboards that report both sides identically.
    private func isFlagDown(mask: UInt64) -> Bool {
        CGEventSource.flagsState(.hidSystemState).rawValue & mask != 0
    }

    private func isRightOptionDown() -> Bool {
        isKeyDown(rightOptionKeyCode) || isFlagDown(mask: 0x40)  // NX_DEVICERALTKEYMASK
    }

    private func isRightCommandDown() -> Bool {
        isKeyDown(chargeKeyCode) || isFlagDown(mask: 0x10)  // NX_DEVICERCMDKEYMASK
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        guard ball.isGrabbed || ball.isSnapped || distanceFromBall(m) <= config.radius * 1.5 else {
            interactive = false
            ignoresMouseEvents = true
            return
        }
        didDrag = false
        ball.velocity = .zero                       // "catch" the ball
        grabOffset = CGPoint(x: ball.center.x - m.x, y: ball.center.y - m.y)
    }

    private func distanceFromBall(_ point: NSPoint) -> CGFloat {
        hypot(point.x - ball.center.x, point.y - ball.center.y)
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
