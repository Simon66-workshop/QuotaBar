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
/// compact height. Above the cap, any positive usage viewport scrolls inside the usage
/// block so the header and footer stay pinned. The whole body scrolls only when the
/// chrome alone exceeds the cap.
///
/// Coalesce. A new layout key, a new band-measurement key, or a screen change schedules
/// one trailing fire. The same key is ignored, so an unchanged refresh does not measure
/// or resize. A timer signal is ignored. The window moves only when the height changes
/// by more than epsilon.

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
    /// Measurement-driven refits allowed before a sample settles within epsilon.
    /// A resize echo that keeps producing new heights stops here instead of looping.
    static let bandRefitBurst: Int = 6
    static let scrollHysteresis: Double = 8
    static let refitAnimation: Double = 0.16
    static let invalidMeasureFallback: Double = 160

    static var verticalPadding: Double { outerPadding * 2 }
}

struct PanelRefitState: Equatable {
    var contentKey: String
    /// Last natural band measurement that scheduled a refit. Independent of contentKey.
    var measureKey: String
    var pendingFireAt: TimeInterval?

    init(contentKey: String = "", measureKey: String = "", pendingFireAt: TimeInterval? = nil) {
        self.contentKey = contentKey
        self.measureKey = measureKey
        self.pendingFireAt = pendingFireAt
    }
}

enum PanelRefitSignal: Equatable {
    /// Layout-relevant content. The same key does not schedule.
    case content(String)
    /// Natural band heights. The same key does not schedule, and it does not replace contentKey.
    case measure(String)
    /// One follow-up after the scroll mode changes. Does not replace either key.
    case scrollFollowUp
    case screen
    case timer
}

/// Learned difference between an unconstrained measurement and the section formula.
/// `slack == 0` is a real calibration, not a stand-in for "never measured".
struct PanelSlackCalibration: Equatable {
    var slack: Double = 0
    var isCalibrated: Bool = false
}

struct PanelBandWatch: Equatable {
    var header: Double = 0
    var usage: Double = 0
    var bottom: Double = 0
    var epoch: Int = 0
    /// Bumped when a resize is applied, so the following sample is that layout's echo.
    var generation: Int = 0
    var echoArmed: Bool = false
    /// Last measurement bucket that scheduled a refit.
    var scheduledKey: String = ""
    /// Meaningful measurement refits since a sample settled on the same bucket.
    var burst: Int = 0
}

enum PanelBandDecision: Equatable {
    case ignore
    case schedule
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

/// Learn slack only from a live unconstrained measurement paired with a real formula.
/// A later content change while scrolling keeps that slack, including zero. This never
/// rebuilds slack from an older total and a newer formula.
func calibratePanelSlack(
    _ calibration: PanelSlackCalibration,
    liveMeasure: Double?,
    formula: Double
) -> PanelSlackCalibration {
    guard let liveMeasure, liveMeasure.isFinite, liveMeasure > 0 else { return calibration }
    guard formula.isFinite, formula > 0 else { return calibration }
    return PanelSlackCalibration(slack: liveMeasure - formula, isCalibrated: true)
}

/// Prefer a live unconstrained measurement. While a scroller is up, rebuild from the
/// section formula plus a calibrated slack. Uncalibrated slack is ignored, so a stored
/// zero cannot be mistaken for a missing sample and replaced with an old total.
func panelNaturalHeight(
    measured: Double?,
    formula: Double,
    calibration: PanelSlackCalibration
) -> Double? {
    if let measured, measured.isFinite, measured > 0 { return measured }
    guard formula.isFinite, formula > 0 else { return nil }
    let slack = calibration.isCalibrated ? calibration.slack : 0
    let rebuilt = formula + slack
    guard rebuilt.isFinite, rebuilt > 0 else { return nil }
    return rebuilt
}

func panelNaturalHeight(measured: Double?, formula: Double, slack: Double) -> Double? {
    panelNaturalHeight(
        measured: measured,
        formula: formula,
        calibration: PanelSlackCalibration(slack: slack, isCalibrated: true)
    )
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
    // A positive leftover keeps the header and footer pinned. Whole-body scroll is
    // only for chrome that already uses the entire cap.
    if viewport > 0 {
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
    case .measure(let key):
        if key == state.measureKey {
            return (state, .ignore)
        }
        var next = state
        next.measureKey = key
        let fireAt = now + wait
        next.pendingFireAt = fireAt
        return (next, .schedule(fireAt: fireAt))
    case .scrollFollowUp, .screen:
        var next = state
        let fireAt = now + wait
        next.pendingFireAt = fireAt
        return (next, .schedule(fireAt: fireAt))
    }
}

/// Stable identity for one layout. Callers pass the rows and chrome that change
/// height, not a request counter and not fields that only change the clock text.
func panelLayoutKey(parts: [String]) -> String {
    parts.joined(separator: "\u{1e}")
}

/// Bucket natural band heights so a sub-epsilon wiggle is the same measurement.
func panelMeasureKey(header: Double, usage: Double, bottom: Double, epsilon: Double) -> String {
    let step = max(epsilon, 0.000_001)
    func bucket(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value / step).rounded())
    }
    return "h\(bucket(header))u\(bucket(usage))b\(bucket(bottom))"
}

