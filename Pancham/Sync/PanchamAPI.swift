import Foundation

enum SyncScope: String, Codable, Sendable {
    case `private`
    case global
}

/// A notation as the server holds it now: its newest revision.
struct RemoteDoc: Sendable {
    let id: UUID
    let scope: SyncScope
    let rev: Int
    /// Position in the server's change feed; the sync cursor.
    let seq: Int64
    let name: String
    /// "" for the library's top level.
    let folder: String
    let deleted: Bool
    let updatedAt: Date
    let forkedFrom: UUID?
    /// The notation's JSON; nil when the request left it out.
    let content: Data?
}

/// One saved version of a notation.
struct RevisionInfo: Sendable, Identifiable {
    let rev: Int
    let seq: Int64
    let name: String
    let folder: String
    let deleted: Bool
    let note: String?
    let device: String?
    let createdAt: Date
    var id: Int { rev }
}

struct SaveResult: Sendable, Equatable {
    let rev: Int
    let seq: Int64
    /// False when the server already had exactly this version.
    let changed: Bool
}

/// The documents API: PostgREST at pancham-api.harsh-agrawal.com, called with the access token
/// from `AuthSession`. Row level security in the database decides what each account may see and
/// change (db/migrations/*_init.sql); this only speaks the protocol.
@MainActor
final class PanchamAPI {
    private let session: AuthSession
    private let transport: HTTPTransport

    init(session: AuthSession) {
        self.session = session
        self.transport = HTTPTransport(config: session.config)
    }

    // MARK: Reading

