// Icona dell'app: una notina sorridente in stile pop (contorni spessi, ombra piena, colori pieni)
// con il bollino rosso di registrazione.   swift scripts/make-icon.swift Resources/AppIcon-1024.png
import AppKit

let S: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png")
/// Variante: nota (default) | bolla | microfono
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "nota"
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Palette
let ink: UInt32 = 0x1F1B3A          // contorni
var lime1: UInt32 = 0xD4F76A, lime2: UInt32 = 0x8FDD4B, limeDeep: UInt32 = 0x3F9A35
if variant == "bolla" { lime1 = 0xFFC9A8; lime2 = 0xFF7E79; limeDeep = 0xC2414F }
if variant == "microfono" { lime1 = 0xFFEA7A; lime2 = 0xFFC53D; limeDeep = 0xC98A12 }
let cream: UInt32 = 0xFFF8E6, creamShade: UInt32 = 0xF3E6C4
let coral: UInt32 = 0xFF4F5E, coralLight: UInt32 = 0xFF8A80
let blush: UInt32 = 0xFF8FB1

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
func fill(_ p: CGPath, _ col: CGColor) { ctx.addPath(p); ctx.setFillColor(col); ctx.fillPath() }
func stroke(_ p: CGPath, _ col: CGColor, _ w: CGFloat) {
    ctx.addPath(p); ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
}

// ---------- Sfondo
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = squircle(body, 150)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: c(0x0E2A10, 0.35))
fill(bg, c(lime2))
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(bg); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [c(lime1), c(lime2)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let shine = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.32), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(shine, startCenter: CGPoint(x: 290, y: 820), startRadius: 0, endCenter: CGPoint(x: 290, y: 820), endRadius: 430, options: [])
// coriandoli pop
for (x, y, r, col) in [(222.0, 300.0, 16.0, c(0xFFFFFF, 0.9)), (812, 742, 20, c(0xFFE15A)), (800, 286, 12, c(0xFFFFFF, 0.85)),
                       (238, 760, 11, c(0xFFE15A)), (186, 300, 9, c(0xFFFFFF, 0.8))] as [(CGFloat, CGFloat, CGFloat, CGColor)] {
    ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
// stellina
func star(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: cy + r))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.18, y: cy + r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx + r * 0.18, y: cy - r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r * 0.18, y: cy - r * 0.18))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx - r * 0.18, y: cy + r * 0.18))
    p.closeSubpath(); return p
}
fill(star(770, 520, 34), c(0xFFFFFF, 0.95))
fill(star(268, 196 + 40, 24), c(0xFFFFFF, 0.9))
ctx.restoreGState()

if variant == "nota" {
// ---------- La notina (ruotata, con ombra piena "sticker")
let note = CGRect(x: 268, y: 214, width: 470, height: 560)
let fold: CGFloat = 112
func notePath(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), rad: CGFloat = 70
    p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))      // angolo piegato
    p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
    p.closeSubpath(); return p
}
ctx.saveGState()
ctx.translateBy(x: note.midX, y: note.midY); ctx.rotate(by: 7 * .pi / 180); ctx.translateBy(x: -note.midX, y: -note.midY)

let shape = notePath(note)
// ombra piena spostata (pop)
ctx.saveGState(); ctx.translateBy(x: 30, y: -30); fill(shape, c(limeDeep)); ctx.restoreGState()
fill(shape, c(cream))
// leggera ombreggiatura in basso
ctx.saveGState(); ctx.addPath(shape); ctx.clip()
let paper = CGGradient(colorsSpace: cs, colors: [c(cream, 0), c(creamShade, 0.9)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: note.midY), end: CGPoint(x: 0, y: note.minY), options: [])
ctx.restoreGState()
// risvolto dell'angolo
let flap = CGMutablePath()
flap.move(to: CGPoint(x: note.maxX, y: note.maxY - fold))
flap.addLine(to: CGPoint(x: note.maxX - fold + 18, y: note.maxY - fold + 18))
flap.addQuadCurve(to: CGPoint(x: note.maxX - fold, y: note.maxY), control: CGPoint(x: note.maxX - fold - 6, y: note.maxY - fold + 40))
flap.closeSubpath()
fill(flap, c(creamShade))
stroke(flap, c(ink), 20)
stroke(shape, c(ink), 24)

