import AppKit
import SwiftUI

// MARK: - Token di colore (ognuno con variante chiara e scura)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Sistema visivo dell'app: colori del brand (indigo-viola dell'icona), superfici, stati, spaziature, raggi.
/// I testi usano i colori di sistema (`.primary`, `.secondary`) per avere il contrasto giusto in entrambi i temi.
enum Theme {
    // Brand
    static let brand = Color(nsColor: .adaptive(light: NSColor(hex: 0x4F46E5), dark: NSColor(hex: 0x8B93FF)))
    static let brandFill = Color(nsColor: .adaptive(light: NSColor(hex: 0x4F46E5), dark: NSColor(hex: 0x6366F1)))
    static let brandSoft = Color(nsColor: .adaptive(light: NSColor(hex: 0xEEF0FF), dark: NSColor(hex: 0x6366F1, alpha: 0.18)))
    static let violet = Color(nsColor: .adaptive(light: NSColor(hex: 0x7C3AED), dark: NSColor(hex: 0xA78BFA)))

    // Registrazione e stati
    static let record = Color(nsColor: .adaptive(light: NSColor(hex: 0xDC2626), dark: NSColor(hex: 0xF87171)))
    static let recordFill = Color(nsColor: .adaptive(light: NSColor(hex: 0xDC2626), dark: NSColor(hex: 0xEF4444)))
    static let warning = Color(nsColor: .adaptive(light: NSColor(hex: 0xB45309), dark: NSColor(hex: 0xFBBF24)))
    static let warningSoft = Color(nsColor: .adaptive(light: NSColor(hex: 0xFEF3C7), dark: NSColor(hex: 0xFBBF24, alpha: 0.14)))
    static let success = Color(nsColor: .adaptive(light: NSColor(hex: 0x15803D), dark: NSColor(hex: 0x4ADE80)))
    static let danger = Color(nsColor: .adaptive(light: NSColor(hex: 0xB91C1C), dark: NSColor(hex: 0xF87171)))
    static let dangerSoft = Color(nsColor: .adaptive(light: NSColor(hex: 0xFEE2E2), dark: NSColor(hex: 0xF87171, alpha: 0.14)))

    // Speaker: tu (microfono) e gli altri (audio della call)
    static let me = brand
    static let others = Color(nsColor: .adaptive(light: NSColor(hex: 0x0F766E), dark: NSColor(hex: 0x2DD4BF)))
    static let othersSoft = Color(nsColor: .adaptive(light: NSColor(hex: 0xCCFBF1), dark: NSColor(hex: 0x2DD4BF, alpha: 0.16)))

    // Superfici
    static let surface = Color(nsColor: .adaptive(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x24242B)))
    static let canvas = Color(nsColor: .adaptive(light: NSColor(hex: 0xF6F6FA), dark: NSColor(hex: 0x18181D)))
    static let border = Color(nsColor: .adaptive(light: NSColor(hex: 0xE2E2EC), dark: NSColor(hex: 0xFFFFFF, alpha: 0.09)))
    static let track = Color(nsColor: .adaptive(light: NSColor(hex: 0xE7E7F0), dark: NSColor(hex: 0xFFFFFF, alpha: 0.08)))

    // Spaziature (ritmo 4/8) e raggi
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32 }
    enum Radius { static let control: CGFloat = 8, card: CGFloat = 12, panel: CGFloat = 16 }

    static let brandGradient = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x6C63FF)), Color(nsColor: NSColor(hex: 0x4B2BC9))],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Aspetto (Sistema / Chiaro / Scuro)

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Componenti

/// Etichetta compatta con icona (cliente, tipo, stato). Il colore non è mai l'unico segnale: c'è sempre testo.
struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var fill: Color = Theme.track
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }
}

/// Avviso in linea (ambra = attenzione, rosso = errore) con icona e testo.
struct Banner: View {
    enum Kind { case warning, error, info }
    let kind: Kind
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(fill))
    }
    private var symbol: String {
        switch kind { case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill"; case .info: return "info.circle.fill" }
    }
    private var tint: Color {
        switch kind { case .warning: return Theme.warning; case .error: return Theme.danger; case .info: return Theme.brand }
    }
    private var fill: Color {
        switch kind { case .warning: return Theme.warningSoft; case .error: return Theme.dangerSoft; case .info: return Theme.brandSoft }
    }
}

/// Marchio dell'app: la vera icona (stessa del Dock e delle notifiche).
struct BrandMark: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.2, height: size * 1.2)   // l'icona ha un margine trasparente attorno
            .accessibilityHidden(true)
    }
}

/// Iniziale dello speaker in un cerchio colorato (Tu = indigo, Altri = verde acqua).
struct SpeakerAvatar: View {
    let name: String
    let isMe: Bool
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(isMe ? Theme.me : Theme.others)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isMe ? Theme.brandSoft : Theme.othersSoft))
            .accessibilityLabel(name)
    }
}

/// Indicatore di livello a segmenti (scala percettiva), con etichetta e stato "silenzio".
struct LevelMeter: View {
    let label: String
    let level: Float
    let color: Color
    var segments = 24

    var body: some View {
        let lit = Int((min(1, sqrt(Double(level)))) * Double(segments) + 0.5)
        HStack(spacing: Theme.Space.s) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? color : Theme.track)
                        .frame(height: 8)
                }
            }
            .animation(.easeOut(duration: 0.12), value: lit)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Livello \(label)")
        .accessibilityValue("\(Int(min(1, sqrt(Double(level))) * 100)) per cento")
    }
}

/// Titolo di sezione piccolo e maiuscolo (es. "AUDIO", "APPUNTI").
struct SectionLabel: View {
    let text: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text.uppercased())
        }
        .font(.caption2.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Componenti editoriali (righe a filetti, niente card)

/// Filetto orizzontale sottile.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// Schede di testo con sottolineatura che scorre (al posto del controllo segmentato).
struct EditorialTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.xl) {
            ForEach(items, id: \.0) { value, label in
                let on = value == selection
                Button {
                    if reduceMotion { selection = value }
                    else { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selection = value } }
                } label: {
                    VStack(spacing: 6) {
                        Text(label)
                            .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                        ZStack {
                            Rectangle().fill(Color.clear).frame(height: 2)
                            if on { Rectangle().fill(Theme.brand).frame(height: 2).matchedGeometryEffect(id: "tab", in: ns) }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
    }
}

/// Riga cliccabile con evidenziazione al passaggio del mouse (liste di suggerimenti, ecc.).
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) { content }
                .padding(.vertical, 10)
                .padding(.horizontal, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Theme.track : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Etichetta di sezione maiuscoletta preceduta da un filetto.
struct RuledLabel: View {
    let text: String
    var rule = true
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if rule { Hairline() }
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }
}
