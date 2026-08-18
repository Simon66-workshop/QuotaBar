import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(listedLanes.enumerated()), id: \.element.id) { index, lane in
                if index > 0 {
                    Divider().opacity(0.18)
                }
                LaneRow(lane: lane)
            }
            if store.snap.isLinked(.grok) {
                AccountRow()
                    .padding(.top, 8)
            }
            if showConnect {
                ConnectCell(idle: connectLanes)
                    .padding(.top, listedLanes.isEmpty ? 0 : 8)
            }
            DiskSection()
                .padding(.top, 10)
            footer
        }
        .padding(16)
        .frame(width: 336)
        .background(Color.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("QuotaBar")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("v1.7")
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
                    .font(.system(size: 11, weight: .semibold))
                Text(idle.map(\.key.title).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

private struct LaneRow: View {
    let lane: Lane

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Ring(value: lane.usedPct ?? 0, tone: lane.tone)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(lane.key.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(lane.label)
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(color)
                }
                Text(subLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(lane.tone == .error || lane.tone == .empty ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if lane.key == .cursor || lane.key == .claude, !lane.details.isEmpty {
                    ForEach(lane.details) { d in
                        HStack(spacing: 6) {
                            Text(d.label)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            ProgressView(value: min(max(d.usedPct, 0), 100), total: 100)
                                .tint(.accentColor)
                            Text("\(Int(d.usedPct.rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                } else if !lane.details.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(lane.details) { d in
                            Text("\(d.label) \(Int(d.usedPct.rounded()))%")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(d.usedPct <= 0 ? 0.10 : 0.16), in: Capsule())
                        }
                    }
                } else {
                    ProgressView(value: min(max(lane.usedPct ?? 0, 0), 100), total: 100)
                        .tint(color == .primary ? .accentColor : color)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var subLine: String {
        if let left = lane.remainingPct, lane.tone == .ok || lane.tone == .warn || lane.tone == .crit {
            return "\(Int(left))% left  ·  \(lane.sub)"
        }
        return lane.sub
    }

    private var color: Color {
        switch lane.tone {
        case .warn: .orange
        case .crit, .error: .red
        default: .primary
        }
    }
}

private struct Ring: View {
    var value: Double
    var tone: Tone

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 3.2)
            Circle()
                .trim(from: 0, to: tone == .empty || tone == .error || value <= 0 ? 0 : max(value, 3) / 100)
                .stroke(stroke, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
    }

    private var stroke: Color {
        switch tone {
        case .warn: .orange
        case .crit, .error: .red
        default: .accentColor
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Disks")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(countLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if store.disks.isEmpty && store.hiddenDisks.isEmpty {
                Text("Waiting for mounted volumes…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.disks.prefix(6))) { disk in
                DiskRow(disk: disk)
            }
            if store.disks.count > 6 {
                Text("+\(store.disks.count - 6) more volumes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if !store.hiddenDisks.isEmpty {
                HStack {
                    Text("Hidden")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(store.hiddenDisks.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                ForEach(store.hiddenDisks) { disk in
                    HStack {
                        Text(disk.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let hint = disk.ignoreHint {
                            Text(hint)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Show") { store.unignoreDisk(disk.id) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
        }
    }

    private var countLabel: String {
        let n = store.disks.count
        if n == 0 { return store.hiddenDisks.isEmpty ? "none" : "all hidden" }
        return "\(n) volume\(n == 1 ? "" : "s")"
    }
}

private struct DiskRow: View {
    @EnvironmentObject private var store: UsageStore
    let disk: DiskVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(disk.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if disk.suggestedIgnore, let hint = disk.ignoreHint {
                    Text(hint)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                Spacer()
                Text("\(Int(disk.usedPct.rounded()))%")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: min(max(disk.usedPct, 0), 100), total: 100)
                .tint(color == .primary ? .accentColor : color)
            HStack {
                Text("\(disk.kindLabel) · \(disk.statusLabel)")
                Spacer()
                Text(disk.rateLabel)
                    .monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            HStack {
                Text(disk.sizeLabel)
                if let note = disk.justChanged {
                    Text(note)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(store.expandedDiskID == disk.id ? "Health ▾" : "Health") {
                    store.toggleInspect(disk)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
                Button(disk.suggestedIgnore ? "Hide \(disk.ignoreHint ?? "disk")" : "Hide") {
                    store.ignoreDisk(disk.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            if store.expandedDiskID == disk.id {
                if store.healthBusyID == disk.id {
                    Text("Reading SMART…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else if let health = store.diskHealth[disk.id] {
                    Text(health.line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(health.smart.lowercased().contains("fail") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch disk.tone {
        case .warn: .orange
        case .crit, .error: .red
        default: .primary
        }
    }
}
