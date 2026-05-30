import Metal
import MetalKit
import ModelIO
import simd
import FootballPhysics

/// The 3D rendering pipeline. Owns the Metal device, command queue, pipeline
/// states, meshes and camera. Driven once per CVDisplayLink frame by
/// `FootballMetalView`.
///
/// Coordinate convention:
///   X = horizontal,  Y = vertical (up),  Z = depth (out of screen).
///   The "ground plane" is the XZ plane at Y = 0.
///   The ball sits at (X, 0, -Z) in world space (Z = screen Y).
///   Gravity acts in -Y direction.
final class MetalScene {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ballPipeline: MTLRenderPipelineState
    private let groundPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState

    // Meshes
    private let ballMesh: MTKMesh
    private let groundMesh: MTKMesh
    private let shadowMesh: MTKMesh   // flat disc for shadow

    // Texture
    private var skinTexture: MTLTexture!
    private let sampler: MTLSamplerState

    // Camera
    private let camera = MetalCamera()

    // Shaders expect a 4×4 uniform (aligned to 256 bytes by Metal convention).
    private var uniforms = SceneUniforms()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        // Compile the embedded Metal shader source at runtime — keeps the .app
        // single-file and avoids SPM resource-handling quirks for .metal.
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        // ── Pipeline descriptors ──────────────────────────────────────────────

        let ballVD = MTLVertexDescriptor()
        ballVD.attributes[0].format = .float3; ballVD.attributes[0].offset = 0;  ballVD.attributes[0].bufferIndex = 0
        ballVD.attributes[1].format = .float3; ballVD.attributes[1].offset = 12; ballVD.attributes[1].bufferIndex = 0
        ballVD.attributes[2].format = .float2; ballVD.attributes[2].offset = 24; ballVD.attributes[2].bufferIndex = 0
        ballVD.layouts[0].stride = 32

        let ballPD = MTLRenderPipelineDescriptor()
        ballPD.vertexFunction   = library.makeFunction(name: "ballVertex")
        ballPD.fragmentFunction = library.makeFunction(name: "ballFragment")
        ballPD.vertexDescriptor = ballVD
        ballPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        ballPD.colorAttachments[0].isBlendingEnabled = true
        ballPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        ballPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        ballPD.depthAttachmentPixelFormat = .depth32Float

        guard let bp = try? device.makeRenderPipelineState(descriptor: ballPD) else { return nil }
        self.ballPipeline = bp

        // Ground pipeline — same vertex layout
        let groundPD = MTLRenderPipelineDescriptor()
        groundPD.vertexFunction   = library.makeFunction(name: "groundVertex")
        groundPD.fragmentFunction = library.makeFunction(name: "groundFragment")
        groundPD.vertexDescriptor = ballVD
        groundPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        groundPD.colorAttachments[0].isBlendingEnabled = true
        groundPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        groundPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        groundPD.depthAttachmentPixelFormat = .depth32Float

        guard let gp = try? device.makeRenderPipelineState(descriptor: groundPD) else { return nil }
        self.groundPipeline = gp

        // Shadow pipeline — same vertex layout
        let shadowPD = MTLRenderPipelineDescriptor()
        shadowPD.vertexFunction   = library.makeFunction(name: "shadowVertex")
        shadowPD.fragmentFunction = library.makeFunction(name: "shadowFragment")
        shadowPD.vertexDescriptor = ballVD
        shadowPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        shadowPD.colorAttachments[0].isBlendingEnabled = true
        shadowPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        shadowPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        shadowPD.depthAttachmentPixelFormat = .depth32Float

        guard let sp = try? device.makeRenderPipelineState(descriptor: shadowPD) else { return nil }
        self.shadowPipeline = sp

        let guidePD = MTLRenderPipelineDescriptor()
        guidePD.vertexFunction = library.makeFunction(name: "guideVertex")
        guidePD.fragmentFunction = library.makeFunction(name: "guideFragment")
        guidePD.colorAttachments[0].pixelFormat = .bgra8Unorm
        guidePD.colorAttachments[0].isBlendingEnabled = true
        guidePD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        guidePD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        guidePD.depthAttachmentPixelFormat = .depth32Float

