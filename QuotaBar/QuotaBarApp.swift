import AppKit
import Combine
import SwiftUI

@main
final class QuotaBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: GlassPanel?
    private var store: UsageStore?
    private var titleWatch: AnyCancellable?
    private var clickMonitor: Any?

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
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.title = store.snap.menuTitle
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        titleWatch = store.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.statusItem?.button?.title = snap.menuTitle
            }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        hidePanel()
        guard let store, let button = statusItem?.button else { return }
        let host = ClearHosting(rootView: MenuPanel().environmentObject(store))
        let fitted = host.sizeThatFits(in: NSSize(width: 352, height: 720))
        let height = Swift.min(Swift.max(fitted.height.isFinite ? fitted.height : 420, 360), 560)
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
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.hasShadow = true
        panel.contentView = glass
        panel.setContentSize(size)
        panel.minSize = size
        panel.maxSize = size
        panel.appearance = NSApp.effectiveAppearance

        position(panel, size: size, under: button)
        panel.orderFront(nil)
        self.panel = panel

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hidePanel()
            }
        }
    }

    private func hidePanel() {
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
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18)
        guard path.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
