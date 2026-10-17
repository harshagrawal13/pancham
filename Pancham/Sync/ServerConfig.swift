import Foundation

/// Where Pancham's backend lives (kamaji), and the Cloudflare Access service token that gets a
/// request through the tunnel's door. The token only opens the door; who you are is the
/// one-time-code sign-in (`AuthSession`).
///
/// Each value comes from the process environment (`PANCHAM_AUTH_URL`, ...) if set, else Info.plist, which
/// `Config/Local.xcconfig` fills in for the Access token. (Deliberately not UserDefaults: a development
/// server must never leak into the real app's settings.)
struct ServerConfig: Sendable, Equatable {
    var authURL: URL
    var restURL: URL
    var accessClientID: String?
    var accessClientSecret: String?

    static let productionAuthURL = URL(string: "https://pancham.harsh-agrawal.com")!
    static let productionRestURL = URL(string: "https://pancham-api.harsh-agrawal.com")!

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     bundle: Bundle = .main) -> ServerConfig {
        func value(env: String, key: String) -> String? {
            for candidate in [environment[env], bundle.object(forInfoDictionaryKey: key) as? String] {
                if let v = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            }
            return nil
        }
        return ServerConfig(
            authURL: value(env: "PANCHAM_AUTH_URL", key: "PanchamAuthURL").flatMap(URL.init(string:)) ?? productionAuthURL,
            restURL: value(env: "PANCHAM_REST_URL", key: "PanchamRestURL").flatMap(URL.init(string:)) ?? productionRestURL,
            accessClientID: value(env: "PANCHAM_ACCESS_CLIENT_ID", key: "PanchamAccessClientID"),
            accessClientSecret: value(env: "PANCHAM_ACCESS_CLIENT_SECRET", key: "PanchamAccessClientSecret"))
    }
}

/// Everything that can go wrong talking to the backend, in the terms the app acts on.
enum RemoteError: Error, Equatable, LocalizedError {
    /// No network, or the server didn't answer. Work continues from the local copy.
    case offline
    /// The session is over (refresh token refused). Back to the sign-in screen.
    case signedOut
    /// Someone saved a newer revision first; `headRev` is theirs.
    case conflict(headRev: Int)
    /// Not allowed (not yours, or global and you are not an admin).
    case forbidden(String)
    case notFound
    /// The server refused the input (bad request, bad code, not on the list...).
    case rejected(code: String, message: String)
    case server(status: Int, message: String)

    /// What a sync pass does about it.
    enum Disposition {
        case stopPass     // nothing more can be done now (no network, signed out)
        case retryLater   // the road, not the notation: keep the work queued, carry on with the rest
        case permanent    // the database turned it down: don't ask again for the same thing
    }

    var disposition: Disposition {
        switch self {
        case .offline, .signedOut: return .stopPass
        case .server: return .retryLater
        case .conflict, .forbidden, .notFound, .rejected: return .permanent
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline: return "Can't reach the Pancham server. Your changes are kept and will sync when it's back."
        case .signedOut: return "You've been signed out. Please sign in again."
        case .conflict: return "This notation changed somewhere else."
        case .forbidden(let m): return m.isEmpty ? "Not allowed." : m
        case .notFound: return "Not found."
        case .rejected(_, let m): return m
        case .server(let s, let m): return "Server error (\(s)). \(m)"
        }
    }
}

/// One HTTP round trip with the Access headers on it. No knowledge of Pancham's routes.
struct HTTPTransport: Sendable {
    let config: ServerConfig
    var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func send(_ method: String, _ base: URL, path: String, query: [URLQueryItem] = [], body: Data? = nil,
              bearer: String? = nil, headers: [String: String] = [:]) async throws -> (status: Int, data: Data) {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let id = config.accessClientID, let secret = config.accessClientSecret {
            req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError where Self.offlineCodes.contains(e.code) {
            throw RemoteError.offline
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
        .secureConnectionFailed, .cannotLoadFromNetwork,
    ]
}