        guard let guide = try? device.makeRenderPipelineState(descriptor: guidePD) else { return nil }
        self.guidePipeline = guide

        // ── Meshes via ModelIO ────────────────────────────────────────────────

        let mtkVD = MTKModelIOVertexDescriptorFromMetal(ballVD)
        (mtkVD.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (mtkVD.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (mtkVD.attributes[2] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate

        let ballAsset = MDLMesh(sphereWithExtent: vector_float3(2, 2, 2),
                                segments: vector_uint2(48, 48),
                                inwardNormals: false,
                                geometryType: MDLGeometryType.triangles,
                                allocator: MTKMeshBufferAllocator(device: device))
        ballAsset.vertexDescriptor = mtkVD
        guard let ballMesh = try? MTKMesh(mesh: ballAsset, device: device) else { return nil }
        self.ballMesh = ballMesh

        let groundAsset = MDLMesh(planeWithExtent: vector_float3(4000, 1, 4000),
                                   segments: vector_uint2(2, 2),
                                   geometryType: MDLGeometryType.triangles,
                                   allocator: MTKMeshBufferAllocator(device: device))
        groundAsset.vertexDescriptor = mtkVD
        // We need to rotate the plane to lie on the XZ plane (Y = 0).
        // MDLMesh.newPlane creates it on XY by default. We apply a rotation in
        // the vertex shader via the model matrix, or just patch the mesh.
        guard let groundMesh = try? MTKMesh(mesh: groundAsset, device: device) else { return nil }
        self.groundMesh = groundMesh

        // Shadow disc — a flat circle at Y = 0
        // Shadow disc — a sphere that is flattened at render time so it becomes a
        // thin elliptical disc resting on the ground plane (Y ≈ 0).
        let shadowAsset = MDLMesh(sphereWithExtent: vector_float3(2, 2, 2),
                                   segments: vector_uint2(32, 16),
                                   inwardNormals: false,
                                   geometryType: MDLGeometryType.triangles,
                                   allocator: MTKMeshBufferAllocator(device: device))
        shadowAsset.vertexDescriptor = mtkVD
        guard let shadowMesh = try? MTKMesh(mesh: shadowAsset, device: device) else { return nil }
        self.shadowMesh = shadowMesh

        // ── Texture ───────────────────────────────────────────────────────────

        skinTexture = Self.makeFootballTexture(device: device)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sampler
    }

    /// Render one frame into the provided drawable + depth texture.
    func draw(in drawable: CAMetalDrawable,
              depthTexture: MTLTexture,
              ballState: BallState,
              config: PhysicsConfig,
              bounds: Bounds,
              viewport: CGRect) {

        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: {
                  let rpd = MTLRenderPassDescriptor()
                  rpd.colorAttachments[0].texture = drawable.texture
                  rpd.colorAttachments[0].loadAction = .clear
                  rpd.colorAttachments[0].storeAction = .store
                  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                  rpd.depthAttachment.texture = depthTexture
                  rpd.depthAttachment.loadAction = .clear
                  rpd.depthAttachment.storeAction = .dontCare
                  rpd.depthAttachment.clearDepth = 1.0
                  return rpd
              }()) else { return }

        // ── Build uniforms ────────────────────────────────────────────────────
        let aspect = Float(drawable.texture.width) / Float(drawable.texture.height)
        uniforms.projection = camera.projectionMatrix(aspect: aspect)
        uniforms.view = camera.viewMatrix()

        let mapping = tankMapping(bounds: bounds, viewport: viewport)
        let scale = max(8, Float(config.radius) * mapping.pointsToWorld)
        let worldBall = screenToTankWorld(ballState.center, worldRadius: scale,
                                          screenRadius: config.radius, bounds: bounds,
                                          mapping: mapping)
        uniforms.model = float4x4(translation: worldBall)
            * float4x4(rotationY: Float(ballState.angle))
            * float4x4(scale: SIMD3<Float>(scale, scale, scale))
        uniforms.squash = Float(ballState.squash)
        uniforms.ballRadius = scale
        uniforms.lightPos = SIMD3<Float>(0, 800, 600)
        uniforms.viewPos = camera.eye

        // The desktop is the visible ground; draw only local helper lines so the
        // 3D relation is readable without tinting the whole screen.
        drawGuideLines(encoder: encoder, center: worldBall, radius: scale, mapping: mapping)

        // ── Shadow disc ───────────────────────────────────────────────────────
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: true))
        var shadowUniforms = uniforms
        let shadowScale = scale * 1.5
        shadowUniforms.model = float4x4(translation: SIMD3<Float>(worldBall.x, 0.5, worldBall.z))
            * float4x4(scale: SIMD3<Float>(shadowScale, shadowScale, shadowScale))
        encoder.setVertexBytes(&shadowUniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        let svBuf = shadowMesh.vertexBuffers[0]
        encoder.setVertexBuffer(svBuf.buffer, offset: svBuf.offset, index: 0)
        for sub in shadowMesh.submeshes {
            encoder.drawIndexedPrimitives(type: sub.primitiveType,
                                          indexCount: sub.indexCount,
                                          indexType: sub.indexType,
                                          indexBuffer: sub.indexBuffer.buffer,
                                          indexBufferOffset: sub.indexBuffer.offset)
        }

        // ── Ball ──────────────────────────────────────────────────────────────
        encoder.setRenderPipelineState(ballPipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: false))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setFragmentTexture(skinTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let bvBuf = ballMesh.vertexBuffers[0]
        encoder.setVertexBuffer(bvBuf.buffer, offset: bvBuf.offset, index: 0)
        for sub in ballMesh.submeshes {
            encoder.drawIndexedPrimitives(type: sub.primitiveType,
                                          indexCount: sub.indexCount,
                                          indexType: sub.indexType,
                                          indexBuffer: sub.indexBuffer.buffer,
                                          indexBufferOffset: sub.indexBuffer.offset)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - Coordinate mapping

    private func tankMapping(bounds: Bounds, viewport: CGRect) -> TankMapping {
        let tankHeight: Float = 620
        let pointsToWorld = tankHeight / max(Float(bounds.rect.height), 1)
        let halfWidth = Float(bounds.rect.width) * pointsToWorld * 0.5
        return TankMapping(pointsToWorld: pointsToWorld,
                           height: tankHeight,
                           minX: -halfWidth,
                           maxX: halfWidth,
                           minZ: -360,
                           maxZ: 360)
    }

    private func screenToTankWorld(_ screen: CGPoint,
                                   worldRadius: Float,
                                   screenRadius: CGFloat,
                                   bounds: Bounds,
                                   mapping: TankMapping) -> SIMD3<Float> {
        let x = Float(screen.x - bounds.rect.midX) * mapping.pointsToWorld
        let lift = max(0, Float(screen.y - bounds.floorY(radius: screenRadius)) * mapping.pointsToWorld)
        return SIMD3<Float>(x, worldRadius + lift, 0)
    }

    private func drawGuideLines(encoder: MTLRenderCommandEncoder,
                                center: SIMD3<Float>,
                                radius: Float,
                                mapping: TankMapping) {
        var vertices: [GuideVertex] = []
        let floorY: Float = 0.75
        let step: Float = 80
        let floorMinor = SIMD4<Float>(0.45, 0.75, 1.0, 0.055)
        let floorMajor = SIMD4<Float>(0.70, 0.92, 1.0, 0.12)
        let wallMinor = SIMD4<Float>(0.58, 0.82, 1.0, 0.035)
        let wallMajor = SIMD4<Float>(0.78, 0.94, 1.0, 0.075)
        let edge = SIMD4<Float>(0.88, 0.97, 1.0, 0.14)
        let drop = SIMD4<Float>(1.0, 1.0, 1.0, 0.26)

        func addLine(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>) {
            vertices.append(GuideVertex(position: a, color: color))
            vertices.append(GuideVertex(position: b, color: color))
        }

        // Fixed floor grid.
        var x = floor(mapping.minX / step) * step
        while x <= mapping.maxX + 0.1 {
            let color = abs(x) < step * 0.5 ? floorMajor : floorMinor
            addLine(SIMD3<Float>(x, floorY, mapping.minZ),
                    SIMD3<Float>(x, floorY, mapping.maxZ),
                    color)
            x += step
        }

        var z = floor(mapping.minZ / step) * step
        while z <= mapping.maxZ + 0.1 {
            let color = abs(z) < step * 0.5 ? floorMajor : floorMinor
            addLine(SIMD3<Float>(mapping.minX, floorY, z),
                    SIMD3<Float>(mapping.maxX, floorY, z),
                    color)
            z += step
        }

        // Fixed back wall grid so the viewer has a stable depth reference.
        x = floor(mapping.minX / step) * step
        while x <= mapping.maxX + 0.1 {
            let color = abs(x) < step * 0.5 ? wallMajor : wallMinor
            addLine(SIMD3<Float>(x, floorY, mapping.maxZ),
                    SIMD3<Float>(x, mapping.height, mapping.maxZ),
                    color)
            x += step
        }

        var y = floor(floorY / step) * step
        while y <= mapping.height + 0.1 {
            let color = abs(y) < step * 0.5 ? wallMajor : wallMinor
            addLine(SIMD3<Float>(mapping.minX, y, mapping.maxZ),
                    SIMD3<Float>(mapping.maxX, y, mapping.maxZ),
                    color)
            y += step
        }

        // Tank boundary edges: subtle enough not to become UI chrome, but fixed.
        addLine(SIMD3<Float>(mapping.minX, floorY, mapping.minZ),
                SIMD3<Float>(mapping.maxX, floorY, mapping.minZ), edge)
        addLine(SIMD3<Float>(mapping.minX, floorY, mapping.maxZ),
                SIMD3<Float>(mapping.maxX, floorY, mapping.maxZ), edge)
        addLine(SIMD3<Float>(mapping.minX, floorY, mapping.minZ),
                SIMD3<Float>(mapping.minX, floorY, mapping.maxZ), edge)
        addLine(SIMD3<Float>(mapping.maxX, floorY, mapping.minZ),
                SIMD3<Float>(mapping.maxX, floorY, mapping.maxZ), edge)
        addLine(SIMD3<Float>(mapping.minX, floorY, mapping.maxZ),
                SIMD3<Float>(mapping.minX, mapping.height, mapping.maxZ), edge)
        addLine(SIMD3<Float>(mapping.maxX, floorY, mapping.maxZ),
                SIMD3<Float>(mapping.maxX, mapping.height, mapping.maxZ), edge)
        addLine(SIMD3<Float>(mapping.minX, mapping.height, mapping.maxZ),
                SIMD3<Float>(mapping.maxX, mapping.height, mapping.maxZ), edge)

        // Ball height reference in the fixed tank, not a moving coordinate axis.
        addLine(SIMD3<Float>(center.x, floorY, center.z),
                SIMD3<Float>(center.x, center.y, center.z),
                drop)

        encoder.setRenderPipelineState(guidePipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: true))
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setVertexBytes(base, length: bytes.count, index: 0)
            }
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    // MARK: - Procedural texture

    private static func makeFootballTexture(device: MTLDevice) -> MTLTexture {
        let size = 1024
        // Draw the football pattern into a CGContext, then upload to Metal.
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var data = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        guard let ctx = CGContext(data: &data, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Self.fallbackTexture(device: device) }

        let s = CGFloat(size)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Matte white base. Do not clip to a circle: UV sphere sampling needs an
        // opaque full-rectangle texture, otherwise transparent corners wrap onto
        // the ball as broken dark patches.
        ctx.setFillColor(CGColor(red: 0.965, green: 0.955, blue: 0.925, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        Self.drawBaseGrain(ctx, size: s)
        Self.drawPanelSeams(ctx, size: s)

        let centers = [
            CGPoint(x: s * 0.12, y: s * 0.50),
            CGPoint(x: s * 0.37, y: s * 0.48),
            CGPoint(x: s * 0.62, y: s * 0.52),
            CGPoint(x: s * 0.87, y: s * 0.50),
        ]
        for (index, center) in centers.enumerated() {
            let rotation = CGFloat(index) * .pi * 0.42 + (index.isMultiple(of: 2) ? 0.0 : .pi)
            Self.drawTriondaCluster(ctx, center: center, scale: s * 0.235, rotation: rotation)
        }
        Self.drawSubtleEmboss(ctx, size: s)

        // Upload to MTLTexture
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                           width: size, height: size,
                                                           mipmapped: false)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else {
            return Self.fallbackTexture(device: device)
        }
        // CGContext writes RGBA; Metal .bgra8Unorm expects BGRA, so swap R/B.
        for i in 0..<(size * size) {
            let base = i * 4
            data.swapAt(base, base + 2)  // swap R and B
        }
        tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: size, height: size, depth: 1)),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func drawBaseGrain(_ ctx: CGContext, size s: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(s * 0.0012)
        for i in stride(from: 0, through: Int(s), by: 18) {
            let y = CGFloat(i)
            let alpha = 0.025 + 0.018 * abs(sin(CGFloat(i) * 0.19))
            ctx.setStrokeColor(CGColor(red: 0.18, green: 0.18, blue: 0.16, alpha: alpha))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addCurve(to: CGPoint(x: s, y: y + sin(y * 0.03) * s * 0.006),
                          control1: CGPoint(x: s * 0.30, y: y + s * 0.010),
                          control2: CGPoint(x: s * 0.70, y: y - s * 0.010))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawPanelSeams(_ ctx: CGContext, size s: CGFloat) {
        func strokeSeam(_ path: CGPath) {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setStrokeColor(CGColor(red: 0.54, green: 0.50, blue: 0.43, alpha: 0.30))
            ctx.setLineWidth(s * 0.026)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0.96, alpha: 0.86))
            ctx.setLineWidth(s * 0.014)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        for x0 in stride(from: -s * 0.18, through: s * 1.12, by: s * 0.25) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: -s * 0.08))
            path.addCurve(to: CGPoint(x: x0 + s * 0.17, y: s * 1.08),
                          control1: CGPoint(x: x0 + s * 0.11, y: s * 0.23),
                          control2: CGPoint(x: x0 - s * 0.08, y: s * 0.78))
            strokeSeam(path)
        }

