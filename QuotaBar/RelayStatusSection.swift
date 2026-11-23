import AppKit
import SwiftUI

extension RelayLinkState {
    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .degraded: return .systemOrange
        case .down: return .systemRed
        case .unknown: return .systemGray
        }
    }

    @MainActor
    var menuImage: NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if self == .unknown {
                self.color.setStroke()
                dot.lineWidth = 1.4
                dot.stroke()
            } else {
                self.color.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

// Keep relay observations out of the existing usage/account rendering path.
struct LiveRelayStatusSection: View {
    @EnvironmentObject private var store: RelayStatusStore

    var body: some View {
        RelayStatusSection(display: store.display)
    }
}

struct RelayStatusSection: View {
    let display: RelayDisplay
    private let rightColumn: CGFloat = 115

    private var snapshot: RelaySnapshot? {
        if case .live(let snapshot) = display { return snapshot }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("转发器连接").fontWeight(.semibold)
                Spacer(minLength: 8)
                Text("最后心跳 · 上海").frame(width: rightColumn, alignment: .trailing)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            linkRow("飞书", link: snapshot?.feishu)
            linkRow("企微", link: snapshot?.wecom)
            HStack {
                Text("网站证书")
                Spacer(minLength: 8)
                Text(snapshot?.certificate.label ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(certificateColor)
            }
            .font(.system(size: 11))
            .frame(height: 16)
            Text(detail)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
                .help(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detail: String {
        switch display {
        case .live(let snapshot): return "快照观测 · \(RelaySnapshot.shanghaiTime(snapshot.observedAt)) 上海"
        case .unavailable(let issue): return issue.label
        }
    }

    private var certificateColor: Color {
        switch snapshot?.certificate.state {
        case .expiring: return .orange
        case .expired: return .red
        case .ok: return .primary
        default: return .secondary
        }
    }

    private func linkRow(_ title: String, link: RelayLink?) -> some View {
        let state = link?.state ?? .unknown
        return HStack(spacing: 6) {
            Group {
                if state == .unknown {
                    Circle().strokeBorder(Color(nsColor: state.color), lineWidth: 1.2)
                } else {
                    Circle().fill(Color(nsColor: state.color))
                }
            }
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
            Text(title).frame(width: 26, alignment: .leading)
            Text(state.label).fontWeight(.medium)
            if let reason = link?.reason.label, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(link?.lastHeartbeat.map(RelaySnapshot.shanghaiTime) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: rightColumn, alignment: .trailing)
        }
        .lineLimit(1)
        .font(.system(size: 11))
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}