// faccina
let eyeY = note.maxY - 205
for ex in [note.midX - 92, note.midX + 92] {
    let eye = CGRect(x: ex - 30, y: eyeY - 42, width: 60, height: 84)
    ctx.setFillColor(c(ink)); ctx.fillEllipse(in: eye)
    ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: ex - 12, y: eyeY + 8, width: 22, height: 26))
}
for bx in [note.midX - 160, note.midX + 160] {
    ctx.setFillColor(c(blush, 0.85)); ctx.fillEllipse(in: CGRect(x: bx - 40, y: eyeY - 92, width: 80, height: 46))
}
// bocca aperta e felice (D rovesciata) con linguetta rosa
let mouthY = eyeY - 104
let mw: CGFloat = 112, mh: CGFloat = 70
let mouth = CGMutablePath()
mouth.move(to: CGPoint(x: note.midX - mw / 2, y: mouthY))
mouth.addLine(to: CGPoint(x: note.midX + mw / 2, y: mouthY))
mouth.addCurve(to: CGPoint(x: note.midX - mw / 2, y: mouthY), control1: CGPoint(x: note.midX + mw / 2, y: mouthY - mh * 1.25),
               control2: CGPoint(x: note.midX - mw / 2, y: mouthY - mh * 1.25))
mouth.closeSubpath()
fill(mouth, c(ink))
ctx.saveGState(); ctx.addPath(mouth); ctx.clip()
ctx.setFillColor(c(0xFF6F91)); ctx.fillEllipse(in: CGRect(x: note.midX - 38, y: mouthY - mh - 22, width: 76, height: 56))
ctx.restoreGState()
stroke(mouth, c(ink), 14)
// righe di testo
for (y, w) in [(note.minY + 118, 300.0), (note.minY + 66, 200.0)] as [(CGFloat, CGFloat)] {
    let r = CGRect(x: note.minX + 64, y: y - 13, width: w, height: 26)
    fill(CGPath(roundedRect: r, cornerWidth: 13, cornerHeight: 13, transform: nil), c(ink, 0.28))
}
ctx.restoreGState()

if variant == "nota" {
// ---------- Onde sonore (la notina ascolta)
for (i, r) in [CGFloat(70), 118].enumerated() {
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: 262, y: 470), radius: r, startAngle: .pi * 0.78, endAngle: .pi * 1.22, clockwise: false)
    stroke(arc, c(0xFFFFFF, i == 0 ? 0.95 : 0.7), 22)
}

// ---------- Bollino REC (adesivo)
let center = CGPoint(x: 290, y: 770)
let R: CGFloat = 92
let sticker = CGPath(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R), transform: nil)
ctx.saveGState(); ctx.translateBy(x: 16, y: -16); fill(sticker, c(limeDeep)); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(sticker); ctx.clip()
let rg = CGGradient(colorsSpace: cs, colors: [c(coralLight), c(coral)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(rg, start: CGPoint(x: center.x - R, y: center.y + R), end: CGPoint(x: center.x + R, y: center.y - R), options: [])
ctx.restoreGState()
stroke(sticker, c(ink), 20)
// pallino bianco al centro (simbolo "registra") + riflesso
ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
ctx.setFillColor(c(0xFFFFFF, 0.55)); ctx.fillEllipse(in: CGRect(x: center.x - 58, y: center.y + 30, width: 34, height: 22))
}

}  // fine variante "nota"

// ---------- Faccina riusabile (occhi lucidi, guance, bocca aperta)
func face(center p: CGPoint, scale k: CGFloat) {
    for ex in [p.x - 92 * k, p.x + 92 * k] {
        ctx.setFillColor(c(ink)); ctx.fillEllipse(in: CGRect(x: ex - 30 * k, y: p.y - 42 * k, width: 60 * k, height: 84 * k))
        ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: ex - 12 * k, y: p.y + 8 * k, width: 22 * k, height: 26 * k))
    }
    for bx in [p.x - 158 * k, p.x + 158 * k] {
        ctx.setFillColor(c(blush, 0.85)); ctx.fillEllipse(in: CGRect(x: bx - 38 * k, y: p.y - 92 * k, width: 76 * k, height: 44 * k))
    }
    let my = p.y - 104 * k, mw = 112 * k, mh = 70 * k
    let m = CGMutablePath()
    m.move(to: CGPoint(x: p.x - mw / 2, y: my)); m.addLine(to: CGPoint(x: p.x + mw / 2, y: my))
    m.addCurve(to: CGPoint(x: p.x - mw / 2, y: my), control1: CGPoint(x: p.x + mw / 2, y: my - mh * 1.25), control2: CGPoint(x: p.x - mw / 2, y: my - mh * 1.25))
    m.closeSubpath()
    fill(m, c(ink))
    ctx.saveGState(); ctx.addPath(m); ctx.clip()
    ctx.setFillColor(c(0xFF6F91)); ctx.fillEllipse(in: CGRect(x: p.x - 38 * k, y: my - mh - 22 * k, width: 76 * k, height: 56 * k))
    ctx.restoreGState()
    stroke(m, c(ink), 14 * k)
}

