import AppKit
import CoreGraphics

/// Procedurally drawn artwork. We synthesise the football and its shadow at
/// runtime instead of shipping image assets, so the app stays a single binary
/// with no `.atlas` bundle to manage (and it scales crisply to any Retina factor).
enum BallTexture {

    /// A classic black-and-white football, shaded to read as a sphere.
    /// - Parameter pixels: square bitmap size. 256 is plenty for a 60pt ball @2x.
    static func football(pixels: Int = 256) -> CGImage? {
        let size = CGFloat(pixels)
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let c = CGPoint(x: size / 2, y: size / 2)
        let r = size / 2 - size * 0.03

        // Clip everything to the ball's circle.
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()

        // Base white sphere with a soft body gradient (highlight up-left).
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        drawSphereShading(in: ctx, center: c, radius: r)

        // Black panels: one centre pentagon + five around the rim.
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        fillPentagon(ctx, center: c, radius: r * 0.34, pointingAngle: .pi / 2)
        let ringDistance = r * 0.80
        let ringRadius = r * 0.30
        for k in 0..<5 {
            let theta = .pi / 2 + CGFloat(k) * (2 * .pi / 5)
            let pc = CGPoint(x: c.x + cos(theta) * ringDistance,
                             y: c.y + sin(theta) * ringDistance)
            // Orient a vertex toward the ball centre for the familiar look.
            fillPentagon(ctx, center: pc, radius: ringRadius, pointingAngle: theta + .pi)
        }

        // Seams: thin dark strokes linking the centre panel toward each rim panel.
        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 0.65).cgColor)
        ctx.setLineWidth(size * 0.012)
        ctx.setLineCap(.round)
        for k in 0..<5 {
            let theta = .pi / 2 + (CGFloat(k) + 0.5) * (2 * .pi / 5)
            ctx.move(to: CGPoint(x: c.x + cos(theta) * r * 0.18,
                                 y: c.y + sin(theta) * r * 0.18))
            ctx.addLine(to: CGPoint(x: c.x + cos(theta) * r * 0.62,
                                    y: c.y + sin(theta) * r * 0.62))
        }
        ctx.strokePath()

        // Glossy specular highlight near the top-left.
        drawSpecular(in: ctx, center: CGPoint(x: c.x - r * 0.34, y: c.y + r * 0.36),
                     radius: r * 0.55)

        // Crisp rim.
        ctx.setStrokeColor(NSColor(white: 0.18, alpha: 0.5).cgColor)
        ctx.setLineWidth(size * 0.01)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// A soft elliptical contact shadow (dark centre fading to clear).
    static func softShadow(pixels: Int = 256) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let size = CGFloat(pixels)
        let c = CGPoint(x: size / 2, y: size / 2)
        let colors = [NSColor(white: 0, alpha: 0.55).cgColor,
                      NSColor(white: 0, alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors, locations: [0, 1]
        ) else { return nil }

        // Squash the radial gradient vertically into a flat ellipse.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1.0, y: 0.45)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: size / 2,
                               options: [])
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: - Private drawing helpers

    private static func fillPentagon(_ ctx: CGContext, center: CGPoint,
                                     radius: CGFloat, pointingAngle: CGFloat) {
        let path = CGMutablePath()
        for i in 0..<5 {
            let a = pointingAngle + CGFloat(i) * (2 * .pi / 5)
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func drawSphereShading(in ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let colors = [NSColor(white: 1.0, alpha: 0).cgColor,
                      NSColor(white: 0.55, alpha: 0.28).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) else { return }
        // Light source up-left → darken toward bottom-right.
        let hi = CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.3)
        ctx.drawRadialGradient(g, startCenter: hi, startRadius: 0,
                               endCenter: center, endRadius: radius * 1.25, options: [])
    }

    private static func drawSpecular(in ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let colors = [NSColor(white: 1.0, alpha: 0.42).cgColor,
                      NSColor(white: 1.0, alpha: 0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }
}
