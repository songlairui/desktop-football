import simd

/// Fixed "aquarium" perspective camera. The screen is treated as a front glass:
/// 2D physics maps to world X/Y, while Z remains a visual depth axis.
///
/// All coordinates live in the world space where X = horizontal, Y = up (height),
/// Z = depth (screen Y inverted). The ground is the XZ plane at Y = 0.
struct MetalCamera {

    /// Distance from the front glass. Large relative to the 3-ball-depth tank so
    /// perspective stays present but subtle.
    let distance: Float = 1850

    /// A fixed, slight off-axis view gives vertical spin visible parallax without
    /// adding camera wobble to the motion.
    let sideOffset: Float = 135
    let liftOffset: Float = 80

    /// World up direction (Y is up).
    let up = SIMD3<Float>(0, 1, 0)

    let near: Float = 1.0
    let far:  Float = 6000.0

    func projectionMatrix(aspect: Float, frontHeight: Float) -> float4x4 {
        let fovY = 2 * atan((frontHeight * 0.5) / distance)
        return float4x4(perspective: fovY, aspect: aspect, near: near, far: far)
    }

    func viewMatrix(frontHeight: Float) -> float4x4 {
        let centerY = frontHeight * 0.5
        let eye = SIMD3<Float>(sideOffset, centerY + liftOffset, distance)
        let target = SIMD3<Float>(0, centerY, 0)
        return float4x4.lookAt(eye: eye, target: target, up: up)
    }

    func eye(frontHeight: Float) -> SIMD3<Float> {
        SIMD3<Float>(sideOffset, frontHeight * 0.5 + liftOffset, distance)
    }
}
