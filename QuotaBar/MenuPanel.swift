import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(store.snap.lanes.enumerated()), id: \.element.id) { index, lane in
                if index > 0 {
                    Divider().opacity(0.18)
                }
                LaneRow(lane: lane)
            }
            if store.snap.grok.tone == .empty || store.snap.grok.tone == .error {
                GrokConnectForm()
                    .padding(.top, 8)
            }
            footer
        }
        .padding(16)
        .frame(width: 336)
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.22),
                        Color.white.opacity(0.04),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.72),
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.28),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16.5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                            .padding(1.1)
                    )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("QuotaBar")
                .font(.system(size: 15, weight: .semibold))
            Text(statusLine)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
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
                Text(lane.sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if lane.key == .cursor, !lane.details.isEmpty {
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
            Text("In Terminal run  grok login  once. Or paste the access token / auth.json here.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("token or auth.json", text: $draft)
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