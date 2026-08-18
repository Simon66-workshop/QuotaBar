import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !listedLanes.isEmpty {
                sectionLabel("Usage")
                UsageTable(lanes: listedLanes)
            }
            if store.snap.isLinked(.grok) {
                AccountRow()
                    .padding(.top, 6)
            }
            if showConnect {
                ConnectCell(idle: connectLanes)
                    .padding(.top, listedLanes.isEmpty ? 0 : 8)
            }
            DiskSection()
                .padding(.top, listedLanes.isEmpty && !showConnect ? 0 : 12)
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(Color.clear)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.bottom, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("QuotaBar")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("v1.8.5")
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
        .padding(.bottom, 10)
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
            Button("Refresh") { Task { await store.refresh() } }
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
        .padding(.top, 12)
        .font(.system(size: 12, weight: .semibold))
    }

    /// Connected or broken — those stay as rows. Empty ones fold into Connect.
    private var listedLanes: [Lane] {
        store.snap.lanes.filter { $0.tone != .empty }
    }

    private var connectLanes: [Lane] {
        store.snap.lanes.filter { $0.tone == .empty || $0.tone == .error }
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
            store.requestPanelRelayout()
        }
        .onChange(of: pick) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                store.requestPanelRelayout()
            }
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
            return
        }
        if formKeys.contains(pick) { return }
        if let broken = idle.first(where: { $0.tone == .error && formKeys.contains($0.key) }) {
            pick = broken.key
            return
        }
        pick = formKeys.first ?? .grok
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

private enum Col {
    static let gap: CGFloat = 6
    static let mark: CGFloat = 14
    static let used: CGFloat = 36
    static let bar: CGFloat = 44
    static let meta: CGFloat = 50
    static let extra: CGFloat = 54
    static let action: CGFloat = 28
}

private struct UsageTable: View {
    let lanes: [Lane]

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: Col.gap, verticalSpacing: 0) {
            GridRow {
                Text("").frame(width: Col.mark)
                Text("Name").gridHeader()
                Text("Used").frame(width: Col.used, alignment: .trailing)
                Color.clear.frame(width: Col.bar)
                Text("Left").frame(width: Col.meta, alignment: .trailing)
                Text("Window").frame(width: Col.extra, alignment: .trailing)
                Color.clear.frame(width: Col.action)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                laneRow(lane, zebra: index % 2 == 1)
                if (lane.key == .cursor || lane.key == .claude), !lane.details.isEmpty {
                    ForEach(lane.details) { detail in
                        GridRow {
                            Color.clear.frame(width: Col.mark)
                            Text(detail.label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(Int(detail.usedPct.rounded()))%")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: Col.used, alignment: .trailing)
                            Meter(value: detail.usedPct, tone: .ok)
                            Color.clear.frame(width: Col.meta)
                            Color.clear.frame(width: Col.extra)
                            Color.clear.frame(width: Col.action)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5).padding(.top, 16)
        }
    }

    @ViewBuilder
    private func laneRow(_ lane: Lane, zebra: Bool) -> some View {
        GridRow {
            Text(lane.key.letter)
                .font(.system(size: 11, weight: .bold).monospaced())
                .foregroundStyle(lane.tone == .ok ? Color.secondary : toneColor(lane.tone))
                .frame(width: Col.mark, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(lane.key.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if lane.tone == .error || lane.tone == .empty {
                    Text(lane.sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(usedText(lane))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(lane.tone == .ok ? Color.primary : toneColor(lane.tone))
                .frame(width: Col.used, alignment: .trailing)
            Meter(value: lane.usedPct ?? 0, tone: lane.tone)
            Text(leftText(lane))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Col.meta, alignment: .trailing)
            Text(lane.key.windowShort)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: Col.extra, alignment: .trailing)
                .lineLimit(1)
            Color.clear.frame(width: Col.action)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .background(zebra ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(fill)
                    .frame(width: max(value <= 0 ? 0 : 2, geo.size.width * CGFloat(min(max(value, 0), 100) / 100)))
            }
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

private func toneColor(_ tone: Tone) -> Color {
    switch tone {
    case .warn: .orange
    case .crit, .error: .red
    default: .primary
    }
}

private extension Text {
    func gridHeader() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Connect Claude Code")
                .font(.system(size: 11, weight: .semibold))
            Text("Reads ~/.claude/.credentials.json and the Claude Code keychain after you run `claude` once. 5-hour + 7-day windows.")
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

private struct DiskSection: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 4)
            if store.disks.isEmpty && store.hiddenDisks.isEmpty {
                Text("Waiting for mounted volumes…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !store.disks.isEmpty {
                Grid(alignment: .center, horizontalSpacing: Col.gap, verticalSpacing: 0) {
                    GridRow {
                        Text("").frame(width: Col.mark)
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Used").frame(width: Col.used, alignment: .trailing)
                        Color.clear.frame(width: Col.bar)
                        Text("Free").frame(width: Col.meta, alignment: .trailing)
                        Text("I/O").frame(width: Col.extra, alignment: .trailing)
                        Color.clear.frame(width: Col.action)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    ForEach(Array(store.disks.prefix(8).enumerated()), id: \.element.id) { index, disk in
                        diskRow(disk, zebra: index % 2 == 1)
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
                .padding(.top, 2)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5).padding(.top, 16)
                }
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
                .padding(.top, 8)
                .padding(.bottom, 2)
                ForEach(store.hiddenDisks) { disk in
                    HStack(spacing: Col.gap) {
                        Text(disk.barLetter)
                            .font(.system(size: 11, weight: .bold).monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: Col.mark, alignment: .center)
                        Text(disk.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
    private func diskRow(_ disk: DiskVolume, zebra: Bool) -> some View {
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
                        .lineLimit(1)
                    if disk.justChanged != nil {
                        Text("new")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .background(zebra ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                .foregroundStyle(health.smart.lowercased().contains("fail") ? .orange : .tertiary)
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