        for y0 in [s * 0.23, s * 0.77] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -s * 0.05, y: y0))
            path.addCurve(to: CGPoint(x: s * 1.05, y: y0 + s * 0.03),
                          control1: CGPoint(x: s * 0.27, y: y0 + s * 0.09),
                          control2: CGPoint(x: s * 0.76, y: y0 - s * 0.08))
            strokeSeam(path)
        }
    }

    private static func drawTriondaCluster(_ ctx: CGContext,
                                           center: CGPoint,
                                           scale: CGFloat,
                                           rotation: CGFloat) {
        let red = CGColor(red: 0.84, green: 0.04, blue: 0.06, alpha: 1)
        let green = CGColor(red: 0.04, green: 0.54, blue: 0.18, alpha: 1)
        let blue = CGColor(red: 0.03, green: 0.42, blue: 0.86, alpha: 1)

        Self.drawTriondaArm(ctx, center: center, scale: scale,
                            rotation: rotation,
                            color: red, icon: .maple)
        Self.drawTriondaArm(ctx, center: center, scale: scale,
                            rotation: rotation + .pi * 2 / 3,
                            color: green, icon: .eagle)
        Self.drawTriondaArm(ctx, center: center, scale: scale,
                            rotation: rotation + .pi * 4 / 3,
                            color: blue, icon: .star)

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation + .pi / 6)
        ctx.scaleBy(x: scale, y: scale)
        let tri = CGMutablePath()
        for i in 0..<3 {
            let a = CGFloat(i) * .pi * 2 / 3 - .pi / 2
            let p = CGPoint(x: cos(a) * 0.20, y: sin(a) * 0.20)
            if i == 0 { tri.move(to: p) } else { tri.addLine(to: p) }
        }
        tri.closeSubpath()
        ctx.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.88, alpha: 0.94))
        ctx.addPath(tri)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.93, green: 0.72, blue: 0.30, alpha: 0.80))
        ctx.setLineWidth(0.025)
        ctx.addPath(tri)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private enum TriondaIcon {
        case star
        case maple
        case eagle
    }

    private static func drawTriondaArm(_ ctx: CGContext,
                                       center: CGPoint,
                                       scale: CGFloat,
                                       rotation: CGFloat,
                                       color: CGColor,
                                       icon: TriondaIcon) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: scale, y: scale)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.05, y: -0.16))
        path.addCurve(to: CGPoint(x: 0.95, y: -0.30),
                      control1: CGPoint(x: 0.28, y: -0.35),
                      control2: CGPoint(x: 0.68, y: -0.36))
        path.addCurve(to: CGPoint(x: 1.15, y: 0.17),
                      control1: CGPoint(x: 1.10, y: -0.20),
                      control2: CGPoint(x: 1.18, y: 0.01))
        path.addCurve(to: CGPoint(x: 0.17, y: 0.24),
                      control1: CGPoint(x: 0.80, y: 0.36),
                      control2: CGPoint(x: 0.45, y: 0.33))
        path.addCurve(to: CGPoint(x: 0.05, y: -0.16),
                      control1: CGPoint(x: 0.07, y: 0.12),
                      control2: CGPoint(x: 0.01, y: -0.04))
        path.closeSubpath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: -0.10, y: -0.48, width: 1.38, height: 0.96))

        ctx.setLineCap(.round)
        for i in -4...4 {
            let y = CGFloat(i) * 0.095
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0.04, y: y - 0.08))
            line.addCurve(to: CGPoint(x: 1.18, y: y + 0.04),
                          control1: CGPoint(x: 0.36, y: y + 0.12),
                          control2: CGPoint(x: 0.82, y: y - 0.13))
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
            ctx.setLineWidth(0.016)
            ctx.addPath(line)
            ctx.strokePath()
        }

        for i in 0..<3 {
            let x = 0.34 + CGFloat(i) * 0.13
            let mark = CGMutablePath()
            mark.move(to: CGPoint(x: x, y: -0.26))
            mark.addLine(to: CGPoint(x: x + 0.10, y: 0.22))
            ctx.setStrokeColor(CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 0.20))
            ctx.setLineWidth(0.028)
            ctx.addPath(mark)
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(red: 0.95, green: 0.75, blue: 0.33, alpha: 0.92))
        ctx.setLineWidth(0.026)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 0.86))
        ctx.setLineWidth(0.018)
        ctx.addPath(path)
        ctx.strokePath()

        switch icon {
        case .star:
            drawStar(ctx, center: CGPoint(x: 0.78, y: -0.01), radius: 0.15)
        case .maple:
            drawMapleLeaf(ctx, center: CGPoint(x: 0.77, y: -0.01), radius: 0.17)
        case .eagle:
            drawEagleGlyph(ctx, center: CGPoint(x: 0.77, y: -0.01), radius: 0.17)
        }

        ctx.restoreGState()
    }

    private static func drawSubtleEmboss(_ ctx: CGContext, size s: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.72, green: 0.68, blue: 0.58, alpha: 0.18))
        ctx.setLineWidth(s * 0.003)
        for x in stride(from: s * 0.04, through: s * 0.96, by: s * 0.115) {
            for y in stride(from: s * 0.08, through: s * 0.92, by: s * 0.18) {
                let path = CGMutablePath()
                path.addEllipse(in: CGRect(x: x - s * 0.015, y: y - s * 0.015,
                                           width: s * 0.03, height: s * 0.03))
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    private static func drawStar(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let path = CGMutablePath()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? radius : radius * 0.42
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.86))
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func drawMapleLeaf(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let points: [CGPoint] = [
            CGPoint(x: 0.00, y: 1.00), CGPoint(x: 0.14, y: 0.42),
            CGPoint(x: 0.45, y: 0.62), CGPoint(x: 0.34, y: 0.25),
            CGPoint(x: 0.72, y: 0.18), CGPoint(x: 0.34, y: -0.02),
            CGPoint(x: 0.52, y: -0.44), CGPoint(x: 0.12, y: -0.22),
            CGPoint(x: 0.05, y: -0.78), CGPoint(x: -0.05, y: -0.78),
            CGPoint(x: -0.12, y: -0.22), CGPoint(x: -0.52, y: -0.44),
            CGPoint(x: -0.34, y: -0.02), CGPoint(x: -0.72, y: 0.18),
            CGPoint(x: -0.34, y: 0.25), CGPoint(x: -0.45, y: 0.62),
            CGPoint(x: -0.14, y: 0.42),
        ]
        let path = CGMutablePath()
        for (index, p) in points.enumerated() {
            let point = CGPoint(x: center.x + p.x * radius, y: center.y + p.y * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.84))
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func drawEagleGlyph(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: radius, y: radius)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.84))
        ctx.setLineWidth(0.16)

        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: -0.85, y: 0.18))
        wing.addCurve(to: CGPoint(x: 0.02, y: 0.38),
                      control1: CGPoint(x: -0.46, y: 0.62),
                      control2: CGPoint(x: -0.16, y: 0.58))
        wing.addCurve(to: CGPoint(x: 0.82, y: 0.02),
                      control1: CGPoint(x: 0.24, y: 0.18),
                      control2: CGPoint(x: 0.50, y: 0.03))
        ctx.addPath(wing)
        ctx.strokePath()

        for i in 0..<3 {
            let y = 0.03 - CGFloat(i) * 0.25
            let feather = CGMutablePath()
            feather.move(to: CGPoint(x: -0.55 + CGFloat(i) * 0.18, y: y))
            feather.addLine(to: CGPoint(x: 0.54 - CGFloat(i) * 0.10, y: y - 0.18))
            ctx.addPath(feather)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func fallbackTexture(device: MTLDevice) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                           width: 4, height: 4, mipmapped: false)
        td.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: td)!
        let white: [UInt8] = Array(repeating: 255, count: 64)  // all white
        tex.replace(region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                       size: .init(width: 4, height: 4, depth: 1)),
                    mipmapLevel: 0, withBytes: white, bytesPerRow: 16)
        return tex
    }

    private static func fillPentagon(_ ctx: CGContext, center: CGPoint, radius: CGFloat, angle: CGFloat) {
        let path = CGMutablePath()
        for i in 0..<5 {
            let a = angle + CGFloat(i) * (2 * .pi / 5)
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    // MARK: - Depth state

    private func makeDepthState(_ device: MTLDevice, readOnly: Bool) -> MTLDepthStencilState {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = !readOnly
        return device.makeDepthStencilState(descriptor: d)!
    }

    // MARK: - Embedded shader source (avoids SPM resource handling for .metal)

    /// The Metal Shading Language source for all vertex/fragment functions.
    /// Kept inline so the .app remains a single binary with no resource bundle.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SceneUniforms {
        float4x4 projection;
        float4x4 view;
        float4x4 model;
        float3   lightPos;
        float3   viewPos;
        float    squash;
        float    ballRadius;
    };

    struct VertexIn {
        float3 position  [[attribute(0)]];
        float3 normal    [[attribute(1)]];
        float2 texCoord  [[attribute(2)]];
    };

    struct VertexOut {
        float4 position  [[position]];
        float3 worldPos;
        float3 worldNormal;
        float2 uv;
    };

    vertex VertexOut ballVertex(VertexIn in [[stage_in]],
                                constant SceneUniforms &u [[buffer(1)]]) {
        VertexOut out;
        float sq = u.squash;
        float sy = 1.0 - sq;
        float sxz = sqrt(1.0 / max(sy, 0.3));
        float3 p = float3(in.position.x * sxz,
                          in.position.y * sy,
                          in.position.z * sxz);
        float3 n = normalize(float3(in.normal.x / sxz,
                                     in.normal.y / sy,
                                     in.normal.z / sxz));
        float4 worldPos = u.model * float4(p, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.worldPos = worldPos.xyz;
        out.worldNormal = normalize((u.model * float4(n, 0.0)).xyz);
        out.uv = in.texCoord;
        return out;
    }

    fragment float4 ballFragment(VertexOut in [[stage_in]],
                                 constant SceneUniforms &u [[buffer(1)]],
                                 texture2d<float> skinTexture [[texture(0)]],
                                 sampler texSampler [[sampler(0)]]) {
        float3 N = normalize(in.worldNormal);
        float3 V = normalize(u.viewPos - in.worldPos);
        float3 L = normalize(u.lightPos - in.worldPos);
        float3 H = normalize(L + V);
        float ambient = 0.18;
        float diff = max(dot(N, L), 0.0);
        float diffuse = 0.20 + 0.75 * diff;
        float spec = pow(max(dot(N, H), 0.0), 64.0);
        float specular = 0.24 * spec;
        float fresnel = pow(1.0 - max(dot(N, V), 0.0), 3.0);
        float rim = 0.25 * fresnel;
        float lighting = ambient + diffuse + specular + rim;
        float4 texColor = skinTexture.sample(texSampler, in.uv);
        float3 lit = texColor.rgb * lighting;
        return float4(lit, texColor.a);
    }

    vertex VertexOut groundVertex(VertexIn in [[stage_in]],
                                  constant SceneUniforms &u [[buffer(1)]]) {
        VertexOut out;
        float4 worldPos = u.model * float4(in.position, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.worldPos = worldPos.xyz;
        out.worldNormal = normalize((u.model * float4(in.normal, 0.0)).xyz);
        out.uv = in.texCoord;
        return out;
    }

    fragment float4 groundFragment(VertexOut in [[stage_in]],
                                   constant SceneUniforms &u [[buffer(1)]]) {
        float2 grid = abs(fract(in.worldPos.xz / 120.0) - 0.5);
        float line = smoothstep(0.0, 0.03, min(grid.x, grid.y));
        float3 color = mix(float3(0.35, 0.55, 0.85), float3(0.25, 0.42, 0.70), line);
        return float4(color, 0.18);
    }

    struct GuideVertexIn {
        float3 position;
        float4 color;
    };

    struct GuideVertexOut {
        float4 position [[position]];
        float4 color;
    };

    vertex GuideVertexOut guideVertex(uint vertexID [[vertex_id]],
                                      constant GuideVertexIn *vertices [[buffer(0)]],
                                      constant SceneUniforms &u [[buffer(1)]]) {
        GuideVertexOut out;
        GuideVertexIn v = vertices[vertexID];
        out.position = u.projection * u.view * float4(v.position, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 guideFragment(GuideVertexOut in [[stage_in]]) {
        return in.color;
    }

    struct ShadowVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex ShadowVertexOut shadowVertex(VertexIn in [[stage_in]],
                                        constant SceneUniforms &u [[buffer(1)]]) {
        ShadowVertexOut out;
        float sq = u.squash;
        float shadowScaleX = 1.0 + sq * 0.4;
        float shadowScaleY = 1.0 - sq * 0.2;
        float3 p = float3(in.position.x * shadowScaleX,
                          0.0,
                          in.position.y * shadowScaleY);
        float4 worldPos = u.model * float4(p, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.uv = in.texCoord;
        return out;
    }

    fragment float4 shadowFragment(ShadowVertexOut in [[stage_in]],
                                   constant SceneUniforms &u [[buffer(1)]]) {
        float2 c = in.uv - 0.5;
        float dist = length(c) * 2.0;
        float alpha = smoothstep(1.0, 0.2, dist) * 0.30;
        return float4(0, 0, 0, alpha);
    }
    """
}

// MARK: - C-compatible uniform struct

private struct GuideVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct TankMapping {
    var pointsToWorld: Float
    var height: Float
    var minX: Float
    var maxX: Float
    var minZ: Float
    var maxZ: Float
}

/// Must be ≤ 256 bytes and aligned to 256 for Metal buffer requirements.
/// We use MemoryLayout<SceneUniforms>.stride for buffer sizes (padded by Swift).
struct SceneUniforms {
    var projection: float4x4 = .init(1)
    var view:       float4x4 = .init(1)
    var model:      float4x4 = .init(1)
    var lightPos:   SIMD3<Float> = .zero
    var _pad0:      Float = 0
    var viewPos:    SIMD3<Float> = .zero
    var _pad1:      Float = 0
    var squash:     Float = 0
    var ballRadius: Float = 30
    var _pad2: SIMD2<Float> = .zero   // align to 16 bytes
}

// MARK: - float4x4 helpers

extension float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }

    init(scale s: SIMD3<Float>) {
        self = .init(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
    }

    init(rotationX angle: Float) {
        let c = cos(angle), s = sin(angle)
        self = .init(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    init(rotationY angle: Float) {
        let c = cos(angle), s = sin(angle)
        self = .init(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    init(perspective fovY: Float, aspect: Float, near: Float, far: Float) {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        self = .init(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = normalize(eye - target)   // camera forward (toward scene)
        let x = normalize(cross(up, z))   // camera right
        let y = cross(z, x)               // camera up
        return .init(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }
}
