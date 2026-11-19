import AppKit
import SwiftUI

/// Isolated smoke/render executable. Does NOT instantiate QuotaBarApp or
/// UsageStore: no status item, auth watchers, provider polling, notification prompt,
/// preferences writes, or installed-app interaction.
@main
struct GoogleCheck {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let lane = GoogleUsage.lane(from: GoogleUsage.run())
            guard lane.tone != .error, let group = lane.googleMenuGroup else {
                // Fixed application diagnostic only, never raw CLI stdout/stderr.
                print("LIVE_GO=UNAVAILABLE · \(lane.sub)")
                exit(1)
            }
            let current = group.bucket(for: .current) != nil
            let weekly = group.bucket(for: .weekly) != nil
            let argonCurrent = lane.googleGroups.first { $0.name == "Gemini 4 Argon" }?.bucket(for: .current) != nil
            let status = current && weekly ? "PASS" : "PARTIAL"
            print("LIVE_GO=\(status) · Gemini 5h=\(current), weekly=\(weekly), Argon 5h=\(argonCurrent), official groups=\(lane.googleGroups.count)")
            return
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let lane = GoogleUsage.parse(try Data(contentsOf: fixtureURL))
        precondition(lane.googleMenuGroup?.bucket(for: .current)?.shownUsedPct == 80)
        precondition(lane.googleMenuGroup?.bucket(for: .weekly)?.shownUsedPct == 25)
        precondition(lane.googleGroups.last?.bucket(for: .current) == nil)
        precondition(UsageSources.all.map(\.key) == [.grok, .gpt, .claude, .google])
        precondition(UsageSources.source(for: .google)?.connectTitle == nil)
        precondition(UsageSources.source(for: .google)?.hasSession() == true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let existing: [Lane] = [
            .used(.grok, percent: 21, sub: "shared weekly pool"),
            .used(.gpt, percent: 15, sub: "5h + weekly"),
            .used(.claude, percent: 82, sub: "Synthetic fixture", details: [
                LaneDetail(label: "Current session", usedPct: 19, reset: "resets Thu 12:10 AM", mark: "AC", window: "5h"),
                LaneDetail(label: "This week", usedPct: 82, reset: "resets Fri 8:00 PM", mark: "AT", window: "week"),
                LaneDetail(label: "Fable this week", usedPct: 94, reset: "resets Fri 8:00 PM", mark: "AF", window: "week")])
        ]
        var weeklyOnly = lane
        if let index = weeklyOnly.googleGroups.firstIndex(where: { $0.name == "Gemini Models" }) {
            weeklyOnly.googleGroups[index].buckets.removeAll { $0.window == "5h" }
        }
        for (name, google) in [
            ("available", lane), ("weekly-only", weeklyOnly),
            ("unavailable", GoogleUsage.lane(from: .unavailable("Antigravity /usage timed out; try Refresh")))
        ] {
            let content = VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("QuotaBar").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("v1.8.25").font(.system(size: 10))
                }
                Text("Offline component check · synthetic data").font(.system(size: 11)).foregroundStyle(.secondary)
                UsageTable(lanes: existing + [google])
                MemoryRow(usage: MemoryUsage(usedBytes: 10_737_418_240, totalBytes: 17_179_869_184))
            }
            .padding(16)
            .frame(width: CGFloat(PanelFitMetrics.panelWidth))
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            let view = NSHostingView(rootView: content)
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = NSRect(x: 0, y: 0, width: PanelFitMetrics.panelWidth, height: 1000)
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            precondition(abs(size.width - PanelFitMetrics.panelWidth) < 1, "table exceeded panel width")
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "Component bitmap unavailable", code: 1)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "Component PNG unavailable", code: 1)
            }
            try png.write(to: output.appendingPathComponent("google-\(name).png"))
            print("COMPONENT_\(name.uppercased())=RENDERED · \(Int(size.width))×\(Int(size.height)) pt · not a live menu-bar app")
        }

        // Exercise the actual native scroll container used for a short usage band.
        let scrolling = ScrollView(.vertical) {
            UsageTable(lanes: existing + [lane])
                .padding(16)
                .frame(width: CGFloat(PanelFitMetrics.panelWidth))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: CGFloat(PanelFitMetrics.panelWidth), height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: scrolling)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: PanelFitMetrics.panelWidth, height: 280)
        // Mount into a hidden window so SwiftUI installs its platform scroll view.
        // Never order it onscreen or activate the app.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        guard let scroll = scrollView(in: host), let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height else {
            throw NSError(domain: "Short usage band did not expose native scrolling", code: 1)
        }
        let bottom = document.bounds.maxY - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.origin.y > 0, "usage band failed to scroll")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "Scrolled bitmap unavailable", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("google-scrolled.png"))
        print("COMPONENT_SCROLL=PASS · native usage band scrolled to bottom at 448×280 pt")
    }

    @MainActor
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }
}
