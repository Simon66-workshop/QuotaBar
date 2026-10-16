import Foundation

/// Parser and menu-bar title checks for Claude AC / AT / AF.
/// Run on macOS or Linux: `QuotaBarTests/run.sh`

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        fputs("FAIL \(message)\n", stderr)
    }
}

func payload(_ text: String) -> [String: Any] {
    let data = Data(text.utf8)
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("fixture did not parse: \(text)\n", stderr)
        exit(1)
    }
    return obj
}

func sampleAuth() -> ClaudeAuth {
    ClaudeAuth(
        access: "token",
        refresh: "",
        expiresAt: .distantFuture,
        subscription: "max",
        tier: "20x"
    )
}

let eastern = TimeZone(identifier: "America/New_York")!

/// Wed Sep 30 8:32 PM Eastern, when the screenshot was taken.
let screenshotNow = ISO8601DateFormatter().date(from: "2026-10-01T00:32:00Z")!

func parse(_ text: String, zone: TimeZone = eastern, now: Date = screenshotNow) -> Lane? {
    ClaudeUsage.parse(payload(text), auth: sampleAuth(), resetTimeZone: zone, now: now)
}

let sessionReset = "2026-10-01T04:10:00.000Z"
let weekReset = "2026-10-02T00:00:00.000Z"

let allThree = """
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": {"utilization": 94, "resets_at": "\(weekReset)"}
}
"""

guard let full = parse(allThree) else {
    fputs("FAIL all three windows parsed to nil\n", stderr)
    exit(1)
}

check(full.details.map(\.mark) == ["AC", "AT", "AF"], "marks \(full.details.map(\.mark))")
check(full.details.map(\.label) == ["Current session", "This week", "Fable this week"], "labels \(full.details.map(\.label))")
check(full.details.map(\.shownPct) == [19, 82, 94], "percents \(full.details.map(\.shownPct))")
check(full.details.map(\.window) == ["5h", "week", "week"], "windows \(full.details.map(\.window))")
check(full.details.map(\.reset) == ["resets Thu 12:10 AM", "resets 8:00 PM", "resets 8:00 PM"], "resets \(full.details.map(\.reset))")
check(full.details.map(\.tone) == [.ok, .ok, .warn], "tones \(full.details.map(\.tone))")
check(full.usedPct == 82, "primary stays the tighter account window, got \(full.usedPct ?? -1)")
check(full.tone == .ok, "lane tone follows week 82, not Fable 94")
check(full.sub == "max 20x", "plan sub \(full.sub)")

let groups = Snapshot.barGroups(lanes: [
    Lane.used(.grok, percent: 21, sub: "week", details: [
        LaneDetail(label: "Chat", usedPct: 10),
        LaneDetail(label: "Builder", usedPct: 11),
    ]),
    Lane.used(.cursor, percent: 40, sub: "month", details: [
        LaneDetail(label: "Cursor Models", usedPct: 12),
        LaneDetail(label: "Other Models", usedPct: 28),
    ]),
    Lane.used(.bot, percent: 55, sub: "week"),
    Lane.used(.gpt, percent: 15, sub: "cap"),
    full,
], disks: [
    DiskVolume(
        id: "sys",
        name: "Macintosh HD",
        path: "/",
        kind: .internalDrive,
        totalBytes: 1000,
        freeBytes: 300,
        usedPct: 70,
        readBps: 0,
        writeBps: 0,
        isReadOnly: false,
        isRoot: true,
        justChanged: nil,
        suggestedIgnore: false,
        ignoreHint: nil
    ),
    DiskVolume(
        id: "ext",
        name: "Backup",
        path: "/Volumes/Backup",
        kind: .external,
        totalBytes: 1000,
        freeBytes: 600,
        usedPct: 40,
        readBps: 0,
        writeBps: 0,
        isReadOnly: false,
        isRoot: false,
        justChanged: nil,
        suggestedIgnore: false,
        ignoreHint: nil
    ),
])
let title = Snapshot.title(from: groups)
check(title == "G 21 · O 15 · AC 19  AT 82  AF 94 · D 70 · E 40", "bar title \(title)")
check(groups.count == 5, "groups \(groups.count)")
check(groups[2].map(\.tone) == [.ok, .ok, .warn], "bar tones \(groups[2].map(\.tone))")
check(!title.contains("Chat"), "grok details stayed off the bar")
check(!title.contains("C 40"), "cursor stayed off the bar")
check(!title.contains("B 55"), "grok bot stayed off the bar")
check(LaneKey.cursor.foldedIntoGrok && LaneKey.bot.foldedIntoGrok, "cursor and bot fold into G")
check(!LaneKey.grok.foldedIntoGrok && !LaneKey.gpt.foldedIntoGrok && !LaneKey.claude.foldedIntoGrok, "other lanes stay separate")
check(LaneKey.sharedPoolCaption == "Shared Grok + Cursor + Bot pool", "shared pool caption")

