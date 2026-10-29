// Icona dell'app, stile minimal: squircle scuro tinta unita + un solo simbolo bianco (e il rosso del "REC").
//   swift scripts/make-icon.swift Resources/AppIcon-1024.png [fumetto|notte|vetro|aurora|onda|righe|contorno]
import AppKit

let S: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png")
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "vetro"
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let white = c(0xF7F6FB), rec = c(0xFF4D5A)

func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath(), k = radius * 1.28
    p.move(to: CGPoint(x: r.minX + k, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control1: CGPoint(x: r.maxX - k * 0.25, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + k * 0.25))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
    p.addCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - k * 0.25), control2: CGPoint(x: r.maxX - k * 0.25, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - k), control1: CGPoint(x: r.minX + k * 0.25, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - k * 0.25))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
    p.addCurve(to: CGPoint(x: r.minX + k, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + k * 0.25), control2: CGPoint(x: r.minX + k * 0.25, y: r.minY))
    p.closeSubpath()
    return p
}
func pill(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil) }

/// Fumetto: corpo arrotondato + codina in basso a sinistra, uniti in un solo tracciato (niente linea di giunzione).
func bubble(_ r: CGRect) -> CGPath {
    let body = CGPath(roundedRect: r, cornerWidth: r.height * 0.42, cornerHeight: r.height * 0.42, transform: nil)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: r.minX + r.width * 0.16, y: r.minY + 60))
    tail.addLine(to: CGPoint(x: r.minX + r.width * 0.10, y: r.minY - r.height * 0.24))
    tail.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + 60), control: CGPoint(x: r.minX + r.width * 0.26, y: r.minY - r.height * 0.02))
    tail.closeSubpath()
    return body.union(tail)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)!
}
/// Alone morbido (gradiente radiale che sfuma a zero).
func glow(_ center: CGPoint, _ radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    ctx.drawRadialGradient(gradient([c(hex, alpha), c(hex, alpha * 0.45), c(hex, 0)], [0, 0.45, 1]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
/// Filo di luce sul bordo alto dello squircle, come il vetro delle icone di sistema.
func rimLight(_ path: CGPath, _ alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFFFFFF, alpha), c(0xFFFFFF, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
}

// ---------- Sfondo: scuro, gradiente appena percettibile (come le icone minimal di sistema)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = squircle(body, 150)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0x000000, 0.35))
ctx.addPath(bg); ctx.setFillColor(c(0x1A1830)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(bg); ctx.clip()
switch variant {
case "notte", "vetro", "onda":
    // Notte profonda con un alone di colore dietro il fumetto
    ctx.drawLinearGradient(gradient([c(0x27224A), c(0x0C0A18)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    if variant == "vetro" {
        glow(CGPoint(x: 330, y: 400), 470, 0x4F46E5, 0.95)
        glow(CGPoint(x: 730, y: 760), 430, 0xD946EF, 0.75)
    } else {
        glow(CGPoint(x: 512, y: 560), 470, variant == "onda" ? 0x5B4FE8 : 0x5B50F0, 0.62)
    }
case "aurora":
    // Gradiente pieno indaco → viola → rosa, in diagonale
    ctx.drawLinearGradient(gradient([c(0x4338CA), c(0x7C3AED), c(0xDB2777)], [0, 0.55, 1]),
                           start: CGPoint(x: 140, y: 924), end: CGPoint(x: 884, y: 100), options: [])
    glow(CGPoint(x: 300, y: 860), 420, 0xFFFFFF, 0.18)
default:
    ctx.drawLinearGradient(gradient([c(0x302C4D), c(0x16142A)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
ctx.restoreGState()
if variant != "fumetto" && variant != "righe" && variant != "contorno" { rimLight(bg, variant == "aurora" ? 0.45 : 0.28) }

/// Le cinque barre dell'onda, centrate nel fumetto.
func bars(in r: CGRect, scale: CGFloat = 1) -> [CGPath] {
    let heights: [CGFloat] = [84, 160, 220, 160, 84].map { $0 * scale }
    let bw: CGFloat = 44 * scale, gap: CGFloat = 32 * scale
    var x = r.midX - (CGFloat(heights.count) * bw + CGFloat(heights.count - 1) * gap) / 2
    return heights.map { h in
        defer { x += bw + gap }
        return pill(CGRect(x: x, y: r.midY - h / 2, width: bw, height: h))
    }
}

/// Pallino REC che "brilla": alone rosso, anello che lo stacca dal fumetto, sfumatura chiara in alto.
func recDot(_ center: CGPoint, ring ringColor: CGColor?, d: CGFloat = 112, ring: CGFloat = 16) {
    glow(center, d * 1.25, 0xFF3B4E, 0.55)
    if let ringColor {
        ctx.setFillColor(ringColor)
        ctx.fillEllipse(in: CGRect(x: center.x - d / 2 - ring, y: center.y - d / 2 - ring, width: d + 2 * ring, height: d + 2 * ring))
    }
    let dot = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
    ctx.saveGState(); ctx.addEllipse(in: dot); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFF7A84), c(0xF0283C)]), start: CGPoint(x: dot.midX, y: dot.maxY), end: CGPoint(x: dot.midX, y: dot.minY), options: [])
    ctx.restoreGState()
}

// ---------- Simbolo
let r = CGRect(x: 262, y: 382, width: 500, height: 380)
let dotCenter = CGPoint(x: r.maxX - 34, y: r.maxY - 30)
switch variant {
case "notte", "aurora":
    // Fumetto bianco con ombra morbida, onda ritagliata (si vede lo sfondo), pallino REC luminoso
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: c(0x000000, variant == "aurora" ? 0.30 : 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState(); ctx.addPath(bubble(r)); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFFFFFF), c(0xE4E1F4)]), start: CGPoint(x: 512, y: r.maxY), end: CGPoint(x: 512, y: r.minY - 90), options: [])
    ctx.restoreGState()
    ctx.setBlendMode(.clear)
    for b in bars(in: r) { ctx.addPath(b); ctx.fillPath() }
    // anello trasparente attorno al pallino: lo stacca dal fumetto senza un colore in più
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - 72, y: dotCenter.y - 72, width: 144, height: 144))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    recDot(dotCenter, ring: nil)
case "vetro":
    // Fumetto di vetro smerigliato sopra gli aloni, onda bianca piena
    let path = bubble(r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 46, color: c(0x000000, 0.40))
    ctx.addPath(path); ctx.setFillColor(c(0xFFFFFF, 0.14)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0.30), c(0xFFFFFF, 0.06)]), start: CGPoint(x: 512, y: r.maxY), end: CGPoint(x: 512, y: r.minY - 90), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(6); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0.85), c(0xFFFFFF, 0.15)]), start: CGPoint(x: 512, y: r.maxY + 10), end: CGPoint(x: 512, y: r.minY - 90), options: [])
    ctx.restoreGState()
    ctx.setFillColor(c(0xFFFFFF))
    for b in bars(in: r) { ctx.addPath(b); ctx.fillPath() }
    recDot(dotCenter, ring: nil, d: 104)
