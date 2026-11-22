import Foundation

enum RelayStatusClient {
    static let endpoint = URL(string: "https://66workshop.cn/api/relay-status/v1")!
    static let timeout: TimeInterval = 5

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

    static func fetch(token: String) async throws -> RelaySnapshot {
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
            return try decode(data, response: response)
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
            guard response.mimeType?.lowercased() == "application/json", data.count <= 16_384 else {
                throw RelayIssue.badResponse
            }
            return try RelaySnapshot.parse(data)
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: header) { return max(0, date.timeIntervalSince(now)) }
        return 60
    }
}

final class RelayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