let noFable = parse("""
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": null
}
""")
check(noFable?.details.map(\.mark) == ["AC", "AT"], "missing fable marks \(noFable?.details.map(\.mark) ?? [])")
check(noFable?.details.contains { $0.mark == "AF" } == false, "AF hidden when seven_day_fable is null")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [noFable].compactMap { $0 }, disks: [])) == "AC 19  AT 82", "bar without AF")

let absentKey = parse("""
{
  "fiveHour": {"percent": 4, "resets_at": "\(sessionReset)"},
  "sevenDay": {"used_percent": 10, "reset_at": "\(weekReset)"}
}
""")
check(absentKey?.details.map(\.mark) == ["AC", "AT"], "camelCase session and week \(absentKey?.details.map(\.mark) ?? [])")
check(absentKey?.details.map(\.shownPct) == [4, 10], "camelCase percents")

let zeroSession = parse("""
{
  "five_hour": {"utilization": 0, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": {"utilization": 0, "resets_at": "\(weekReset)"}
}
""")
check(zeroSession?.details.map { "\($0.mark ?? "")\($0.shownPct)" } == ["AC0", "AT82", "AF0"], "zero is a real reading")

let onlyWeekAndFable = parse("""
{
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": {"utilization": 94, "resets_at": "\(weekReset)"}
}
""")
check(onlyWeekAndFable?.details.map(\.mark) == ["AT", "AF"], "missing session hides AC")

let opusNotFable = parse("""
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_opus": {"utilization": 94, "resets_at": "\(weekReset)"},
  "seven_day_sonnet": {"utilization": 8, "resets_at": "\(weekReset)"}
}
""")
check(opusNotFable?.details.map(\.mark) == ["AC", "AT", nil, nil], "opus and sonnet are not AF \(opusNotFable?.details.map(\.mark) ?? [])")
check(opusNotFable?.details.map(\.label) == ["Current session", "This week", "Sonnet this week", "Opus this week"], "named model order")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [opusNotFable].compactMap { $0 }, disks: [])) == "AC 19  AT 82", "opus stays off the bar")

let limits = parse("""
{
  "limits": [
    {"kind": "weekly_scoped", "utilization": 94, "resets_at": "\(weekReset)", "scope": {"model": {"display_name": "Fable"}}},
    {"kind": "weekly_all", "utilization": 82, "resets_at": "\(weekReset)"},
    {"kind": "session", "utilization": 19, "resets_at": "\(sessionReset)"}
  ]
}
""")
check(limits?.details.map(\.mark) == ["AC", "AT", "AF"], "limits[] order \(limits?.details.map(\.mark) ?? [])")
check(limits?.details.map(\.shownPct) == [19, 82, 94], "limits[] percents")
check(limits?.details.map(\.reset) == ["resets Thu 12:10 AM", "resets 8:00 PM", "resets 8:00 PM"], "limits[] resets")

