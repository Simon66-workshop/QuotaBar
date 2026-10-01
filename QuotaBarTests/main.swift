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
])
let title = Snapshot.title(from: groups)
check(title == "G 21 · C 40 · AC19 AT82 AF94 · D 70", "bar title \(title)")
check(groups.count == 4, "groups \(groups.count)")
check(groups[2].map(\.tone) == [.ok, .ok, .warn], "bar tones \(groups[2].map(\.tone))")
check(!title.contains("Chat"), "grok details stayed off the bar")
check(!title.contains("Cursor"), "cursor details stayed off the bar")

let noFable = parse("""
{
  "five_hour": {"utilization": 19, "resets_at": "\(sessionReset)"},
  "seven_day": {"utilization": 82, "resets_at": "\(weekReset)"},
  "seven_day_fable": null
}
""")
check(noFable?.details.map(\.mark) == ["AC", "AT"], "missing fable marks \(noFable?.details.map(\.mark) ?? [])")
check(noFable?.details.contains { $0.mark == "AF" } == false, "AF hidden when seven_day_fable is null")
check(Snapshot.title(from: Snapshot.barGroups(lanes: [noFable].compactMap { $0 }, disks: [])) == "AC19 AT82", "bar without AF")

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
check(Snapshot.title(from: Snapshot.barGroups(lanes: [opusNotFable].compactMap { $0 }, disks: [])) == "AC19 AT82", "opus stays off the bar")

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
check(Snapshot.title(from: Snapshot.barGroups(lanes: [fableTwice].compactMap { $0 }, disks: [])) == "AC19 AT82 AF94", "bar has a single AF")

if failures == 0 {
    print("ok \(checks) checks")
} else {
    fputs("\(failures) failed of \(checks)\n", stderr)
    exit(1)
}
