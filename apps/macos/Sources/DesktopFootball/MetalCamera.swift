import simd

/// Fixed "aquarium" perspective camera. The screen is treated as a front glass:
/// 2D physics maps to world X/Y, while Z remains a visual depth axis.
///
/// All coordinates live in the world space where X = horizontal, Y = up (height),
/// Z = depth (screen Y inverted). The ground is the XZ plane at Y = 0.
struct MetalCamera {

    /// Camera position in world space. Slightly above and in front of the tank.
    let eye = SIMD3<Float>(0, 430, 900)

    /// Where the camera looks — the middle of the fixed tank volume.
    let target = SIMD3<Float>(0, 240, 0)

    /// World up direction (Y is up).
    let up = SIMD3<Float>(0, 1, 0)

    /// Vertical field of view in radians.
    let fovY: Float = 50.0 * .pi / 180.0

    let near: Float = 1.0
    let far:  Float = 3000.0

    func projectionMatrix(aspect: Float) -> float4x4 {
        float4x4(perspective: fovY, aspect: aspect, near: near, far: far)
    }

    func viewMatrix() -> float4x4 {
        float4x4.lookAt(eye: eye, target: target, up: up)
    }
}
