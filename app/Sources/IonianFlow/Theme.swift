import AppKit
import CoreText
import SwiftUI

// Ionian Flow's look, built on the generated brand tokens (IonianTokens.swift) and the rules in
// brand/patterns/app-macos.md. Values the brand documents per component (the 64×58 keycap, the 62 pt
// pill) are the only literals here.

// MARK: - Resources and fonts

enum IonianResources {
    /// A bundled file: the app bundle first, then the source tree (for `swift run` and tests).
    static func url(_ folder: String, _ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder) { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/\(folder)/\(name).\(ext)").standardized
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    static func image(_ folder: String, _ name: String, _ ext: String = "jpg") -> NSImage? {
        url(folder, name, ext).flatMap { NSImage(contentsOf: $0) }
    }
}

enum IonianFont {
    static let families: [IonianFamily: String] = [.display: "Funnel Display", .sans: "Funnel Sans", .mono: "Geist Mono"]
    private static let files = ["FunnelDisplay-Variable", "FunnelSans-Variable", "GeistMono-Variable"]

    /// Info.plist's ATSApplicationFontsPath covers the app bundle; this covers `swift run` and the renderer.
    static func register() {
        guard !NSFontManager.shared.availableFontFamilies.contains("Funnel Display") else { return }
        for file in files {
            if let url = IonianResources.url("Fonts", file, "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Family plus a CSS weight resolves to the variable font's wght axis (600 gives wght 600).
    static func ns(_ family: IonianFamily, size: CGFloat, weight: CGFloat) -> NSFont {
        let w: NSFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : weight >= 400 ? .regular : .light
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: families[family]!,
            .traits: [NSFontDescriptor.TraitKey.weight: w],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: w)
    }
}

extension Font {
    static func ionian(_ style: IonianTextStyle, weight: CGFloat? = nil, size: CGFloat? = nil) -> Font {
        Font(IonianFont.ns(style.family, size: size ?? style.size, weight: weight ?? style.weight) as CTFont)
    }
}

private struct IonianTextModifier: ViewModifier {
    let style: IonianTextStyle
    var weight: CGFloat?

    func body(content: Content) -> some View {
        let font = IonianFont.ns(style.family, size: style.size, weight: weight ?? style.weight)
        let natural = font.ascender - font.descender + font.leading
        content
            .font(Font(font as CTFont))
            .kerning(style.tracking * style.size)
            .textCase(style.uppercase ? .uppercase : nil)
            .lineSpacing(max(0, style.size * style.lineHeight - natural))
    }
}

extension View {
    /// A brand type style: face, size, weight, tracking, line height and uppercase for mono labels.
    func ionianText(_ style: IonianTextStyle, weight: CGFloat? = nil) -> some View {
        modifier(IonianTextModifier(style: style, weight: weight))
    }
}

// MARK: - Environment

private struct IonianOffscreenKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by the renderer: live Liquid Glass can't be drawn offscreen, so glass uses the GLS-01 recipe.
    var ionianOffscreen: Bool {
        get { self[IonianOffscreenKey.self] }
        set { self[IonianOffscreenKey.self] = newValue }
    }
}

var reduceMotionEnabled: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - Shadows

/// Only the shadow of a shape, cut out under the shape itself so translucent fills stay clean.
struct ShadowOnly<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0

    var body: some View {
        let pad = radius * 3 + abs(x) + abs(y) + 2
        Canvas { ctx, size in
            let full = CGRect(origin: .zero, size: size)
            let path = shape.path(in: full.insetBy(dx: pad, dy: pad))
            var outside = Path(full)
            outside.addPath(path)
            ctx.clip(to: outside, style: FillStyle(eoFill: true))
            ctx.addFilter(.shadow(color: color, radius: radius, x: x, y: y, options: .shadowOnly))
            ctx.fill(path, with: .color(.black))
        }
        .padding(-pad)
        .allowsHitTesting(false)
    }
}

private struct ShadowLayers<S: InsettableShape>: ViewModifier {
    let shadow: IonianShadow
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let layers = shadow.layers(dark: scheme == .dark)
        content.background { ForEach(layers.indices, id: \.self) { i in layer(layers[i]) } }
    }

