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
    private var ballMesh: MTKMesh
    private var ballLocalTransform = matrix_identity_float4x4
    private let groundMesh: MTKMesh
    private let shadowMesh: MTKMesh   // flat disc for shadow
    private let ballVertexDescriptor: MTLVertexDescriptor
    private var currentBallModelKind: BallModelKind = .fifa2026

    // Texture
    private let sampler: MTLSamplerState
    private let footballFallbackTexture: MTLTexture
    private let classicSoccerTexture: MTLTexture
    private let basketballFallbackTexture: MTLTexture
    private let defaultNormalTexture: MTLTexture
    private let defaultMetallicTexture: MTLTexture
    private let defaultRoughnessTexture: MTLTexture
    private var baseColorTexture: MTLTexture!
    private var normalTexture: MTLTexture!
    private var metallicTexture: MTLTexture!
    private var roughnessTexture: MTLTexture!


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

        let ballVD = Self.makeVertexDescriptor(includeTangent: true)
        let simpleVD = Self.makeVertexDescriptor(includeTangent: false)
        self.ballVertexDescriptor = ballVD

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

        // Ground pipeline — no tangent data needed.
        let groundPD = MTLRenderPipelineDescriptor()
        groundPD.vertexFunction   = library.makeFunction(name: "groundVertex")
        groundPD.fragmentFunction = library.makeFunction(name: "groundFragment")
        groundPD.vertexDescriptor = simpleVD
        groundPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        groundPD.colorAttachments[0].isBlendingEnabled = true
        groundPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        groundPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        groundPD.depthAttachmentPixelFormat = .depth32Float

        guard let gp = try? device.makeRenderPipelineState(descriptor: groundPD) else { return nil }
        self.groundPipeline = gp

        // Shadow pipeline — no tangent data needed.
        let shadowPD = MTLRenderPipelineDescriptor()
        shadowPD.vertexFunction   = library.makeFunction(name: "shadowVertex")
        shadowPD.fragmentFunction = library.makeFunction(name: "shadowFragment")
        shadowPD.vertexDescriptor = simpleVD
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

        let ballMTKVD = Self.makeModelIOVertexDescriptor(from: ballVD, includeTangent: true)
        let simpleMTKVD = Self.makeModelIOVertexDescriptor(from: simpleVD, includeTangent: false)

        // ── Texture ───────────────────────────────────────────────────────────

        let proceduralTexture = Self.makeFootballTexture(device: device)
        let classicTexture = Self.makeClassicSoccerTexture(device: device)
        let basketballTexture = Self.makeBasketballTexture(device: device)
        guard let defaultNormal = Self.makeSolidTexture(device: device, rgba: [128, 128, 255, 255]),
              let defaultMetallic = Self.makeSolidTexture(device: device, rgba: [0, 0, 0, 255]),
              let defaultRoughness = Self.makeSolidTexture(device: device, rgba: [180, 180, 180, 255])
        else { return nil }
        footballFallbackTexture = proceduralTexture
        classicSoccerTexture = classicTexture
        basketballFallbackTexture = basketballTexture
        defaultNormalTexture = defaultNormal
        defaultMetallicTexture = defaultMetallic
        defaultRoughnessTexture = defaultRoughness
        baseColorTexture = proceduralTexture
        normalTexture = defaultNormal
        metallicTexture = defaultMetallic
        roughnessTexture = defaultRoughness

        // 先尝试加载 USDZ 模型
        if let usdzModel = BallModel.loadUSDZ(kind: .fifa2026,
                                              device: device,
                                              vertexDescriptor: ballVD) {
            self.ballMesh = usdzModel.mesh
            self.ballLocalTransform = usdzModel.normalizationTransform
            self.baseColorTexture = usdzModel.material.baseColor ?? proceduralTexture
            self.normalTexture = usdzModel.material.normal ?? defaultNormal
            self.metallicTexture = usdzModel.material.metallic ?? defaultMetallic
            self.roughnessTexture = usdzModel.material.roughness ?? defaultRoughness
            print("✅ 使用 USDZ Trionda 模型")
        } else {
            // Fallback: 使用程序化 sphere
            guard let ballMesh = Self.makeFallbackBallMesh(device: device,
                                                           modelIOVertexDescriptor: ballMTKVD) else { return nil }
            self.ballMesh = ballMesh
            print("⚠️ USDZ 加载失败，使用程序化 sphere")
        }
        let groundAsset = MDLMesh(planeWithExtent: vector_float3(4000, 1, 4000),
                                   segments: vector_uint2(2, 2),
                                   geometryType: MDLGeometryType.triangles,
                                   allocator: MTKMeshBufferAllocator(device: device))
        groundAsset.vertexDescriptor = simpleMTKVD
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
        shadowAsset.vertexDescriptor = simpleMTKVD
        guard let shadowMesh = try? MTKMesh(mesh: shadowAsset, device: device) else { return nil }
        self.shadowMesh = shadowMesh

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sampler
    }

    func setBallModel(_ kind: BallModelKind) {
        guard kind != currentBallModelKind else { return }

        if kind.isProcedural {
            let modelIOVD = Self.makeModelIOVertexDescriptor(from: ballVertexDescriptor,
                                                             includeTangent: true)
            guard let fallbackMesh = Self.makeFallbackBallMesh(device: device,
                                                               modelIOVertexDescriptor: modelIOVD) else {
                print("⚠️ 切换球模型失败，保留当前模型：\(kind.menuTitle)")
                return
            }
            ballMesh = fallbackMesh
            ballLocalTransform = matrix_identity_float4x4
            applyMaterial(PBRMaterial(), fallbackBaseColor: fallbackBaseTexture(for: kind))
            currentBallModelKind = kind
            print("✅ 切换球模型：\(kind.menuTitle)（程序化球面）")
            return
        }

        if let model = BallModel.loadUSDZ(kind: kind,
                                          device: device,
                                          vertexDescriptor: ballVertexDescriptor) {
            ballMesh = model.mesh
            ballLocalTransform = model.normalizationTransform
            applyMaterial(model.material, fallbackBaseColor: fallbackBaseTexture(for: kind))
            currentBallModelKind = kind
            print("✅ 切换球模型：\(kind.menuTitle)")
            return
        }

        let modelIOVD = Self.makeModelIOVertexDescriptor(from: ballVertexDescriptor,
                                                         includeTangent: true)
        guard let fallbackMesh = Self.makeFallbackBallMesh(device: device,
                                                           modelIOVertexDescriptor: modelIOVD) else {
            print("⚠️ 切换球模型失败，保留当前模型：\(kind.menuTitle)")
            return
        }
        ballMesh = fallbackMesh
        ballLocalTransform = matrix_identity_float4x4
        applyMaterial(PBRMaterial(), fallbackBaseColor: fallbackBaseTexture(for: kind))
        currentBallModelKind = kind
        print("⚠️ \(kind.menuTitle) USDZ 加载失败，使用程序化 sphere")
    }

    private func applyMaterial(_ material: PBRMaterial, fallbackBaseColor: MTLTexture) {
        baseColorTexture = material.baseColor ?? fallbackBaseColor
        normalTexture = material.normal ?? defaultNormalTexture
        metallicTexture = material.metallic ?? defaultMetallicTexture
        roughnessTexture = material.roughness ?? defaultRoughnessTexture
    }

    private func fallbackBaseTexture(for kind: BallModelKind) -> MTLTexture {
        switch kind {
        case .classicSoccer:
            return classicSoccerTexture
        case .basketball:
            return basketballFallbackTexture
        case .fifa2026, .football:
            return footballFallbackTexture
        }
    }

    /// Render one frame into the provided drawable + depth texture.
    func draw(in drawable: CAMetalDrawable,
              depthTexture: MTLTexture,
              ballState: BallState,
              config: PhysicsConfig,
              bounds: Bounds,
              viewport: CGRect,
              renderEffects: BallRenderEffects,
              showsGuideLines: Bool) {

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
        let pointsToWorld = tankPointsToWorld(viewport: viewport)
        let scale = max(8, Float(config.radius) * pointsToWorld)
        let visualScale: Float = 1.0
        let visualRadius = scale * visualScale
        let mapping = tankMapping(bounds: bounds,
                                  viewport: viewport,
                                  pointsToWorld: pointsToWorld,
                                  visualRadius: visualRadius)
        uniforms.projection = camera.projectionMatrix(aspect: aspect, frontHeight: mapping.height)
        uniforms.view = camera.viewMatrix(frontHeight: mapping.height)

        let worldBall = renderEffects.overrideWorldPosition
            ?? screenToTankWorld(ballState.center, mapping: mapping)
        uniforms.model = float4x4(translation: worldBall)
            * float4x4(rotationY: Float(renderEffects.rotationY))
            * float4x4(rotationX: Float(renderEffects.rotationX))
            * float4x4(rotationZ: Float(ballState.angle + renderEffects.rotationZ))
            * float4x4(scale: SIMD3<Float>(visualRadius, visualRadius, visualRadius))
        uniforms.localModel = ballLocalTransform
        uniforms.squash = 0
        uniforms.ballRadius = visualRadius
        let sunDirection = simd_normalize(SIMD3<Float>(-0.55, 0.70, 0.45))
        uniforms.lightPos = sunDirection
        uniforms.viewPos = camera.eye(frontHeight: mapping.height)

        // The desktop is the visible ground; draw only local helper lines so the
        // 3D relation is readable without tinting the whole screen.
        if showsGuideLines {
            drawGuideLines(encoder: encoder, center: worldBall, radius: visualRadius, mapping: mapping)
        }

        // Optional rope for the Hanging Charm mode. Drawn before the ball so
        // the ball's depth occludes the rope endpoint.
        if let ropeAnchor = renderEffects.ropeAnchor {
            drawRope(encoder: encoder, from: ropeAnchor, to: worldBall)
        }

        // ── Shadow discs ──────────────────────────────────────────────────────
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: true))
        let svBuf = shadowMesh.vertexBuffers[0]
        encoder.setVertexBuffer(svBuf.buffer, offset: svBuf.offset, index: 0)

        func drawShadow(_ shadowUniforms: inout SceneUniforms) {
            encoder.setVertexBytes(&shadowUniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&shadowUniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
            for sub in shadowMesh.submeshes {
                encoder.drawIndexedPrimitives(type: sub.primitiveType,
                                              indexCount: sub.indexCount,
                                              indexType: sub.indexType,
                                              indexBuffer: sub.indexBuffer.buffer,
                                              indexBufferOffset: sub.indexBuffer.offset)
            }
        }

        var wallShadowUniforms = uniforms
        wallShadowUniforms.squash = 1
        let wallShadowScale = visualRadius * 1.16
        let wallShadowOffset = SIMD3<Float>(
            -sunDirection.x * visualRadius * 0.58,
            -sunDirection.y * visualRadius * 0.46,
            -visualRadius * 0.82
        )
        wallShadowUniforms.model = float4x4(translation: worldBall + wallShadowOffset)
            * float4x4(scale: SIMD3<Float>(wallShadowScale * 1.04, wallShadowScale * 0.96, 1))
        drawShadow(&wallShadowUniforms)

        var contactShadowUniforms = uniforms
        contactShadowUniforms.squash = 0
        let contactShadowScale = visualRadius * 0.82
        contactShadowUniforms.model = float4x4(translation: SIMD3<Float>(worldBall.x, mapping.floorY + 0.5, worldBall.z))
            * float4x4(scale: SIMD3<Float>(contactShadowScale, contactShadowScale, contactShadowScale))
        drawShadow(&contactShadowUniforms)

        // ── Ball ──────────────────────────────────────────────────────────────
        encoder.setRenderPipelineState(ballPipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: false))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)

        encoder.setFragmentTexture(baseColorTexture, index: 0)
        encoder.setFragmentTexture(normalTexture, index: 1)
        encoder.setFragmentTexture(metallicTexture, index: 2)
        encoder.setFragmentTexture(roughnessTexture, index: 3)
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

    private func tankPointsToWorld(viewport: CGRect) -> Float {
        let tankHeight: Float = 620
        return tankHeight / max(Float(viewport.height), 1)
    }

    private func tankMapping(
        bounds: Bounds,
        viewport: CGRect,
        pointsToWorld: Float,
        visualRadius: Float
    ) -> TankMapping {
        let tankHeight: Float = 620
        let halfWidth = Float(viewport.width) * pointsToWorld * 0.5
        let floorY = Float(bounds.rect.minY - viewport.minY) * pointsToWorld
        let halfDepth = max(visualRadius * 3, 120)
        return TankMapping(pointsToWorld: pointsToWorld,
                           height: tankHeight,
                           minX: -halfWidth,
                           maxX: halfWidth,
                           minZ: -halfDepth,
                           maxZ: halfDepth,
                           floorY: floorY,
                           screenMidX: Float(viewport.midX),
                           screenMinY: Float(viewport.minY))
    }

    private func screenToTankWorld(_ screen: CGPoint,
                                   mapping: TankMapping) -> SIMD3<Float> {
        let x = (Float(screen.x) - mapping.screenMidX) * mapping.pointsToWorld
        let y = (Float(screen.y) - mapping.screenMinY) * mapping.pointsToWorld
        return SIMD3<Float>(x, y, 0)
    }

    private func drawGuideLines(encoder: MTLRenderCommandEncoder,
                                center: SIMD3<Float>,
                                radius: Float,
                                mapping: TankMapping) {
        var vertices: [GuideVertex] = []
        let floorY = mapping.floorY + 0.75
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

    /// Draws a thin semi-transparent line from `from` to `to` in world space.
    /// Reuses `guidePipeline` and its `GuideVertex` layout. Drawn with the
    /// depth state set read-only so the rope never occludes the ball itself.
    private func drawRope(encoder: MTLRenderCommandEncoder,
                          from: SIMD3<Float>,
                          to: SIMD3<Float>) {
        // Two segments of slightly different colour: a brighter "core" and a
        // fainter "halo" beneath, so the rope reads against both light and
        // dark backgrounds without picking a fixed colour.
        let core = SIMD4<Float>(0.82, 0.86, 0.92, 0.55)
        let halo = SIMD4<Float>(0.65, 0.72, 0.85, 0.22)
        let vertices: [GuideVertex] = [
            GuideVertex(position: from, color: halo),
            GuideVertex(position: to,   color: halo),
            GuideVertex(position: from, color: core),
            GuideVertex(position: to,   color: core),
        ]
        encoder.setRenderPipelineState(guidePipeline)
        encoder.setDepthStencilState(makeDepthState(device, readOnly: true))
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setVertexBytes(base, length: bytes.count, index: 0)
            }
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        // Halo first, then core on top.
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2)
        encoder.drawPrimitives(type: .line, vertexStart: 2, vertexCount: 2)
    }

    // MARK: - Mesh layout

    private static func makeFallbackBallMesh(
        device: MTLDevice,
        modelIOVertexDescriptor: MDLVertexDescriptor
    ) -> MTKMesh? {
        let ballAsset = MDLMesh(sphereWithExtent: vector_float3(2, 2, 2),
                                segments: vector_uint2(48, 48),
                                inwardNormals: false,
                                geometryType: MDLGeometryType.triangles,
                                allocator: MTKMeshBufferAllocator(device: device))
        ballAsset.vertexDescriptor = modelIOVertexDescriptor
        BallModel.ensureTangents(mesh: ballAsset)
        return try? MTKMesh(mesh: ballAsset, device: device)
    }

    private static func makeVertexDescriptor(includeTangent: Bool) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = 12
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = 24
        descriptor.attributes[2].bufferIndex = 0
        if includeTangent {
            descriptor.attributes[3].format = .float3
            descriptor.attributes[3].offset = 32
            descriptor.attributes[3].bufferIndex = 0
        }
        descriptor.layouts[0].stride = includeTangent ? 44 : 32
        return descriptor
    }

    private static func makeModelIOVertexDescriptor(
        from descriptor: MTLVertexDescriptor,
        includeTangent: Bool
    ) -> MDLVertexDescriptor {
        let modelIODescriptor = MTKModelIOVertexDescriptorFromMetal(descriptor)
        (modelIODescriptor.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (modelIODescriptor.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (modelIODescriptor.attributes[2] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        if includeTangent {
            (modelIODescriptor.attributes[3] as! MDLVertexAttribute).name = MDLVertexAttributeTangent
        }
        return modelIODescriptor
    }

    // MARK: - Procedural texture

    private static func makeSolidTexture(device: MTLDevice, rgba: [UInt8]) -> MTLTexture? {
        guard rgba.count == 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixel = rgba
        pixel.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                      size: MTLSize(width: 1, height: 1, depth: 1)),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: 4
                )
            }
        }
        return texture
    }

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
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                           width: size, height: size,
                                                           mipmapped: false)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else {
            return Self.fallbackTexture(device: device)
        }
        // CGContext writes RGBA; Metal BGRA expects BGRA, so swap R/B.
        for i in 0..<(size * size) {
            let base = i * 4
            data.swapAt(base, base + 2)  // swap R and B
        }
        tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: size, height: size, depth: 1)),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func makeBasketballTexture(device: MTLDevice) -> MTLTexture {
        let size = 1024
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
        ctx.setFillColor(CGColor(red: 0.93, green: 0.42, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        for i in stride(from: 0, through: Int(s), by: 9) {
            let y = CGFloat(i)
            let alpha = 0.035 + 0.025 * abs(sin(CGFloat(i) * 0.31))
            ctx.setStrokeColor(CGColor(red: 0.22, green: 0.09, blue: 0.025, alpha: alpha))
            ctx.setLineWidth(s * 0.0011)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addCurve(to: CGPoint(x: s, y: y + sin(y * 0.018) * s * 0.004),
                          control1: CGPoint(x: s * 0.28, y: y + s * 0.012),
                          control2: CGPoint(x: s * 0.72, y: y - s * 0.012))
            ctx.addPath(path)
            ctx.strokePath()
        }

        func strokeSeam(_ path: CGPath, width: CGFloat = 0.028) {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(CGColor(red: 0.05, green: 0.026, blue: 0.012, alpha: 0.92))
            ctx.setLineWidth(s * width)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.74, blue: 0.35, alpha: 0.20))
            ctx.setLineWidth(s * width * 0.24)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        let horizontal = CGMutablePath()
        horizontal.move(to: CGPoint(x: -s * 0.02, y: s * 0.50))
        horizontal.addCurve(to: CGPoint(x: s * 1.02, y: s * 0.50),
                            control1: CGPoint(x: s * 0.28, y: s * 0.43),
                            control2: CGPoint(x: s * 0.72, y: s * 0.57))
        strokeSeam(horizontal)

        let vertical = CGMutablePath()
        vertical.move(to: CGPoint(x: s * 0.50, y: -s * 0.02))
        vertical.addCurve(to: CGPoint(x: s * 0.50, y: s * 1.02),
                          control1: CGPoint(x: s * 0.43, y: s * 0.28),
                          control2: CGPoint(x: s * 0.57, y: s * 0.72))
        strokeSeam(vertical)

        for x in [s * 0.19, s * 0.81] {
            let curve = CGMutablePath()
            curve.move(to: CGPoint(x: x, y: -s * 0.05))
            curve.addCurve(to: CGPoint(x: x, y: s * 1.05),
                           control1: CGPoint(x: s * 0.50, y: s * 0.22),
                           control2: CGPoint(x: s * 0.50, y: s * 0.78))
            strokeSeam(curve, width: 0.024)
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                           width: size, height: size,
                                                           mipmapped: false)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else {
            return Self.fallbackTexture(device: device)
        }
        for i in 0..<(size * size) {
            let base = i * 4
            data.swapAt(base, base + 2)
        }
        tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: size, height: size, depth: 1)),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func makeClassicSoccerTexture(device: MTLDevice) -> MTLTexture {
        let size = 1024
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
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        ctx.setFillColor(CGColor(red: 0.94, green: 0.935, blue: 0.895, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        Self.drawSoccerLeatherGrain(ctx, size: s)
        Self.drawClassicSoccerPanels(ctx, size: s)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                           width: size, height: size,
                                                           mipmapped: false)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else {
            return Self.fallbackTexture(device: device)
        }
        for i in 0..<(size * size) {
            let base = i * 4
            data.swapAt(base, base + 2)
        }
        tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: size, height: size, depth: 1)),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func drawSoccerLeatherGrain(_ ctx: CGContext, size s: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(s * 0.0009)
        for i in stride(from: 0, through: Int(s), by: 13) {
            let y = CGFloat(i)
            let alpha = 0.018 + 0.014 * abs(sin(CGFloat(i) * 0.27))
            ctx.setStrokeColor(CGColor(red: 0.20, green: 0.20, blue: 0.18, alpha: alpha))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addCurve(to: CGPoint(x: s, y: y + sin(y * 0.025) * s * 0.004),
                          control1: CGPoint(x: s * 0.25, y: y + s * 0.006),
                          control2: CGPoint(x: s * 0.72, y: y - s * 0.006))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawClassicSoccerPanels(_ ctx: CGContext, size s: CGFloat) {
        let black = CGColor(red: 0.025, green: 0.026, blue: 0.028, alpha: 1)
        let seam = CGColor(red: 0.24, green: 0.23, blue: 0.20, alpha: 0.54)
        let seamLight = CGColor(red: 1.0, green: 0.985, blue: 0.90, alpha: 0.64)
        let whitePanel = CGColor(red: 0.965, green: 0.955, blue: 0.91, alpha: 1)
        let shadowStroke = CGColor(red: 0.08, green: 0.08, blue: 0.075, alpha: 0.20)

        func drawMotif(center: CGPoint, scale: CGFloat, rotation: CGFloat) {
            let pentagonRadius = scale * 0.235
            let hexRadius = scale * 0.225
            let hexDistance = scale * 0.405

            for i in 0..<5 {
                let a = rotation - .pi / 2 + CGFloat(i) * 2 * .pi / 5
                let c = CGPoint(x: center.x + cos(a) * hexDistance,
                                y: center.y + sin(a) * hexDistance)
                Self.drawPolygon(ctx,
                                 center: c,
                                 radius: hexRadius,
                                 sides: 6,
                                 angle: a + .pi / 6,
                                 fill: whitePanel,
                                 stroke: seam,
                                 lineWidth: scale * 0.030)
                Self.drawPolygon(ctx,
                                 center: c,
                                 radius: hexRadius * 0.96,
                                 sides: 6,
                                 angle: a + .pi / 6,
                                 fill: nil,
                                 stroke: seamLight,
                                 lineWidth: scale * 0.008)
            }

            for i in 0..<5 {
                let a = rotation - .pi / 2 + CGFloat(i) * 2 * .pi / 5
                let path = CGMutablePath()
                path.move(to: CGPoint(x: center.x + cos(a) * pentagonRadius * 0.92,
                                      y: center.y + sin(a) * pentagonRadius * 0.92))
                path.addLine(to: CGPoint(x: center.x + cos(a) * hexDistance * 0.72,
                                         y: center.y + sin(a) * hexDistance * 0.72))
                ctx.setStrokeColor(seam)
                ctx.setLineWidth(scale * 0.020)
                ctx.addPath(path)
                ctx.strokePath()
            }

            Self.drawPolygon(ctx,
                             center: center,
                             radius: pentagonRadius,
                             sides: 5,
                             angle: rotation - .pi / 2,
                             fill: black,
                             stroke: seam,
                             lineWidth: scale * 0.032)
            Self.drawPolygon(ctx,
                             center: center,
                             radius: pentagonRadius * 0.92,
                             sides: 5,
                             angle: rotation - .pi / 2,
                             fill: nil,
                             stroke: CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
                             lineWidth: scale * 0.010)

            ctx.saveGState()
            ctx.setStrokeColor(shadowStroke)
            ctx.setLineWidth(scale * 0.006)
            for i in 0..<5 {
                let a = rotation - .pi / 2 + CGFloat(i) * 2 * .pi / 5 + .pi / 5
                let p0 = CGPoint(x: center.x + cos(a) * scale * 0.18,
                                 y: center.y + sin(a) * scale * 0.18)
                let p1 = CGPoint(x: center.x + cos(a) * scale * 0.56,
                                 y: center.y + sin(a) * scale * 0.56)
                let path = CGMutablePath()
                path.move(to: p0)
                path.addLine(to: p1)
                ctx.addPath(path)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (0.16, 0.19, 0.27),
            (0.34, 0.41, -0.08),
            (0.16, 0.63, 0.18),
            (0.34, 0.85, -0.20),
        ]
        let stepX = s / 3
        for row in rows {
            var x = row.0 * s - stepX
            while x < s * 1.34 {
                let scale = s * 0.30
                drawMotif(center: CGPoint(x: x, y: row.1 * s),
                          scale: scale,
                          rotation: row.2 + x * 0.002)
                x += stepX
            }
        }

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.36, green: 0.34, blue: 0.29, alpha: 0.16))
        ctx.setLineWidth(s * 0.003)
        for y in stride(from: s * 0.10, through: s * 0.92, by: s * 0.135) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -s * 0.04, y: y))
            path.addCurve(to: CGPoint(x: s * 1.04, y: y + s * 0.012),
                          control1: CGPoint(x: s * 0.30, y: y - s * 0.035),
                          control2: CGPoint(x: s * 0.68, y: y + s * 0.035))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawPolygon(_ ctx: CGContext,
                                    center: CGPoint,
                                    radius: CGFloat,
                                    sides: Int,
                                    angle: CGFloat,
                                    fill: CGColor?,
                                    stroke: CGColor?,
                                    lineWidth: CGFloat) {
        guard sides >= 3 else { return }
        let path = CGMutablePath()
        for i in 0..<sides {
            let a = angle + CGFloat(i) * 2 * .pi / CGFloat(sides)
            let p = CGPoint(x: center.x + cos(a) * radius,
                            y: center.y + sin(a) * radius)
            if i == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        path.closeSubpath()

        ctx.saveGState()
        if let fill {
            ctx.setFillColor(fill)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if let stroke, lineWidth > 0 {
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(lineWidth)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
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
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
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
        float4x4 localModel;
        float3   lightPos;
        float3   viewPos;
        float    squash;
        float    ballRadius;
    };

    struct BallVertexIn {
        float3 position  [[attribute(0)]];
        float3 normal    [[attribute(1)]];
        float2 texCoord  [[attribute(2)]];
        float3 tangent   [[attribute(3)]];
    };

    struct BallVertexOut {
        float4 position  [[position]];
        float3 worldPos;
        float3 worldNormal;
        float3 worldTangent;
        float2 uv;
    };

    struct SurfaceVertexIn {
        float3 position  [[attribute(0)]];
        float3 normal    [[attribute(1)]];
        float2 texCoord  [[attribute(2)]];
    };

    struct SurfaceVertexOut {
        float4 position  [[position]];
        float3 worldPos;
        float3 worldNormal;
        float2 uv;
    };

    vertex BallVertexOut ballVertex(BallVertexIn in [[stage_in]],
                                    constant SceneUniforms &u [[buffer(1)]]) {
        BallVertexOut out;
        float4 localPos4 = u.localModel * float4(in.position, 1.0);
        float3 localPosition = localPos4.xyz;
        float3 localNormal = normalize((u.localModel * float4(in.normal, 0.0)).xyz);
        float3 localTangent = normalize((u.localModel * float4(in.tangent, 0.0)).xyz);

        float3 p = localPosition;
        float3 n = localNormal;
        float3 t = localTangent;
        float4 worldPos = u.model * float4(p, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.worldPos = worldPos.xyz;
        out.worldNormal = normalize((u.model * float4(n, 0.0)).xyz);
        out.worldTangent = normalize((u.model * float4(t, 0.0)).xyz);
        out.uv = in.texCoord;
        return out;
    }

    float pbrDistributionGGX(float NdotH, float roughness) {
        float a = roughness * roughness;
        float a2 = a * a;
        float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
        return a2 / max(3.14159265 * denom * denom, 0.0001);
    }

    float pbrGeometrySchlickGGX(float NdotV, float roughness) {
        float r = roughness + 1.0;
        float k = (r * r) * 0.125;
        return NdotV / max(NdotV * (1.0 - k) + k, 0.0001);
    }

    float pbrGeometrySmith(float NdotV, float NdotL, float roughness) {
        return pbrGeometrySchlickGGX(NdotV, roughness) *
               pbrGeometrySchlickGGX(NdotL, roughness);
    }

    float3 pbrFresnelSchlick(float cosTheta, float3 F0) {
        return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
    }

    fragment float4 ballFragment(BallVertexOut in [[stage_in]],
                                 constant SceneUniforms &u [[buffer(1)]],
                                 texture2d<float> skinTexture [[texture(0)]],
                                 texture2d<float> normalTexture [[texture(1)]],
                                 texture2d<float> metallicTexture [[texture(2)]],
                                 texture2d<float> roughnessTexture [[texture(3)]],
                                 sampler texSampler [[sampler(0)]]) {
        float3 macroN = normalize(in.worldNormal);
        float3 fallbackT = normalize(cross(abs(macroN.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0), macroN));
        float3 rawT = in.worldTangent - macroN * dot(macroN, in.worldTangent);
        float tangentWeight = step(0.0001, length(rawT));
        float3 T = normalize(mix(fallbackT, rawT / max(length(rawT), 0.0001), tangentWeight));
        float3 B = normalize(cross(macroN, T));
        float3x3 TBN = float3x3(T, B, macroN);

        float3 normalSample = normalTexture.sample(texSampler, in.uv).xyz * 2.0 - 1.0;
        float3 detailN = normalize(TBN * normalSample);

        float3 albedo = skinTexture.sample(texSampler, in.uv).rgb;
        float luma = dot(albedo, float3(0.2126, 0.7152, 0.0722));
        float chroma = length(albedo - float3(luma));
        float colorMask = smoothstep(0.035, 0.16, chroma);
        float3 V = normalize(u.viewPos - in.worldPos);
        float macroFacing = max(dot(macroN, V), 0.0);
        float edgeCalm = smoothstep(0.06, 0.64, macroFacing);
        float saturation = mix(1.10, 1.62, colorMask) * mix(0.90, 1.0, edgeCalm);
        albedo = clamp(mix(float3(luma), albedo, saturation), 0.0, 1.0);
        albedo = clamp(albedo * mix(1.04, 1.16, colorMask), 0.0, 1.0);
        float metallic = clamp(metallicTexture.sample(texSampler, in.uv).r * 0.08, 0.0, 0.05);
        float roughness = clamp(roughnessTexture.sample(texSampler, in.uv).r, 0.35, 0.75);
        roughness = mix(max(roughness, 0.62), roughness, edgeCalm);

        // Bump is strongly dialled out at the silhouette so the texture cannot
        // break the sphere outline. The macro normal still drives the big light
        // envelope and the fallback clear-coat highlight.
        float bumpWeight = smoothstep(0.24, 0.78, macroFacing) * 0.48;
        float3 bumpN = normalize(mix(macroN, detailN, bumpWeight));
        float3 shadeN = bumpN;
        float3 specN = bumpN;
        float3 keyDir = normalize(u.lightPos);
        float3 fillDir = normalize(float3(0.55, 0.42, 0.75));
        float3 rimDir = normalize(float3(0.45, 0.25, -0.85));
        float3 H = normalize(keyDir + V);

        float NdotV = max(dot(specN, V), 0.03);
        float NdotL = max(dot(shadeN, keyDir), 0.0);
        float NdotH = max(dot(specN, H), 0.0);
        float VdotH = max(dot(V, H), 0.0);
        float fill = max(dot(shadeN, fillDir), 0.0);
        // rim / fresnel / hemi stay on macroN so the ball's overall light
        // envelope (silhouette glow, hemisphere ambient) reads as a clean
        // sphere instead of being chopped up by the bump.
        float macroKey = max(dot(macroN, keyDir), 0.0);
        float rimLight = max(dot(macroN, rimDir), 0.0);
        float wrapKey = NdotL * 0.72 + 0.28;

        float3 keyTint = float3(1.0, 0.91, 0.72);
        float3 fillTint = float3(0.74, 0.82, 1.0);
        float3 F0 = mix(float3(0.045), albedo, metallic);
        float D = pbrDistributionGGX(NdotH, roughness);
        float G = pbrGeometrySmith(NdotV, NdotL, roughness);
        float3 F = pbrFresnelSchlick(VdotH, F0);
        float3 specularBRDF = (D * G * F) / max(4.0 * NdotV * NdotL, 0.001);
        float3 kD = (1.0 - F) * (1.0 - metallic);

        float3 keyLight = (kD * albedo * (1.0 / 3.14159265) + specularBRDF) *
                          keyTint * 3.15 * NdotL;
        float3 fillLight = albedo * fillTint * (0.30 + 0.46 * fill);

        // The physically based F0 on a matte football can be too subtle at this
        // desktop size. Keep a macro-normal clear coat so the highlight remains
        // visible even when the normal map or roughness texture is noisy.
        float macroSpecDot = max(dot(macroN, H), 0.0);
        float clearCoat = pow(macroSpecDot, 42.0) * 0.58;
        float broadHotspot = smoothstep(0.56, 0.98, macroSpecDot) * 0.16;
        float coatVisibility = smoothstep(0.16, 0.58, macroFacing) * (0.58 + 0.42 * macroKey);
        float fresnel = pow(1.0 - macroFacing, 3.0);

        float hemi = clamp(macroN.y * 0.5 + 0.5, 0.0, 1.0);
        float3 ambientSky = float3(0.82, 0.88, 1.0);
        float3 ambientGround = float3(0.46, 0.40, 0.32);
        float3 ambient = albedo * mix(ambientGround, ambientSky, hemi) * 0.44;

        float lightEnvelope = mix(0.70, 1.0, smoothstep(-0.12, 0.78, dot(macroN, keyDir)));
        float viewEnvelope = mix(0.64, 1.0, smoothstep(0.04, 0.86, macroFacing));
        float3 rim = float3(0.78, 0.86, 1.0) * (0.035 * rimLight + 0.055 * fresnel) * lightEnvelope;
        float3 visibleLight = keyTint * (clearCoat + broadHotspot) * coatVisibility;
        float3 color = (ambient + keyLight + fillLight + albedo * 0.44 * wrapKey) *
                       lightEnvelope * viewEnvelope +
                       rim + visibleLight;

        float litLuma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = mix(float3(litLuma), color, mix(1.12, 1.24, colorMask));
        color = color / (color + float3(0.74));
        color = clamp(color * 1.18, 0.0, 1.0);
        color = pow(color, float3(1.0 / 2.2));

        return float4(color, 1.0);
    }

    vertex SurfaceVertexOut groundVertex(SurfaceVertexIn in [[stage_in]],
                                         constant SceneUniforms &u [[buffer(1)]]) {
        SurfaceVertexOut out;
        float4 worldPos = u.model * float4(in.position, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.worldPos = worldPos.xyz;
        out.worldNormal = normalize((u.model * float4(in.normal, 0.0)).xyz);
        out.uv = in.texCoord;
        return out;
    }

    fragment float4 groundFragment(SurfaceVertexOut in [[stage_in]],
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

    vertex ShadowVertexOut shadowVertex(SurfaceVertexIn in [[stage_in]],
                                        constant SceneUniforms &u [[buffer(1)]]) {
        ShadowVertexOut out;
        float3 p = u.squash > 0.5
            ? float3(in.position.x, in.position.y, 0.0)
            : float3(in.position.x, 0.0, in.position.y);
        float4 worldPos = u.model * float4(p, 1.0);
        out.position = u.projection * u.view * worldPos;
        out.uv = in.texCoord;
        return out;
    }

    fragment float4 shadowFragment(ShadowVertexOut in [[stage_in]],
                                   constant SceneUniforms &u [[buffer(1)]]) {
        float2 c = in.uv - 0.5;
        float dist = length(c) * 2.0;
        if (u.squash > 0.5) {
            float wallBody = smoothstep(1.0, 0.10, dist) * 0.18;
            float wallCore = smoothstep(0.56, 0.0, dist) * 0.08;
            return float4(0, 0, 0, wallBody + wallCore);
        }
        float softBody = smoothstep(1.0, 0.18, dist) * 0.26;
        float contactCore = smoothstep(0.42, 0.0, dist) * 0.18;
        float alpha = softBody + contactCore;
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
    var floorY: Float
    var screenMidX: Float
    var screenMinY: Float
}

/// Keep this trivially copyable; `setVertexBytes` / `setFragmentBytes` copy the
/// exact Swift stride into Metal's transient constant buffer each frame.
struct SceneUniforms {
    var projection: float4x4 = .init(1)
    var view:       float4x4 = .init(1)
    var model:      float4x4 = .init(1)
    var localModel: float4x4 = .init(1)
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

    init(rotationZ angle: Float) {
        let c = cos(angle), s = sin(angle)
        self = .init(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
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
