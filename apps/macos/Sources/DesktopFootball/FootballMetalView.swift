import AppKit
import Metal
import MetalKit
import FootballPhysics

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
    func render(ballState: BallState, config: PhysicsConfig, bounds: Bounds) {
        updateRenderTargets()
        guard let depthTexture,
              let drawable = metalLayer.nextDrawable() else { return }
        let viewport = window?.frame ?? NSRect(origin: .zero, size: self.bounds.size)
        scene.draw(in: drawable, depthTexture: depthTexture,
                   ballState: ballState, config: config, bounds: bounds,
                   viewport: viewport)
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
