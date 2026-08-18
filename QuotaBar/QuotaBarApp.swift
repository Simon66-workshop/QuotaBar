import AppKit
import Combine
import SwiftUI

@main
final class QuotaBarApp: NSObject, NSApplicationDelegate {
    /// NSApplication.delegate is unowned — keep the instance alive for the process lifetime.
    private static var retained: QuotaBarApp?

    private var statusItem: NSStatusItem?
    private var panel: GlassPanel?
    /// Must retain the hosting controller. Retaining only the panel/view lets ARC
    /// free NSHostingController → blank, dead panel ("bar click does nothing").
    private var panelHost: NSViewController?
    private var store: UsageStore?
    private var titleWatch: AnyCancellable?
    private var clickMonitor: Any?
    private var monitorWorkItem: DispatchWorkItem?
    private var openedAt: Date = .distantPast
    private var fallbackMenu: NSMenu?

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
        self.store = store

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.target = self
        // Do not mark this selector private — some macOS builds drop private @objc actions.
        button.action = #selector(handleBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        applyTitle(store.snap)

        titleWatch = store.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.applyTitle(snap)
            }
    }

    @objc func handleBarClick(_ sender: Any?) {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseUp {
            showFallbackMenu()
            return
        }
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        hidePanel()
        guard let store, let button = statusItem?.button else { return }

        NSApp.activate(ignoringOtherApps: true)

        let host = ClearHosting(rootView: MenuPanel().environmentObject(store))
        _ = host.view
        var fitted = host.sizeThatFits(in: NSSize(width: 352, height: 900))
        if !fitted.height.isFinite || fitted.height < 200 {
            fitted = NSSize(width: 352, height: 420)
        }
        let height = Swift.min(Swift.max(fitted.height, 360), 660)
        let size = NSSize(width: 352, height: height)
        host.view.frame = NSRect(origin: .zero, size: size)

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
        // Never .transient — it auto-hides when other windows activate.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.contentView = glass
        panel.setContentSize(size)
        panel.appearance = NSApp.effectiveAppearance

        position(panel, size: size, under: button)

        self.panelHost = host
        self.panel = panel
        self.openedAt = Date()

        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel === panel, panel.isVisible else { return }
            self.clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if Date().timeIntervalSince(self.openedAt) < 0.4 { return }
                let screenLoc = NSEvent.mouseLocation
                if panel.frame.contains(screenLoc) { return }
                if let button = self.statusItem?.button, let win = button.window {
                    let bar = win.convertToScreen(button.convert(button.bounds, to: nil))
                    if bar.contains(screenLoc) { return }
                }
                self.hidePanel()
            }
        }
        monitorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func hidePanel() {
        monitorWorkItem?.cancel()
        monitorWorkItem = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
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
        hidePanel()
        guard let store, let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: store.snap.menuTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for lane in store.snap.lanes {
            let line = "\(lane.key.title)  \(lane.label)  ·  \(lane.sub)"
            let item = NSMenuItem(title: String(line.prefix(80)), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Refresh now", #selector(menuRefresh)))
        menu.addItem(makeItem("Copy summary", #selector(menuCopy)))
        if store.snap.grok.tone == .empty || store.snap.grok.tone == .error {
            menu.addItem(makeItem("Sign in with Grok…", #selector(menuSignIn)))
        } else {
            menu.addItem(makeItem("Re-sign in with Grok…", #selector(menuSignIn)))
            menu.addItem(makeItem("Disconnect Grok", #selector(menuDisconnect)))
        }
        menu.addItem(.separator())
        let alerts = makeItem(store.notifyEnabled ? "Alerts ✓" : "Alerts", #selector(menuToggleAlerts))
        menu.addItem(alerts)
        let login = makeItem(store.launchAtLogin ? "Open at login ✓" : "Open at login", #selector(menuToggleLogin))
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit QuotaBar", #selector(menuQuit)))

        fallbackMenu = menu
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            statusItem?.menu = menu
            button.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        }
    }

    private func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func menuRefresh() { Task { await store?.refresh() } }
    @objc func menuCopy() { store?.copySummary() }
    @objc func menuSignIn() { store?.startDeviceLogin(); showPanel() }
    @objc func menuDisconnect() { Task { await store?.disconnectGrok() } }
    @objc func menuToggleAlerts() { store?.toggleNotify() }
    @objc func menuToggleLogin() { store?.toggleLaunchAtLogin() }
    @objc func menuQuit() { store?.quit() }

    private func applyTitle(_ snap: Snapshot) {
        guard let button = statusItem?.button else { return }
        let raw = snap.menuTitle
        let attr = NSMutableAttributedString(string: raw)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        attr.addAttribute(.font, value: font, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))

        func color(for lane: Lane) -> NSColor? {
            switch lane.tone {
            case .warn: return .systemOrange
            case .crit, .error: return .systemRed
            default: return nil
            }
        }

        let parts: [(Lane, String)] = [
            (snap.grok, snap.grok.key.letter),
            (snap.cursor, snap.cursor.key.letter),
            (snap.bot, snap.bot.key.letter),
        ]
        for (lane, letter) in parts {
            guard let tint = color(for: lane) else { continue }
            let needle = "\(letter) \(lane.label == "—" ? "—" : "\(Int(lane.usedPct ?? 0))")"
            if let range = raw.range(of: needle) {
                let ns = NSRange(range, in: raw)
                attr.addAttribute(.foregroundColor, value: tint, range: ns)
            }
        }
        button.attributedTitle = attr
        button.toolTip = snap.lanes.map { "\($0.key.title) \($0.label) · \($0.sub)" }.joined(separator: "\n")
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
    override var contentRect(forFrameRect frameRect: NSRect) -> NSRect { frameRect }
    override var frameRect(forContentRect contentRect: NSRect) -> NSRect { contentRect }
}

final class ClearHosting<Content: View>: NSHostingController<Content> {
    override func loadView() {
        super.loadView()
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// Card-sized glass only. Never full-screen — a previous overlay ate desktop clicks.
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
