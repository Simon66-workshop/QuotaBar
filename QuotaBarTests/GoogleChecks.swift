import Foundation

func runGoogleChecks() {
    let path = CommandLine.arguments[1]
    guard let fixture = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: fixture) as? [String: Any] else {
        check(false, "synthetic Google fixture loads")
        return
    }
    func changed(_ update: (inout [String: Any]) -> Void) -> Lane {
        var json = root
        update(&json)
        return GoogleUsage.parse(try! JSONSerialization.data(withJSONObject: json))
    }
    func changingGroups(_ update: (inout [[String: Any]]) -> Void) -> Lane {
        changed { json in
            var command = json["command"] as! [String: Any]
            var data = command["data"] as! [String: Any]
            var groups = data["groups"] as! [[String: Any]]
            update(&groups)
            data["groups"] = groups
            command["data"] = data
            json["command"] = command
        }
    }
    func changingBucket(_ key: String, _ value: Any?) -> Lane {
        changingGroups { groups in
            var buckets = groups[0]["buckets"] as! [[String: Any]]
            buckets[0][key] = value
            groups[0]["buckets"] = buckets
        }
    }
    func unknown(_ lane: Lane, _ message: String) {
        check(lane.key == .google && lane.tone == .error && lane.usedPct == nil && lane.remainingPct == nil,
              message + " fails closed, not zero/stale")
        check(lane.showsOnBar && Snapshot.assemble([lane]).menuTitle == "GO — · M —", message + " is GO —")
    }

    let lane = GoogleUsage.parse(fixture)
    check(lane.key == .google && LaneKey.google.letter == "GO", "Google is its own GO lane")
    check(lane.usedPct == 80 && lane.remainingPct == 20 && lane.window == "5h", "GO is max used Gemini window, not remaining or blended groups")
    check(lane.tone == .ok && lane.details.isEmpty, "GO uses service bands and no AC/AT/AF/O marks")
    check(lane.sub.contains("highest used window (5h)"), "GO identifies selected window and used convention")
    check(lane.googleGroups.map(\.name) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"], "all official groups retained")
    check(lane.googleGroups.map { $0.buckets.count } == [2, 2, 1], "no invented Argon 5h window")
    check(lane.googleGroups[0].buckets.map(\.shownUsedPct) == [25, 80], "remaining fractions become used percent")
    check(lane.googleGroups[0].buckets.map(\.shownRemainingPct) == [75, 20], "remaining stays explicit")
    check(lane.googleGroups[0].buckets[0].resetLabel(timeZone: TimeZone(identifier: "America/New_York")!) == "resets Nov 26, 1:01 AM EST", "UTC reset is converted for display only")
    check(lane.googleSummaryLines.joined().contains("not Claude AC/AT/AF or Codex O"), "copy/tooltip distinguish third-party quota")
    check(lane.googleSummaryLines.joined().contains("[gemini-argon-wtu-weekly]"), "copy/tooltip retain bucket identity")
    check(lane.googleSummaryLines.joined().contains("80% used / 20% left · 5h"), "copy/tooltip include used, left, window")

    let weekly = changingBucket("remaining_fraction", 0.1)
    check(weekly.usedPct == 90 && weekly.window == "week" && weekly.tone == .warn, "weekly can be primary with 85% service warning")
    check(changingBucket("remaining_fraction", 0.05).tone == .crit, "95% used service critical band")
    check(changingBucket("remaining_fraction", 0).usedPct == 100, "zero remaining means fully used")
    let allFree = changingGroups { groups in
        var buckets = groups[0]["buckets"] as! [[String: Any]]
        for i in buckets.indices { buckets[i]["remaining_fraction"] = 1 }
        groups[0]["buckets"] = buckets
    }
    check(allFree.usedPct == 0 && allFree.window == "5h", "fresh Gemini quota is real zero; tie selects 5h, ignores high third-party/Argon")
    let weeklyOnly = changingGroups { groups in
        groups[0]["buckets"] = [(groups[0]["buckets"] as! [[String: Any]])[0]]
    }
    check(weeklyOnly.usedPct == 25 && weeklyOnly.window == "week", "only returned Gemini windows are used")
    let noGemini = changingGroups { $0.removeFirst() }
    unknown(noGemini, "missing Gemini Models")
    check(noGemini.googleGroups.count == 2, "other official groups still visible when GO cannot be computed")
    let future = changingGroups { groups in
        groups[0]["buckets"] = [["id": "future-gemini", "name": "Future window", "window": "daily", "remaining_fraction": 0.2, "reset_time": "2026-11-26T06:01:14Z"]]
    }
    unknown(future, "unrecognized Gemini window")
    check(future.googleGroups[0].buckets[0].windowLabel == "daily", "unknown future windows retained honestly in detail")

    for (key, value) in [("status", "FAILURE"), ("command", "wrong type")] {
        unknown(changed { $0[key] = value }, key)
    }
    unknown(changed { $0["command"] = ["name": "credits", "data": ["remaining_credits": 100]] }, "credits payload")
    unknown(changed { $0["command"] = ["name": "usage", "data": [:]] }, "missing groups")
    unknown(changed { $0["command"] = ["name": "usage", "data": ["groups": NSNull()]] }, "null groups")
    unknown(changingGroups { $0 = [] }, "empty groups")
    unknown(changingGroups { $0[0]["buckets"] = [] }, "empty buckets")
    unknown(changingGroups { $0.append($0[0]) }, "duplicate group")
    unknown(changingGroups { groups in
        var buckets = groups[0]["buckets"] as! [[String: Any]]
        buckets.append(buckets[0]); groups[0]["buckets"] = buckets
    }, "duplicate bucket")
    for value in [-0.1, 1.1, true, "0.5", NSNull()] as [Any] {
        unknown(changingBucket("remaining_fraction", value), "invalid fraction \(type(of: value))")
    }
    unknown(changingBucket("remaining_fraction", nil), "missing fraction")
    unknown(changed {
        $0["command"] = ["name": "usage", "data": ["groups": [["name": "Gemini Models", "buckets": [["id": "gemini-weekly", "name": "Requests", "window": "weekly", "request_count": 10, "reset_time": "2026-11-26T06:01:14Z"]]]]]]
    }, "raw request counters")
    unknown(changingBucket("reset_time", "not-a-time"), "invalid reset")
    unknown(changingBucket("reset_time", nil), "missing reset")
    unknown(changingBucket("id", ""), "missing identity")
    check(changingBucket("reset_time", "2026-11-26T01:01:14.123-05:00").tone != .error, "fractional offset timestamp accepted")
    unknown(GoogleUsage.parse(Data("not JSON".utf8)), "invalid JSON")
    unknown(GoogleUsage.parse(fixture.prefix(100)), "truncated JSON")
    unknown(GoogleUsage.lane(from: .unavailable("timed out")), "process failure replaces any old result")

    let preserved = Snapshot.assemble([
        .used(.grok, percent: 21, sub: "shared"), .used(.gpt, percent: 15, sub: "cap"),
        .used(.claude, percent: 82, sub: "max", details: [
            LaneDetail(label: "session", usedPct: 19, mark: "AC"),
            LaneDetail(label: "week", usedPct: 82, mark: "AT"),
            LaneDetail(label: "Fable", usedPct: 94, mark: "AF")]), lane
    ])
    check(preserved.menuTitle == "G 21 · O 15 · AC 19  AT 82  AF 94 · GO 80 · M —", "GO preserves existing G/O/AC/AT/AF/RAM ordering")
    check(!LaneKey.google.foldedIntoGrok, "GO never shares Grok pool")
    check(GoogleUsage.executable.hasSuffix("/antigravity/bin/agy") && GoogleUsage.arguments == ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"], "production uses only official read-only command")

    // Local fake executables only: no network, credential access, auth, or app launch.
    let echo = GoogleUsage.run(executablePath: "/usr/bin/printf", commandArguments: ["%s", String(decoding: fixture, as: UTF8.self)])
    check(GoogleUsage.lane(from: echo).usedPct == 80, "process stdout parses official envelope")
    unknown(GoogleUsage.lane(from: GoogleUsage.run(executablePath: "/nonexistent/agy")), "CLI absent")
    unknown(GoogleUsage.lane(from: GoogleUsage.run(executablePath: "/bin/sh", commandArguments: ["-c", "printf private-diagnostic >&2; exit 7"])), "nonzero exit, stderr discarded")
    let start = ProcessInfo.processInfo.systemUptime
    unknown(GoogleUsage.lane(from: GoogleUsage.run(executablePath: "/bin/sh", commandArguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)), "timeout kills owned uncooperative child")
    check(ProcessInfo.processInfo.systemUptime - start < 2, "timeout is wall-clock bounded")
    unknown(GoogleUsage.lane(from: GoogleUsage.run(executablePath: "/usr/bin/yes", commandArguments: [], timeout: 2, outputLimit: 32_768)), "oversized stdout is bounded without deadlock")
    unknown(GoogleUsage.lane(from: GoogleUsage.run(executablePath: "/bin/sh", commandArguments: ["-c", "exit 0"])), "empty stdout")
    let safeInput = GoogleUsage.run(executablePath: "/bin/sh", commandArguments: ["-c", "if read line; then exit 1; fi; test -z \"${GEMINI_API_KEY+x}${GOOGLE_API_KEY+x}\" || exit 1; printf '%s' 'safe'"])
    if case .success(let data) = safeInput {
        check(String(decoding: data, as: UTF8.self) == "safe", "stdin is EOF and API-key environment is excluded")
    } else { check(false, "stdin / environment isolation") }
}
