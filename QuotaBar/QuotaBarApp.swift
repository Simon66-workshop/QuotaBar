import AppKit
import Combine
import SwiftUI

@main
final class QuotaBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: GlassPanel?
    /// CRITICAL: must retain the hosting controller. Retaining only the panel / contentView
    /// lets ARC free NSHostingController → panel appears blank / non-interactive
    /// ("bar click does nothing").
    private var panelHost: NSViewController?
    private var store: UsageStore?
    private var titleWatch: AnyCancellable?
    private var clickMonitor: Any?
    private var monitorWorkItem: DispatchWorkItem?
    /// Ignore outside-clicks briefly after open so the opening click cannot dismiss.
    private var openedAt: Date = .distantPast

    static func main() {
        let app = NSApplication.shared
        let delegate = QuotaBarApp()
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
        button.title = store.snap.menuTitle
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        titleWatch = store.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.statusItem?.button?.title = snap.menuTitle
            }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        hidePanel()
        guard let store, let button = statusItem?.button else { return }

        // Accessory apps need an explicit activate so the panel can become key
        // and SwiftUI controls (buttons / SecureField) work.
        NSApp.activate(ignoringOtherApps: true)

        let host = ClearHosting(rootView: MenuPanel().environmentObject(store))
        // Force view load before measuring.
        _ = host.view
        var fitted = host.sizeThatFits(in: NSSize(width: 352, height: 900))
        if !fitted.height.isFinite || fitted.height < 200 {
            fitted = NSSize(width: 352, height: 420)
        }
        let height = Swift.min(Swift.max(fitted.height, 360), 640)
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
        // popUpMenu is above most UI and stays with the menu bar.
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

        // Strong refs BEFORE orderFront — otherwise ARC frees host mid-show.
        self.panelHost = host
        self.panel = panel
        self.openedAt = Date()

        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Install outside-click monitor after a short delay so the opening
        // mouse-up cannot immediately dismiss the panel.
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
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        self.panel = nil
        self.panelHost = nil
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

/// Card-sized glass only. Never full-screen — a previous full-screen effect view
/// ate all desktop clicks.
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