func armPanelBandEcho(_ watch: PanelBandWatch) -> PanelBandWatch {
    var next = watch
    next.generation += 1
    next.echoArmed = true
    return next
}

/// A real layout-content change, as opposed to a resize echo, may measure again.
func resetPanelBandBurst(_ watch: PanelBandWatch) -> PanelBandWatch {
    var next = watch
    next.burst = 0
    return next
}

/// Record natural band heights. Returns `.schedule` when they moved into a new
/// measurement bucket. A stale epoch is dropped. A usage height that merely echoes
/// the open scroller viewport is not a new natural size. Repeating the bucket just
/// scheduled — including the layout echo of a resize — does not schedule again.
/// A burst that never settles stops so a resize cannot feed itself; a later
/// layout-content change clears that burst.
func observePanelBands(
    watch: PanelBandWatch,
    header: Double,
    usage: Double,
    bottom: Double,
    epoch: Int,
    epsilon: Double,
    usageViewport: Double?
) -> (PanelBandWatch, PanelBandDecision) {
    guard epoch == watch.epoch else { return (watch, .ignore) }
    let slack = max(0, epsilon)
    var usageH = finitePositive(usage)
    if let usageViewport, usageViewport > 0,
       abs(usageH - usageViewport) <= max(slack, 1),
       watch.usage > usageViewport + max(slack, 1) {
        usageH = watch.usage
    }

    var next = watch
    next.echoArmed = false
    let headerH = finitePositive(header)
    let bottomH = finitePositive(bottom)
    if headerH > 0.5 { next.header = headerH }
    if bottomH > 0.5 { next.bottom = bottomH }
    if usageH > 0.5 {
        next.usage = usageH
    } else if headerH > 0.5 && bottomH > 0.5 {
        next.usage = 0
    }
    let changed = bandMoved(watch.header, next.header, slack)
        || bandMoved(watch.usage, next.usage, slack)
        || bandMoved(watch.bottom, next.bottom, slack)
    let key = panelMeasureKey(header: next.header, usage: next.usage, bottom: next.bottom, epsilon: slack)
    if !changed {
        return (next, .ignore)
    }
    // Same bucket as the refit we already scheduled, including a resize echo.
    if key == watch.scheduledKey {
        return (next, .ignore)
    }
    if watch.burst >= PanelFitMetrics.bandRefitBurst {
        return (next, .ignore)
    }
    next.burst = watch.burst + 1
    next.scheduledKey = key
    return (next, .schedule)
}

func shouldApplyPanelHeight(current: Double, proposed: Double, epsilon: Double) -> Bool {
    guard proposed.isFinite, proposed > 0 else { return false }
    guard current.isFinite, current > 0 else { return true }
    return abs(proposed - current) > max(0, epsilon)
}

private func bandMoved(_ previous: Double, _ next: Double, _ epsilon: Double) -> Bool {
    abs(previous - next) > epsilon
}

private func finitePositive(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 0 }
    return value
}

private func finiteNonNegative(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return max(0, value)
}