    @ViewBuilder private func layer(_ l: IonianShadowLayer) -> some View {
        if l.spread > 0 && l.radius == 0 {  // a ring, drawn just outside the shape
            shape.inset(by: -l.spread / 2).stroke(l.color, lineWidth: l.spread)
        } else {
            ShadowOnly(shape: shape, color: l.color, radius: l.radius, x: l.x, y: l.y)
        }
    }
}

extension View {
    func ionianShadow<S: InsettableShape>(_ shadow: IonianShadow, in shape: S) -> some View {
        modifier(ShadowLayers(shadow: shadow, shape: shape))
    }
}

// MARK: - The Flow sign

/// brand/assets/signs/flow.svg: eight rounded bars on the viewBox `17 0.5 30 30`.
struct FlowSign: Shape {
    /// x, y, height of each bar (width 2.4, radius 1.2), in viewBox units.
    private static let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (18.55, 13.0, 5), (22.05, 10.5, 10), (25.55, 7.0, 17), (29.05, 4.5, 22),
        (32.55, 8.5, 14), (36.05, 6.0, 19), (39.55, 11.0, 9), (43.05, 13.0, 5),
    ]

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 30
        let ox = rect.midX - 15 * s, oy = rect.midY - 15 * s
        var p = Path()
        for b in Self.bars {
            let r = CGRect(x: ox + (b.x - 17) * s, y: oy + (b.y - 0.5) * s, width: 2.4 * s, height: b.h * s)
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 1.2 * s, height: 1.2 * s))
        }
        return p
    }
}

// MARK: - Chrome and the app icon

/// A crop of a chrome still. Never recolored (CHR-07).
struct ChromeStill: View {
    let name: String
    var scale: CGFloat = 1
    /// Focal point as a fraction of the image, 0...1.
    var focus = CGPoint(x: 0.5, y: 0.5)

    var body: some View {
        GeometryReader { geo in
            if let image = IonianResources.image("Chrome", name) {
                let fill = max(geo.size.width / image.size.width, geo.size.height / image.size.height) * scale
                let w = image.size.width * fill, h = image.size.height * fill
                Image(nsImage: image).resizable().frame(width: w, height: h)
                    .offset(x: -(w - geo.size.width) * focus.x, y: -(h - geo.size.height) * focus.y)
            } else {
                Color.night
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The Flow tile with the white sign (AIC-01..06).
struct AppIcon: View {
    var size: CGFloat = 56

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Radius.icon, style: .continuous)
        ZStack {
            ChromeStill(name: "tile-flow")
            FlowSign().fill(Color.white)
                .frame(width: size * 0.726, height: size * 0.726)
                .shadow(color: .black.opacity(0.55), radius: 0.75, y: 1)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .ionianShadow(IonianShadows.icon, in: shape)
        .accessibilityLabel("Ionian Flow")
    }
}

/// App icon, then `ionian / flow` in live type (IDN-03).
struct Lockup: View {
    var body: some View {
        HStack(spacing: Space.s3) {
            AppIcon(size: 28)
            (Text("ionian").foregroundStyle(Color.ink) + Text(" / flow").font(.ionian(IonianType.wordmark, weight: 500)).foregroundStyle(Color.faint))
                .ionianText(IonianType.wordmark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ionian Flow")
    }
}

// MARK: - Text pieces

/// Mono, accent, tracked, uppercase, directly above the heading it labels (EYB-04).
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { Text(text).ionianText(IonianType.eyebrow).foregroundStyle(Color.accent) }
}

/// Mono uppercase meta label.
struct MonoLabel: View {
    let text: String
    var color = Color.faint
    init(_ text: String, color: Color = Color.faint) { self.text = text; self.color = color }

    var body: some View { Text(text).ionianText(IonianType.label).foregroundStyle(color) }
}

/// Window and panel sizes and the content widths that have no Space token (MAC-22). One place.
enum WindowLayout {
    static let lead: CGFloat = 520
    static let sidebar: CGFloat = 210
    static let main = CGSize(width: 820, height: 640)
    static let mainMin = CGSize(width: 700, height: 500)
    static let setup = CGSize(width: 700, height: 720)
    static let transcript = CGSize(width: 400, height: 600)
    static let transcriptMin = CGSize(width: 300, height: 320)
    static let pill = CGSize(width: 720, height: 280)
}

enum StatusState {
    case ready, working, off
    var color: Color { self == .ready ? .live : self == .working ? .building : .idea }
}

/// The dot always sits next to its word (STS-01).
struct StatusDot: View {
    let state: StatusState
    let word: String
    var wordColor = Color.faint

    var body: some View {
        HStack(spacing: Space.s2) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            MonoLabel(word, color: wordColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A shortcut in a settings row: mono on `code-bg`, no border (CMD-07).
struct KeyChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).ionianText(IonianType.code).foregroundStyle(Color.ink)
            .padding(.horizontal, Space.s2).padding(.vertical, Space.s1 / 2)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.codeBg))
            .fixedSize()
    }
}

/// The drawn key (KEY-01): only inside a how-it-works visual.
struct Key: View {
    let label: String
    /// Label size: 16 for words like "fn", larger for a lone symbol like ⌥.
    var size: CGFloat = 16
    var held = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(Color.line).offset(y: held ? 1 : 3)
            shape.fill(Color.bg)
            shape.strokeBorder(Color.line)
            Text(label).ionianText(.init(family: .mono, size: size, weight: 400, lineHeight: 1, tracking: 0, uppercase: false))
                .foregroundStyle(Color.ink)
        }
        .frame(width: 64, height: 58)
        .background {
            if held {
                shape.inset(by: -2).stroke(Color.building.opacity(0.18), lineWidth: 4)
            } else {
                ShadowOnly(shape: shape, color: Color(.sRGB, red: 0.02, green: 0.098, blue: 0.235, opacity: 0.1), radius: 11, y: 10)
            }
        }
        .offset(y: held ? 2 : 0)
    }
}

