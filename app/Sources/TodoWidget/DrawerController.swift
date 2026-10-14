import AppKit
import SwiftUI

/// A borderless, non-activating panel that can still take keyboard focus (for quick add).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the collapsed tab (draggable, always snapped to the left or right screen edge)
/// and the drawer that slides out from whichever edge the tab is on.
@MainActor
@Observable
final class DrawerController {
    private let model: AppModel
    private let prefs: Preferences
    private let tabPanel: FloatingPanel
    private let drawerPanel: FloatingPanel
    private(set) var isOpen = false
    /// True while the tab is being dragged (the view uses it to suppress the open click).
    private(set) var isDraggingTab = false
    private var dragOffset: NSPoint?
    private var clickMonitors: [Any] = []
    @ObservationIgnored private(set) lazy var keys = DrawerKeys(model: model, prefs: prefs, controller: self)
    /// E2E: a synthetic pointer location used instead of the real mouse while dragging.
    var simulatedMouse: NSPoint?
    private var currentMouse: NSPoint { simulatedMouse ?? NSEvent.mouseLocation }

    static let tabSize = NSSize(width: 38, height: 84)
    static let defaultDrawerWidth: CGFloat = 400
    static let minDrawerWidth: CGFloat = 340
    private static let maxDrawerWidth: CGFloat = 900
    private static let edgeInset: CGFloat = 10

