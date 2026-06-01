import Metal
import MetalKit
import ModelIO
import simd
import Foundation

enum BallModelKind: Int, CaseIterable {
    case fifa2026
    case classicSoccer
    case basketball
    case football

    var menuTitle: String {
        switch self {
        case .fifa2026: return "2026 FIFA Football"
        case .classicSoccer: return "Classic Soccer Ball"
        case .basketball: return "Basketball"
        case .football: return "Football"
        }
    }

    var resourceName: String {
        switch self {
        case .fifa2026: return "fifa_trionda_ball_world_cup_2026"
        case .classicSoccer: return "ClassicSoccer"
        case .basketball: return "Basketball"
        case .football: return "Football"
        }
    }

    var isProcedural: Bool {
        self == .classicSoccer
    }

    var usesTriondaExternalTextures: Bool {
        self == .fifa2026
    }

    var resourceSearchSubdirectories: [String?] {
        switch self {
        case .fifa2026:
            return [
                nil,
                "TriondaBall",
                "TriondaBall/0",
                "Resources/TriondaBall",
                "Resources/TriondaBall/0",
            ]
        case .classicSoccer:
            return [nil]
        case .basketball, .football:
            return [
                nil,
                "BallModels",
                "Resources/BallModels",
            ]
        }
    }
}

/// PBR 材质结构
struct PBRMaterial {
    var baseColor: MTLTexture? = nil
    var normal: MTLTexture? = nil
    var metallic: MTLTexture? = nil
    var roughness: MTLTexture? = nil
}

/// 足球模型封装
final class BallModel {
    let mesh: MTKMesh
    let material: PBRMaterial
    let normalizationTransform: float4x4
    let originalRadius: Float

    init(mesh: MTKMesh, material: PBRMaterial, normalizationTransform: float4x4, originalRadius: Float) {
        self.mesh = mesh
        self.material = material
        self.normalizationTransform = normalizationTransform
        self.originalRadius = originalRadius
    }

    /// 从 SPM Bundle 加载 USDZ 模型
    static func loadUSDZ(kind: BallModelKind,
                         device: MTLDevice,
                         vertexDescriptor: MTLVertexDescriptor) -> BallModel? {
        guard let url = bundleResourceURL(forResource: kind.resourceName,
                                          withExtension: "usdz",
                                          subdirectories: kind.resourceSearchSubdirectories) else {
            print("BallModel: \(kind.menuTitle) USDZ not found in bundle")
            return nil
        }

        let bufferAllocator = MTKMeshBufferAllocator(device: device)

        // 构建 ModelIO 顶点描述符，匹配 Metal vertex descriptor
        let modelIOVD = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        if modelIOVD.attributes.count > 0,
           let a0 = modelIOVD.attributes[0] as? MDLVertexAttribute {
            a0.name = MDLVertexAttributePosition
        }
        if modelIOVD.attributes.count > 1,
           let a1 = modelIOVD.attributes[1] as? MDLVertexAttribute {
            a1.name = MDLVertexAttributeNormal
        }
        if modelIOVD.attributes.count > 2,
           let a2 = modelIOVD.attributes[2] as? MDLVertexAttribute {
            a2.name = MDLVertexAttributeTextureCoordinate
        }
        if modelIOVD.attributes.count > 3,
           let a3 = modelIOVD.attributes[3] as? MDLVertexAttribute {
            a3.name = MDLVertexAttributeTangent
        }

        let asset = MDLAsset(url: url,
                             vertexDescriptor: modelIOVD,
                             bufferAllocator: bufferAllocator)

        // 提取第一个网格（递归搜索）
        guard let mesh = findFirstMeshInAsset(asset) else {
            print("BallModel: no mesh found in USDZ")
            return nil
        }

        // 计算原始半径
        let bounds = mesh.boundingBox
        let dx = bounds.maxBounds.x - bounds.minBounds.x
        let dy = bounds.maxBounds.y - bounds.minBounds.y
        let dz = bounds.maxBounds.z - bounds.minBounds.z
        let originalRadius = max(dx, max(dy, dz)) / 2.0
        guard dx > .leastNonzeroMagnitude,
              dy > .leastNonzeroMagnitude,
              dz > .leastNonzeroMagnitude,
              originalRadius > .leastNonzeroMagnitude else {
            print("BallModel: invalid mesh bounds")
            return nil
        }
        let center = SIMD3<Float>(
            (bounds.minBounds.x + bounds.maxBounds.x) * 0.5,
            (bounds.minBounds.y + bounds.maxBounds.y) * 0.5,
            (bounds.minBounds.z + bounds.maxBounds.z) * 0.5
        )
        print("BallModel: original size = \(dx), \(dy), \(dz)")

        // 生成切线
        ensureTangents(mesh: mesh)

        // 转换为 MTKMesh
        guard let mtkMesh = try? MTKMesh(mesh: mesh, device: device) else {
            print("BallModel: failed to convert to MTKMesh")
            return nil
        }

        let material = kind.usesTriondaExternalTextures
            ? loadTriondaExternalTextures(device: device)
            : loadMaterialTextures(from: mesh, device: device, assetURL: url)

        print("BallModel: loaded \(kind.menuTitle) (\(mtkMesh.submeshes.count) submeshes)")
        let normalizationTransform = float4x4(scale: SIMD3<Float>(repeating: 1.0 / originalRadius))
            * float4x4(translation: -center)
        return BallModel(
            mesh: mtkMesh,
            material: material,
            normalizationTransform: normalizationTransform,
            originalRadius: originalRadius
        )
    }