// MARK: - Wave

/// Fourteen staggered bars (LSN-04). Driven by the mic level when given; flat at 12% when idle;
/// frozen at 60% under Reduce Motion.
struct Wave: View {
    var level: Float?
    var bars = 14
    var active = true
    /// 1 is the 30 pt wave of the pill; smaller for meters.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { 30 * scale }

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3 * scale) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule().fill(Color.wave).frame(width: 3 * scale, height: height * fraction(i, t))
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
    }

    private func fraction(_ i: Int, _ t: Double) -> CGFloat {
        if !active { return 0.12 }
        if reduceMotion { return 0.6 }
        let n = i + 1
        let delay = n % 5 == 0 ? 0.85 : n % 3 == 0 ? 0.6 : n % 2 == 0 ? 0.3 : 0
        let phase = ((t + delay) / MotionDuration.wave).truncatingRemainder(dividingBy: 1)
        let swing = 0.5 - 0.5 * cos(phase * 2 * .pi)  // 18% to 100% and back, eased
        let amp = level.map { 0.1 + 0.9 * Double(min(1, sqrt($0) * 3)) } ?? 1
        return CGFloat(0.18 + 0.82 * swing * amp)
    }
}

// MARK: - Glass

/// `radius.pill` clamped to half the height, so it also holds when a pill grows taller than one line.
struct PillShape: InsettableShape {
    private var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Path(roundedRect: r, cornerSize: CGSize(width: min(Radius.pill, r.height / 2), height: min(Radius.pill, r.height / 2)), style: .circular)
    }

    func inset(by amount: CGFloat) -> PillShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// Glass for surfaces that float over the desktop (MAC-11). macOS 26: Liquid Glass. Older macOS and
/// offscreen renders: the GLS-01 recipe.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.ionianOffscreen) private var offscreen
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !offscreen {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background { if !offscreen { shape.fill(.ultraThinMaterial) } }  // a material draws a seam offscreen
                .background(shape.fill(Color.glass))
                .overlay(shape.strokeBorder(Color.glassLine))
                .overlay(shape.inset(by: 1).stroke(
                    LinearGradient(colors: [Color.glassLine, .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .ionianShadow(IonianShadows.glass, in: shape)
        }
    }
}

extension View {
    func ionianGlass<S: InsettableShape>(in shape: S) -> some View { modifier(GlassSurface(shape: shape)) }
}

// MARK: - Layout pieces

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.line).frame(height: 1) }
}

// MARK: - Settings pages

/// A settings page: the brand page head, then sections, scrolling together on `bg`.
struct SettingsPage<Content: View>: View {
    let title: String
    var lead: String?
    @ViewBuilder var content: Content

    init(_ page: AppModel.Page, @ViewBuilder content: () -> Content) {
        self.init(title: page.title, lead: page.subtitle, content: content)
    }

