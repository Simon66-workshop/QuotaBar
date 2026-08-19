import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class QuotaBarApp: NSObject, NSApplicationDelegate {
    private static var retained: QuotaBarApp?

    private var statusItem: NSStatusItem?
    private var panel: GlassPanel?
    private var panelHost: ClearHosting<AnyView>?
    private var store: UsageStore?
    private var titleWatch: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastBarToggle = Date.distantPast
    private var lastTitle = ""
    private var barActionAt = Date.distantPast

    private static let panelWidth: CGFloat = 360

    static func main() {
        let app = NSApplication.shared
        let delegate = QuotaBarApp()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        store.onWillOpenBrowser = { [weak self] in
            self?.hidePanel()
            // Safari taking focus often kills NSStatusItem.button.action.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.rebuildStatusItem()
            }
        }
        store.onLoginFinished = { [weak self] in
            self?.hidePanel()
            self?.rebuildStatusItem()
        }
        store.onPanelRelayout = { [weak self] in
            self?.relayoutPanel()
        }
        self.store = store

        rebuildStatusItem()
        applyTitle(store.snap, disks: store.disks)

        titleWatch = Publishers.CombineLatest(store.$snap, store.$disks)
            .receive(on: RunLoop.main)
            .sink { [weak self] snap, disks in
                self?.applyTitle(snap, disks: disks)
            }

        // Local: clicks that still land on our status-item window after action dies.
        // Global: clicks the system treats as someone else's after Safari OAuth.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            self?.handleClick(event)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func rebuildStatusItem() {
        if let existing = statusItem {
            existing.menu = nil
            existing.button?.target = nil
            existing.button?.action = nil
            NSStatusBar.system.removeStatusItem(existing)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.isEnabled = true
            button.appearsDisabled = false
        }
        statusItem = item
        rebindBar()
        if let snap = store?.snap {
            applyTitle(snap, disks: store?.disks ?? [])
        }
    }

    private func rebindBar() {
        guard let button = statusItem?.button else { return }
        statusItem?.menu = nil
        button.target = self
        button.action = #selector(handleBarClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.isEnabled = true
        button.appearsDisabled = false
    }

    @objc func handleBarClick(_ sender: Any?) {
        barActionAt = Date()
        let type = NSApp.currentEvent?.type
        if type == .rightMouseDown || type == .rightMouseUp {
            showFallbackMenu()
            return
        }
        togglePanel()
    }

    private func handleClick(_ event: NSEvent) {
        if event.type == .leftMouseUp || event.type == .rightMouseUp { return }
        if isBarEvent(event), Date().timeIntervalSince(barActionAt) < 0.28 {
            return
        }
        if isBarEvent(event) {
            if event.type == .rightMouseDown {
                DispatchQueue.main.async { [weak self] in self?.showFallbackMenu() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.togglePanel() }
            }
            return
        }
        guard panelOnScreen else { return }
        if let panel, panel.frame.contains(NSEvent.mouseLocation) { return }
        if event.window === panel { return }
        hidePanel()
    }

    @objc private func otherAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        hidePanel()
        rebindBar()
    }

    private func togglePanel() {
        if Date().timeIntervalSince(lastBarToggle) < 0.32 { return }
        lastBarToggle = Date()
        rebindBar()
        if panelOnScreen {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private var panelOnScreen: Bool {
        guard let panel, panel.isVisible, panel.frame.width > 8, panel.frame.height > 8 else { return false }
        if !panel.occlusionState.contains(.visible) { return false }
        return true
    }

    private func isBarEvent(_ event: NSEvent) -> Bool {
        if let win = statusItem?.button?.window, event.window === win { return true }
        return isClickOnBar(NSEvent.mouseLocation)
    }

    private func isClickOnBar(_ loc: NSPoint) -> Bool {
        guard let button = statusItem?.button, let win = button.window else { return false }
        var bar = win.convertToScreen(button.convert(button.bounds, to: nil))
        if bar.width < 8 || bar.height < 8 {
            bar = win.frame
        }
        return bar.insetBy(dx: -8, dy: -6).contains(loc)
    }

    private func showPanel() {
        hidePanel()
        guard let store, let button = statusItem?.button else { return }
        rebindBar()

        let host = ClearHosting(rootView: AnyView(MenuPanel().environmentObject(store)))
        _ = host.view
        applyFittedSize(host, under: button)
        self.panelHost = host
        // Never NSApp.activate — that is what dies the bar action after Safari.
        panel?.orderFrontRegardless()
        button.highlight(true)
        store.setLiveIO(true)
    }

    private func relayoutPanel() {
        guard let host = panelHost, let button = statusItem?.button, panelOnScreen else { return }
        applyFittedSize(host, under: button)
    }

    private func applyFittedSize(_ host: ClearHosting<AnyView>, under button: NSView) {
        // Unconstrain so sizeThatFits measures content, not the last frame.
        host.view.setFrameSize(NSSize(width: Self.panelWidth, height: 1))
        host.view.layoutSubtreeIfNeeded()
        var fitted = host.sizeThatFits(in: NSSize(width: Self.panelWidth, height: 900))
        if !fitted.height.isFinite || fitted.height < 160 {
            fitted = NSSize(width: Self.panelWidth, height: 360)
        }
        let height = Swift.min(Swift.max(fitted.height, 200), 720)
        let size = NSSize(width: Self.panelWidth, height: height)
        host.view.frame = NSRect(origin: .zero, size: size)

        if let panel, panelOnScreen {
            if let glass = panel.contentView {
                glass.setFrameSize(size)
            }
            panel.setContentSize(size)
            position(panel, size: size, under: button)
            return
        }

        let glass = GlassBackdrop(frame: NSRect(origin: .zero, size: size))
        host.view.autoresizingMask = [.width, .height]
        glass.addSubview(host.view)

        let panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.contentView = glass
        panel.setContentSize(size)
        panel.appearance = NSApp.effectiveAppearance

        position(panel, size: size, under: button)
        self.panel = panel
    }

    private func hidePanel() {
        store?.setLiveIO(false)
        statusItem?.button?.highlight(false)
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        self.panel = nil
        self.panelHost = nil
    }

    private func showFallbackMenu() {
        if Date().timeIntervalSince(lastBarToggle) < 0.32 { return }
        lastBarToggle = Date()
        hidePanel()
        rebindBar()
        guard let store, let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: store.snap.barTitle(disks: store.disks), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(makeItem("Refresh now", #selector(menuRefresh)))
        menu.addItem(makeItem("Copy summary", #selector(menuCopy)))
        menu.addItem(makeItem(store.notifyEnabled ? "Alerts ✓" : "Alerts", #selector(menuToggleAlerts)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit QuotaBar", #selector(menuQuit)))

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            let loc = button.convert(NSPoint(x: button.bounds.midX, y: 0), to: nil)
            menu.popUp(positioning: nil, at: loc, in: button)
        }
    }

    private func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func menuRefresh() { Task { await store?.refresh() } }
    @objc func menuCopy() { store?.copySummary() }
    @objc func menuSignIn() { store?.startDeviceLogin() }
    @objc func menuDisconnect() { Task { await store?.disconnectGrok() } }
    @objc func menuToggleAlerts() { store?.toggleNotify() }
    @objc func menuToggleLogin() { store?.toggleLaunchAtLogin() }
    @objc func menuQuit() { store?.quit() }

    private func applyTitle(_ snap: Snapshot, disks: [DiskVolume]) {
        guard let button = statusItem?.button else { return }
        let raw = snap.barTitle(disks: disks)
        if raw != lastTitle {
            lastTitle = raw
            rebindBar()
        }
        let attr = NSMutableAttributedString(string: raw)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        attr.addAttribute(.font, value: font, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))

        func color(for tone: Tone) -> NSColor? {
            switch tone {
            case .warn: return .systemOrange
            case .crit, .error: return .systemRed
            default: return nil
            }
        }

        var searchFrom = raw.startIndex
        for (lane, letter) in snap.barLanes.map({ ($0, $0.key.letter) }) {
            guard let tint = color(for: lane.tone) else { continue }
            let needle = "\(letter) \(lane.label == "—" ? "—" : "\(Int(lane.usedPct ?? 0))")"
            if let range = raw.range(of: needle, range: searchFrom..<raw.endIndex) {
                attr.addAttribute(.foregroundColor, value: tint, range: NSRange(range, in: raw))
                searchFrom = range.upperBound
            }
        }
        searchFrom = raw.startIndex
        for bit in Snapshot.barDiskBits(disks) {
            let needle = "\(bit.letter) \(bit.pct)"
            if let range = raw.range(of: needle, range: searchFrom..<raw.endIndex) {
                if let tint = color(for: bit.tone) {
                    attr.addAttribute(.foregroundColor, value: tint, range: NSRange(range, in: raw))
                }
                searchFrom = range.upperBound
            }
        }
        button.attributedTitle = attr
        var tip = snap.barLanes.map { "\($0.key.title) \($0.label) · \($0.sub)" }
        tip.append(contentsOf: disks.map { "\($0.name) \(Int($0.usedPct.rounded()))% · \($0.sizeLabel) · \($0.rateLabel)" })
        button.toolTip = tip.isEmpty ? "QuotaBar" : tip.joined(separator: "\n")
    }

    private func position(_ panel: NSPanel, size: NSSize, under button: NSView) {
        guard let buttonWindow = button.window else {
            panel.setFrame(NSRect(origin: NSPoint(x: 80, y: 80), size: size), display: true)
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - size.width / 2
        var y = buttonRect.minY - size.height - 6
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = Swift.min(Swift.max(x, visible.minX + 8), visible.maxX - size.width - 8)
            if y < visible.minY + 8 {
                y = buttonRect.maxY + 6
            }
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func contentRect(forFrameRect frameRect: NSRect) -> NSRect { frameRect }
    override func frameRect(forContentRect contentRect: NSRect) -> NSRect { contentRect }
}

final class ClearHosting<Content: View>: NSHostingController<Content> {
    override func loadView() {
        super.loadView()
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class GlassBackdrop: NSView {
    private let effect: NSVisualEffectView

    override init(frame: NSRect) {
        let fx = NSVisualEffectView(frame: frame)
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.material = .hudWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        effect = fx
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.7
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        effect.frame = bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