    init(model: AppModel, prefs: Preferences, updater: Updater) {
        self.model = model
        self.prefs = prefs
        tabPanel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.tabSize))
        drawerPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.defaultDrawerWidth, height: 600))
        tabPanel.contentView = NSHostingView(rootView: EdgeTabView(model: model, prefs: prefs, controller: self))
        drawerPanel.contentView = NSHostingView(rootView: DrawerView(model: model, prefs: prefs, updater: updater, controller: self))
        applyPrefs()
        tabPanel.orderFrontRegardless()
        observePrefs()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    private func observePrefs() {
        withObservationTracking {
            _ = prefs.windowLevel
            _ = prefs.edge
            _ = prefs.drawerWidth
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyPrefs()
                    self?.observePrefs()
                }
            }
        }
    }

    func applyPrefs() {
        for p in [tabPanel, drawerPanel] {
            p.level = prefs.windowLevel.level
            p.collectionBehavior = prefs.windowLevel == .desktop
                ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
                : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
        layout()
    }

    // MARK: geometry

    /// The screen the tab lives on (remembered by display id), falling back to the main screen.
    private var screen: NSScreen {
        NSScreen.screens.first { $0.displayID == prefs.tabDisplay } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func tabFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let s = Self.tabSize
        let x = prefs.edge == .right ? vf.maxX - s.width : vf.minX
        let travel = max(0, vf.height - s.height)
        let y = vf.minY + travel * min(max(prefs.tabY, 0), 1)
        return NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func layout() {
        tabPanel.setFrame(tabFrame(on: screen), display: true)
        drawerPanel.setFrame(drawerFrame(open: isOpen), display: true)
    }

    private func drawerFrame(open: Bool) -> NSRect {
        let vf = screen.visibleFrame
        let w = liveWidth ?? clampedWidth(prefs.drawerWidth)
        let right = prefs.edge == .right
        let shownX = right ? vf.maxX - w - Self.edgeInset : vf.minX + Self.edgeInset
        let hiddenX = right ? vf.maxX + 4 : vf.minX - w - 4
        return NSRect(x: open ? shownX : hiddenX, y: vf.minY + 12, width: w, height: vf.height - 24)
    }

    /// Keep the drawer between its minimum and most of the screen.
    private func clampedWidth(_ w: Double) -> CGFloat {
        let maxW = min(Self.maxDrawerWidth, screen.visibleFrame.width * 0.7)
        return min(max(CGFloat(w), Self.minDrawerWidth), max(Self.minDrawerWidth, maxW))
    }

    // MARK: resizing the drawer

    /// Width while the inner edge is being dragged (saved to prefs when the drag ends).
    private var liveWidth: CGFloat?
    private var resizeStart: (mouse: NSPoint, width: CGFloat)?

    /// Follow the pointer while the drawer's inner edge is dragged (screen coordinates, since
    /// the window's origin moves with it when docked on the right).
    func resizeDrawer() {
        let mouse = currentMouse
        if resizeStart == nil { resizeStart = (mouse, drawerPanel.frame.width) }
        guard let start = resizeStart else { return }
        let dx = mouse.x - start.mouse.x
        liveWidth = clampedWidth(Double(start.width + (prefs.edge == .right ? -dx : dx)))
        drawerPanel.setFrame(drawerFrame(open: true), display: true)
    }

    func endResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        if let w = liveWidth { prefs.drawerWidth = Double(w) }
        liveWidth = nil
        layout()
    }

    // MARK: dragging the tab

    /// Pulling the tab off its edge is sticky: it resists (moves a fraction of the pointer) until
    /// the pointer has moved `breakDistance`, then pops free and quickly catches up.
    static let breakDistance: CGFloat = 12
    private static let stickResistance: CGFloat = 0.35

    /// True once the tab has broken free of the edge during a drag (the view rounds all corners).
    private(set) var isFree = false
    private var dragStartMouse: NSPoint = .zero
    /// Offset left over when it snaps off; decays to zero so the tab catches up with the pointer.
    private var lag: NSPoint = .zero
    private var catchUpTimer: Timer?

    /// Follow the pointer while dragging (screen coordinates, so the moving window doesn't skew it).
    func dragTab() {
        let mouse = currentMouse
        if dragOffset == nil {
            let f = tabPanel.frame
            dragOffset = NSPoint(x: mouse.x - f.minX, y: mouse.y - f.minY)
            dragStartMouse = mouse
            lag = .zero
            isFree = false
            isDraggingTab = true
        }
        var dx = mouse.x - dragStartMouse.x
        var dy = mouse.y - dragStartMouse.y
        if !isFree {
            if hypot(dx, dy) < Self.breakDistance {
                dx *= Self.stickResistance
                dy *= Self.stickResistance
            } else {
                isFree = true
                lag = NSPoint(x: dx * Self.stickResistance - dx, y: dy * Self.stickResistance - dy)
                startCatchUp()
            }
        }
        if isFree {
            dx += lag.x
            dy += lag.y
        }
        moveTab(dx: dx, dy: dy)
    }

    private func moveTab(dx: CGFloat, dy: CGFloat) {
        guard let off = dragOffset else { return }
        tabPanel.setFrameOrigin(NSPoint(x: dragStartMouse.x - off.x + dx, y: dragStartMouse.y - off.y + dy))
    }

    /// Quick exponential catch-up after snapping off (the "pop").
    private func startCatchUp() {
        catchUpTimer?.invalidate()
        catchUpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.dragOffset != nil else { self.catchUpTimer?.invalidate(); return }
                self.lag = NSPoint(x: self.lag.x * 0.7, y: self.lag.y * 0.7)
                if abs(self.lag.x) < 0.3 && abs(self.lag.y) < 0.3 {
                    self.lag = .zero
                    self.catchUpTimer?.invalidate()
                }
                let m = self.currentMouse
                self.moveTab(dx: m.x - self.dragStartMouse.x + self.lag.x, dy: m.y - self.dragStartMouse.y + self.lag.y)
            }
        }
    }

    /// Snap to the nearest left/right edge of the screen the tab was dropped on, and remember it.
    /// Released before breaking free: it settles back where it was.
    func endTabDrag() {
        catchUpTimer?.invalidate()
        dragOffset = nil
        let wasFree = isFree
        let f = tabPanel.frame
        let center = NSPoint(x: f.midX, y: f.midY)
        let target = wasFree ? (NSScreen.screens.first { $0.frame.contains(center) } ?? screen) : screen
        let vf = target.visibleFrame
        let side: Edge = wasFree ? (center.x < vf.midX ? .left : .right) : prefs.edge
        let travel = max(1, vf.height - Self.tabSize.height)
        let tabY = wasFree ? Double(min(max((f.minY - vf.minY) / travel, 0), 1)) : prefs.tabY
        let x = side == .right ? vf.maxX - Self.tabSize.width : vf.minX
        let snapped = NSRect(x: x, y: vf.minY + travel * tabY, width: Self.tabSize.width, height: Self.tabSize.height)
        let displayID = target.displayID

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tabPanel.animator().setFrame(snapped, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Landed: flatten against the edge and remember where it is.
                self.isFree = false
                self.isDraggingTab = false
                self.prefs.tabDisplay = displayID
                self.prefs.tabY = tabY
                self.prefs.edge = side
                self.layout()
            }
        })
    }

    // MARK: open / close

    func open() {
        guard !isOpen, !isDraggingTab else { return }
        isOpen = true
        model.archiveIfNeeded()
        model.reload()
        drawerPanel.setFrame(drawerFrame(open: false), display: false)
        drawerPanel.alphaValue = 0
        drawerPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drawerPanel.animator().setFrame(drawerFrame(open: true), display: true)
            drawerPanel.animator().alphaValue = 1
            tabPanel.animator().alphaValue = 0
        }
        drawerPanel.makeKey()
        installClickAway()
        keys.install(for: drawerPanel)
        model.ensureHighlight()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeClickAway()
        keys.remove()
        model.selectedId = nil
        model.showShortcuts = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            drawerPanel.animator().setFrame(drawerFrame(open: false), display: true)
            drawerPanel.animator().alphaValue = 0
            tabPanel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.drawerPanel.orderOut(nil)
            }
        })
    }

    func toggle() { isOpen ? close() : open() }

    /// Give the drawer keyboard focus (e.g. when typing in quick add or editing).
    func engage() {
        drawerPanel.makeKey()
    }

    /// A text field in the drawer is being edited (its field editor is first responder).
    var firstResponderIsText: Bool { drawerPanel.firstResponder is NSText }

    /// Leave the text field being edited, so plain keys go back to the list.
    func endTyping() {
        drawerPanel.makeFirstResponder(nil)
    }

    /// When unpinned, a click anywhere outside the drawer (other apps, the desktop, or our
    /// own settings window) collapses it. Global mouse monitors need no extra permission.
    private func installClickAway() {
        removeClickAway()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.drawerPanel || event.window === self.tabPanel { return }
                self.handleOutsideClick()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            handler(event)
            return event
        }) {
            clickMonitors.append(l)
        }
    }

    /// A click landed outside the drawer: collapse it unless pinned.
    func handleOutsideClick() {
        guard isOpen, !prefs.pinned else { return }
        close()
    }

    // E2E inspection
    var tabFrame: NSRect { tabPanel.frame }
    var drawerFrameNow: NSRect { drawerPanel.frame }
    var screenVisibleFrame: NSRect { screen.visibleFrame }
    var windowNumbers: [String: Int] {
        ["tab": tabPanel.windowNumber, "drawer": drawerPanel.isVisible ? drawerPanel.windowNumber : 0]
    }
    func panel(_ name: String) -> NSPanel? { name == "tab" ? tabPanel : name == "drawer" ? drawerPanel : nil }

    private func removeClickAway() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    /// Content views for debug snapshots.
    var snapshotTargets: [(String, NSView)] {
        [("tab", tabPanel.contentView), ("drawer", drawerPanel.contentView)].compactMap { name, v in v.map { (name, $0) } }
    }
}

extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}