if variant == "bolla" {
    // Fumetto bianco con codina, faccina e una piccola onda sonora "detta"
    let b = CGRect(x: 214, y: 300, width: 596, height: 470)
    let bubble = CGMutablePath()
    bubble.addPath(CGPath(roundedRect: b, cornerWidth: 220, cornerHeight: 220, transform: nil))
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 330, y: 330)); tail.addLine(to: CGPoint(x: 250, y: 196)); tail.addLine(to: CGPoint(x: 450, y: 312)); tail.closeSubpath()
    let full = CGMutablePath(); full.addPath(bubble); full.addPath(tail)
    ctx.saveGState(); ctx.translateBy(x: 28, y: -28); fill(full, c(limeDeep)); ctx.restoreGState()
    fill(full, c(cream))
    ctx.saveGState(); ctx.addPath(full); ctx.clip()
    let pg = CGGradient(colorsSpace: cs, colors: [c(cream, 0), c(creamShade, 0.8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(pg, start: CGPoint(x: 0, y: 560), end: CGPoint(x: 0, y: 280), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // contorno unico (bolla + codina) disegnato come unione
    ctx.saveGState()
    ctx.addPath(full); ctx.setStrokeColor(c(ink)); ctx.setLineWidth(24); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.restoreGState()
    fill(CGPath(roundedRect: b.insetBy(dx: 12, dy: 12), cornerWidth: 208, cornerHeight: 208, transform: nil), c(cream))
    let tailIn = CGMutablePath()
    tailIn.move(to: CGPoint(x: 340, y: 346)); tailIn.addLine(to: CGPoint(x: 272, y: 224)); tailIn.addLine(to: CGPoint(x: 430, y: 326)); tailIn.closeSubpath()
    fill(tailIn, c(cream))
    face(center: CGPoint(x: b.midX, y: b.midY + 60), scale: 1.0)
    // punto REC rosso come "fiore" sul fumetto
    let rc = CGPoint(x: 770, y: 760), R: CGFloat = 70
    let st = CGPath(ellipseIn: CGRect(x: rc.x - R, y: rc.y - R, width: 2 * R, height: 2 * R), transform: nil)
    ctx.saveGState(); ctx.translateBy(x: 12, y: -12); fill(st, c(limeDeep)); ctx.restoreGState()
    fill(st, c(coral)); stroke(st, c(ink), 18)
    ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: rc.x - 22, y: rc.y - 22, width: 44, height: 44))
}

if variant == "microfono" {
    // Microfono con faccina: testa a capsula con griglia, asta e base
    let head = CGRect(x: 342, y: 330, width: 340, height: 470)
    let headPath = CGPath(roundedRect: head, cornerWidth: 170, cornerHeight: 170, transform: nil)
    let stand = CGMutablePath()
    stand.addArc(center: CGPoint(x: 512, y: 440), radius: 230, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
    let pole = CGMutablePath(); pole.move(to: CGPoint(x: 512, y: 210)); pole.addLine(to: CGPoint(x: 512, y: 150))
    let base = CGPath(roundedRect: CGRect(x: 402, y: 132, width: 220, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil)
    // ombre piene
    ctx.saveGState(); ctx.translateBy(x: 26, y: -26)
    fill(headPath, c(limeDeep)); stroke(stand, c(limeDeep), 34); stroke(pole, c(limeDeep), 34); fill(base, c(limeDeep))
    ctx.restoreGState()
    stroke(stand, c(ink), 34); stroke(pole, c(ink), 34); fill(base, c(ink))
    fill(headPath, c(cream))
    ctx.saveGState(); ctx.addPath(headPath); ctx.clip()
    // griglia nella parte alta della capsula
    ctx.setFillColor(c(0xE9E1F5)); ctx.fill(CGRect(x: head.minX, y: head.maxY - 150, width: head.width, height: 150))
    for i in 0..<5 {
        let x = head.minX + 60 + CGFloat(i) * 55
        let l = CGMutablePath(); l.move(to: CGPoint(x: x, y: head.maxY - 140)); l.addLine(to: CGPoint(x: x, y: head.maxY))
        stroke(l, c(ink, 0.28), 12)
    }
    let band = CGMutablePath(); band.move(to: CGPoint(x: head.minX, y: head.maxY - 150)); band.addLine(to: CGPoint(x: head.maxX, y: head.maxY - 150))
    stroke(band, c(ink), 18)
    ctx.restoreGState()
    stroke(headPath, c(ink), 24)
    face(center: CGPoint(x: head.midX, y: head.minY + 230), scale: 0.78)
    // punto REC sulla fascia
    ctx.setFillColor(c(coral)); ctx.fillEllipse(in: CGRect(x: head.maxX - 70, y: head.maxY - 172, width: 44, height: 44))
    stroke(CGPath(ellipseIn: CGRect(x: head.maxX - 70, y: head.maxY - 172, width: 44, height: 44), transform: nil), c(ink), 10)
}

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