let camelFable = parse("""
{
  "five_hour_utilization": 19,
  "seven_day_utilization": 82,
  "sevenDayFable": {"utilization": "94", "resets_at": "\(weekReset)"},
  "models": [{"display_name": "Fable", "utilization": 94, "resets_at": "\(weekReset)"}]
}
""")
check(camelFable?.details.filter { $0.mark == "AF" }.count == 1, "fable key and models[] collapse to one AF")
check(camelFable?.details.first { $0.mark == "AF" }?.shownPct == 94, "string utilization 94")
check(camelFable?.details.first { $0.mark == "AC" }?.reset == nil, "bare utilization has no reset")

let thresholds = parse("""
{
  "five_hour": {"utilization": 84.4},
  "seven_day": {"utilization": 85},
  "seven_day_fable": {"utilization": 95}
}
""")
check(thresholds?.details.map(\.tone) == [.ok, .warn, .crit], "84 ok, 85 warn, 95 crit \(thresholds?.details.map(\.tone) ?? [])")
check(thresholds?.details.map(\.shownPct) == [84, 85, 95], "rounded percents")
check(thresholds?.usedPct == 85, "primary is week 85")
check(thresholds?.tone == .warn, "lane tone warn at 85")

let tie = parse("""
{
  "five_hour": {"utilization": 40, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 40, "resets_at": "\(weekReset)"}
}
""")
check(tie?.window == "5h", "tie keeps the session window")
check(tie?.usedPct == 40, "tie percent")

let opusOnly = parse("""
{"seven_day_opus": {"utilization": 94, "resets_at": "\(weekReset)"}}
""")
check(opusOnly?.details.map(\.mark) == [nil], "opus-only has no AF mark")
check(opusOnly?.details.first?.label == "Opus this week", "opus label")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [opusOnly].compactMap { $0 }, disks: [])) == "A 94", "opus-only stays a single A figure")

let broken = Lane.error(.claude, message: "Claude Desktop usage had no session or week window")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [broken], disks: [])) == "A —", "error lane stays A —")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [Lane.error(.grok, message: "billing HTTP 401")], disks: [])) == "G —", "grok error stays on the bar")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [Lane.used(.cursor, percent: 40, sub: "month"), Lane.used(.bot, percent: 9, sub: "week")], disks: [])) == "QuotaBar", "cursor and bot alone stay off the bar")

check(parse("{}") == nil, "empty object")
check(parse("{\"five_hour\": \"nope\", \"seven_day\": [], \"seven_day_fable\": {\"utilization\": null}, \"limits\": {\"kind\": \"session\"}, \"models\": \"fable\"}") == nil, "malformed types")
check(parse("{\"limits\": [null, \"x\", {\"kind\": \"nope\", \"percent\": 5}, {\"kind\": \"weekly_scoped\"}]}") == nil, "limits garbage")

let partialGarbage = parse("""
{
  "five_hour": {"utilization": "19", "resets_at": "\(sessionReset)"},
  "seven_day": "bad",
  "seven_day_fable": {},
  "limits": [null, "x", {"kind": "weekly_scoped"}]
}
""")
check(partialGarbage?.details.map(\.mark) == ["AC"], "one valid window among garbage \(partialGarbage?.details.map(\.mark) ?? [])")
check(partialGarbage?.details.first?.shownPct == 19, "string 19")
check(partialGarbage?.details.first?.reset == "resets Thu 12:10 AM", "fractional timestamp")

let emptyScoped = parse("""
{
  "limits": [
    {"kind": "session", "percent": 19, "resets_at": "\(sessionReset)"},
    {"kind": "weekly", "used_percentage": 82, "resets_at": "\(weekReset)"},
    {"kind": "weekly_scoped", "percent": 94, "resets_at": "\(weekReset)", "scope": {"model": {"display_name": ""}}}
  ]
}
""")
check(emptyScoped?.details.map(\.mark) == ["AC", "AT", nil], "unnamed scoped limit is not AF")
check(emptyScoped?.details.last?.label == "Model this week", "empty model label")

