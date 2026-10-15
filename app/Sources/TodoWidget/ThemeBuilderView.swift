import SwiftUI

// MARK: - Picker (onboarding and Settings › Themes)

/// A grid of theme cards; tapping one switches to it.
struct ThemePicker: View {
    let prefs: Preferences
    var onSelect: (Theme) -> Void = { _ in }
    /// Shows a "New theme" tile when set.
    var onNew: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)], spacing: 12) {
            ForEach(prefs.allThemes) { t in
                let selected = prefs.themeID == t.id
                Button {
                    withAnimation(.snappy) { prefs.selectTheme(t) }
                    onSelect(t)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ThemePreview(theme: t)
                            .frame(height: 84)
                            .overlay(alignment: .topTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white, t.accent)
                                        .padding(6)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? t.accent : Color.secondary.opacity(0.25),
                                                                                      lineWidth: selected ? 2 : 1))
                        Text(t.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(t.name) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if let onNew {
                Button(action: onNew) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(height: 84)
                            .overlay { Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary) }
                        Text("New theme").font(.callout).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A miniature drawer painted in a theme's colors.
struct ThemePreview: View {
    let accent: Color
    let background: Color
    let text: Color
    let priority: Color
    let done: Color
    var large = false

    /// Follows the current appearance, like the real drawer.
    init(theme t: Theme) {
        accent = t.accent
        background = t.background ?? Color(nsColor: .windowBackgroundColor)
        text = t.text ?? .primary
        priority = t.priority
        done = t.done
    }

    /// One palette, regardless of the current appearance (the builder's preview).
    init(colors c: ThemeColors, dark: Bool, large: Bool) {
        func color(_ r: ThemeColors.Role) -> Color { Color(nsColor: c.nsColor(r, dark: dark)) }
        accent = color(.accent)
        background = color(.background)
        text = color(.text)
        priority = color(.priority)
        done = color(.done)
        self.large = large
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 4 : 5) {
            if large {
                Text("Today").font(.system(size: 17, weight: .bold)).padding(.bottom, 4)
            }
            row(bar: priority, title: "Reply to the design review", unread: true)
            row(bar: accent, title: "Draft the release notes", unread: false, chip: true)
            row(bar: nil, title: "Book flights for the offsite", unread: false, isDone: true)
            if large {
                HStack {
                    Spacer()
                    Text("Undo").font(.caption.weight(.semibold)).foregroundStyle(accent)
                }
                .padding(.top, 4)
            }
        }
        .foregroundStyle(text)
        .padding(large ? 16 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: .rect(cornerRadius: large ? 18 : 12))
        .accessibilityHidden(true)
    }

    private func row(bar: Color?, title: String, unread: Bool, chip: Bool = false, isDone: Bool = false) -> some View {
        let s: CGFloat = large ? 1 : 0.55
        return HStack(spacing: 7 * s) {
            ZStack {
                Circle().strokeBorder(text.opacity(isDone ? 0.3 : 0.55), lineWidth: 1.5 * s)
                if isDone { Circle().fill(done.opacity(0.32)) }
            }
            .frame(width: 18 * s, height: 18 * s)
            if let bar { Capsule().fill(bar).frame(width: 4 * s, height: 22 * s) }
            if large {
                Text(title).font(.system(size: 13, weight: unread ? .semibold : .regular))
                    .strikethrough(isDone).opacity(isDone ? 0.55 : 1).lineLimit(1)
            } else {
                Capsule().fill(text.opacity(isDone ? 0.3 : 0.75)).frame(height: 4)
            }
            Spacer(minLength: 4)
            if chip {
                Text("new").font(.system(size: 10 * s, weight: .semibold))
                    .padding(.horizontal, 6 * s).padding(.vertical, 1)
                    .background(accent.opacity(0.18), in: Capsule()).foregroundStyle(accent)
            }
            if unread { Circle().fill(accent).frame(width: 8 * s, height: 8 * s) }
        }
        .padding(.horizontal, 6 * s).padding(.vertical, 5 * s)
        .background(unread ? text.opacity(0.08) : .clear, in: .rect(cornerRadius: 10 * s))
    }
}

// MARK: - Settings › Themes

struct ThemesPane: View {
    @Bindable var prefs: Preferences
    /// The custom theme being edited (unsaved changes live here until Save).
    @State private var draft: Theme?

    init(prefs: Preferences) {
        self.prefs = prefs
        _draft = State(initialValue: prefs.theme.isBuiltIn ? nil : prefs.theme)
    }

    var body: some View {
        PaneHeader(title: "Themes", subtitle: "Colors for the drawer, the tab and these windows. Pick one, or build your own.")
        Card {
            ThemePicker(prefs: prefs, onSelect: { t in draft = t.isBuiltIn ? nil : t }, onNew: startNew)
                .padding(16)
            Divider()
            CardRow(title: "Appearance", detail: "Light, dark, or follow macOS.") {
                Picker("", selection: $prefs.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 240).labelsHidden()
            }
        }
        if let d = draft {
            ThemeBuilder(theme: Binding(get: { draft ?? d }, set: { draft = $0 }),
                         saved: prefs.customThemes.first { $0.id == d.id },
                         onSave: save, onDelete: delete, onDiscard: discard)
                .id(d.id)
        } else {
            Card {
                CardRow(title: "Make it yours", detail: "Built-in themes can't be edited. Duplicate \(prefs.theme.name) to start a theme of your own.") {
                    Button("Duplicate \(prefs.theme.name)") { draft = prefs.theme.duplicate(named: "\(prefs.theme.name) copy") }
                        .glassButton()
                }
            }
        }
    }

    private func startNew() {
        draft = prefs.theme.duplicate(named: "My theme")
    }

    private func save() {
        guard let d = draft else { return }
        prefs.saveCustomTheme(d)
        prefs.selectTheme(d)
    }

    private func delete() {
        guard let d = draft else { return }
        prefs.deleteCustomTheme(id: d.id)
        draft = nil
    }

    private func discard() {
        guard let d = draft else { return }
        draft = prefs.customThemes.first { $0.id == d.id }
    }
}

struct ThemeBuilder: View {
    @Binding var theme: Theme
    /// The stored version, or `nil` for a theme that hasn't been saved yet.
    let saved: Theme?
    let onSave: () -> Void
    let onDelete: () -> Void
    let onDiscard: () -> Void
    @State private var editDark = NSApp?.effectiveAppearance.isDark ?? false
    @State private var confirmDelete = false

    private var palette: WritableKeyPath<Theme, ThemeColors> { editDark ? \.dark : \.light }
    private var colors: ThemeColors { theme[keyPath: palette] }
    private var dirty: Bool { saved != theme }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    TextField("Theme name", text: $theme.name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    if saved == nil { Text("Not saved").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Picker("", selection: $editDark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                    .help("Which palette you're editing")
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(ThemeColors.Role.allCases) { roleRow($0) }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        ThemePreview(colors: colors, dark: editDark, large: true).frame(height: 190)
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 280)
                }
                HStack {
                    Text("Switch appearance to").fontWeight(.semibold)
                    Picker("", selection: Binding(get: { theme.appearance?.rawValue ?? "" },
                                                  set: { theme.appearance = Appearance(rawValue: $0) })) {
                        Text("Don't switch").tag("")
                        Text("Light").tag(Appearance.light.rawValue)
                        Text("Dark").tag(Appearance.dark.rawValue)
                    }
                    .labelsHidden().frame(width: 140)
                    Spacer()
                }
                Divider()
                HStack {
                    if saved != nil {
                        Button("Delete", role: .destructive) { confirmDelete = true }.glassButton()
                    }
                    Spacer()
                    Button(saved == nil ? "Cancel" : "Discard changes", action: onDiscard).glassButton().disabled(saved != nil && !dirty)
                    Button("Save theme", action: onSave).glassButton(prominent: true)
                        .disabled(!dirty || theme.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
        .confirmationDialog("Delete \(theme.name)?", isPresented: $confirmDelete) {
            Button("Delete theme", role: .destructive, action: onDelete)
        }
    }

    private func roleRow(_ role: ThemeColors.Role) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(role.label).fontWeight(.semibold)
                Text(colors[role] == nil ? "System default" : role.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if colors[role] != nil {
                Button { theme[keyPath: palette][role] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Use the system default")
                    .accessibilityLabel("Reset \(role.label)")
            }
            ColorPicker(role.label, selection: Binding(
                get: { Color(nsColor: colors.nsColor(role, dark: editDark)) },
                set: { theme[keyPath: palette][role] = NSColor($0).hex }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        .padding(.vertical, 7)
    }

    private var warnings: [String] {
        let bg = colors.nsColor(.background, dark: editDark)
        var w: [String] = []
        let text = Contrast.ratio(colors.nsColor(.text, dark: editDark), bg)
        if text < 4.5 { w.append(String(format: "Text is hard to read on this background (%.1f:1, aim for 4.5:1).", text)) }
        let accent = colors.nsColor(.accent, dark: editDark)
        if Contrast.ratio(accent, bg) < 3 { w.append("The accent is hard to see on this background.") }
        if Contrast.ratio(.white, accent) < 3 { w.append("White labels on the accent (like the unread badge) are hard to read.") }
        return w
    }
}
