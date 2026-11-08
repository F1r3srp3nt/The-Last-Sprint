import SwiftUI
import AppKit

// Appearance, window chrome and control styles shared by the Oslo Sprint products. Original code
// written for these apps. The same file is kept in each product so both stay independently
// buildable; keep the copies identical when changing either.

// MARK: - Appearance

/// The user's appearance choice. Futuristic is the default for new and migrated installations.
enum DSAppearance: String, CaseIterable, Identifiable {
    /// Dark navy theme with the technical grid and restrained glow.
    case futuristic = "Futuristic"
    /// The same dark palette without grid or glow.
    case dark = "Dark"
    case light = "Light"
    /// Follows macOS (dark palette in Dark Mode, light palette in Light Mode), without decoration.
    case system = "System"

    var id: String { rawValue }

    static let storageKey = "appearance"
    /// Set once the one-time move to the Futuristic default has run.
    static let migrationKey = "appearance.futuristicDefault.v1"

    var title: String {
        switch self {
        case .futuristic: return "Futuristic"
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match System"
        }
    }

    var detail: String {
        switch self {
        case .futuristic: return "Deep navy with a technical grid and cyan accents. The default."
        case .dark: return "The same dark palette, without the grid or glow."
        case .light: return "Light palette for bright rooms."
        case .system: return "Follows macOS: the dark palette in Dark Mode, the light palette in Light Mode."
        }
    }

    /// The AppKit appearance to force, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .futuristic, .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    /// Grid and glow are part of the Futuristic look only.
    var decorated: Bool { self == .futuristic }

    static func resolve(_ raw: String?) -> DSAppearance {
        raw.flatMap(DSAppearance.init(rawValue:)) ?? .futuristic
    }

    static var stored: DSAppearance { resolve(UserDefaults.standard.string(forKey: storageKey)) }

    /// One-time migration. Installations that never chose, or that had "Match System" (the earlier
    /// default), move to Futuristic. An explicit Dark or Light choice is kept. After this has run, a
    /// later explicit "Match System" choice is respected.
    static func migrateStoredPreference(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let stored = defaults.string(forKey: storageKey)
        if stored == nil || stored == DSAppearance.system.rawValue || DSAppearance(rawValue: stored ?? "") == nil {
            defaults.set(DSAppearance.futuristic.rawValue, forKey: storageKey)
        }
        defaults.set(true, forKey: migrationKey)
    }

    /// Applies the choice to the whole app (windows, sheets, alerts, menus and native controls).
    @MainActor static func apply(_ appearance: DSAppearance) {
        NSApplication.shared.appearance = appearance.nsAppearance
    }
}

private struct DSDecoratedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether decorative grid and glow are shown (Futuristic appearance only).
    var dsDecorated: Bool {
        get { self[DSDecoratedKey.self] }
        set { self[DSDecoratedKey.self] = newValue }
    }
}

extension View {
    /// Root modifier: applies the appearance to AppKit and the decoration flag to SwiftUI, and paints
    /// the native window background with the canvas colour so no grey window or title-bar shows.
    func dsAppearance(_ appearance: DSAppearance) -> some View {
        self
            .environment(\.dsDecorated, appearance.decorated)
            .background(DSWindowChrome())
            .onAppear { DSAppearance.apply(appearance) }
            .onChange(of: appearance) { _, newValue in DSAppearance.apply(newValue) }
    }
}

/// Configures the hosting NSWindow: canvas-coloured background and a transparent title bar, so the
/// themed content (not the grey system window colour) is what shows behind the toolbar. Window
/// controls, resizing and full-screen stay native.
struct DSWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.configure()
    }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let window else { return }
            window.backgroundColor = DS.canvasNSColor
            window.titlebarAppearsTransparent = true
        }
    }
}

// MARK: - Glow

extension View {
    /// Restrained cyan glow for an active element's shape (selected row, focused field, primary
    /// action). Apply it to backgrounds and borders, never to body text. Off unless the Futuristic
    /// appearance is on, and off with Increase Contrast.
    func dsGlow(_ active: Bool, tone: Color = DS.accent) -> some View {
        modifier(DSGlowModifier(active: active, tone: tone))
    }
}

private struct DSGlowModifier: ViewModifier {
    let active: Bool
    let tone: Color
    @Environment(\.dsDecorated) private var decorated
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let on = active && decorated && contrast != .increased
        content.shadow(color: tone.opacity(on ? 0.38 : 0), radius: on ? 7 : 0)
    }
}

// MARK: - Secondary buttons

/// Secondary action: raised navy fill, fine cyan border, light text. Keyboard focus rings are drawn
/// by the system.
struct DSSecondaryButtonStyle: ButtonStyle {
    var tone: DSTone = .accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        // Destructive buttons keep a red reading whatever tone the style was given.
        let tone: DSTone = configuration.role == .destructive ? .danger : self.tone
        return configuration.label
            .font(.system(size: controlSize == .large ? 14 : (controlSize == .small ? 12 : 13), weight: .medium))
            .foregroundStyle(tone == .accent ? DS.textPrimary : tone.color)
            .padding(.horizontal, controlSize == .small ? 8 : 12)
            .padding(.vertical, controlSize == .large ? 7 : (controlSize == .small ? 2 : 4))
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(configuration.isPressed ? tone.color.opacity(0.20) : DS.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(tone.color.opacity(contrast == .increased ? 0.9 : (configuration.isPressed ? 0.7 : 0.38)),
                              lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}

// MARK: - Text fields

/// Single-line fields on a sunken navy background with a fine border that turns cyan (with a
/// restrained glow) while the field has keyboard focus. Text editing, selection, undo and the
/// field's accessibility are the native ones.
///
/// Use it on fields that do not also bind `.focused(...)` themselves.
struct DSTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        DSTextFieldBox(field: configuration)
    }
}

private struct DSTextFieldBox<Field: View>: View {
    let field: Field
    @FocusState private var focused: Bool

    var body: some View {
        field
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(DS.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .dsFieldChrome(focused: focused, radius: DS.Radius.control)
    }
}

extension TextFieldStyle where Self == DSTextFieldStyle {
    static var ds: DSTextFieldStyle { DSTextFieldStyle() }
}

// MARK: - Sheets and lists

extension View {
    /// Root of a sheet: themed canvas, panels, buttons and fields (the sheet frame stays native).
    func dsSheetContent() -> some View {
        self
            .groupBoxStyle(DSPanelGroupBoxStyle())
            .buttonStyle(.dsSecondary)
            .textFieldStyle(.ds)
            .tint(DS.accent)
            .background(DSBackground())
    }

    /// Lists drawn on the themed canvas: no opaque list background, transparent rows.
    func dsListBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}
