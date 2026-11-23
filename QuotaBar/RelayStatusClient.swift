import Foundation

enum RelayStatusClient {
    static let endpoint = URL(string: "https://66workshop.cn/api/relay-status/v1")!
    static let timeout: TimeInterval = 5
    static let maxPayloadBytes = 16_384
    static let greenWindowHeader = "QuotaBar-Green-For-Ms"

    struct Payload: Codable {
        let body: Data
        let greenForMilliseconds: Int

        func snapshot() throws -> RelaySnapshot {
            try RelaySnapshot.parse(body, greenForMilliseconds: greenForMilliseconds)
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return config
    }

    static func fetchPayload(token: String) async throws -> Payload {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let session = URLSession(configuration: configuration(), delegate: RelayNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RelayIssue.badResponse }
            let snapshot = try decode(data, response: response)
            return Payload(body: data, greenForMilliseconds: snapshot.greenForMilliseconds)
        } catch let issue as RelayIssue {
            throw issue
        } catch let error as URLError {
            throw issue(for: error.code)
        } catch {
            throw RelayIssue.network
        }
    }

    static func decode(_ data: Data, response: HTTPURLResponse, now: Date = Date()) throws -> RelaySnapshot {
        switch response.statusCode {
        case 200:
            // This endpoint is no-store. Fail closed if an intermediary says
            // it served an aged response, even on the first observation.
            if let age = response.value(forHTTPHeaderField: "Age")?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                guard !age.isEmpty, age.utf8.allSatisfy({ (48...57).contains($0) }) else {
                    throw RelayIssue.badResponse
                }
                guard age.utf8.allSatisfy({ $0 == 48 }) else { throw RelayIssue.expired }
            }
            guard response.value(forHTTPHeaderField: "Cache-Control")?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "no-store",
                  response.mimeType?.lowercased() == "application/json", data.count <= maxPayloadBytes,
                  let header = response.value(forHTTPHeaderField: "Date"), header.utf8.count == 29 else {
                throw RelayIssue.badResponse
            }
            let formatter = httpDateFormatter()
            guard let date = formatter.date(from: header), formatter.string(from: date) == header else {
                throw RelayIssue.badResponse
            }
            // An older server (no header) supplies no positive green window.
            let greenForMilliseconds: Int
            if let raw = response.value(forHTTPHeaderField: greenWindowHeader) {
                guard (1...5).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
                      let value = Int(raw) else { throw RelayIssue.badResponse }
                greenForMilliseconds = value
            } else {
                greenForMilliseconds = 0
            }
            let snapshot = try Payload(body: data, greenForMilliseconds: greenForMilliseconds).snapshot()
            let second = RelayTimestamp.microsecondsPerSecond
            let dateAge = Int64(date.timeIntervalSince1970) * second - snapshot.observation.microsecondsSince1970
            let freshness = Int(RelaySnapshot.freshness)
            guard snapshot.age < freshness, dateAge < Int64(freshness) * second else { throw RelayIssue.expired }
            // HTTP Date and snapshot_age_s count whole seconds; the two
            // rounded observations can disagree by one second. Never use
            // the Mac wall clock to decide whether a snapshot is fresh.
            guard dateAge > -second, abs(dateAge - Int64(snapshot.age) * second) <= second else {
                throw RelayIssue.badResponse
            }
            return snapshot
        case 401: throw RelayIssue.unauthorized
        case 429: throw RelayIssue.rateLimited(retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        case 500...599: throw RelayIssue.unavailable
        default: throw RelayIssue.httpError
        }
    }

    static func issue(for code: URLError.Code) -> RelayIssue {
        switch code {
        case .notConnectedToInternet: return .offline
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tls
        default: return .network
        }
    }

    private static func retryAfter(_ header: String?, now: Date) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 60 }
        if !header.isEmpty, header.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = Double(header), seconds.isFinite { return seconds }

        if let date = httpDateFormatter().date(from: header) { return max(0, date.timeIntervalSince(now)) }
        return 60
    }

    private static func httpDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}

final class RelayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
