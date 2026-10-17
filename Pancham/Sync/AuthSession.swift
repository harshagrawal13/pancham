import Foundation
import Observation

struct Account: Codable, Equatable, Sendable {
    let id: UUID
    let email: String
    let isAdmin: Bool

    /// The one rule for changing notations: your own are yours; global ones are admins'.
    func canEdit(_ scope: SyncScope) -> Bool { scope == .private || isAdmin }
}

/// What is kept between launches: enough to stay signed in and work offline.
struct StoredSession: Codable, Equatable {
    var account: Account
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
}

/// Email-code sign-in and the session that follows it.
///
/// The refresh token lives in `session.json` beside the cache, readable only by you (0600). It is a
/// file rather than a Keychain item because this build is ad-hoc signed, which makes every rebuild a
/// different app to the Keychain and prompts for the login password each time; the token is
/// revoked by signing out, and idles out after 90 days. Move it to the Keychain when the app has a
/// stable signing identity.
///
/// Launching never needs the network: a stored session is signed in, and notations open from the
/// local cache. The access token (an hour) is refreshed only when something is about to use it.
@MainActor @Observable
final class AuthSession {
    private(set) var account: Account?
    private var stored: StoredSession?
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var refreshing: Task<StoredSession, Error>?
    /// Bumped by sign-out, so a refresh that was already on its way can't sign you back in.
    @ObservationIgnored private var generation = 0

    var config: ServerConfig { transport.config }

    init(config: ServerConfig = .load(), directory: URL = AuthSession.defaultDirectory()) {
        self.transport = HTTPTransport(config: config)
        self.file = directory.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder.iso.decode(StoredSession.self, from: data) {
            stored = s
            account = s.account
        }
    }

    /// ~/Library/Application Support/Pancham, or $PANCHAM_DATA_DIR: how a development run (against
    /// server/dev_stack.py) keeps its session and cache apart from the real ones.
    nonisolated static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["PANCHAM_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pancham", isDirectory: true)
    }

    // MARK: Sign in

    /// Ask for a six-digit code to be emailed. Throws `.rejected` with the server's wording when the
    /// address isn't on the list or codes are being asked for too fast.
    func requestCode(email: String) async throws {
        let (status, data) = try await transport.send(
            "POST", transport.config.authURL, path: "auth/v1/otp",
            body: try JSONSerialization.data(withJSONObject: ["email": email]))
        try Self.check(status, data)
    }

    func verify(email: String, code: String) async throws {
        let (status, data) = try await transport.send(
            "POST", transport.config.authURL, path: "auth/v1/verify",
            body: try JSONSerialization.data(withJSONObject: ["email": email, "token": code]))
        try Self.check(status, data)
        adopt(try Self.parseTokens(data, now: Date()))
    }

    func signOut() async {
        let s = stored
        generation += 1
        refreshing = nil
        stored = nil
        account = nil
        try? FileManager.default.removeItem(at: file)
        guard let s else { return }
        // Best effort: if the server can't be reached the token still idles out in 90 days.
        _ = try? await transport.send(
            "POST", transport.config.authURL, path: "auth/v1/logout",
            body: try? JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken]),
            bearer: s.accessToken)
    }

    // MARK: Tokens

    /// A bearer token good for at least a minute, refreshing first if need be. `.signedOut` when the
    /// server says the session is over (and the app goes back to sign-in); `.offline` leaves the
    /// session alone.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let s = stored else { throw RemoteError.signedOut }
        if !forceRefresh, s.expiresAt.timeIntervalSinceNow > 60 { return s.accessToken }
        // One refresh at a time: everything that finds the token stale waits on the same request.
        let task: Task<StoredSession, Error>
        if let refreshing {
            task = refreshing
        } else {
            task = Task { try await self.refresh(using: s.refreshToken) }
            refreshing = task
        }
        defer { if refreshing == task { refreshing = nil } }
        do {
            return try await task.value.accessToken
        } catch RemoteError.rejected(let code, _) where code == "refresh_token_not_found" {
            stored = nil
            account = nil
            try? FileManager.default.removeItem(at: file)
            throw RemoteError.signedOut
        }
    }

    private func refresh(using refreshToken: String) async throws -> StoredSession {
        let started = generation
        let (status, data) = try await transport.send(
            "POST", transport.config.authURL, path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken]))
        try Self.check(status, data)
        let fresh = try Self.parseTokens(data, now: Date())
        guard started == generation else { throw RemoteError.signedOut }      // signed out meanwhile
        adopt(fresh)
        return fresh
    }

    // MARK: Internals

    private func adopt(_ s: StoredSession) {
        stored = s
        account = s.account
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Written to a private temporary file first, so the token is never readable by anyone else,
        // not even for the moment between writing and tightening the permissions.
        if let data = try? JSONEncoder.iso.encode(s) {
            let temp = file.deletingLastPathComponent().appendingPathComponent(".session.json.tmp")
            try? fm.removeItem(at: temp)
            if fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                _ = try? fm.replaceItemAt(file, withItemAt: temp)
            }
        }
    }

    private static func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error_code"] as? String ?? "http_\(status)"
        let msg = obj?["msg"] as? String ?? "The server answered \(status)."
        // Not the sign-in server's own answer (Cloudflare's 403 or 429, a gateway error): not a refusal.
        if obj == nil { throw RemoteError.server(status: status, message: "The server couldn't be reached properly (HTTP \(status)).") }
        throw RemoteError.rejected(code: code, message: msg)
    }

    static func parseTokens(_ data: Data, now: Date) throws -> StoredSession {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let user = o["user"] as? [String: Any], let idString = user["id"] as? String,
              let id = UUID(uuidString: idString), let email = user["email"] as? String
        else { throw RemoteError.server(status: 200, message: "The sign-in answer wasn't understood.") }
        let ttl = (o["expires_in"] as? Double) ?? 3600
        return StoredSession(account: Account(id: id, email: email, isAdmin: user["admin"] as? Bool ?? false),
                             refreshToken: refresh, accessToken: access, expiresAt: now.addingTimeInterval(ttl))
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
