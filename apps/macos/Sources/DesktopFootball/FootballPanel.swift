import AppKit
import CoreVideo
import FootballPhysics

enum IdleMotionMode: Int, CaseIterable {
    case exhibitionSpin
    case fingerSpin
    case physicalRoll

    var menuTitle: String {
        switch self {
        case .exhibitionSpin: return "Exhibition"
        case .fingerSpin: return "Finger Spin"
        case .physicalRoll: return "Field Breeze"
        }
    }
}

private enum FingerSpinPhase {
    case charging
    case coasting
}

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
    private static let dockClearance: CGFloat = 80

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
    private var wasInGlassStrikeDisk = false

    // MARK: 3D render feel
    private var visualRotationX: CGFloat = 0
    private var visualRotationY: CGFloat = 0
    private var visualRotationZ: CGFloat = 0
    private var visualSpinVelocityX: CGFloat = 0
    private var visualSpinVelocityY: CGFloat = 0
    private var visualSpinVelocityZ: CGFloat = 0
    private var idleSpinPhase: CGFloat = 0
    private var fingerSpinDirection: CGFloat = 1
    private var fingerSpinPhaseState: FingerSpinPhase = .charging
    private var fingerSpinTimer: CGFloat = 0
    private var fingerSpinDuration: CGFloat = 0.11
    private var fingerSpinPeakSpeed: CGFloat = 25.0
    private var fingerSpinBaseSpeed: CGFloat = 1.2
    private var fingerSpinBurstIndex = 0
    private var fingerSpinBurstCount = 5
    private var fingerSpinCurrentSpeed: CGFloat = 1.2
    private var physicalRollCountdown: CGFloat = 3.0
    private var physicalRollDirection: CGFloat = 1
    private var physicalRollTargetSpeed: CGFloat = 90
    private var fpsSampleStart: CFTimeInterval = 0
    private var fpsSampleFrames = 0
    private(set) var measuredFPS: Double = 0

    // MARK: Interaction state
    private var didDrag = false
    private var grabOffset = CGPoint.zero
    private var interactive = false

    /// kVK_RightOption — snaps the ball under the cursor.
    private let rightOptionKeyCode: CGKeyCode = 61
    private var wasSnapHeld = false

    // MARK: Game mode
    private(set) var isGameMode = false
    private(set) var showsGuideLines = false
    private(set) var showsFPS = false
    private(set) var idleMotionMode: IdleMotionMode = .exhibitionSpin
    private(set) var ballModelKind: BallModelKind = .fifa2026
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
        bounds = screen.map(Self.playArea) ?? Bounds(rect: initialFrame.insetByBottom(Self.dockClearance))
        ball = BallState.resting(atX: bounds.rect.midX, bounds: bounds, config: config)
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

        syncWindowToBall(mouse: mouse)
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
        wasInGlassStrikeDisk = false
        resetVisual3D()
        syncWindowToBall()
    }

    /// Switch the gravity world (normal / zero / balloon). The ball wakes up so it
    /// immediately responds to the new gravity instead of staying asleep.
    func setGameMode(_ on: Bool) {
        isGameMode = on
        config.kickRadius = on ? 160 : PhysicsConfig.normalKickRadius
        config.kickGain   = on ? 165 : PhysicsConfig.normalKickGain
        syncCursorRingPanel()
        if !on {
            chargeFraction = 0
            chargeStartTime = nil
        }
    }

    func setGuideLines(_ on: Bool) {
        showsGuideLines = on
        syncCursorRingPanel()
        syncWindowToBall()
    }

    func setFPSVisible(_ on: Bool) {
        showsFPS = on
        measuredFPS = 0
        fpsSampleStart = 0
        fpsSampleFrames = 0
        syncWindowToBall()
    }

    func setIdleMotionMode(_ mode: IdleMotionMode) {
        idleMotionMode = mode
        resetIdleMotionTimers()
        resetVisual3D()
        syncWindowToBall()
    }

    func setBallModel(_ kind: BallModelKind) {
        ballModelKind = kind
        ballView.setBallModel(kind)
        syncWindowToBall()
    }

    private func syncCursorRingPanel() {
        if isGameMode && showsGuideLines {
            if cursorRingPanel != nil { return }
            let ring = CursorRingPanel(kickRadius: config.kickRadius)
            ring.orderFrontRegardless()
            cursorRingPanel = ring
        } else {
            cursorRingPanel?.orderOut(nil)
            cursorRingPanel = nil
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
        applyOffAxisStrike(impulse: CGPoint(x: cos(angle) * gustStrength,
                                            y: sin(angle) * gustStrength),
                           strength: 0.35)
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
        wasInGlassStrikeDisk = false
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
        updateFPS(now: now)
        tick(dt: min(dt, 0.1), now: now)
    }

    private func stopLoop() {
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
    }

    // MARK: - Per-frame update

    private func tick(dt: CGFloat, now: CFTimeInterval) {
        let mouse = NSEvent.mouseLocation
        let previousMouse = prevMouse
        let mVel = CGPoint(x: (mouse.x - previousMouse.x) / dt, y: (mouse.y - previousMouse.y) / dt)
        prevMouse = mouse
        var didGlassStrike = false
        var motionState: MotionState = .idle

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
            motionState = .grabbed
        } else if doSnap {
            if !ball.isSnapped {
                ball.center = snapPoint; ball.velocity = .zero; ball.isSnapped = true
            }
            ball.snapStep(target: snapPoint, dt: dt, bounds: bounds, config: config)
            sound.setRollSpeed(0)
            motionState = .grabbed
        } else {
            ball.isSnapped = false
            // During charge: suppress the dynamic kick so the player can aim without
            // accidentally poking the ball. Outside charge, a kick is an explicit
            // sweep through the projected contact disk on the front glass plane.
            if !chargeHeld {
                let strike = GlassContact.evaluate(
                    ballCenter: ball.center,
                    previousMouse: previousMouse,
                    mouse: mouse,
                    mouseVelocity: mVel,
                    strikeRadius: glassStrikeRadius,
                    minimumSpeed: config.swipeSoundThreshold,
                    wasInside: wasInGlassStrikeDisk,
                    cooldownReady: now - lastKickAt > 0.11
                )
                if strike.didStrike {
                    applyGlassStrike(strike, now: now)
                    didGlassStrike = true
                }
            }

            let events = ball.step(dt: dt, fieldForce: .zero, bounds: bounds, config: config)

            if let impact = events.landed {
                sound.playBounce(impact: impact)
            }
            if let impact = events.hitWall { sound.playBounce(impact: impact * 0.6) }

            let state = ball.motionState(config: config, bounds: bounds)
            motionState = state
            sound.setRollSpeed(state == .rolling ? abs(ball.velocity.x) : 0)

            // ── Combo detection (only when free-rolling, not grabbing/snapping) ──
            if !chargeHeld { detectCombos(mouse: mouse, mVel: mVel, now: now) }
        }

        // ── Cursor ring (game mode) ──────────────────────────────────────────────
        if let ring = cursorRingPanel {
            let d = hypot(mouse.x - ball.center.x, mouse.y - ball.center.y)
            ring.update(mouse: mouse, inRange: d < config.kickRadius, chargeFraction: chargeFraction)
        }

        updateVisual3D(dt: dt, motionState: motionState)
        updateInteractivity(mouse: mouse)
        wasInGlassStrikeDisk = distanceFromBall(mouse) <= glassStrikeRadius
        syncWindowToBall(mouse: mouse, didStrike: didGlassStrike)
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
    private func syncWindowToBall(mouse: NSPoint = NSEvent.mouseLocation,
                                  didStrike: Bool = false) {
        syncOverlayFrameToBall()
        ballView.render(ballState: ball,
                        config: config,
                        bounds: bounds,
                        interaction: interactionFeedback(mouse: mouse, didStrike: didStrike),
                        renderEffects: currentRenderEffects,
                        fps: showsFPS ? measuredFPS : nil,
                        showsGuideLines: showsGuideLines)
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
            nowInteractive = d <= glassGrabExitRadius
        } else {
            nowInteractive = d <= glassGrabRadius
        }
        interactive = nowInteractive
        ignoresMouseEvents = !nowInteractive
        if nowInteractive {
            (ball.isGrabbed ? NSCursor.closedHand : NSCursor.openHand).set()
        }
    }

    private var glassGrabRadius: CGFloat {
        config.radius * 1.30
    }

    private var glassGrabExitRadius: CGFloat {
        config.radius * 1.70
    }

    private var glassStrikeRadius: CGFloat {
        isGameMode ? config.kickRadius : max(config.radius * 2.2, config.radius + 34)
    }

    private var glassRevealRadius: CGFloat {
        glassStrikeRadius * 1.65
    }

    private func interactionFeedback(mouse: NSPoint,
                                     didStrike: Bool) -> GlassInteractionFeedback {
        let d = distanceFromBall(mouse)
        return GlassInteractionFeedback(
            ballCenter: ball.center,
            mouse: mouse,
            visibleRadius: glassGrabRadius,
            strikeRadius: glassStrikeRadius,
            isNear: d <= glassRevealRadius,
            canGrab: d <= glassGrabRadius,
            isGrabbed: ball.isGrabbed,
            isSnapped: ball.isSnapped,
            didStrike: didStrike
        )
    }

    private func applyGlassStrike(_ strike: GlassContact.Result, now: CFTimeInterval) {
        ball.velocity.x += strike.impulse.x
        ball.velocity.y += strike.impulse.y
        if ball.isGrounded(config: config, bounds: bounds),
           abs(strike.impulse.y) < abs(strike.impulse.x) * 0.35 {
            ball.velocity.y += 160 + 180 * strike.strength
        }
        capBallSpeed(to: config.maxSpeed * 1.18)
        applyOffAxisStrike(impulse: strike.impulse,
                           strength: strike.strength,
                           contactOffset: strike.contactOffset)

        let angle = atan2(strike.impulse.y, strike.impulse.x)
        let power = 0.35 + strike.strength * 0.65
        EffectsOverlayPanel.shared.showStrikeEffect(at: ball.center, power: power)
        EffectsOverlayPanel.shared.showSlashEffect(at: ball.center, angle: angle, power: power)
        sound.playKick(strength: hypot(strike.impulse.x, strike.impulse.y))
        lastKickAt = now
    }

    private func capBallSpeed(to maxSpeed: CGFloat) {
        let speed = hypot(ball.velocity.x, ball.velocity.y)
        guard speed > maxSpeed, speed > 0 else { return }
        let k = maxSpeed / speed
        ball.velocity.x *= k
        ball.velocity.y *= k
    }

    private var currentRenderEffects: BallRenderEffects {
        BallRenderEffects(rotationX: visualRotationX,
                          rotationY: visualRotationY,
                          rotationZ: visualRotationZ)
    }

    private func resetVisual3D() {
        visualRotationX = 0
        visualRotationY = 0
        visualRotationZ = 0
        visualSpinVelocityX = 0
        visualSpinVelocityY = 0
        visualSpinVelocityZ = 0
        resetIdleMotionTimers()
    }

    private func resetIdleMotionTimers() {
        fingerSpinDirection = 1
        fingerSpinPhaseState = .charging
        fingerSpinTimer = 0
        fingerSpinDuration = CGFloat.random(in: 0.09...0.13)
        fingerSpinPeakSpeed = CGFloat.random(in: 22.0...30.0)
        fingerSpinBaseSpeed = CGFloat.random(in: 1.0...1.45)
        fingerSpinBurstIndex = 0
        fingerSpinBurstCount = Int.random(in: 3...7)
        fingerSpinCurrentSpeed = fingerSpinBaseSpeed
        physicalRollDirection = Bool.random() ? 1 : -1
        physicalRollTargetSpeed = CGFloat.random(in: 70...140) * physicalRollDirection
        physicalRollCountdown = CGFloat.random(in: 4.0...8.0)
    }

    private func updateVisual3D(dt: CGFloat, motionState: MotionState) {
        guard dt > 0 else { return }
        switch idleMotionMode {
        case .exhibitionSpin:
            if motionState == .idle {
                updateExhibitionSpinIdle(dt: dt)
            } else {
                decayExtraSpin(dt: dt, damping60: 0.90)
            }
        case .fingerSpin:
            if motionState == .idle {
                updateFingerSpinIdle(dt: dt)
            } else {
                let damping60: CGFloat = motionState == .grabbed ? 0.90 : 0.994
                decayExtraSpin(dt: dt, damping60: damping60)
            }
        case .physicalRoll:
            if isFieldBreezeEligible(motionState: motionState) {
                updateFieldBreezeIdle(dt: dt, motionState: motionState)
            } else {
                decayExtraSpin(dt: dt, damping60: 0.90)
            }
        }

        visualRotationX += visualSpinVelocityX * dt
        visualRotationY += visualSpinVelocityY * dt
        visualRotationZ += visualSpinVelocityZ * dt
    }

    // MARK: Exhibition Spin — slow, steady turntable rotation for display.
    private static let exhibitionSpinSpeed: CGFloat = 8.0   // °/s – gentle turntable pace

    private func updateExhibitionSpinIdle(dt: CGFloat) {
        // Damp any residual extra spin from kicks toward zero.
        decayExtraSpin(dt: dt, damping60: 0.96)

        // Slow, steady Y-axis rotation. Smoothly ramp up from standstill.
        let target = Self.exhibitionSpinSpeed
        let ramp: CGFloat = 0.4   // seconds to reach ~63 %
        let alpha = 1 - exp(-dt / ramp)
        visualSpinVelocityY += (target - visualSpinVelocityY) * alpha

        // A very subtle X-axis wobble so it doesn't look robotic.
        idleSpinPhase += dt
        visualRotationX += 0.15 * CGFloat(sin(idleSpinPhase * 0.35))
    }

    private func updateFingerSpinIdle(dt: CGFloat) {
        idleSpinPhase += dt
        fingerSpinTimer += dt

        let targetY: CGFloat
        switch fingerSpinPhaseState {
        case .charging:
            let t = min(1, fingerSpinTimer / max(fingerSpinDuration, 0.001))
            let burstProgress = CGFloat(fingerSpinBurstIndex + 1) / CGFloat(max(fingerSpinBurstCount, 1))
            let burstPeak = lerp(fingerSpinBaseSpeed + 5.0,
                                 fingerSpinPeakSpeed,
                                 smoothStep(burstProgress))
            let startSpeed = fingerSpinCurrentSpeed
            targetY = fingerSpinDirection * lerp(startSpeed, burstPeak, easeOutCubic(t))
            if t >= 1 {
                fingerSpinCurrentSpeed = max(fingerSpinCurrentSpeed, burstPeak)
                fingerSpinPhaseState = .coasting
                fingerSpinTimer = 0
                fingerSpinDuration = fingerSpinBurstIndex >= fingerSpinBurstCount - 1
                    ? CGFloat.random(in: 1.45...2.05)
                    : CGFloat.random(in: 0.08...0.16)
            }

        case .coasting:
            let t = min(1, fingerSpinTimer / max(fingerSpinDuration, 0.001))
            let coastSpeed = fingerSpinBurstIndex >= fingerSpinBurstCount - 1
                ? fingerSpinBaseSpeed
                : fingerSpinCurrentSpeed
            targetY = fingerSpinDirection * lerp(fingerSpinCurrentSpeed,
                                                 coastSpeed,
                                                 smoothStep(t))
            if t >= 1 {
                fingerSpinPhaseState = .charging
                fingerSpinTimer = 0
                if fingerSpinBurstIndex >= fingerSpinBurstCount - 1 {
                    fingerSpinBurstIndex = 0
                    fingerSpinBurstCount = Int.random(in: 3...7)
                    fingerSpinDuration = CGFloat.random(in: 0.09...0.13)
                    fingerSpinPeakSpeed = CGFloat.random(in: 22.0...30.0)
                    fingerSpinBaseSpeed = CGFloat.random(in: 1.0...1.45)
                    fingerSpinCurrentSpeed = fingerSpinBaseSpeed
                } else {
                    fingerSpinBurstIndex += 1
                    fingerSpinDuration = CGFloat.random(in: 0.08...0.12)
                }
            }
        }

        let spinBlend = 1 - pow(fingerSpinPhaseState == .charging ? 0.48 : 0.80, dt * 60.0)
        visualSpinVelocityY += (targetY - visualSpinVelocityY) * spinBlend

        let tilt = min(0.06, abs(visualSpinVelocityY) * 0.0025)
        let targetX = tilt * sin(idleSpinPhase * 0.55)
        let targetZ = tilt * cos(idleSpinPhase * 0.55)
        let tiltBlend = 1 - pow(0.86, dt * 60.0)
        visualSpinVelocityX += (targetX - visualSpinVelocityX) * tiltBlend
        visualSpinVelocityZ += (targetZ - visualSpinVelocityZ) * tiltBlend
    }

    private func updateFieldBreezeIdle(dt: CGFloat, motionState: MotionState) {
        decayExtraSpin(dt: dt, damping60: 0.88)

        guard isFieldBreezeEligible(motionState: motionState) else { return }

        physicalRollCountdown -= dt
        if physicalRollCountdown <= 0 {
            if Double.random(in: 0...1) < 0.32 { physicalRollDirection *= -1 }
            physicalRollTargetSpeed = CGFloat.random(in: 55...155) * physicalRollDirection
            physicalRollCountdown = CGFloat.random(in: 5.5...11.0)
        }

        let blend = 1 - pow(0.965, dt * 60.0)
        ball.velocity.x += (physicalRollTargetSpeed - ball.velocity.x) * blend
    }

    private func isFieldBreezeEligible(motionState: MotionState) -> Bool {
        guard ball.isResting(config: config, bounds: bounds) else { return false }
        switch motionState {
        case .idle:
            return true
        case .rolling:
            return hypot(ball.velocity.x, ball.velocity.y) < 240
        case .flying, .grabbed:
            return false
        }
    }

    private func decayExtraSpin(dt: CGFloat, damping60: CGFloat) {
        let damping = pow(damping60, dt * 60.0)
        visualSpinVelocityX *= damping
        visualSpinVelocityY *= damping
        visualSpinVelocityZ *= damping
    }

    private func applyOffAxisStrike(impulse: CGPoint,
                                    strength: CGFloat,
                                    contactOffset: CGPoint = .zero) {
        let speed = hypot(impulse.x, impulse.y)
        guard speed > 0 else { return }

        let radius = max(config.radius, 1)
        let maxOffset = radius * 0.78
        let clampedOffset = clampVector(contactOffset, maxLength: maxOffset)
        let miss = min(1, hypot(clampedOffset.x, clampedOffset.y) / maxOffset)
        let frontBackOffset = sqrt(max(0, maxOffset * maxOffset
                                       - clampedOffset.x * clampedOffset.x
                                       - clampedOffset.y * clampedOffset.y)) * miss * 0.55
        let scale = min(1.35, speed / 6_500) * (0.50 + 0.50 * strength)

        // Billiards-style angular impulse: torque = r x p. A centre hit mainly
        // changes translation; off-centre hits add spin whose sign follows the
        // miss direction and the incoming impulse.
        let rx = clampedOffset.x
        let ry = clampedOffset.y
        let rz = frontBackOffset
        let torqueX = -rz * impulse.y
        let torqueY = rz * impulse.x
        let torqueZ = rx * impulse.y - ry * impulse.x

        visualSpinVelocityX += torqueX / (radius * radius) * scale
        visualSpinVelocityY += torqueY / (radius * radius) * scale
        visualSpinVelocityZ += torqueZ / (radius * radius) * scale
        visualSpinVelocityX = min(max(visualSpinVelocityX, -18), 18)
        visualSpinVelocityY = min(max(visualSpinVelocityY, -18), 18)
        visualSpinVelocityZ = min(max(visualSpinVelocityZ, -14), 14)
    }

    private func clampVector(_ vector: CGPoint, maxLength: CGFloat) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > maxLength, length > 0 else { return vector }
        let scale = maxLength / length
        return CGPoint(x: vector.x * scale, y: vector.y * scale)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * min(1, max(0, t))
    }

    private func updateFPS(now: CFTimeInterval) {
        guard showsFPS else { return }
        if fpsSampleStart == 0 {
            fpsSampleStart = now
            fpsSampleFrames = 0
            return
        }
        fpsSampleFrames += 1
        let elapsed = now - fpsSampleStart
        guard elapsed >= 0.5 else { return }
        measuredFPS = Double(fpsSampleFrames) / elapsed
        fpsSampleStart = now
        fpsSampleFrames = 0
    }

    /// The union of every screen's play area — used only while the ball is
    /// being carried, so it can travel between displays. Offset/odd-sized displays
    /// leave "void" gaps inside the bounding box the ball can pass through.
    private func roamingBounds() -> Bounds {
        let screens = NSScreen.screens
        guard let first = screens.first else { return bounds }
        let union = screens.dropFirst().reduce(Self.playArea(for: first).rect) { rect, screen in
            rect.union(Self.playArea(for: screen).rect)
        }
        return Bounds(rect: union)
    }

    /// The full viewport of the screen the given point sits on, with a fixed bottom
    /// Dock clearance — the play area when
    /// the ball is free, so each display keeps its own edges. If the point is in a
    /// gap between displays (or off them all) we fall back to the nearest screen so
    /// the ball is pulled back onto a real display rather than lost in the void.
    private func screenBounds(containing point: CGPoint) -> Bounds {
        guard let screen = screen(containing: point) else { return bounds }
        return Self.playArea(for: screen)
    }

    private static func playArea(for screen: NSScreen) -> Bounds {
        let frame = screen.frame
        let menuBarHeight = frame.height - screen.visibleFrame.maxY
        return Bounds(rect: CGRect(
            x: frame.minX,
            y: frame.minY + dockClearance,
            width: frame.width,
            height: frame.height - dockClearance - menuBarHeight
        ))
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
                self.applyOffAxisStrike(
                    impulse: CGPoint(x: cos(angle) * capturedImpulse,
                                     y: sin(angle) * capturedImpulse),
                    strength: capturedPower
                )
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
        applyOffAxisStrike(impulse: CGPoint(x: ux * impulse, y: uy * impulse),
                           strength: multiplier / 4.0)
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
        guard ball.isGrabbed || ball.isSnapped || distanceFromBall(m) <= glassGrabRadius else {
            interactive = false
            ignoresMouseEvents = true
            return
        }
        didDrag = false
        ball.velocity = .zero                       // "catch" the ball
        ball.isGrabbed = true
        ball.isSnapped = false
        grabOffset = CGPoint(x: ball.center.x - m.x, y: ball.center.y - m.y)
    }

    private func distanceFromBall(_ point: NSPoint) -> CGFloat {
        hypot(point.x - ball.center.x, point.y - ball.center.y)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        ball.isGrabbed = false
        if didDrag {
            // release → tick throws with carried velocity
        } else {
            ball.applyClick(config: config)          // tap → dribble pop
            sound.playKick(strength: 420)
        }
        didDrag = false
    }
}

private extension CGRect {
    func insetByBottom(_ amount: CGFloat) -> CGRect {
        let inset = min(max(amount, 0), height)
        return CGRect(x: minX, y: minY + inset, width: width, height: height - inset)
    }
}
