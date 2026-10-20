import SwiftUI

/// deviantART v7 (2011) look: sage-green paper, dark green-gray header, teal links, Verdana body,
/// Trebuchet headings, soft thumb shadows, "gruze" boxes. Every value below was sampled from the
/// archived site (web.archive.org, deviantart.com 2011-09-01) or lifted from its v6core.css.
enum Theme {
    // Ground
    static let background   = Color(hex: 0xD5E0D2)   // page (body gradient settles here)
    static let sidebar      = Color(hex: 0xDAE4D9)   // left browse column
    static let sidebarRule  = Color(hex: 0xAEBEB2)   // its right edge
    static let surface      = Color(hex: 0xDDE6DB)   // gruze box body
    static let surfaceSunk  = Color(hex: 0xE3EADF)   // comment / inner well
    static let surfaceHover = Color(hex: 0xE8EFE6)   // row hover
    static let paper        = Color(hex: 0xFBFCFA)   // inputs, literature page
    static let border       = Color(hex: 0xA6B2A6)   // gruze border
    static let rule         = Color(hex: 0xBFCDBD)   // section divider…
    static let ruleLight    = Color(hex: 0xEDF2ED)   // …and its 1px highlight underneath
    static let highlight    = Color(hex: 0xF2FCF1)   // top inner highlight of boxes/buttons

    // Header ("overhead")
    static let headerTop    = Color(hex: 0x53655B)
    static let headerBottom = Color(hex: 0x738678)
    static let headerLine   = Color(hex: 0x40504B)
    static let headerText   = Color(hex: 0xEAF2EE)
    static let headerMuted  = Color(hex: 0x9EB1A3)
    static let headerAccent = Color(hex: 0xBDD023)   // "Открытая коллекция изображений" yellow-green
    static let menu         = Color(hex: 0x3C4441)   // dropdown panels hanging off the header

    // Ink
    static let text         = Color(hex: 0x2C3635)
    static let muted        = Color(hex: 0x6B8678)   // "in Paintings", detail labels
    static let faint        = Color(hex: 0x8C9B8C)
    static let link         = Color(hex: 0x337287)
    static let linkHover    = Color(hex: 0x196BA7)
    static let selected     = Color(hex: 0xB35E33)   // current sidebar item ("Deviations")
    static let danger       = Color(hex: 0xB8412F)
    // Caution notes (uncommon formats): pale straw, like the site's "mature content" notices.
    static let warnBackground = Color(hex: 0xF6F1D2)
    static let warnBorder     = Color(hex: 0xD6C877)
    static let warnInk        = Color(hex: 0x7A5A00)
    static let accent       = link

    // Buttons (gmbutton2 / "Search Art")
    static let buttonTop    = Color(hex: 0xF4F7F3)
    static let buttonBottom = Color(hex: 0xDCE4DA)
    static let buttonBorder = Color(hex: 0x9EAD9E)
    static let goTop        = Color(hex: 0xF0F59C)
    static let goBottom     = Color(hex: 0xD6E35A)
    static let goBorder     = Color(hex: 0xA9B83E)
    static let goText       = Color(hex: 0x4E6117)

    // Tags: general = the site's link teal, meta = the header's olive-green, darkened for paper.
    static let general      = link
    static let meta         = Color(hex: 0x6A7F1C)
    static let tweetBackground = paper

    static func tagColor(_ kind: TagKind) -> Color { kind == .meta ? meta : general }
    static func kindName(_ kind: TagKind) -> String { kind == .meta ? "Мета" : "Обычные" }

    // MARK: Type (Verdana body, Trebuchet display — the 2011 site's own families)
    static let bodyFamily = "Verdana"
    static let displayFamily = "Trebuchet MS"

    // MARK: Layout
    static let headerHeight: CGFloat = 42
    static let sidebarWidth: CGFloat = 208
    static let detailSidebarWidth: CGFloat = 300
    static let cardRadius: CGFloat = 5
    static let fieldMaxWidth: CGFloat = 640   // readable line length for inputs / prose
    static let thumbBox: CGFloat = 150        // DA's 150px thumbnail box
    static let zoomSteps: [CGFloat] = [0.75, 0.85, 0.92, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7]
}

/// Spacing — 4pt base. Every gap in the app is one of these, chosen by what it separates:
///  xs  4  — a glyph and the thing it belongs to (tag ↔ ×, "in" ↔ category, row inner padding)
///  s   8  — items of one group: buttons in a row, heading ↔ its rule, lines of a key/value list
///  m   12 — rule ↔ the content it heads; elements inside a box
///  l   16 — padding inside every box; sibling boxes/rows; sidebar inset
///  xl  24 — page gutters (left, right, top); between sections; page header ↔ content
///  xxl 32 — between the two columns of a detail page; bottom of a scroll page
/// Plus two fixed metrics: `iconLabel` (icon ↔ its label) and `control` (height of every button/field).
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let iconLabel: CGFloat = 6
    static let control: CGFloat = 26
}