    init(title: String, lead: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.lead = lead
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(title).ionianText(IonianType.title).foregroundStyle(Color.ink)
                    if let lead {
                        Text(lead).ionianText(IonianType.lead).foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: WindowLayout.lead, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bg.ignoresSafeArea())
    }
}

/// A mono eyebrow, a `surface` card of rows split by `line` hairlines, and a muted note under it.
struct SettingsSection<Accessory: View, Footer: View, Content: View>: View {
    var header: String?
    var accessory: Accessory
    var footer: Footer
    var content: Content

    init(_ header: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder footer: () -> Footer,
         @ViewBuilder content: () -> Content) {
        self.header = header
        self.accessory = accessory()
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if header != nil || Accessory.self != EmptyView.self {
                HStack {
                    if let header { MonoLabel(header, color: Color.muted).accessibilityAddTraits(.isHeader) }
                    Spacer()
                    accessory
                }
                .padding(.horizontal, Space.s1)
            }
            SettingsCard { content }
            footer.padding(.horizontal, Space.s1)
        }
    }
}

extension SettingsSection where Accessory == EmptyView, Footer == EmptyView {
    init(_ header: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(header, accessory: { EmptyView() }, footer: { EmptyView() }, content: content)
    }
}

extension SettingsSection where Accessory == EmptyView, Footer == SettingsNote {
    init(_ header: String? = nil, note: String, ink: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(header, accessory: { EmptyView() }, footer: { SettingsNote(note, ink: ink) }, content: content)
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ header: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.init(header, accessory: accessory, footer: { EmptyView() }, content: content)
    }
}

/// The sentence under a section: `muted`, or `ink` when it's a problem to act on.
struct SettingsNote: View {
    let text: String
    var ink = false
    init(_ text: String, ink: Bool = false) { self.text = text; self.ink = ink }

    var body: some View {
        Text(text).ionianText(IonianType.small).foregroundStyle(ink ? Color.ink : Color.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rows on `surface` with a `line` edge and hairlines between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Hairline() }
                    rows[i].padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.line))
    }
}

/// A setting: its name, what it does under it, and the control at the trailing edge.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var trailing: Trailing

    init(_ title: String, _ detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).ionianText(IonianType.body).foregroundStyle(Color.ink)
                if let detail {
                    Text(detail).ionianText(IonianType.small).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s4)
            trailing
        }
        .frame(minHeight: 28)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(_ title: String, _ detail: String? = nil) { self.init(title, detail) { EmptyView() } }
}

/// A native switch in a row. The label stays for VoiceOver.
struct SettingToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    init(_ title: String, _ detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingRow(title, detail) { Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch) }
    }
}

/// A text field on `surface`, `radius.sm`, `line` edge; `accent` while focused (MAC-07).
struct BrandField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(_ prompt: String, text: Binding<String>) { self.prompt = prompt; _text = text }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.muted))
            .textFieldStyle(.plain)
            .ionianText(IonianType.body)
            .foregroundStyle(Color.ink)
            .focused($focused)
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .background(shape.fill(Color.surface))
            .overlay(shape.strokeBorder(focused ? Color.accent : Color.line, lineWidth: focused ? FocusRing.width : 1))
    }
}

// MARK: - Buttons

/// The one filled control: `btn-bg` and `btn-fg` on a pill, 48 pt or 38 pt in dense rows (BTN-01..04).
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, compact: compact)
    }

    private struct Label: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .ionianText(IonianType.body, weight: 500)
                .font(.ionian(IonianType.body, weight: 500, size: compact ? 14 : 16))
                .foregroundStyle(Color.btnFg)
                .padding(.horizontal, compact ? Space.s4 : Space.s6)
                .frame(height: compact ? 38 : 48)
                .background(Capsule().fill(Color.btnBg))
                .opacity(!enabled ? 0.4 : (configuration.isPressed || hovering) ? 0.9 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

/// Every other action: a mono label in accent. The caller adds the glyph (`›`, `↗`, `↓`) to the title (LNK-01).
struct MonoLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }

    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .ionianText(IonianType.label)
                .fixedSize()
                .foregroundStyle(hovering || configuration.isPressed ? Color.accentHover : Color.accent)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == MonoLinkButtonStyle {
    static var monoLink: MonoLinkButtonStyle { MonoLinkButtonStyle() }
}