let farWeek = parse("""
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "2026-10-06T00:00:00.943648+00:00"},
  "seven_day_fable": {"utilization": 94, "resets_at": "2026-10-06T00:00:00.943648+00:00"}
}
""")
check(farWeek?.details.map(\.reset) == ["resets Thu 12:10 AM", "resets Mon 8:00 PM", "resets Mon 8:00 PM"], "weekly reset days out keeps weekday \(farWeek?.details.map(\.reset) ?? [])")

let fableTwice = parse("""
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": {"utilization": 94, "resets_at": "\(weekReset)"},
  "limits": [
    {"kind": "weekly_scoped", "utilization": 94, "resets_at": "\(weekReset)", "scope": {"model": {"display_name": "Claude Fable"}}}
  ]
}
""")
check(fableTwice?.details.filter { $0.mark == "AF" }.count == 1, "differently named Fable sources collapse to one AF \(fableTwice?.details.map(\.label) ?? [])")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [fableTwice].compactMap { $0 }, disks: [])) == "AC 19  AT 82  AF 94", "bar has a single AF")

runPanelFitChecks()

if failures == 0 {
    print("ok \(checks) checks")
} else {
    fputs("\(failures) failed of \(checks)\n", stderr)
    exit(1)
}

func near(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 0.000_001
}

func fired(_ decision: PanelRefitDecision, at expected: TimeInterval) -> Bool {
    guard case .schedule(let fireAt) = decision else { return false }
    return near(fireAt, expected)
}

