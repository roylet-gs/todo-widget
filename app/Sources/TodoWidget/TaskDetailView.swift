import SwiftUI

struct TaskDetailView: View {
    let model: AppModel
    let prefs: Preferences
    let controller: DrawerController
    let task: TodoTask

    @State private var editing = false
    @State private var title = ""
    @State private var priority: UInt8 = 2
    @State private var due = ""

    private var rank: Int? { model.open.firstIndex { $0.id == task.id }.map { $0 + 1 } }
    private var history: [ChangeEvent] { (try? model.store.taskHistory(id: task.id)) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.select(nil) } label: {
                    HStack(spacing: 6) {
                        Label("Today", systemImage: "chevron.left").font(.callout.weight(.semibold))
                        if prefs.showKeyHints { KeyCap(prefs.key(.back).display) }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .keyHelp(prefs, "Back to the list", .back)
                Spacer()
                if let rank { Text("#\(rank) of \(model.open.count)").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editing { editor } else { titleBlock }
                    if let s = task.summary { section("Summary") { Text(s).textSelection(.enabled) } }
                    if let r = task.rationale {
                        section("Why it's ranked here") { Text(r) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                    }
                    if task.sourceUrl != nil || task.excerpt != nil { original }
                    if !history.isEmpty {
                        section("History") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(history, id: \.id) { e in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(clockTime(e.ts)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                        Text(describe(e)).font(.caption).strikethrough(e.undone)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.toggleDone(task) } label: {
                        HStack(spacing: 6) {
                            Text(task.isDone ? "Reopen" : "Mark done")
                            if prefs.showKeyHints { KeyCap(prefs.key(.toggleDone).display, onAccent: true) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .keyHelp(prefs, task.isDone ? "Reopen" : "Mark done", .toggleDone)
                    Button {
                        if editing { save() } else { startEdit() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(editing ? "Save" : "Edit")
                            if prefs.showKeyHints { KeyCap(prefs.key(editing ? .save : .edit).display) }
                        }
                    }
                    .glassButton()
                    .keyHelp(prefs, editing ? "Save" : "Edit", editing ? .save : .edit)
                    Button(role: .destructive) { model.delete(task) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            if prefs.showKeyHints { KeyCap(prefs.key(.delete).display) }
                        }
                    }
                    .glassButton()
                    .keyHelp(prefs, "Delete", .delete)
                    .accessibilityLabel("Delete")
                }
                .controlSize(.large)
            }
            .padding(14)
        }
        .onChange(of: model.wantsEdit) { _, w in
            guard w else { return }
            model.wantsEdit = false
            if !editing { startEdit() }
        }
        .onChange(of: model.wantsSave) { _, w in
            guard w else { return }
            model.wantsSave = false
            if editing { save() }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(.system(size: 18, weight: .bold)).textSelection(.enabled)
            FlowChips(items: chips)
        }
    }

    private var chips: [(String, Color?)] {
        var c: [(String, Color?)] = [("P\(task.priority)", Palette.priority(task.priority))]
        if let s = task.source { c.append((s, nil)) }
        if let d = task.due { c.append(("Due \(d)", nil)) }
        c.append(("Added by \(task.addedBy)", nil))
        if task.userRankedAt != nil { c.append(("Placed by you", nil)) }
        return c
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title, axis: .vertical).textFieldStyle(.roundedBorder)
            Picker("Priority", selection: $priority) {
                Text("P1").tag(UInt8(1)); Text("P2").tag(UInt8(2)); Text("P3").tag(UInt8(3))
            }
            .pickerStyle(.segmented)
            TextField("Due (e.g. Thu, 2026-10-20)", text: $due).textFieldStyle(.roundedBorder)
        }
        .onAppear { controller.engage() }
    }

    private var original: some View {
        section("Original") {
            VStack(alignment: .leading, spacing: 8) {
                if let ex = task.excerpt {
                    VStack(alignment: .leading, spacing: 4) {
                        if let from = task.sourceFrom { Text(from).font(.caption).foregroundStyle(.secondary) }
                        Text(ex).textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 16))
                }
                if let s = task.sourceUrl, let url = URL(string: s) {
                    Link(destination: url) {
                        Label("Open in \(task.source ?? "source")", systemImage: "arrow.up.right").font(.callout.weight(.semibold))
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            content().font(.callout)
        }
    }

    private func describe(_ e: ChangeEvent) -> String {
        let verb = switch e.op {
        case "create": "added"
        case "update": "edited"
        case "done": "marked done"
        case "reopen": "reopened"
        case "reorder": "re-ranked"
        case "move": "moved"
        case "archive": "cleared"
        case "delete": "deleted"
        default: e.op
        }
        return "\(e.actor) \(verb)" + (e.reason.map { ": \($0)" } ?? "")
    }

    private func startEdit() {
        title = task.title
        priority = task.priority
        due = task.due ?? ""
        editing = true
    }

    private func save() {
        model.update(task, patch: TaskPatch(title: title, priority: priority, due: due, summary: nil, rationale: nil, source: nil, sourceUrl: nil, excerpt: nil, sourceFrom: nil))
        editing = false
    }
}

/// Simple wrapping row of chips.
struct FlowChips: View {
    let items: [(String, Color?)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(.caption2.weight(item.1 == nil ? .regular : .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .foregroundStyle(item.1 == nil ? Color.primary : Color.white)
                    .background(item.1 ?? Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
