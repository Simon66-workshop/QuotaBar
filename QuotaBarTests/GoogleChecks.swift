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
        check(lane.showsOnBar && Snapshot.assemble([lane]).menuTitle == "GO used 5h:—  W:— · M —", message + " has no GO figures")
    }

    let lane = GoogleUsage.parse(fixture)
    check(lane.key == .google && LaneKey.google.letter == "GO", "Google is its own GO lane")
    check(lane.usedPct == nil && lane.remainingPct == nil && lane.tone == .ok && lane.details.isEmpty,
          "GO has no scalar or AC/AT/AF/O marks")
    check(lane.googleGroups.map(\.name) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"], "all official groups retained")
    check(lane.googleGroups.map { $0.buckets.count } == [2, 2, 1], "no invented Argon 5h window")
    let currentBucket = lane.googleMenuGroup?.bucket(for: .current)
    let weeklyBucket = lane.googleMenuGroup?.bucket(for: .weekly)
    check(currentBucket?.shownUsedPct == 80 && currentBucket?.shownRemainingPct == 20, "5h uses its own remaining fraction")
    check(weeklyBucket?.shownUsedPct == 25 && weeklyBucket?.shownRemainingPct == 75, "weekly uses its own remaining fraction")
    let eastern = TimeZone(identifier: "America/New_York")!
    check(currentBucket?.resetLabel(timeZone: eastern) == "resets Nov 19, 6:01 AM EST"
          && weeklyBucket?.resetLabel(timeZone: eastern) == "resets Nov 26, 1:01 AM EST", "both independent UTC resets are converted for display only")
    let summary = lane.googleSummaryLines.joined(separator: "\n")
    check(summary.contains("not Claude AC/AT/AF or Codex O"), "copy/tooltip distinguish third-party quota")
    check(summary.contains("Gemini 4 Argon\n  Current usage (5h) · Not provided\n  Weekly limit · Gemini 4 Argon Weekly Limit [gemini-argon-wtu-weekly]"),
          "copy/tooltip explicitly show missing Argon current and preserve weekly identity")
    check(summary.contains("80% used / 20% left · 5h · \(currentBucket?.resetLabel() ?? "")")
          && summary.contains("25% used / 75% left · weekly · \(weeklyBucket?.resetLabel() ?? "")"),
          "copy/tooltip include both used/left/reset pairs")

    func googleTokens(_ lane: Lane) -> [Snapshot.BarToken] {
        Snapshot.assemble([lane]).barGroups(disks: []).first ?? []
    }
    check(googleTokens(changingBucket("remaining_fraction", 0.15)) == [
        .init(text: "GO used 5h:80%", tone: .ok), .init(text: "W:85%", tone: .warn)
    ], "5h and weekly bar figures are separate, each with its service color")
    check(googleTokens(changingBucket("remaining_fraction", 0.05)).last?.tone == .crit, "95% used service critical band")
    check(googleTokens(changingBucket("remaining_fraction", 0)).last?.text == "W:100%", "zero remaining means fully used")
    let allFree = changingGroups { groups in
        var buckets = groups[0]["buckets"] as! [[String: Any]]
        for i in buckets.indices { buckets[i]["remaining_fraction"] = 1 }
        groups[0]["buckets"] = buckets
    }
    check(googleTokens(allFree).map(\.text) == ["GO used 5h:0%", "W:0%"], "each returned free window is real zero; no Argon or third-party fallback")
    let weeklyOnly = changingGroups { groups in
        groups[0]["buckets"] = [(groups[0]["buckets"] as! [[String: Any]])[0]]
    }
    check(googleTokens(weeklyOnly) == [.init(text: "GO used 5h:—", tone: .error), .init(text: "W:25%", tone: .ok)],
          "weekly-only Gemini never fills current")
    let currentOnly = changingGroups { groups in
        groups[0]["buckets"] = [(groups[0]["buckets"] as! [[String: Any]])[1]]
    }
    check(googleTokens(currentOnly).map(\.text) == ["GO used 5h:80%", "W:—"], "current-only Gemini never fills weekly")
    let reordered = changingGroups { $0.reverse() }
    check(reordered.googleDisplayGroups.first?.name == "Gemini Models" && googleTokens(reordered) == googleTokens(lane),
          "primary group is shown first without relying on payload order")
    let newWindowID = changingBucket("id", "gemini-new-weekly-id")
    check(googleTokens(newWindowID) == googleTokens(lane), "window, not ID spelling, defines the official period")
    let argonCurrent = changingGroups { groups in
        var buckets = groups[2]["buckets"] as! [[String: Any]]
        buckets.append(["id": "argon-5h", "name": "Argon current", "window": "5h",
                        "remaining_fraction": 0.4, "reset_time": "2026-11-19T15:30:00Z"])
        groups[2]["buckets"] = buckets
    }
    check(argonCurrent.googleGroups.last?.bucket(for: .current)?.shownUsedPct == 60 && googleTokens(argonCurrent) == googleTokens(lane),
          "an official Argon current window becomes visible only when returned, never in the GO bar")
    let ambiguous = changingGroups { groups in
        var buckets = groups[0]["buckets"] as! [[String: Any]]
        var another = buckets[0]
        another["id"] = "another-weekly-bucket"
        buckets.append(another)
        groups[0]["buckets"] = buckets
    }
    check(googleTokens(ambiguous).map(\.text) == ["GO used 5h:80%", "W:—"]
          && ambiguous.googleMenuGroup?.unavailableLabel(for: .weekly) == "Ambiguous window"
          && ambiguous.googleMenuGroup?.additionalBuckets.count == 2, "ambiguous periods never select a number arbitrarily; raw buckets remain separate")
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
    check(preserved.menuTitle == "G 21 · O 15 · AC 19  AT 82  AF 94 · GO used 5h:80%  W:25% · M —", "GO preserves existing G/O/AC/AT/AF/RAM ordering")
    check(!LaneKey.google.foldedIntoGrok, "GO never shares Grok pool")
    check(GoogleUsage.executable.hasSuffix("/antigravity/bin/agy") && GoogleUsage.arguments == ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"], "production uses only official read-only command")

    // Local fake executables only: no network, credential access, auth, or app launch.
    let echo = GoogleUsage.run(executablePath: "/usr/bin/printf", commandArguments: ["%s", String(decoding: fixture, as: UTF8.self)])
    check(googleTokens(GoogleUsage.lane(from: echo)) == googleTokens(lane), "process stdout parses both periods from official envelope")
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
