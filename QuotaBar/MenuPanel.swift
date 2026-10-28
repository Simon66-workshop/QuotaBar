import SwiftUI

struct MenuPanel: View {
    var probeEpoch: Int
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var fit: PanelFitModel

    var body: some View {
        fitted
            .background(Color.clear)
            .onPreferenceChange(PanelBandKey.self) { bands in
                if fit.record(header: bands.header, usage: bands.usage, bottom: bands.bottom, epoch: probeEpoch) {
                    store.requestMeasuredRefit(header: fit.header, usage: fit.usage, bottom: fit.bottom)
                }
            }
    }

    @ViewBuilder
    private var fitted: some View {
        switch fit.plan.scroll {
        case .body:
            ScrollView(.vertical) {
                stack(usageViewport: nil)
                    .frame(width: CGFloat(PanelFitMetrics.panelWidth), alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: CGFloat(PanelFitMetrics.panelWidth), height: CGFloat(max(fit.plan.height, 1)))
        case .usage(let viewport):
            stack(usageViewport: viewport)
                .frame(
                    width: CGFloat(PanelFitMetrics.panelWidth),
                    height: CGFloat(max(fit.plan.height, 1)),
                    alignment: .top
                )
        case .none:
            stack(usageViewport: nil)
                .frame(width: CGFloat(PanelFitMetrics.panelWidth), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Header, usage, and the account / disk / footer chrome keep the 1.8.22 gaps.
    /// Usage is the only band that scrolls; the others stay intrinsic.
    private func stack(usageViewport: Double?) -> some View {
        VStack(alignment: .leading, spacing: PanelSpace.section) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .panelBand(.header)
            usageBand(viewport: usageViewport)
            bottomChrome
                .fixedSize(horizontal: false, vertical: true)
                .panelBand(.bottom)
        }
        .padding(CGFloat(PanelFitMetrics.outerPadding))
    }

    @ViewBuilder
    private func usageBand(viewport: Double?) -> some View {
        if !listedLanes.isEmpty {
            let block = usageBlock.panelBand(.usage)
            if let viewport, viewport > 0 {
                ScrollView(.vertical) {
                    block.fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: CGFloat(viewport))
            } else {
                block
            }
        }
    }

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: PanelSpace.label) {
            sectionLabel("Usage")
            UsageTable(lanes: listedLanes)
        }
    }

    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: PanelSpace.section) {
            if TokenReader.hasGrokSession() {
                AccountRow()
            }
            if showConnect {
                ConnectCell(idle: connectLanes)
            }
            MemoryRow(usage: store.memory)
            DiskSection()
            footer
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("QuotaBar")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("v1.8.24")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text(statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if !store.copiedNote.isEmpty {
                Text(store.copiedNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        if store.busy { return "Refreshing…" }
        if store.snap.fetchedAt == .distantPast { return "Waiting for live data" }
        let s = Int(Date().timeIntervalSince(store.snap.fetchedAt))
        if s < 5 { return "Live · just now" }
        if s < 60 { return "Live · \(s)s ago" }
        return "Live · \(max(1, s / 60))m ago"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") { Task { await store.refresh(userInitiated: true) } }
                .buttonStyle(.bordered)
            Button("Copy") { store.copySummary() }
                .buttonStyle(.borderless)
            Spacer()
            Toggle("Alerts", isOn: Binding(
                get: { store.notifyEnabled },
                set: { _ in store.toggleNotify() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            Toggle("Login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { _ in store.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            Button("Quit") { store.quit() }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    /// Connected or broken — those stay as rows. Empty ones fold into Connect.
    /// Cursor and Grok Bot are the G row, not their own rows.
    private var panelLanes: [Lane] {
        store.snap.lanes.filter { !$0.key.foldedIntoGrok }
    }

    private var listedLanes: [Lane] {
        panelLanes.filter { $0.tone != .empty }
    }

    private var connectLanes: [Lane] {
        panelLanes.filter { $0.tone == .empty }
    }

    private var showConnect: Bool {
        store.loginInProgress || !connectLanes.isEmpty
    }
}

private struct ConnectCell: View {
    @EnvironmentObject private var store: UsageStore
    let idle: [Lane]
    @State private var pick: LaneKey = .grok

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Connect")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Text(idle.map(\.key.title).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }

            if !hintLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hintLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if formKeys.count > 1 {
                Picker("Service", selection: $pick) {
                    ForEach(formKeys, id: \.self) { key in
                        Text(UsageSources.source(for: key)?.connectTitle ?? key.title).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if formKeys.contains(pick) {
                switch pick {
                case .grok: GrokConnectForm()
                case .gpt: ChatGPTConnectForm()
                case .claude: ClaudeConnectForm()
                default: EmptyView()
                }
            }
        }
        .onAppear { syncPick() }
        .onChange(of: idle.map(\.id)) { _, _ in syncPick() }
        .onChange(of: store.loginInProgress) { _, live in
            if live { pick = .grok }
            store.noteConnectPick(pick)
            store.requestPanelRelayout()
        }
        .onChange(of: pick) { _, newValue in
            store.noteConnectPick(newValue)
        }
        .onChange(of: store.deviceUserCode) { _, _ in
            store.requestPanelRelayout()
        }
    }

    private var formKeys: [LaneKey] {
        var keys = idle.compactMap { lane -> LaneKey? in
            UsageSources.source(for: lane.key)?.connectTitle == nil ? nil : lane.key
        }
        if store.loginInProgress, !keys.contains(.grok) {
            keys.insert(.grok, at: 0)
        }
        return keys
    }

    private var hintLines: [String] {
        idle.compactMap { lane in
            switch lane.key {
            case .cursor: return "Cursor — open the Cursor app once. QuotaBar reads the local session."
            case .bot: return "Grok Bot — same Cursor session."
            default: return nil
            }
        }
    }

    private func syncPick() {
        if store.loginInProgress {
            pick = .grok
            store.noteConnectPick(pick)
            return
        }
        if formKeys.contains(pick) {
            store.noteConnectPick(pick)
            return
        }
        if let broken = idle.first(where: { $0.tone == .error && formKeys.contains($0.key) }) {
            pick = broken.key
        } else {
            pick = formKeys.first ?? .grok
        }
        store.noteConnectPick(pick)
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Grok account")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button("Re-sign in") { store.startDeviceLogin() }
                .buttonStyle(.borderless)
            Button("Disconnect") {
                Task { await store.disconnectGrok() }
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum PanelSpace {
    /// Same gap between usage, the Grok account row, connect, and disks.
    static let section: CGFloat = CGFloat(PanelFitMetrics.sectionSpacing)
    static let label: CGFloat = 4
    static let row: CGFloat = 3
}

private enum Col {
    static let gap: CGFloat = 6
    static let mark: CGFloat = 22
    static let nameMin: CGFloat = 132
    static let used: CGFloat = 36
    static let bar: CGFloat = 44
    static let meta: CGFloat = 48
    static let extra: CGFloat = 44
    static let action: CGFloat = 32
}

private struct UsageTable: View {
    let lanes: [Lane]

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: Col.gap, verticalSpacing: 0) {
            GridRow {
                Text("").frame(width: Col.mark, height: 12)
                Text("Name").gridHeader()
                Text("Used").frame(width: Col.used, alignment: .trailing)
                Color.clear.frame(width: Col.bar, height: 1)
                Text("Left").frame(width: Col.meta, alignment: .trailing)
                Text("Window").frame(width: Col.extra, alignment: .trailing)
                Color.clear.frame(width: Col.action, height: 1)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
            }
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                let figures = lane.details.filter { $0.mark != nil }
                if figures.isEmpty {
                    GridRow {
                        Text(lane.key.letter)
                            .font(.system(size: 11, weight: .bold).monospaced())
                            .foregroundStyle(lane.tone == .ok ? Color.secondary : toneColor(lane.tone))
                            .frame(width: Col.mark, alignment: .center)
                        nameCell(
                            title: lane.key.title,
                            caption: lane.key == .grok ? LaneKey.sharedPoolCaption : nil,
                            sub: (lane.tone == .error || lane.tone == .empty) ? lane.sub : nil
                        )
                        Text(usedText(lane))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(lane.tone == .ok ? Color.primary : toneColor(lane.tone))
                            .frame(width: Col.used, alignment: .trailing)
                        Meter(value: lane.usedPct ?? 0, tone: lane.tone)
                        Text(leftText(lane))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: Col.meta, alignment: .trailing)
                        Text(lane.window)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .frame(width: Col.extra, alignment: .trailing)
                            .lineLimit(1)
                        Color.clear.frame(width: Col.action, height: 1)
                    }
                    .padding(.vertical, PanelSpace.row)
                    .padding(.horizontal, 2)
                    .background(index % 2 == 1 ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    if (lane.key == .cursor || lane.key == .claude), !lane.details.isEmpty {
                        ForEach(lane.details) { detail in
                            GridRow {
                                Color.clear.frame(width: Col.mark)
                                Text(detail.label)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                                Text("\(Int(detail.usedPct.rounded()))%")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: Col.used, alignment: .trailing)
                                Meter(value: detail.usedPct, tone: .ok)
                                Color.clear.frame(width: Col.meta, height: 1)
                                Color.clear.frame(width: Col.extra, height: 1)
                                Color.clear.frame(width: Col.action, height: 1)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                } else {
                    GridRow {
                        Text(lane.key.letter)
                            .font(.system(size: 11, weight: .bold).monospaced())
                            .foregroundStyle(Color.secondary)
                            .frame(width: Col.mark, alignment: .center)
                        nameCell(
                            title: lane.key.title,
                            caption: lane.key == .grok ? LaneKey.sharedPoolCaption : nil,
                            sub: lane.sub.isEmpty ? nil : lane.sub
                        )
                        Color.clear.frame(width: Col.used, height: 1)
                        Color.clear.frame(width: Col.bar, height: 1)
                        Color.clear.frame(width: Col.meta, height: 1)
                        Color.clear.frame(width: Col.extra, height: 1)
                        Color.clear.frame(width: Col.action, height: 1)
                    }
                    .padding(.vertical, PanelSpace.row)
                    .padding(.horizontal, 2)
                    .background(index % 2 == 1 ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    ForEach(figures) { detail in
                        GridRow {
                            Text(detail.mark ?? "")
                                .font(.system(size: 10, weight: .bold).monospaced())
                                .foregroundStyle(detail.tone == .ok ? Color.secondary : toneColor(detail.tone))
                                .frame(width: Col.mark, alignment: .center)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(detail.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                if let reset = detail.reset, !reset.isEmpty {
                                    Text(reset)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                            Text("\(detail.shownPct)%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(detail.tone == .ok ? Color.primary : toneColor(detail.tone))
                                .frame(width: Col.used, alignment: .trailing)
                            Meter(value: detail.usedPct, tone: detail.tone)
                            Text("\(100 - detail.shownPct)%")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: Col.meta, alignment: .trailing)
                            Text(detail.window ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .frame(width: Col.extra, alignment: .trailing)
                                .lineLimit(1)
                            Color.clear.frame(width: Col.action, height: 1)
                        }
                        .padding(.vertical, PanelSpace.row)
                        .padding(.horizontal, 2)
                    }
                    ForEach(lane.details.filter { $0.mark == nil }) { detail in
                        GridRow {
                            Color.clear.frame(width: Col.mark)
                            Text(detail.label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                            Text("\(detail.shownPct)%")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: Col.used, alignment: .trailing)
                            Meter(value: detail.usedPct, tone: .ok)
                            Color.clear.frame(width: Col.meta, height: 1)
                            Color.clear.frame(width: Col.extra, height: 1)
                            Color.clear.frame(width: Col.action, height: 1)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func nameCell(title: String, caption: String?, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
    }

    private func usedText(_ lane: Lane) -> String {
        if let n = lane.usedPct { return "\(Int(n))%" }
        return "—"
    }

    private func leftText(_ lane: Lane) -> String {
        guard let left = lane.remainingPct, lane.tone == .ok || lane.tone == .warn || lane.tone == .crit else {
            return "—"
        }
        return "\(Int(left))%"
    }
}

private struct Meter: View {
    var value: Double
    var tone: Tone

    var body: some View {
        let fraction = CGFloat(min(max(value, 0), 100) / 100)
        let fillWidth = value <= 0 ? CGFloat(0) : max(2, Col.bar * fraction)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))
            Capsule()
                .fill(fill)
                .frame(width: fillWidth)
        }
        .frame(width: Col.bar, height: 5)
    }

    private var fill: Color {
        switch tone {
        case .warn: .orange
        case .crit, .error: .red
        default: Color.accentColor.opacity(0.85)
        }
    }
}

private enum PanelBand {
    case header, usage, bottom
}

private struct PanelBandHeights: Equatable {
    var header: CGFloat = 0
    var usage: CGFloat = 0
    var bottom: CGFloat = 0

    static func reading(_ band: PanelBand, _ height: CGFloat) -> PanelBandHeights {
        var value = PanelBandHeights()
        switch band {
        case .header: value.header = height
        case .usage: value.usage = height
        case .bottom: value.bottom = height
        }
        return value
    }
}

private struct PanelBandKey: PreferenceKey {
    static var defaultValue = PanelBandHeights()
    static func reduce(value: inout PanelBandHeights, nextValue: () -> PanelBandHeights) {
        let next = nextValue()
        if next.header > 0 { value.header = next.header }
        if next.usage > 0 { value.usage = next.usage }
        if next.bottom > 0 { value.bottom = next.bottom }
    }
}

private extension View {
    func panelBand(_ band: PanelBand) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PanelBandKey.self,
                    value: PanelBandHeights.reading(band, geo.size.height)
                )
            }
        )
    }
}

private func toneColor(_ tone: Tone) -> Color {
    switch tone {
    case .warn: .orange
    case .crit, .error: .red
    default: .primary
    }
}

private extension Text {
    func gridHeader() -> some View {
        self.frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }
}

private struct GrokConnectForm: View {
    @EnvironmentObject private var store: UsageStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Grok")
                .font(.system(size: 11, weight: .semibold))
            Text("0.2.111 prints Signed in but often does not write auth.json. Sign in here so QuotaBar writes key + expires_at itself.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !store.deviceUserCode.isEmpty {
                HStack {
                    Text(store.deviceUserCode)
                        .font(.system(size: 18, weight: .bold).monospaced())
                    Spacer()
                    Button("Copy code") { store.copyUserCode() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            if !store.deviceNote.isEmpty {
                Text(store.deviceNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(store.loginInProgress ? "Waiting…" : "Sign in with Grok") {
                    store.startDeviceLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.loginInProgress)
                if store.loginInProgress {
                    Button("Cancel") { store.cancelDeviceLogin() }
                        .buttonStyle(.borderless)
                }
            }
            SecureField("or paste token / auth.json", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack {
                Button("Save & refresh") {
                    let value = draft
                    draft = ""
                    Task { await store.connectGrok(value) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear") {
                    Task { await store.disconnectGrok() }
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ChatGPTConnectForm: View {
    @EnvironmentObject private var store: UsageStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect ChatGPT")
                .font(.system(size: 11, weight: .semibold))
            Text("Reads ~/.codex/auth.json after `codex login`. No extra browser login needed if Codex is already signed in.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("or paste Codex auth.json / access token", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button("Save ChatGPT") {
                let value = draft
                draft = ""
                Task { await store.connectChatGPT(value) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ClaudeConnectForm: View {
    @EnvironmentObject private var store: UsageStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Claude")
                .font(.system(size: 11, weight: .semibold))
            Text("Reads Claude Desktop Settings → Usage from the app's local session. Open Claude and stay signed in. A terminal `claude` login is not required. If the row stays here, click Allow on the Keychain prompt for Claude Safe Storage, then Refresh. Pasting Claude Code credentials is optional.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("or paste .credentials.json / access token", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button("Save Claude") {
                let value = draft
                draft = ""
                Task { await store.connectClaude(value) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MemoryRow: View {
    let usage: MemoryUsage?

    var body: some View {
        HStack(spacing: Col.gap) {
            Text("M")
                .font(.system(size: 11, weight: .bold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: Col.mark, alignment: .center)
            Text("Memory")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: Col.gap)
            Text(usage?.sizeLabel ?? "Unavailable")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, PanelSpace.row)
        .help("Active + wired + compressed physical memory; not memory pressure")
    }
}

private struct DiskSection: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSpace.label) {
            HStack {
                Text("Disks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Text(countLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if store.disks.isEmpty && store.hiddenDisks.isEmpty {
                Text("Waiting for mounted volumes…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !store.disks.isEmpty {
                Grid(alignment: .center, horizontalSpacing: Col.gap, verticalSpacing: 0) {
                    GridRow {
                        Text("").frame(width: Col.mark, height: 12)
                        Text("Name").gridHeader()
                        Text("Used").frame(width: Col.used, alignment: .trailing)
                        Color.clear.frame(width: Col.bar, height: 1)
                        Text("Free").frame(width: Col.meta, alignment: .trailing)
                        Text("I/O").frame(width: Col.extra, alignment: .trailing)
                        Color.clear.frame(width: Col.action, height: 1)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                    }
                    ForEach(Array(store.disks.prefix(8).enumerated()), id: \.element.id) { index, disk in
                        GridRow {
                            Button {
                                store.toggleInspect(disk)
                            } label: {
                                Text(disk.barLetter)
                                    .font(.system(size: 11, weight: .bold).monospaced())
                                    .foregroundStyle(disk.kind == .external ? Color.accentColor : Color.secondary)
                                    .frame(width: Col.mark, alignment: .center)
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.toggleInspect(disk)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(disk.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if disk.justChanged != nil {
                                        Text("new")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Text("\(Int(disk.usedPct.rounded()))%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(disk.tone == .ok ? Color.primary : toneColor(disk.tone))
                                .frame(width: Col.used, alignment: .trailing)
                            Meter(value: disk.usedPct, tone: disk.tone)
                            Text(disk.freeLabel)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: Col.meta, alignment: .trailing)
                                .lineLimit(1)
                            Text(disk.rateShort)
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(disk.rateShort == "—" ? .tertiary : .secondary)
                                .frame(width: Col.extra, alignment: .trailing)
                                .lineLimit(1)
                            Button("Hide") { store.ignoreDisk(disk.id) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: Col.action, alignment: .trailing)
                        }
                        .padding(.vertical, PanelSpace.row)
                        .padding(.horizontal, 2)
                        .background(index % 2 == 1 ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        if store.expandedDiskID == disk.id {
                            GridRow {
                                Color.clear.frame(width: Col.mark)
                                healthCell(disk)
                                    .gridCellColumns(5)
                                Color.clear.frame(width: Col.action)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if store.disks.count > 8 {
                Text("+\(store.disks.count - 8) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            if !store.hiddenDisks.isEmpty {
                HStack {
                    Text("Hidden")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.3)
                    Spacer()
                    Text("\(store.hiddenDisks.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                ForEach(store.hiddenDisks) { disk in
                    HStack(spacing: Col.gap) {
                        Text(disk.barLetter)
                            .font(.system(size: 11, weight: .bold).monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: Col.mark, alignment: .center)
                        Text(disk.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let hint = disk.ignoreHint {
                            Text(hint)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Button("Show") { store.unignoreDisk(disk.id) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: Col.action, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var countLabel: String {
        let n = store.disks.count
        let ext = store.disks.filter { $0.kind == .external }.count
        if n == 0 { return store.hiddenDisks.isEmpty ? "none" : "all hidden" }
        if ext == 0 { return "\(n)" }
        return "\(n)  ·  \(ext) external"
    }

    @ViewBuilder
    private func healthCell(_ disk: DiskVolume) -> some View {
        if store.healthBusyID == disk.id {
            Text("Reading SMART…")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        } else if let health = store.diskHealth[disk.id] {
            Text(healthLine(health, disk))
                .font(.system(size: 10.5))
                .foregroundStyle(health.smart.lowercased().contains("fail") ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func healthLine(_ health: DiskHealth, _ disk: DiskVolume) -> String {
        var parts = [health.smart]
        if !health.bus.isEmpty { parts.append(health.bus) }
        parts.append(disk.sizeLabel)
        if !health.note.isEmpty { parts.append(health.note) }
        return parts.joined(separator: "  ·  ")
    }
}