func runPanelFitChecks() {
    check(menuBarHeight(screenMaxY: 900, visibleMaxY: 875) == 25, "menu bar is the strip above the visible frame")
    check(menuBarHeight(screenMaxY: 800, visibleMaxY: 800) == 0, "flush frames have no menu bar inset")
    check(menuBarHeight(screenMaxY: 100, visibleMaxY: 140) == 0, "negative menu bar clamps to zero")

    let cap = panelHeightCap(visibleHeight: 1000, menuBarHeight: 40, safetyMargin: 16)
    check(cap == 944, "cap is visible frame minus menu bar and margin, got \(cap)")
    let anchored = panelHeightCap(visibleHeight: 1000, menuBarHeight: 40, safetyMargin: 16, roomBelowAnchor: 700)
    check(anchored == 684, "room under the status item tightens the cap, got \(anchored)")
    let collapsed = panelHeightCap(visibleHeight: 100, menuBarHeight: 200, safetyMargin: 16)
    check(collapsed == 0, "cap clamps at zero, got \(collapsed)")
    let room = roomBelowStatusItem(statusBottom: 880, anchorGap: 6, visibleMinY: 40)
    check(room == 834, "room below the anchor, got \(room)")

    let compact = fitPanel(
        measured: nil,
        header: 40, usage: 100, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 800,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(compact == PanelFitPlan(height: 272, scroll: .none), "small content keeps its compact height \(compact)")

    let measuredWins = fitPanel(
        measured: 300,
        header: 40, usage: 400, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 800,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(measuredWins.scroll == .none && measuredWins.height == 300, "a real measurement wins when it fits \(measuredWins)")

    let usageScroll = fitPanel(
        measured: nil,
        header: 40, usage: 900, bottom: 200,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 700.8,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(usageScroll == PanelFitPlan(height: 700, scroll: .usage(408)), "tall usage scrolls inside the cap \(usageScroll)")

    let measuredSplit = fitPanel(
        measured: 900,
        header: 10, usage: 600, bottom: 10,
        verticalPadding: 0, sectionSpacing: 0,
        cap: 700,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(measuredSplit == PanelFitPlan(height: 700, scroll: .usage(400)), "split uses measured total minus usage \(measuredSplit)")

    let bodyScroll = fitPanel(
        measured: nil,
        header: 200, usage: 400, bottom: 400,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 500,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(bodyScroll == PanelFitPlan(height: 500, scroll: .body), "chrome that does not fit scrolls the whole body \(bodyScroll)")

    let noUsage = fitPanel(
        measured: nil,
        header: 40, usage: 0, bottom: 800,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 400,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(noUsage == PanelFitPlan(height: 400, scroll: .body), "no usage block scrolls the body \(noUsage)")
    check(panelSectionExtra(header: 40, usage: 0, bottom: 800, verticalPadding: 32, sectionSpacing: 10) == 42, "one gap when usage is absent")

    let barelyOver = fitPanel(
        measured: 600.4,
        header: 40, usage: 400, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 600,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(barelyOver == PanelFitPlan(height: 600, scroll: .none), "sub-point overflow stays unscrolling \(barelyOver)")

    let holdScroll = fitPanel(
        measured: 596,
        header: 40, usage: 400, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 600,
        epsilon: 0.5,
        currentlyScrolling: true, hysteresis: 8
    )
    check(holdScroll.scroll != .none && holdScroll.height == 600, "hysteresis keeps an open scroller \(holdScroll)")

    let releaseScroll = fitPanel(
        measured: 580,
        header: 40, usage: 400, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 600,
        epsilon: 0.5,
        currentlyScrolling: true, hysteresis: 8
    )
    check(releaseScroll == PanelFitPlan(height: 580, scroll: .none), "a real shrink leaves the scroller \(releaseScroll)")

    let badProbe = fitPanel(
        measured: 900,
        header: 40, usage: 0, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 600,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(badProbe == PanelFitPlan(height: 600, scroll: .body), "missing usage measurement scrolls the body \(badProbe)")

    let empty = fitPanel(
        measured: nil,
        header: .nan, usage: .infinity, bottom: -4,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 600,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(empty == PanelFitPlan(height: 160, scroll: .none), "non-finite sections fall back \(empty)")

    let uncapped = fitPanel(
        measured: 400,
        header: 40, usage: 100, bottom: 80,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 0,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(uncapped == PanelFitPlan(height: 400, scroll: .none), "a zero cap does not squash a measurement \(uncapped)")
    check(panelFormulaHeight(header: 40, usage: 100, bottom: 80, verticalPadding: 32, sectionSpacing: 10) == 272, "formula matches the compact stack")
    check(panelNaturalHeight(measured: 300, formula: 280, slack: 8) == 300, "a live measurement beats the rebuilt height")
    check(panelNaturalHeight(measured: nil, formula: 280, slack: 8) == 288, "while scrolling, rebuild from formula plus slack")
    check(panelNaturalHeight(measured: nil, formula: 0, slack: 8) == nil, "no bands and no measurement is not a height")
    let uncalibrated = PanelSlackCalibration(slack: -100, isCalibrated: false)
    check(panelNaturalHeight(measured: nil, formula: 1052, calibration: uncalibrated) == 1052, "uncalibrated slack is not applied")

    let shortViewport = fitPanel(
        measured: nil,
        header: 40, usage: 100, bottom: 548,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 700,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(shortViewport == PanelFitPlan(height: 700, scroll: .usage(60)), "a 60pt usage viewport stays pinned \(shortViewport)")
    let chromeFillsCap = fitPanel(
        measured: nil,
        header: 324, usage: 100, bottom: 324,
        verticalPadding: 32, sectionSpacing: 10,
        cap: 700,
        epsilon: 0.5,
        currentlyScrolling: false, hysteresis: 8
    )
    check(chromeFillsCap == PanelFitPlan(height: 700, scroll: .body), "chrome that fills the cap scrolls the body \(chromeFillsCap)")

    runSlackSequenceChecks()
    runBandRefitChecks()

    var state = PanelRefitState()
    let first = coalescePanelRefit(state: state, signal: .content("a"), now: 10, delay: 0.12)
    state = first.0
    check(fired(first.1, at: 10.12), "content schedules a trailing fire \(first.1)")
    check(state.contentKey == "a" && near(state.pendingFireAt, 10.12), "pending fire is stored")

    let burst = coalescePanelRefit(state: state, signal: .content("b"), now: 10.05, delay: 0.12)
    state = burst.0
    check(fired(burst.1, at: 10.17), "a second change pushes the fire back \(burst.1)")
    check(state.contentKey == "b", "latest content key wins")

    let tick = coalescePanelRefit(state: state, signal: .timer, now: 10.10, delay: 0.12)
    check(tick.0 == state && tick.1 == .ignore, "a timer tick does not schedule or clear \(tick.1)")

    let same = coalescePanelRefit(state: PanelRefitState(contentKey: "b"), signal: .content("b"), now: 20, delay: 0.12)
    check(same.1 == .ignore && same.0.pendingFireAt == nil, "the same content key does not refit")

    let screen = coalescePanelRefit(state: state, signal: .screen, now: 10.20, delay: 0.12)
    check(fired(screen.1, at: 10.32), "screen changes schedule even when content is unchanged \(screen.1)")
    check(screen.0.contentKey == "b", "a screen change keeps the content key")

    let layout = panelLayoutKey(parts: ["lane:grok:listed", "copied:", "disks:main"])
    let refreshed = panelLayoutKey(parts: ["lane:grok:listed", "copied:", "disks:main"])
    check(layout == refreshed, "the same rows produce the same layout key")
    var laid = PanelRefitState()
    let firstLayout = coalescePanelRefit(state: laid, signal: .content(layout), now: 30, delay: 0.12)
    laid = firstLayout.0
    check(fired(firstLayout.1, at: 30.12), "a layout key schedules one trailing fire")
    let quietRefresh = coalescePanelRefit(state: laid, signal: .content(refreshed), now: 120, delay: 0.12)
    check(quietRefresh.1 == .ignore && quietRefresh.0.pendingFireAt == laid.pendingFireAt, "an unchanged 90s refresh does no refit")
    let counted = coalescePanelRefit(state: laid, signal: .content("c41"), now: 120, delay: 0.12)
    check(fired(counted.1, at: 120.12), "a request counter would still schedule, which is why the key is the layout")
    let measuredBands = coalescePanelRefit(state: laid, signal: .measure("h80u1200b520"), now: 40, delay: 0.12)
    check(fired(measuredBands.1, at: 40.12), "a new band measurement schedules")
    check(measuredBands.0.contentKey == layout, "a measurement does not replace the layout key")
    let afterMeasure = coalescePanelRefit(state: measuredBands.0, signal: .content(layout), now: 210, delay: 0.12)
    check(afterMeasure.1 == .ignore, "an unchanged refresh after a measurement does no refit")
    let sameBands = coalescePanelRefit(state: measuredBands.0, signal: .measure("h80u1200b520"), now: 41, delay: 0.12)
    check(sameBands.1 == .ignore, "the same band measurement does not refit again")
    let follow = coalescePanelRefit(state: measuredBands.0, signal: .scrollFollowUp, now: 42, delay: 0.12)
    check(fired(follow.1, at: 42.12) && follow.0.contentKey == layout && follow.0.measureKey == "h80u1200b520", "a scroll follow-up keeps both keys")
    check(
        panelMeasureKey(header: 40, usage: 600, bottom: 260, epsilon: 0.5)
            == panelMeasureKey(header: 40.2, usage: 600.1, bottom: 259.9, epsilon: 0.5),
        "sub-point band changes share a measure key"
    )
    check(
        panelMeasureKey(header: 40, usage: 600, bottom: 260, epsilon: 0.5)
            != panelMeasureKey(header: 40, usage: 600, bottom: 280, epsilon: 0.5),
        "a real band change is a new measure key"
    )

    check(shouldApplyPanelHeight(current: 200, proposed: 200.4, epsilon: 0.5) == false, "sub-point height is ignored")
    check(shouldApplyPanelHeight(current: 200, proposed: 212, epsilon: 0.5) == true, "a real height change applies")
    check(shouldApplyPanelHeight(current: 0, proposed: 180, epsilon: 0.5) == true, "the first height applies")
    check(shouldApplyPanelHeight(current: 180, proposed: .nan, epsilon: 0.5) == false, "a non-finite height does not apply")
}

func runSlackSequenceChecks() {
    func formula(usage: Double, bottom: Double) -> Double {
        panelFormulaHeight(header: 40, usage: usage, bottom: bottom, verticalPadding: 32, sectionSpacing: 10)
    }
    func plan(measured: Double?, usage: Double, bottom: Double, scrolling: Bool) -> PanelFitPlan {
        fitPanel(
            measured: measured,
            header: 40, usage: usage, bottom: bottom,
            verticalPadding: 32, sectionSpacing: 10,
            cap: 700,
            epsilon: 0.5,
            currentlyScrolling: scrolling, hysteresis: 8
        )
    }

    let gaps = panelSectionExtra(header: 40, usage: 600, bottom: 260, verticalPadding: 32, sectionSpacing: 10)
    check(gaps == 52, "padding and gaps are 52, got \(gaps)")
    let initial = formula(usage: 600, bottom: 260)
    check(initial == 952, "header 40 + usage 600 + bottom 260 + gaps 52 = 952, got \(initial)")

    var calibration = PanelSlackCalibration()
    check(calibration.isCalibrated == false, "slack starts uncalibrated")
    calibration = calibratePanelSlack(calibration, liveMeasure: initial, formula: initial)
    check(calibration.isCalibrated && calibration.slack == 0, "an exact measurement is a valid zero slack, got \(calibration.slack)")

    let opened = plan(measured: initial, usage: 600, bottom: 260, scrolling: false)
    check(opened == PanelFitPlan(height: 700, scroll: .usage(348)), "cap 700 gives usage viewport 348, got \(opened)")

    let grownFormula = formula(usage: 600, bottom: 360)
    check(grownFormula == 1052, "bottom 360 needs 1052, got \(grownFormula)")
    let grownCalibration = calibratePanelSlack(calibration, liveMeasure: nil, formula: grownFormula)
    check(grownCalibration == calibration, "growth while scrolling does not recalibrate from the old 952 total")
    let grownNatural = panelNaturalHeight(measured: nil, formula: grownFormula, calibration: grownCalibration)
    check(grownNatural == 1052, "grown natural height is 1052, not the stale 952, got \(grownNatural ?? -1)")
    let grown = plan(measured: grownNatural, usage: 600, bottom: 360, scrolling: true)
    check(grown == PanelFitPlan(height: 700, scroll: .usage(248)), "grown bottom gets viewport 248, got \(grown)")
    if case .usage(let viewport) = grown.scroll {
        let occupied = 40 + viewport + 360 + gaps
        check(occupied == 700, "grown stack fits in 700 instead of the stale 800, got \(occupied)")
    } else {
        check(false, "grown bottom keeps a usage viewport, got \(grown)")
    }

    let shrunkFormula = formula(usage: 180, bottom: 360)
    check(shrunkFormula == 632, "usage 180 after the growth needs 632, got \(shrunkFormula)")
    let shrunkCalibration = calibratePanelSlack(grownCalibration, liveMeasure: nil, formula: shrunkFormula)
    check(shrunkCalibration.isCalibrated && shrunkCalibration.slack == 0, "shrink keeps the learned zero slack")
    let shrunkNatural = panelNaturalHeight(measured: nil, formula: shrunkFormula, calibration: shrunkCalibration)
    check(shrunkNatural == 632, "shrink uses 632, not the old 952 total, got \(shrunkNatural ?? -1)")
    let shrunk = plan(measured: shrunkNatural, usage: 180, bottom: 360, scrolling: true)
    check(shrunk == PanelFitPlan(height: 632, scroll: .none), "shrinking usage to 180 leaves the cap instead of sticking at 700, got \(shrunk)")

    var learned = calibratePanelSlack(PanelSlackCalibration(), liveMeasure: 960, formula: initial)
    check(learned.isCalibrated && abs(learned.slack - 8) < 0.001, "a taller measurement learns slack 8, got \(learned.slack)")
    learned = calibratePanelSlack(learned, liveMeasure: nil, formula: grownFormula)
    check(abs(learned.slack - 8) < 0.001, "a later formula keeps the non-zero slack")
    check(
        panelNaturalHeight(measured: nil, formula: grownFormula, calibration: learned) == 1060,
        "non-zero slack still applies to the new formula"
    )
}

func runBandRefitChecks() {
    var watch = PanelBandWatch()
    let initial = observePanelBands(
        watch: watch, header: 40, usage: 600, bottom: 260,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    watch = initial.0
    check(initial.1 == .schedule, "a first natural measurement schedules")
    check(watch.header == 40 && watch.usage == 600 && watch.bottom == 260, "bands are stored")

    let wiggle = observePanelBands(
        watch: watch, header: 40.2, usage: 600.1, bottom: 260.2,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    check(wiggle.1 == .ignore, "a sub-point band change does not schedule")

    let reading = observePanelBands(
        watch: watch, header: 40, usage: 600, bottom: 280,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    watch = reading.0
    check(reading.1 == .schedule && watch.bottom == 280, "a taller bottom band schedules a refit, got \(reading.1)")

    let echo = armPanelBandEcho(watch)
    check(echo.generation == 1 && echo.echoArmed, "a resize arms the next sample")
    let viewportEcho = observePanelBands(
        watch: echo, header: 40, usage: 348, bottom: 280,
        epoch: 0, epsilon: 0.5, usageViewport: 348
    )
    check(viewportEcho.1 == .ignore, "the scroller viewport is not a new usage height")
    check(viewportEcho.0.usage == 600, "natural usage survives the viewport echo, got \(viewportEcho.0.usage)")
    check(viewportEcho.0.echoArmed == false && viewportEcho.0.generation == 1, "the resize generation is consumed")

    let stale = observePanelBands(
        watch: viewportEcho.0, header: 10, usage: 10, bottom: 10,
        epoch: 3, epsilon: 0.5, usageViewport: nil
    )
    check(stale.1 == .ignore && stale.0.header == 40 && stale.0.usage == 600, "a stale probe epoch does not clobber")

    let later = observePanelBands(
        watch: viewportEcho.0, header: 40, usage: 600, bottom: 310,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    check(later.1 == .schedule && later.0.bottom == 310, "a later real band change still schedules")

    var looping = PanelBandWatch()
    var last: PanelBandDecision = .schedule
    for i in 0..<(PanelFitMetrics.bandRefitBurst + 2) {
        let bottom = i % 2 == 0 ? 100.0 : 160.0
        let step = observePanelBands(
            watch: looping, header: 40, usage: 600, bottom: bottom,
            epoch: 0, epsilon: 0.5, usageViewport: nil
        )
        looping = step.0
        last = step.1
    }
    check(last == .ignore, "a resize feedback loop stops scheduling")
    check(looping.burst == PanelFitMetrics.bandRefitBurst, "the burst stays capped, got \(looping.burst)")

    let settled = observePanelBands(
        watch: looping, header: looping.header, usage: looping.usage, bottom: looping.bottom,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    check(settled.1 == .ignore && settled.0.burst == PanelFitMetrics.bandRefitBurst, "a duplicate sample does not reopen the loop")
    let opened = resetPanelBandBurst(settled.0)
    check(opened.burst == 0, "a layout-content change clears the burst")
    let after = observePanelBands(
        watch: opened, header: 40, usage: 600, bottom: opened.bottom + 30,
        epoch: 0, epsilon: 0.5, usageViewport: nil
    )
    check(after.1 == .schedule, "a change after a content refit schedules again")
}
