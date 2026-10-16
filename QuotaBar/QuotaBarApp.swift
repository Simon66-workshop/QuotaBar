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
    private let fitModel = PanelFitModel()
    private var panelLive = false
    private var refitState = PanelRefitState()
    private var refitWork: DispatchWorkItem?
    private var scrollFollowUps = 0

    private static let panelWidth: CGFloat = CGFloat(PanelFitMetrics.panelWidth)

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
        store.onPanelRelayout = { [weak self] signal in
            self?.noteRefit(signal)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refitWork?.cancel()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        noteRefit(.screen)
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

        let host = ClearHosting(rootView: AnyView(
            MenuPanel(probeEpoch: fitModel.epoch)
                .environmentObject(store)
                .environmentObject(fitModel)
        ))
        _ = host.view
        self.panelHost = host
        panelLive = true
        applyFittedSize(host, under: button, animate: false)
        // Never NSApp.activate — that is what dies the bar action after Safari.
        panel?.orderFrontRegardless()
        button.highlight(true)
        store.setLiveIO(true)
        store.requestPanelRelayout()
    }

    private func noteRefit(_ signal: PanelRefitSignal) {
        guard panelLive else {
            switch signal {
            case .content, .screen: scrollFollowUps = 0
            case .measure, .scrollFollowUp, .timer: break
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let (next, decision) = coalescePanelRefit(
            state: refitState,
            signal: signal,
            now: now,
            delay: PanelFitMetrics.refitDelay
        )
        refitState = next
        guard case .schedule(let fireAt) = decision else { return }
        switch signal {
        case .content:
            fitModel.noteContentRefit()
            scrollFollowUps = 0
        case .screen:
            scrollFollowUps = 0
        case .measure, .scrollFollowUp, .timer:
            break
        }
        refitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performRefit()
        }
        refitWork = work
        let delay = max(0, fireAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performRefit() {
        refitState.pendingFireAt = nil
        guard panelLive, let host = panelHost, let button = statusItem?.button else { return }
        applyFittedSize(host, under: button, animate: true)
    }

    private func applyFittedSize(_ host: ClearHosting<AnyView>, under button: NSView, animate: Bool) {
        // Measure the SwiftUI ideal height. A floor of 200/360 left one short
        // row floating in a tall glass with blank space above and below.
        let cap = screenCap(under: button)
        let scrolling = fitModel.plan.scroll != .none
        host.view.layoutSubtreeIfNeeded()

        let formula = panelFormulaHeight(
            header: fitModel.header,
            usage: fitModel.usage,
            bottom: fitModel.bottom,
            verticalPadding: PanelFitMetrics.verticalPadding,
            sectionSpacing: PanelFitMetrics.sectionSpacing
        )
        let liveMeasure: Double? = scrolling ? nil : measureIntrinsic(host, resetFrame: panel == nil)
        fitModel.calibration = calibratePanelSlack(
            fitModel.calibration,
            liveMeasure: liveMeasure,
            formula: formula
        )
        let measured = panelNaturalHeight(
            measured: liveMeasure,
            formula: formula,
            calibration: fitModel.calibration
        )
        let plan = makePlan(measured: measured, cap: cap, scrolling: scrolling)
        let previousScroll = fitModel.plan.scroll
        if plan != fitModel.plan {
            fitModel.apply(plan)
            host.view.layoutSubtreeIfNeeded()
        }
        host.sizingOptions = []
        place(host, height: CGFloat(plan.height), under: button, animate: animate && panelOnScreen)
        if previousScroll != fitModel.plan.scroll, scrollFollowUps < 2 {
            scrollFollowUps += 1
            noteRefit(.scrollFollowUp)
        }
    }

    private func makePlan(measured: Double?, cap: Double, scrolling: Bool) -> PanelFitPlan {
        if scrolling && !fitModel.probesReady {
            let limit = cap > 0 ? cap.rounded(.down) : max(fitModel.plan.height, 1)
            return PanelFitPlan(height: max(limit, 1), scroll: .body)
        }
        return fitPanel(
            measured: measured,
            header: fitModel.header,
            usage: fitModel.usage,
            bottom: fitModel.bottom,
            verticalPadding: PanelFitMetrics.verticalPadding,
            sectionSpacing: PanelFitMetrics.sectionSpacing,
            cap: cap,
            epsilon: PanelFitMetrics.heightEpsilon,
            currentlyScrolling: scrolling,
            hysteresis: PanelFitMetrics.scrollHysteresis
        )
    }

    /// Unconstrained content height. Do not squash a visible panel down to 1pt;
    /// that flash is what the trailing refit is there to avoid.
    private func measureIntrinsic(_ host: ClearHosting<AnyView>, resetFrame: Bool) -> Double {
        host.sizingOptions = [.intrinsicContentSize]
        if resetFrame {
            host.view.setFrameSize(NSSize(width: Self.panelWidth, height: 1))
        }
        host.view.invalidateIntrinsicContentSize()
        host.view.layoutSubtreeIfNeeded()
        let proposed = host.sizeThatFits(in: NSSize(width: Self.panelWidth, height: .greatestFiniteMagnitude))
        var height = proposed.height
        let intrinsic = host.view.intrinsicContentSize.height
        if !height.isFinite || height < 48 {
            height = intrinsic
        }
        if !height.isFinite || height < 48 {
            height = CGFloat(PanelFitMetrics.invalidMeasureFallback)
        }
        return Double(height)
    }

    private func screenCap(under button: NSView) -> Double {
        let screen = button.window?.screen ?? NSScreen.main
        guard let screen else {
            return panelHeightCap(visibleHeight: 900, menuBarHeight: 24, safetyMargin: PanelFitMetrics.safetyMargin)
        }
        let visible = screen.visibleFrame
        let menu = menuBarHeight(screenMaxY: Double(screen.frame.maxY), visibleMaxY: Double(visible.maxY))
        let room: Double?
        if let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            room = roomBelowStatusItem(
                statusBottom: Double(buttonRect.minY),
                anchorGap: PanelFitMetrics.anchorGap,
                visibleMinY: Double(visible.minY)
            )
        } else {
            room = nil
        }
        return panelHeightCap(
            visibleHeight: Double(visible.height),
            menuBarHeight: menu,
            safetyMargin: PanelFitMetrics.safetyMargin,
            roomBelowAnchor: room
        )
    }

    private func place(_ host: ClearHosting<AnyView>, height: CGFloat, under button: NSView, animate: Bool) {
        let size = NSSize(width: Self.panelWidth, height: height)
        let frame = panelFrame(size: size, under: button)
        if let panel {
            let moved = abs(panel.frame.minX - frame.minX) > 0.5 || abs(panel.frame.minY - frame.minY) > 0.5
            let resized = shouldApplyPanelHeight(
                current: Double(panel.frame.height),
                proposed: Double(height),
                epsilon: PanelFitMetrics.heightEpsilon
            )
            guard resized || moved else { return }
            if resized && animate {
                let target = size
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = PanelFitMetrics.refitAnimation
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                } completionHandler: {
                    guard abs(panel.frame.height - target.height) <= 0.5 else { return }
                    host.view.frame = NSRect(origin: .zero, size: target)
                    panel.contentView?.setFrameSize(target)
                }
                return
            }
            host.view.frame = NSRect(origin: .zero, size: size)
            panel.contentView?.setFrameSize(size)
            panel.setFrame(frame, display: true)
            return
        }

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.contentView = glass
        panel.setContentSize(size)
        panel.appearance = NSApp.effectiveAppearance

        panel.setFrame(frame, display: true)
        self.panel = panel
    }

    private func hidePanel() {
        panelLive = false
        refitWork?.cancel()
        refitWork = nil
        refitState = PanelRefitState()
        scrollFollowUps = 0
        store?.setLiveIO(false)
        statusItem?.button?.highlight(false)
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        self.panel = nil
        self.panelHost = nil
        fitModel.reset()
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

    @objc func menuRefresh() { Task { await store?.refresh(userInitiated: true) } }
    @objc func menuCopy() { store?.copySummary() }
    @objc func menuSignIn() { store?.startDeviceLogin() }
    @objc func menuDisconnect() { Task { await store?.disconnectGrok() } }
    @objc func menuToggleAlerts() { store?.toggleNotify() }
    @objc func menuToggleLogin() { store?.toggleLaunchAtLogin() }
    @objc func menuQuit() { store?.quit() }

    private func applyTitle(_ snap: Snapshot, disks: [DiskVolume]) {
        guard let button = statusItem?.button else { return }
        let groups = snap.barGroups(disks: disks)
        let raw = Snapshot.title(from: groups)
        if raw != lastTitle {
            lastTitle = raw
            rebindBar()
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attr = NSMutableAttributedString()
        func color(for tone: Tone) -> NSColor {
            switch tone {
            case .warn: return .systemOrange
            case .crit, .error: return .systemRed
            default: return .labelColor
            }
        }
        func append(_ text: String, _ tone: Tone) {
            attr.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color(for: tone),
            ]))
        }
        if groups.isEmpty {
            append("QuotaBar", .ok)
        } else {
            for (groupIndex, group) in groups.enumerated() {
                if groupIndex > 0 { append(" · ", .ok) }
                for (tokenIndex, token) in group.enumerated() {
                    if tokenIndex > 0 { append("  ", .ok) }
                    append(token.text, token.tone)
                }
            }
        }
        button.attributedTitle = attr
        var tip: [String] = []
        for lane in snap.barLanes {
            let marked = lane.details.filter { $0.mark != nil }
            if marked.isEmpty {
                if lane.key == .grok {
                    tip.append("Grok \(lane.label) · \(LaneKey.sharedPoolCaption) · \(lane.sub)")
                } else {
                    tip.append("\(lane.key.title) \(lane.label) · \(lane.sub)")
                }
            } else {
                for detail in marked {
                    var line = "\(detail.mark ?? "") \(detail.label) \(detail.shownPct)%"
                    if let reset = detail.reset, !reset.isEmpty {
                        line += " · \(reset)"
                    }
                    tip.append(line)
                }
            }
        }
        tip.append(contentsOf: disks.map { "\($0.name) \(Int($0.usedPct.rounded()))% · \($0.sizeLabel) · \($0.rateLabel)" })
        button.toolTip = tip.isEmpty ? "QuotaBar" : tip.joined(separator: "\n")
    }

    /// Top edge stays `anchorGap` points under the status item while the height changes.
    private func panelFrame(size: NSSize, under button: NSView) -> NSRect {
        guard let buttonWindow = button.window else {
            return NSRect(origin: NSPoint(x: 80, y: 80), size: size)
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let gap = CGFloat(PanelFitMetrics.anchorGap)
        var x = buttonRect.midX - size.width / 2
        var y = buttonRect.minY - size.height - gap
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = Swift.min(Swift.max(x, visible.minX + 8), visible.maxX - size.width - 8)
            if y < visible.minY + 8 {
                y = buttonRect.maxY + gap
            }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
final class PanelFitModel: ObservableObject {
    @Published private(set) var plan = PanelFitPlan(height: 0, scroll: .none)
    private(set) var epoch = 0
    private(set) var bandWatch = PanelBandWatch()
    /// sizeThatFits minus the section formula. Validity is separate from the slack value.
    var calibration = PanelSlackCalibration()

    var header: Double { bandWatch.header }
    var usage: Double { bandWatch.usage }
    var bottom: Double { bandWatch.bottom }
    var probesReady: Bool { header >= 1 && bottom >= 1 }

    /// Stores the sample and reports whether it should schedule the debounced refit.
    func record(header: CGFloat, usage: CGFloat, bottom: CGFloat, epoch: Int) -> Bool {
        let viewport: Double?
        if case .usage(let value) = plan.scroll { viewport = value } else { viewport = nil }
        let (next, decision) = observePanelBands(
            watch: bandWatch,
            header: Double(header),
            usage: Double(usage),
            bottom: Double(bottom),
            epoch: epoch,
            epsilon: PanelFitMetrics.heightEpsilon,
            usageViewport: viewport
        )
        bandWatch = next
        return decision == .schedule
    }

    func noteContentRefit() {
        bandWatch = resetPanelBandBurst(bandWatch)
    }

    func apply(_ plan: PanelFitPlan) {
        guard plan != self.plan else { return }
        self.plan = plan
        bandWatch = armPanelBandEcho(bandWatch)
    }

    func reset() {
        epoch += 1
        calibration = PanelSlackCalibration()
        bandWatch = PanelBandWatch(epoch: epoch)
        let cleared = PanelFitPlan(height: 0, scroll: .none)
        if plan != cleared {
            plan = cleared
        }
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