/// "1 group", "3 groups".
func plural(_ n: Int, _ word: String) -> String {
    let forms = ["tag": ["тег", "тега", "тегов"], "action": ["действие", "действия", "действий"],
                 "group": ["группа", "группы", "групп"], "crop": ["фрагмент", "фрагмента", "фрагментов"]]
    guard let words = forms[word] else { return "\(n) \(word)" }
    let index = (11...14).contains(n % 100) ? 2 : n % 10 == 1 ? 0 : (2...4).contains(n % 10) ? 1 : 2
    return "\(n) \(words[index])"
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

import MemebooruCore

/// Interface zoom (⌘+ / ⌘−). Multiplies every explicit font size and the thumbnail size.
private struct ZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues { var zoom: CGFloat { get { self[ZoomKey.self] } set { self[ZoomKey.self] = newValue } } }

/// Phone width (compact size class): one column, rows stacked instead of side by side.
private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var compactLayout: Bool { get { self[CompactLayoutKey.self] } set { self[CompactLayoutKey.self] = newValue } } }

extension View {
    /// Hand cursor on macOS (links, tags, thumbnails).
    func linkPointer() -> some View {
        #if os(macOS)
        return self.pointerStyle(.link)
        #else
        return self
        #endif
    }
    func pageBackground() -> some View { background(Theme.background.ignoresSafeArea()) }

    /// A "gruze" box: sage body, 1px border, a 1px light line along the top edge. No drop shadow —
    /// boxes sit flat on the page; only artwork casts shadows.
    func card(_ padding: CGFloat = Space.l) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.highlight).frame(height: 1).padding(.horizontal, Theme.cardRadius).padding(.top, 1)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border, lineWidth: 1))
    }

    /// The soft shadow DA put under every thumbnail and the full-size image.
    func thumbShadow() -> some View {
        self.compositingGroup().shadow(color: .black.opacity(0.32), radius: 2.5, x: 0, y: 1.5)
    }

    /// Sunken text field: paper fill, sage border, teal border while focused.
    func fieldChrome(focused: Bool = false) -> some View {
        self.padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .frame(minHeight: Space.control)   // same height as a button, so a field and a button sit flush in a row
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? Theme.link : Theme.border, lineWidth: 1))
    }
}

/// Zoom-aware font. Body text is Verdana; `display` switches to Trebuchet MS for headings.
struct ZFont: ViewModifier {
    @Environment(\.zoom) private var zoom
    let size: CGFloat; let weight: Font.Weight; let display: Bool
    func body(content: Content) -> some View {
        content.font(.custom(display ? Theme.displayFamily : Theme.bodyFamily, fixedSize: size * zoom).weight(weight))
    }
}
extension View {
    func zfont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View { modifier(ZFont(size: size, weight: weight, display: false)) }
    /// Trebuchet heading, tight tracking like the site's titles.
    func dfont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(ZFont(size: size, weight: weight, display: true)).kerning(size >= 20 ? -0.6 : 0)
    }
}

/// Text that behaves like a hyperlink: teal, darker blue + underline on hover, hand cursor.
struct LinkText: View {
    let text: String
    var color: Color = Theme.link
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(text).zfont(size, weight)
            .foregroundStyle(hover && color == Theme.link ? Theme.linkHover : color)
            .underline(hover).lineLimit(1).fixedSize()
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .linkPointer()
            .accessibilityAddTraits(.isButton)          // a link to VoiceOver and UI tests, not plain text
            .accessibilityAction { action() }
    }
}

/// Section heading ("Просмотр", "Подробности") — bold Tahoma-like, spaced, with the site's white emboss.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).zfont(12, .bold).kerning(0.6).foregroundStyle(Theme.text)
            .shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
    }
}

/// 1px rule with a 1px highlight under it — the site's section divider.
struct Rule: View {
    var body: some View {
        VStack(spacing: 0) { Theme.rule.frame(height: 1); Theme.ruleLight.frame(height: 1) }
    }
}

/// Labeled input.
struct Field: View {
    let title: String
    @Binding var text: String
    var lines: Int = 1
    var tint: Color = Theme.text     // tag fields color their text by kind
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).zfont(11, .bold).foregroundStyle(Theme.muted)
            TextField("", text: $text, axis: .vertical).lineLimit(lines...).textFieldStyle(.plain).zfont(13)
                .foregroundStyle(tint)
                .focused($focused)
                .fieldChrome(focused: focused)
                .onSubmit(onCommit)
        }
        .frame(maxWidth: Theme.fieldMaxWidth, alignment: .leading)
    }
}

