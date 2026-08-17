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
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let store, let button = statusItem?.button else { return }
        let host = ClearHosting(rootView: MenuPanel().environmentObject(store))
        let fitted = host.sizeThatFits(in: NSSize(width: 352, height: 900))
        let height = Swift.min(Swift.max(fitted.height, 380), 640)
        let size = NSSize(width: 352, height: height)
        host.view.frame = NSRect(origin: .zero, size: size)

        let glass = GlassBackdrop(frame: host.view.bounds)
        glass.autoresizingMask = [.width, .height]
        host.view.autoresizingMask = [.width, .height]
        glass.addSubview(host.view)

        let panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = glass
        panel.appearance = NSApp.effectiveAppearance

        position(panel, under: button)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !panel.frame.contains(loc) {
                self.hidePanel()
            }
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func position(_ panel: NSPanel, under button: NSView) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - panel.frame.width / 2
        var y = buttonRect.minY - panel.frame.height - 6
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = Swift.min(Swift.max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            if y < visible.minY + 8 {
                y = buttonRect.maxY + 6
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    private let effect: NSView

    override init(frame: NSRect) {
        if let type = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = type.init(frame: frame)
            if glass.responds(to: NSSelectorFromString("setCornerRadius:")) {
                glass.setValue(18, forKey: "cornerRadius")
            }
            effect = glass
        } else {
            let fx = NSVisualEffectView(frame: frame)
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.material = .underWindowBackground
            effect = fx
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.7
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.shadowOpacity = 0
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
}
