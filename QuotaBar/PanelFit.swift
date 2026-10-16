import Foundation

/// Panel height and refit coalescing. Foundation only, so the decisions are unit tested.
///
/// Cap. `visibleFrame.height - menuBarHeight - safetyMargin`, where menu-bar height is
/// `screen.maxY - visibleFrame.maxY` on the screen that holds the status item. The same
/// margin is removed from the room under the status item, and the smaller of the two wins.
/// There is no fixed 720.
///
/// Split. `natural` is the measured content height, or the sum of header, usage, bottom,
/// padding, and section gaps when a live measurement is unavailable. At or under the cap
/// (within epsilon, or a hysteresis band while already scrolling) the panel keeps that
/// compact height. Above the cap, the usage block scrolls when the leftover viewport is
/// usable; otherwise the whole body scrolls. Header and bottom chrome stay outside the
/// usage scroller.
///
/// Coalesce. A new content key or a screen change schedules one trailing fire. The same
/// content key is ignored. A timer signal is ignored, so a polling tick never resizes.
/// The window moves only when the height changes by more than epsilon.

enum PanelScrollMode: Equatable {
    case none
    case usage(Double)
    case body
}

struct PanelFitPlan: Equatable {
    var height: Double
    var scroll: PanelScrollMode
}

enum PanelFitMetrics {
    static let panelWidth: Double = 448
    static let outerPadding: Double = 16
    static let sectionSpacing: Double = 10
    static let safetyMargin: Double = 16
    static let anchorGap: Double = 6
    static let refitDelay: Double = 0.12
    static let heightEpsilon: Double = 0.5
    static let minUsageViewport: Double = 72
    static let scrollHysteresis: Double = 8
    static let refitAnimation: Double = 0.16
    static let invalidMeasureFallback: Double = 160

    static var verticalPadding: Double { outerPadding * 2 }
}

struct PanelRefitState: Equatable {
    var contentKey: String
    var pendingFireAt: TimeInterval?

    init(contentKey: String = "", pendingFireAt: TimeInterval? = nil) {
        self.contentKey = contentKey
        self.pendingFireAt = pendingFireAt
    }
}

enum PanelRefitSignal: Equatable {
    case content(String)
    case screen
    case timer
}

enum PanelRefitDecision: Equatable {
    case ignore
    /// Trailing fire. Replaces any fire already pending.
    case schedule(fireAt: TimeInterval)
}

func menuBarHeight(screenMaxY: Double, visibleMaxY: Double) -> Double {
    let height = screenMaxY - visibleMaxY
    guard height.isFinite else { return 0 }
    return max(0, height)
}

/// Distance from the panel's anchored top down to the bottom of the visible frame.
func roomBelowStatusItem(statusBottom: Double, anchorGap: Double, visibleMinY: Double) -> Double {
    let room = statusBottom - max(0, anchorGap) - visibleMinY
    guard room.isFinite else { return 0 }
    return max(0, room)
}

func panelHeightCap(
    visibleHeight: Double,
    menuBarHeight: Double,
    safetyMargin: Double,
    roomBelowAnchor: Double? = nil
) -> Double {
    let margin = finiteNonNegative(safetyMargin)
    let screenCap = finiteNonNegative(visibleHeight) - finiteNonNegative(menuBarHeight) - margin
    let capped: Double
    if let room = roomBelowAnchor, room.isFinite {
        capped = min(screenCap, finiteNonNegative(room) - margin)
    } else {
        capped = screenCap
    }
    guard capped.isFinite else { return 0 }
    return max(0, capped)
}

/// Padding plus the gaps between the header, usage, and bottom bands that are present.
func panelSectionExtra(
    header: Double,
    usage: Double,
    bottom: Double,
    verticalPadding: Double,
    sectionSpacing: Double
) -> Double {
    let count = [header, usage, bottom].filter { finitePositive($0) > 0 }.count
    let gaps = Double(max(0, count - 1))
    return finiteNonNegative(verticalPadding) + finiteNonNegative(sectionSpacing) * gaps
}

