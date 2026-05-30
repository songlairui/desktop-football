import AppKit
import Metal
import MetalKit
import FootballPhysics

struct GlassInteractionFeedback {
    var ballCenter: CGPoint
    var mouse: CGPoint
    var visibleRadius: CGFloat
    var strikeRadius: CGFloat
    var isNear: Bool
    var canGrab: Bool
    var isGrabbed: Bool
    var isSnapped: Bool
    var didStrike: Bool
}

/// A plain `NSView` backed by a `CAMetalLayer` that owns the Metal rendering
/// pipeline. Driven once per CVDisplayLink tick by `FootballPanel`.
///
/// Unlike `MTKView`, this uses CVDisplayLink for frame timing (consistent with
/// the existing 60 fps loop) and provides explicit control over drawable
/// acquisition so we never block the main thread on a GPU fence.
final class FootballMetalView: NSView {

    private let metalLayer: CAMetalLayer
    private var depthTexture: MTLTexture?
    private let scene: MetalScene
    private let strikeRingLayer = CAShapeLayer()
    private let hitRingLayer = CAShapeLayer()
    private let cursorLineLayer = CAShapeLayer()

    init(frame: NSRect, scene: MetalScene) {
        self.scene = scene
        metalLayer = CAMetalLayer()
        metalLayer.device = scene.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = nil   // transparent
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true

        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(metalLayer)
        configureGlassOverlayLayers()
        layer?.addSublayer(strikeRingLayer)
        layer?.addSublayer(hitRingLayer)
        layer?.addSublayer(cursorLineLayer)
        layer?.masksToBounds = false
        updateRenderTargets()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderTargets()
    }

    override func layout() {
        super.layout()
        updateRenderTargets()
    }

    private func updateRenderTargets() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))
        let drawableSize = CGSize(width: w, height: h)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        CATransaction.commit()

        guard metalLayer.drawableSize != drawableSize || depthTexture == nil else { return }
        metalLayer.drawableSize = CGSize(width: w, height: h)
        rebuildDepthTexture(width: w, height: h)
    }

    /// Called once per CVDisplayLink tick (from main thread). Grabs a drawable,
    /// tells the scene to render, and presents it.
    func render(ballState: BallState,
                config: PhysicsConfig,
                bounds: Bounds,
                interaction: GlassInteractionFeedback) {
        updateRenderTargets()
        updateGlassOverlay(interaction)
        guard let depthTexture,
              let drawable = metalLayer.nextDrawable() else { return }
        let viewport = window?.frame ?? NSRect(origin: .zero, size: self.bounds.size)
        scene.draw(in: drawable, depthTexture: depthTexture,
                   ballState: ballState, config: config, bounds: bounds,
                   viewport: viewport)
    }

    private func configureGlassOverlayLayers() {
        strikeRingLayer.fillColor = nil
        strikeRingLayer.lineWidth = 1.5
        strikeRingLayer.lineDashPattern = [6, 6]
        strikeRingLayer.isHidden = true

        hitRingLayer.fillColor = nil
        hitRingLayer.lineWidth = 2
        hitRingLayer.isHidden = true

        cursorLineLayer.fillColor = nil
        cursorLineLayer.lineWidth = 1
        cursorLineLayer.lineCap = .round
        cursorLineLayer.isHidden = true
    }

    private func updateGlassOverlay(_ feedback: GlassInteractionFeedback) {
        let shouldShow = feedback.isNear || feedback.isGrabbed || feedback.isSnapped || feedback.didStrike
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        strikeRingLayer.frame = bounds
        hitRingLayer.frame = bounds
        cursorLineLayer.frame = bounds

        guard shouldShow, let window else {
            strikeRingLayer.isHidden = true
            hitRingLayer.isHidden = true
            cursorLineLayer.isHidden = true
            return
        }

        let origin = window.frame.origin
        let ball = CGPoint(x: feedback.ballCenter.x - origin.x,
                           y: feedback.ballCenter.y - origin.y)
        let mouse = CGPoint(x: feedback.mouse.x - origin.x,
                            y: feedback.mouse.y - origin.y)

        let strikeRect = CGRect(x: ball.x - feedback.strikeRadius,
                                y: ball.y - feedback.strikeRadius,
                                width: feedback.strikeRadius * 2,
                                height: feedback.strikeRadius * 2)
        let hitRect = CGRect(x: ball.x - feedback.visibleRadius,
                             y: ball.y - feedback.visibleRadius,
                             width: feedback.visibleRadius * 2,
                             height: feedback.visibleRadius * 2)

        let accent: NSColor
        if feedback.didStrike {
            accent = .systemYellow
        } else if feedback.isGrabbed || feedback.isSnapped {
            accent = .systemOrange
        } else if feedback.canGrab {
            accent = .white
        } else {
            accent = .systemCyan
        }

        strikeRingLayer.path = CGPath(ellipseIn: strikeRect, transform: nil)
        strikeRingLayer.strokeColor = accent.withAlphaComponent(feedback.canGrab ? 0.28 : 0.18).cgColor
        strikeRingLayer.isHidden = false

        hitRingLayer.path = CGPath(ellipseIn: hitRect, transform: nil)
        hitRingLayer.strokeColor = accent.withAlphaComponent(feedback.canGrab ? 0.68 : 0.34).cgColor
        hitRingLayer.isHidden = false

        let line = CGMutablePath()
        line.move(to: mouse)
        line.addLine(to: ball)
        cursorLineLayer.path = line
        cursorLineLayer.strokeColor = accent.withAlphaComponent(feedback.canGrab ? 0.26 : 0.14).cgColor
        cursorLineLayer.isHidden = !feedback.canGrab && !feedback.isGrabbed && !feedback.isSnapped
    }

    private func rebuildDepthTexture(width: Int, height: Int) {
        guard width > 0, height > 0,
              (depthTexture == nil ||
               depthTexture!.width != width || depthTexture!.height != height)
        else { return }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        depthTexture = scene.device.makeTexture(descriptor: td)
    }
}