/// Page heading row: Trebuchet title + muted count + trailing controls, then a rule.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.m) { titleRow; Spacer(minLength: Space.l); HStack(spacing: Space.s) { trailing } }
                VStack(alignment: .leading, spacing: Space.m) { titleRow; HStack(spacing: Space.s) { trailing } }
            }
            Rule()
        }
        // Pages stack items 16 apart; the header adds 8 so page content always starts a full section
        // gap (24) under the rule — on every page, gallery included.
        .padding(.bottom, Space.s)
    }
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title).dfont(24).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                .shadow(color: .white.opacity(0.7), radius: 0, x: 0, y: 1)
                .accessibilityIdentifier("pageTitle")
            if let subtitle { Text(subtitle).zfont(12).foregroundStyle(Theme.muted).lineLimit(1).fixedSize().accessibilityIdentifier("pageSubtitle") }
        }
    }
}

extension View {
    /// The one page frame: 24 left/right/top (so the page title lines up with "Просмотр" in the sidebar),
    /// 32 at the bottom so the last row never sits on the window edge.
    /// On a phone the sides drop to 16, so cards keep their width.
    func pageInsets() -> some View { modifier(PageInsets()) }
}

private struct PageInsets: ViewModifier {
    @Environment(\.compactLayout) private var compact
    func body(content: Content) -> some View {
        content.padding(.horizontal, compact ? Space.l : Space.xl).padding(.top, compact ? Space.l : Space.xl).padding(.bottom, Space.xxl)
    }
}

/// A titled block: Trebuchet heading (+ optional trailing control), rule 8 below it, content 12 below
/// the rule. Used for every section on the post page so they all share one rhythm.
struct SectionBlock<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(title).dfont(16, .regular).foregroundStyle(Theme.text)
                Spacer(minLength: Space.s)
                trailing
            }
            Rule().padding(.top, Space.s)
            VStack(alignment: .leading, spacing: Space.s) { content }.padding(.top, Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension SectionBlock where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = EmptyView(); self.content = content()
    }
}

/// Scrolling main column for non-gallery pages.
struct PageColumn<Content: View>: View {
    var spacing: CGFloat = Space.l
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            // Lazy so pages with many heavy rows (Duplicates, History) only build what's on screen.
            LazyVStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pageInsets()
        }
        .pageBackground()
    }
}

/// Button kinds: normal (light sage gradient), prominent (the yellow-green "Search Art" button),
/// danger (normal chrome, red ink).
enum SoftKind { case normal, prominent, danger }

struct SoftButtonStyle: ButtonStyle {
    let kind: SoftKind
    var hover: Bool = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && enabled
        let top = kind == .prominent ? Theme.goTop : Theme.buttonTop
        let bottom = kind == .prominent ? Theme.goBottom : Theme.buttonBottom
        return configuration.label
            .padding(.horizontal, Space.m)
            .frame(height: Space.control)
            .foregroundStyle(enabled ? fg : Theme.faint)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: pressed ? [bottom, top] : [top, bottom], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(enabled && !pressed ? 0.12 : 0), radius: 0, x: 0, y: 1)
            .opacity(enabled ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 4))
    }
    private var fg: Color {
        switch kind {
        case .normal:    return hover ? Theme.linkHover : Theme.text
        case .prominent: return Theme.goText
        case .danger:    return Theme.danger
        }
    }
    private var border: Color {
        switch kind {
        case .prominent: return Theme.goBorder
        case .danger:    return hover ? Theme.danger.opacity(0.6) : Theme.buttonBorder
        case .normal:    return hover ? Theme.faint : Theme.buttonBorder
        }
    }
}

/// Text button that never wraps.
struct GlassButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    private var kind: SoftKind { tint == Theme.danger ? .danger : (prominent ? .prominent : .normal) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.iconLabel) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }.zfont(12).lineLimit(1).fixedSize()
        }
        .buttonStyle(SoftButtonStyle(kind: kind, hover: hover))
        .onHover { hover = $0 }
        .linkPointer()
    }
}

/// Icon (optionally + label) button.
struct GlassIconButton: View {
    let symbol: String
    var label: String? = nil
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    private var kind: SoftKind { tint == Theme.danger ? .danger : .normal }
    var body: some View {
        Button(action: action) {
            if let label {
                HStack(spacing: Space.iconLabel) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    Text(label)
                }.zfont(12).lineLimit(1).fixedSize()
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(height: 15)
            }
        }
        .buttonStyle(SoftButtonStyle(kind: kind, hover: hover))
        .onHover { hover = $0 }
        .linkPointer()
    }
}