    // MARK: - Mesh 查找

    private static func findFirstMeshInAsset(_ asset: MDLAsset) -> MDLMesh? {
        for index in 0..<asset.count {
            let object = asset.object(at: index)
            if let found = findMeshRecursive(object) { return found }
        }
        return nil
    }

    private static func findMeshRecursive(_ object: MDLObject) -> MDLMesh? {
        if let mesh = object as? MDLMesh { return mesh }
        let childCount = object.children.count
        for i in 0..<childCount {
            let child = object.children[i]
            if let found = findMeshRecursive(child) { return found }
        }
        return nil
    }

    // MARK: - Tangent

    static func ensureTangents(mesh: MDLMesh) {
        if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTangent, as: .float3) != nil {
            print("BallModel: tangents already present")
            return
        }
        mesh.addTangentBasis(
            forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
            tangentAttributeNamed: MDLVertexAttributeTangent,
            bitangentAttributeNamed: nil
        )
        print("BallModel: generated tangents")
    }

    // MARK: - PBR Textures

    private static func loadTriondaExternalTextures(device: MTLDevice) -> PBRMaterial {
        let loader = MTKTextureLoader(device: device)
        let colorOptions: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.bottomLeft,
            .SRGB: true
        ]
        let dataOptions: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.bottomLeft,
            .SRGB: false
        ]

        return PBRMaterial(
            baseColor: loadBundledTexture(named: "basic_fx_baseColor", loader: loader, options: colorOptions),
            normal: loadBundledTexture(named: "basic_fx_normal", loader: loader, options: dataOptions),
            metallic: loadBundledTexture(named: "basic_fx_metallicRoughness_metal", loader: loader, options: dataOptions),
            roughness: loadBundledTexture(named: "basic_fx_metallicRoughness_rough", loader: loader, options: dataOptions)
        )
    }

    private static func loadMaterialTextures(from mesh: MDLMesh,
                                             device: MTLDevice,
                                             assetURL: URL) -> PBRMaterial {
        let loader = MTKTextureLoader(device: device)
        let colorOptions: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.bottomLeft,
            .SRGB: true
        ]
        let dataOptions: [MTKTextureLoader.Option: Any] = [
            .origin: MTKTextureLoader.Origin.bottomLeft,
            .SRGB: false
        ]

        return PBRMaterial(
            baseColor: firstMaterialTexture(from: mesh,
                                            semantics: [.baseColor],
                                            loader: loader,
                                            options: colorOptions,
                                            assetURL: assetURL),
            normal: firstMaterialTexture(from: mesh,
                                         semantics: [.tangentSpaceNormal, .objectSpaceNormal, .bump],
                                         loader: loader,
                                         options: dataOptions,
                                         assetURL: assetURL),
            metallic: firstMaterialTexture(from: mesh,
                                           semantics: [.metallic],
                                           loader: loader,
                                           options: dataOptions,
                                           assetURL: assetURL),
            roughness: firstMaterialTexture(from: mesh,
                                            semantics: [.roughness],
                                            loader: loader,
                                            options: dataOptions,
                                            assetURL: assetURL)
        )
    }

    private static func firstMaterialTexture(
        from mesh: MDLMesh,
        semantics: [MDLMaterialSemantic],
        loader: MTKTextureLoader,
        options: [MTKTextureLoader.Option: Any],
        assetURL: URL
    ) -> MTLTexture? {
        guard let submeshes = mesh.submeshes else { return nil }
        for object in submeshes {
            guard let submesh = object as? MDLSubmesh,
                  let material = submesh.material else { continue }
            for semantic in semantics {
                for property in material.properties(with: semantic) {
                    if let texture = loadMaterialTexture(property: property,
                                                         loader: loader,
                                                         options: options,
                                                         assetURL: assetURL) {
                        print("BallModel: loaded material texture \(property.name)")
                        return texture
                    }
                }
            }
        }
        return nil
    }

    private static func loadMaterialTexture(
        property: MDLMaterialProperty,
        loader: MTKTextureLoader,
        options: [MTKTextureLoader.Option: Any],
        assetURL: URL
    ) -> MTLTexture? {
        if let mdlTexture = property.textureSamplerValue?.texture {
            do {
                return try loader.newTexture(texture: mdlTexture, options: options)
            } catch {
                print("BallModel: material texture error: \(error)")
            }
        }

        if let url = property.urlValue {
            if let texture = loadTexture(url: url, loader: loader, options: options) {
                return texture
            }
        }

        if let string = property.stringValue, !string.isEmpty {
            let candidate = URL(fileURLWithPath: string)
            if let texture = loadTexture(url: candidate, loader: loader, options: options) {
                return texture
            }
            let relativeURL = assetURL.deletingLastPathComponent().appendingPathComponent(string)
            if let texture = loadTexture(url: relativeURL, loader: loader, options: options) {
                return texture
            }
        }
        return nil
    }

    private static func loadTexture(
        url: URL,
        loader: MTKTextureLoader,
        options: [MTKTextureLoader.Option: Any]
    ) -> MTLTexture? {
        do {
            return try loader.newTexture(URL: url, options: options)
        } catch {
            return nil
        }
    }

    private static func loadBundledTexture(
        named: String,
        loader: MTKTextureLoader,
        options: [MTKTextureLoader.Option: Any]
    ) -> MTLTexture? {
        let extensions = ["jpg", "jpeg", "png"]
        for ext in extensions {
            if let texURL = bundleResourceURL(
                forResource: named,
                withExtension: ext,
                subdirectories: [
                    nil,
                    "TriondaBall",
                    "TriondaBall/0",
                    "Resources/TriondaBall",
                    "Resources/TriondaBall/0",
                ]
            ) {
                do {
                    let tex = try loader.newTexture(URL: texURL, options: options)
                    print("BallModel: loaded \(named) (\(tex.width)x\(tex.height))")
                    return tex
                } catch {
                    print("BallModel: \(named) error: \(error)")
                }
            }
        }
        print("BallModel: texture not found: \(named)")
        return nil
    }

    private static func bundleResourceURL(forResource name: String,
                                          withExtension ext: String,
                                          subdirectories: [String?]) -> URL? {
        for subdirectory in subdirectories {
            if let url = Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }
}
