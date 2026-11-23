import Combine
import Foundation
import Network

enum RelayPollTiming {
    static func delay(failures: Int, jitter: Double) -> TimeInterval {
        let base: Double
        switch failures {
        case ...1: base = 30
        case 2: base = 60
        case 3: base = 120
        default: base = 300
        }
        return base + min(3, max(-3, jitter))
    }
}

@MainActor
final class RelayStatusStore: ObservableObject {
    @Published private(set) var display = RelayDisplay.unavailable(.waiting)

    private let loadSnapshot: () async throws -> RelaySnapshot
    private let now: () -> TimeInterval
    private let jitter: () -> Double
    private var monitor: NWPathMonitor?
    private var timer: Task<Void, Never>?
    private var flight: Task<Void, Never>?
    private var online = true
    private var networkEpoch = 0
    private var started = false
    private var unauthorized = false
    private var failures = 0
    private var lastAttempt: TimeInterval?
    private var nextPoll: TimeInterval = 0
    private var retryNotBefore: TimeInterval = 0
    private var retryIssue: RelayIssue?
    private var expires: TimeInterval?
    // Keep the high-water mark even after errors/expiry. Refusing older observations
    // is fail-closed and avoids retaining an unbounded history of deadlines.
    private var latest: (observedAt: Date, deadline: TimeInterval)?

    init(
        loadSnapshot: @escaping () async throws -> RelaySnapshot = RelayStatusHelper.load,
        now: @escaping () -> TimeInterval = {
            let clock = ContinuousClock()
            let origin = clock.now
            return {
                let elapsed = origin.duration(to: clock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
        }(),
        jitter: @escaping () -> Double = { .random(in: -3...3) }
    ) {
        self.loadSnapshot = loadSnapshot
        self.now = now
        self.jitter = jitter
    }

    func start(monitorNetwork: Bool = true) {
        guard !started else { return }
        started = true
        if monitorNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(connected) }
            }
            monitor.start(queue: DispatchQueue(label: "app.quotabar.mac.relay-status.network"))
            self.monitor = monitor
        }
        tick()
    }

    func stop() {
        started = false
        monitor?.cancel()
        monitor = nil
        timer?.cancel()
        timer = nil
        flight?.cancel()
    }

    func manualRefresh() {
        unauthorized = false
        requestSoon()
    }

    func woke() { requestSoon() }

    func panelOpened() {
        if now() - (lastAttempt ?? -.infinity) >= 15 { requestSoon() }
        else { tick() } // Still enforce expiry before the panel is presented.
    }

    func networkChanged(_ connected: Bool) {
        guard started, online != connected else { return }
        online = connected
        networkEpoch += 1
        if connected {
            if display == .unavailable(.offline) {
                display = .unavailable(now() < retryNotBefore ? retryIssue ?? .waiting : .waiting)
            }
            requestSoon()
        } else {
            expires = nil
            if display != .unavailable(.notConfigured) {
                display = .unavailable(unauthorized ? .unauthorized : .offline)
            }
            tick()
        }
    }

    private func requestSoon() {
        if flight == nil { nextPoll = now() }
        tick()
    }

    private func tick() {
        guard started else { return }
        let time = now()
        var displayDeadline = TimeInterval.infinity
        if let expires {
            if time >= expires {
                self.expires = nil
                display = .unavailable(.expired)
            } else {
                displayDeadline = expires
                if case .live(let snapshot) = display {
                    let aged = snapshot.agingHeartbeats(at: time, snapshotDeadline: expires)
                    if aged != snapshot { display = .live(aged) }
                    displayDeadline = min(expires, aged.nextHeartbeatDeadline(snapshotDeadline: expires) ?? .infinity)
                }
            }
        }
        let canPoll = online && !unauthorized && flight == nil
        let due = max(nextPoll, retryNotBefore)
        if canPoll && time >= due {
            begin()
        }
        timer?.cancel()
        timer = nil
        let wake = min(displayDeadline, canPoll && flight == nil ? due : .infinity)
        if wake.isFinite {
            // Bound a single sleep, not the server's Retry-After deadline.
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(min(300, max(0, wake - (self?.now() ?? wake))))) }
                catch { return }
                self?.tick()
            }
        }
    }

    private func begin() {
        let epoch = networkEpoch
        lastAttempt = now()
        flight = Task { [weak self] in
            guard let self else { return }
            guard started, online, epoch == networkEpoch, !Task.isCancelled else {
                finish(nil, epoch: epoch, requestStarted: now())
                return
            }
            // Conservatively charge helper startup and the local credential read too.
            let requestStarted = now()
            let result: Result<RelaySnapshot, RelayIssue>
            do {
                result = .success(try await loadSnapshot())
            } catch {
                result = .failure((error as? RelayIssue) ?? .network)
            }
            finish(result, epoch: epoch, requestStarted: requestStarted)
        }
    }

    private func finish(_ result: Result<RelaySnapshot, RelayIssue>?, epoch: Int, requestStarted: TimeInterval) {
        flight = nil
        guard started else { return }
        let time = now()
        if let result {
            switch result {
            case .success(let snapshot) where online && epoch == networkEpoch:
                if let latest, snapshot.observedAt < latest.observedAt {
                    fail(.expired, at: time)
                    break
                }
                var deadline = snapshot.expiresAt(requestStartedAt: requestStarted)
                if let latest, snapshot.observedAt == latest.observedAt {
                    deadline = min(deadline, latest.deadline)
                }
                latest = (snapshot.observedAt, deadline)
                if time < deadline {
                    failures = 0
                    retryNotBefore = 0
                    retryIssue = nil
                    nextPoll = time + RelayPollTiming.delay(failures: 0, jitter: jitter())
                    expires = deadline
                    // Include time spent in the request/helper, and use the
                    // clamped deadline so repeats cannot extend green.
                    display = .live(snapshot.agingHeartbeats(at: time, snapshotDeadline: deadline))
                } else {
                    fail(.expired, at: time)
                }
            case .failure(let issue) where online && epoch == networkEpoch:
                fail(issue, at: time)
            case .failure(let issue):
                // Retain local configuration and explicit server gates even if
                // connectivity changed; never reuse an old success.
                switch issue {
                case .rateLimited, .unauthorized, .notConfigured: fail(issue, at: time)
                default: break
                }
            default: break
            }
        }
        tick()
    }

    private func fail(_ issue: RelayIssue, at time: TimeInterval) {
        expires = nil
        display = .unavailable(issue)
        switch issue {
        case .unauthorized:
            retryIssue = nil
            unauthorized = true
            retryNotBefore = 0
        case .notConfigured:
            retryIssue = nil
            failures = 0
            retryNotBefore = 0
            nextPoll = time + RelayPollTiming.delay(failures: 0, jitter: jitter())
        default:
            failures = min(failures + 1, 4)
            var delay = RelayPollTiming.delay(failures: failures, jitter: jitter())
            if case .rateLimited(let minimum) = issue { delay = max(delay, minimum) }
            retryIssue = issue
            retryNotBefore = time + delay
            nextPoll = retryNotBefore
        }
    }

    #if QUOTABAR_COMPONENT_CHECK
    func clockAdvanced() { tick() }
    func waitForAttempt() async { await flight?.value }
    #endif
}