    /// Notations (newest revision, content included) changed after `cursor`, oldest first.
    func feed(after cursor: Int64, limit: Int = 50) async throws -> [RemoteDoc] {
        let data = try await rest("GET", "docs", query: [
            URLQueryItem(name: "seq", value: "gt.\(cursor)"),
            URLQueryItem(name: "order", value: "seq.asc"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ])
        return try Self.parseDocs(data)
    }

    func head(of id: UUID) async throws -> RemoteDoc? {
        let data = try await rest("GET", "docs", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")])
        return try Self.parseDocs(data).first
    }

    /// Your deleted notations, newest first, without content. Deleting is a revision, so they can come back.
    func deletedDocs() async throws -> [RemoteDoc] {
        let data = try await rest("GET", "docs", query: [
            URLQueryItem(name: "deleted", value: "eq.true"),
            URLQueryItem(name: "scope", value: "eq.private"),
            URLQueryItem(name: "select", value: "id,scope,rev,seq,name,folder,deleted,updated_at,forked_from"),
            URLQueryItem(name: "order", value: "updated_at.desc"),
        ])
        return try Self.parseDocs(data)
    }

    /// Every revision of a notation, newest first, without content.
    func history(of id: UUID) async throws -> [RevisionInfo] {
        let data = try await rest("GET", "revisions", query: [
            URLQueryItem(name: "doc_id", value: "eq.\(id.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "rev,seq,name,folder,deleted,note,device,created_at"),
            URLQueryItem(name: "order", value: "rev.desc"),
        ])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Self.unexpected() }
        return try rows.map { r in
            guard let rev = r["rev"] as? Int, let seq = (r["seq"] as? NSNumber)?.int64Value,
                  let name = r["name"] as? String,
                  let created = (r["created_at"] as? String).flatMap(Self.parseDate)
            else { throw Self.unexpected() }
            return RevisionInfo(rev: rev, seq: seq, name: name, folder: r["folder"] as? String ?? "",
                                deleted: r["deleted"] as? Bool ?? false, note: r["note"] as? String,
                                device: r["device"] as? String, createdAt: created)
        }
    }

    /// One revision's notation JSON.
    func content(of id: UUID, rev: Int) async throws -> Data {
        let data = try await rest("GET", "revisions", query: [
            URLQueryItem(name: "doc_id", value: "eq.\(id.uuidString.lowercased())"),
            URLQueryItem(name: "rev", value: "eq.\(rev)"),
            URLQueryItem(name: "select", value: "content"),
        ])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let content = rows.first?["content"] else { throw RemoteError.notFound }
        return try Self.serialize(content)
    }

    // MARK: Writing

    /// Save a notation: create it (`base` 0) or add a revision on top of revision `base`.
    /// Throws `.conflict` if someone saved in between. `content` left nil keeps the current content
    /// (a delete, or an undelete, sends none).
    @discardableResult
    func save(id: UUID, base: Int, name: String, folder: String, content: Data? = nil, deleted: Bool = false,
              scope: SyncScope = .private, forkedFrom: UUID? = nil, note: String? = nil) async throws -> SaveResult {
        var body: [String: Any] = [
            "p_doc": id.uuidString.lowercased(), "p_base": base, "p_name": name, "p_folder": folder,
            "p_deleted": deleted, "p_scope": scope.rawValue, "p_device": Self.deviceName,
        ]
        if let content {
            guard let object = try? JSONSerialization.jsonObject(with: content), object is [String: Any] else {
                throw RemoteError.rejected(code: "invalid_json", message: "That notation file isn't valid JSON.")
            }
            body["p_content"] = object
        }
        if let forkedFrom { body["p_forked_from"] = forkedFrom.uuidString.lowercased() }
        if let note { body["p_note"] = note }
        let data = try await rest("POST", "rpc/save_revision", body: try JSONSerialization.data(withJSONObject: body))
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rev = o["rev"] as? Int, let seq = (o["seq"] as? NSNumber)?.int64Value
        else { throw Self.unexpected() }
        return SaveResult(rev: rev, seq: seq, changed: o["changed"] as? Bool ?? true)
    }

    // MARK: Plumbing

    private func rest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var refreshed = false
        while true {
            let token = try await session.accessToken(forceRefresh: refreshed)
            let (status, data) = try await transport.send(method, transport.config.restURL, path: path,
                                                          query: query, body: body, bearer: token)
            // PostgREST says JWT problems with PGRST30x; any other 401 is "not allowed".
            if status == 401, (Self.errorObject(data)["code"] as? String ?? "").hasPrefix("PGRST30") {
                if !refreshed { refreshed = true; continue }
                throw RemoteError.server(status: 401, message: "The server doesn't accept this session's token.")
            }
            return try Self.interpret(status, data)
        }
    }

    static func interpret(_ status: Int, _ data: Data) throws -> Data {
        if (200..<300).contains(status) { return data }
        let o = errorObject(data)
        let code = o["code"] as? String ?? ""
        // Only PostgREST and Postgres answer in {code, message}. Anything else (Cloudflare's 403 or
        // 429 page, a gateway error, an expired Access token) is the road, not the database: it is
        // transient and must never be held against a notation.
        guard !code.isEmpty, let message = o["message"] as? String else {
            throw RemoteError.server(status: status, message: "The server couldn't be reached properly (HTTP \(status)).")
        }
        switch (status, code) {
        case (409, "PT409"): throw RemoteError.conflict(headRev: Int(o["details"] as? String ?? "") ?? 0)
        case (404, "PT404"): throw RemoteError.notFound
        case (401, _), (403, _): throw RemoteError.forbidden(message)
        case (400..<500, _) where status != 404: throw RemoteError.rejected(code: code, message: message)
        default: throw RemoteError.server(status: status, message: message)
        }
    }

    private static func errorObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func unexpected() -> RemoteError {
        .server(status: 200, message: "The server's answer wasn't understood.")
    }

    static func parseDocs(_ data: Data) throws -> [RemoteDoc] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw unexpected() }
        return try rows.map { r in
            guard let id = (r["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let scope = (r["scope"] as? String).flatMap(SyncScope.init(rawValue:)),
                  let rev = r["rev"] as? Int, let seq = (r["seq"] as? NSNumber)?.int64Value,
                  let name = r["name"] as? String
            else { throw unexpected() }
            return RemoteDoc(
                id: id, scope: scope, rev: rev, seq: seq, name: name, folder: r["folder"] as? String ?? "",
                deleted: r["deleted"] as? Bool ?? false,
                updatedAt: (r["updated_at"] as? String).flatMap(parseDate) ?? Date(),
                forkedFrom: (r["forked_from"] as? String).flatMap(UUID.init(uuidString:)),
                content: try r["content"].map(serialize))
        }
    }

    /// The bytes a notation file holds: the same layout the editor writes, so a pulled file and a
    /// saved one differ only where the notation does.
    static func serialize(_ json: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Postgres writes microseconds; ISO8601DateFormatter wants at most milliseconds.
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }

    /// Which Mac made a revision, for the history list. gethostname, not Host: no DNS lookup.
    static let deviceName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count - 1)
        let name = String(cString: buf)
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }()
}