/// Sum of the bands that are actually present, including padding and section gaps.
func panelFormulaHeight(
    header: Double,
    usage: Double,
    bottom: Double,
    verticalPadding: Double,
    sectionSpacing: Double
) -> Double {
    let headerH = finitePositive(header)
    let usageH = finitePositive(usage)
    let bottomH = finitePositive(bottom)
    guard headerH > 0 || usageH > 0 || bottomH > 0 else { return 0 }
    let extra = panelSectionExtra(
        header: headerH,
        usage: usageH,
        bottom: bottomH,
        verticalPadding: verticalPadding,
        sectionSpacing: sectionSpacing
    )
    return headerH + usageH + bottomH + extra
}

/// Prefer a live unconstrained measurement. While a scroller is up, rebuild from the
/// section formula plus the slack learned the last time the panel was unconstrained.
func panelNaturalHeight(measured: Double?, formula: Double, slack: Double) -> Double? {
    if let measured, measured.isFinite, measured > 0 { return measured }
    guard formula > 0 else { return nil }
    let rebuilt = formula + slack
    guard rebuilt.isFinite, rebuilt > 0 else { return nil }
    return rebuilt
}

/// `measured` is the hosting view's unconstrained height. Pass nil while a scroller is
/// already active and the section heights are the source of truth.
func fitPanel(
    measured: Double?,
    header: Double,
    usage: Double,
    bottom: Double,
    verticalPadding: Double,
    sectionSpacing: Double,
    cap: Double,
    minUsageViewport: Double,
    epsilon: Double,
    currentlyScrolling: Bool,
    hysteresis: Double
) -> PanelFitPlan {
    let headerH = finitePositive(header)
    let usageH = finitePositive(usage)
    let bottomH = finitePositive(bottom)
    let formula = panelFormulaHeight(
        header: headerH,
        usage: usageH,
        bottom: bottomH,
        verticalPadding: verticalPadding,
        sectionSpacing: sectionSpacing
    )
    let measuredH = measured.flatMap { value in
        value.isFinite && value > 0 ? value : nil
    }
    if headerH == 0, usageH == 0, bottomH == 0, measuredH == nil {
        return PanelFitPlan(height: PanelFitMetrics.invalidMeasureFallback, scroll: .none)
    }
    let natural = measuredH ?? formula
    if natural <= 0 {
        return PanelFitPlan(height: PanelFitMetrics.invalidMeasureFallback, scroll: .none)
    }

    let limit = cap.isFinite && cap > 0 ? cap.rounded(.down) : natural.rounded(.up)
    let fits = currentlyScrolling
        ? natural <= limit - max(0, hysteresis)
        : natural <= limit + max(0, epsilon)
    if fits {
        let rounded = natural.rounded(.up)
        let height = rounded <= limit ? rounded : limit
        return PanelFitPlan(height: max(1, height), scroll: .none)
    }

    if usageH <= 0 || usageH > natural + 1 {
        return PanelFitPlan(height: limit, scroll: .body)
    }
    let fixed = natural - usageH
    let viewport = (limit - fixed).rounded()
    if usageH >= minUsageViewport, viewport >= minUsageViewport {
        return PanelFitPlan(height: limit, scroll: .usage(viewport))
    }
    return PanelFitPlan(height: limit, scroll: .body)
}

func coalescePanelRefit(
    state: PanelRefitState,
    signal: PanelRefitSignal,
    now: TimeInterval,
    delay: TimeInterval
) -> (PanelRefitState, PanelRefitDecision) {
    let wait = max(0, delay)
    switch signal {
    case .timer:
        return (state, .ignore)
    case .content(let key):
        if key == state.contentKey {
            return (state, .ignore)
        }
        var next = state
        next.contentKey = key
        let fireAt = now + wait
        next.pendingFireAt = fireAt
        return (next, .schedule(fireAt: fireAt))
    case .screen:
        var next = state
        let fireAt = now + wait
        next.pendingFireAt = fireAt
        return (next, .schedule(fireAt: fireAt))
    }
}

func shouldApplyPanelHeight(current: Double, proposed: Double, epsilon: Double) -> Bool {
    guard proposed.isFinite, proposed > 0 else { return false }
    guard current.isFinite, current > 0 else { return true }
    return abs(proposed - current) > max(0, epsilon)
}

private func finitePositive(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 0 }
    return value
}

private func finiteNonNegative(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return max(0, value)
}
