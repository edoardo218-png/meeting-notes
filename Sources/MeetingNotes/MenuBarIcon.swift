import AppKit

/// Icona della barra dei menu: il fumetto dell'app in versione "template" (monocromatica, si adatta a chiaro/scuro
/// e si colora con `contentTintColor`, es. rosso mentre registra).
enum MenuBarIcon {
    enum Glyph { case wave, dots }

    static func image(_ glyph: Glyph) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Corpo del fumetto + codina in basso a sinistra (come nell'icona dell'app)
            let body = CGRect(x: 1.25, y: 4.25, width: 17.5, height: 12.5)
            let bubble = CGPath(roundedRect: body, cornerWidth: 5.4, cornerHeight: 5.4, transform: nil)
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: body.minX + 2.6, y: body.minY + 2))
            tail.addLine(to: CGPoint(x: body.minX + 1.6, y: 0.8))
            tail.addQuadCurve(to: CGPoint(x: body.minX + 7.4, y: body.minY + 2), control: CGPoint(x: body.minX + 4.4, y: body.minY))
            tail.closeSubpath()
            let shape = CGMutablePath()
            shape.addPath(bubble.union(tail))

            // Ritagli: onda sonora (5 barre) oppure tre puntini "sta scrivendo"
            switch glyph {
            case .wave:
                let heights: [CGFloat] = [3.2, 6.0, 8.2, 6.0, 3.2]
                let w: CGFloat = 1.6, gap: CGFloat = 1.3
                var x = body.midX - (CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap) / 2
                for h in heights {
                    shape.addPath(CGPath(roundedRect: CGRect(x: x, y: body.midY - h / 2, width: w, height: h),
                                         cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
                    x += w + gap
                }
            case .dots:
                for i in -1...1 {
                    let d: CGFloat = 2.4
                    shape.addEllipse(in: CGRect(x: body.midX + CGFloat(i) * 4.2 - d / 2, y: body.midY - d / 2, width: d, height: d))
                }
            }
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Meeting Notes"
        return img
    }
}