case "onda":
    // Fumetto bianco, l'onda è il "REC": barre rosse → arancio, niente pallino
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: c(0x000000, 0.55))
    ctx.addPath(bubble(r)); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    for b in bars(in: r) { ctx.addPath(b) }
    ctx.clip()
    ctx.drawLinearGradient(gradient([c(0xFF4D6D), c(0xFF8A3D)]), start: CGPoint(x: r.minX + 90, y: 512), end: CGPoint(x: r.maxX - 90, y: 512), options: [])
    ctx.restoreGState()
case "righe":
    // Pallino REC + tre righe: la registrazione che diventa appunti
    let cy: CGFloat = 512, h: CGFloat = 64
    ctx.setFillColor(rec); ctx.fillEllipse(in: CGRect(x: 270, y: cy + 92 - 58, width: 116, height: 116))
    for (i, w) in [CGFloat(290), 360, 230].enumerated() {
        let y = cy + 92 - CGFloat(i) * 120 - h / 2
        let x: CGFloat = i == 0 ? 440 : 270
        ctx.addPath(pill(CGRect(x: x, y: y, width: i == 0 ? w : w + 120, height: h))); ctx.setFillColor(white); ctx.fillPath()
    }
case "contorno":
    // Fumetto a contorno spesso con il pallino rosso al centro
    let r = CGRect(x: 262, y: 392, width: 500, height: 370)
    ctx.addPath(bubble(r)); ctx.setStrokeColor(white); ctx.setLineWidth(58); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.setFillColor(rec); ctx.fillEllipse(in: CGRect(x: r.midX - 70, y: r.midY - 70, width: 140, height: 140))
default:
    // Fumetto bianco pieno con un'onda sonora ritagliata dentro
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(bubble(r)); ctx.setFillColor(white); ctx.fillPath()
    ctx.setBlendMode(.clear)
    for b in bars(in: r) { ctx.addPath(b); ctx.fillPath() }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // pallino REC in alto a destra
    let d: CGFloat = 112, ring: CGFloat = 16
    let dc = CGPoint(x: r.maxX - 34, y: r.maxY - 30)
    ctx.setFillColor(c(0x22203A)); ctx.fillEllipse(in: CGRect(x: dc.x - d / 2 - ring, y: dc.y - d / 2 - ring, width: d + 2 * ring, height: d + 2 * ring))
    ctx.setFillColor(rec); ctx.fillEllipse(in: CGRect(x: dc.x - d / 2, y: dc.y - d / 2, width: d, height: d))
}

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
