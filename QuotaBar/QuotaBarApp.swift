import AppKit
import Combine
import SwiftUI

@main
final class QuotaBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store: UsageStore?
    private var titleWatch: AnyCancellable?

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

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 352, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel().environmentObject(store)
        )
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.title = store.menuTitle
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        titleWatch = store.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.statusItem?.button?.title = snap.menuTitle
            }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
