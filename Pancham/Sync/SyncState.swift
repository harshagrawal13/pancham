import Foundation

/// Where one signed-in account's local copy lives:
///
///     ~/Library/Application Support/Pancham/accounts/<account id>/
///         library/   your private notations, as folder/name.pancham (what the sidebar shows)
///         global/    the shared ones, same layout (read-only unless you are an admin)
///         sync.json  what has been synced (`SyncState`)
///
/// It is a cache: everything in it is on the server, so deleting the folder loses nothing.
struct AccountStorage {
    let root: URL
    var libraryRoot: URL { root.appendingPathComponent("library", isDirectory: true) }
    var globalRoot: URL { root.appendingPathComponent("global", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("sync.json") }
    var lockFile: URL { root.appendingPathComponent("sync.lock") }

    init(account: Account, base: URL = AuthSession.defaultDirectory()) {
        let unresolved = base.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(account.id.uuidString.lowercased(), isDirectory: true)
        let fm = FileManager.default
        for sub in ["library", "global"] {
            try? fm.createDirectory(at: unresolved.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        // Resolved once, so every URL the app derives from this root has the same prefix.
        root = URL(fileURLWithPath: Self.canonicalPath(unresolved), isDirectory: true)
    }

    /// The real path of `url`, symlinks resolved. Unlike `URL.resolvingSymlinksInPath`, which turns
    /// /private/tmp into /tmp, this never drops /private, so two spellings of one place compare
    /// equal. A path that doesn't exist (a file just deleted) is resolved through its nearest
    /// existing folder.
    static func canonicalPath(_ url: URL) -> String {
        func real(_ path: String) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(path, &buffer).map { String(cString: $0) }
        }
        var path = url.standardizedFileURL.path
        var tail: [String] = []
        while !path.isEmpty, path != "/" {
            if let r = real(path) { return ([r] + tail.reversed()).joined(separator: "/") }
            tail.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
        return url.standardizedFileURL.path
    }

    /// `url`'s path below `root`, e.g. "library/Yaman/Aaj Ibaadat.pancham"; nil if it isn't inside.
    func relative(_ url: URL) -> String? {
        let p = cheaplyInside(url) ? url.standardizedFileURL.path : Self.canonicalPath(url)
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : nil
    }

    /// Is `url` one of the shared (global) notations?
    func isGlobal(_ url: URL) -> Bool {
        let quick = url.standardizedFileURL.path
        if quick.hasPrefix(globalRoot.path + "/") { return true }
        if quick.hasPrefix(libraryRoot.path + "/") { return false }
        return Self.canonicalPath(url).hasPrefix(globalRoot.path + "/")      // another spelling of the same place
    }

    /// URLs the app itself made (from `libraryRoot`/`globalRoot`) already share the root's prefix; only
    /// a foreign spelling needs the real-path walk.
    private func cheaplyInside(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.path + "/") }

    /// "size-modification time" of a file, or nil if it isn't there.
    static func stamp(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? NSNumber, let when = a[.modificationDate] as? Date else { return nil }
        return "\(size)-\(when.timeIntervalSince1970)"
    }

    func url(forRelative path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// A marker beside the cache folder (not inside it, so wiping the cache doesn't re-ask) that says the
    /// "bring my old notations along?" question has been answered.
    /// The first account to sign in on this Mac is the one the old, pre-account notations belong to; no
    /// later account is ever offered them (they could otherwise import someone else's notations).
    func claimsLegacyLibrary() -> Bool {
        let owner = root.deletingLastPathComponent().appendingPathComponent("legacy-owner")
        if let existing = try? String(contentsOf: owner, encoding: .utf8) { return existing == root.lastPathComponent }
        try? root.lastPathComponent.write(to: owner, atomically: true, encoding: .utf8)
        return true
    }

    private var legacyMarker: URL {
        root.deletingLastPathComponent().appendingPathComponent("legacy-import-answered-\(root.lastPathComponent)")
    }
    var legacyImportAnswered: Bool { FileManager.default.fileExists(atPath: legacyMarker.path) }
    func markLegacyImportAnswered() { FileManager.default.createFile(atPath: legacyMarker.path, contents: Data()) }

    func scope(of url: URL) -> SyncScope { isGlobal(url) ? .global : .private }

    func directory(_ root: URL, folder: String) -> URL {
        folder.isEmpty ? root : root.appendingPathComponent(sanitizeFileName(folder), isDirectory: true)
    }

    /// `dir/base.pancham`, or `dir/base 2.pancham`, ...: a name no file and no entry (`claimed`) has.
    func uniqueURL(in dir: URL, base: String, claimed: Set<String>) -> URL {
        var n = 1
        while true {
            let url = dir.appendingPathComponent(n == 1 ? base : "\(base) \(n)").appendingPathExtension("pancham")
            if !FileManager.default.fileExists(atPath: url.path), !(relative(url).map(claimed.contains) ?? false) { return url }
            n += 1
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Notation files at the top of `root` and one folder down: what the sidebar can show.
    func noteFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        func notes(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { ["pancham", "json"].contains($0.pathExtension.lowercased()) }
        }
        var out: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? [] {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out += notes(item)
            } else if ["pancham", "json"].contains(item.pathExtension.lowercased()) {
                out.append(item)
            }
        }
        return out
    }

    /// Take the lock that says "this process syncs this account's cache". Two engines scanning one
    /// folder would each register the same new file as a different notation. Returns the open
    /// descriptor to hold (and close to release), or nil if another process has it.
    func acquireLock() -> Int32? {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return fd
    }
}

/// One notation in the local cache, and what the server last agreed about it.
struct SyncEntry: Codable, Equatable {
    var docID: UUID
    var scope: SyncScope
    /// Below the account folder: "library/Yaman/Aaj Ibaadat.pancham". Renaming or moving the file
    /// changes this; the next push turns the difference into a revision.
    var path: String
    /// The server revision this file was last in step with. 0: never pushed.
    var rev: Int
    /// Hash of the file's bytes then. A different hash now means edits not yet pushed.
    var syncedHash: String
    /// The file's size and modification time when it was last in step: if they haven't changed, so
    /// haven't the bytes, and a sync pass needn't read and hash the file.
    var syncedStamp: String?
    var syncedName: String
    var syncedFolder: String
    /// For a notation added from the global library: where it came from. Sent with the first push.
    var forkedFrom: UUID?
    /// Sent with the first push, e.g. "imported", shown in the history.
    var note: String?
    /// The server refused these exact bytes (not valid JSON, a name too long...); don't retry until
    /// they change, and keep saying so (`failedMessage`) rather than showing "Synced".
    var failedKey: String?
    var failedMessage: String?
    /// Pushes that were sent without an answer coming back (the last few): if the server turns out to
    /// hold exactly one of them, it is our own push, not someone else's edit.
    var inflight: [InFlight]?
}

extension SyncEntry {
    /// The file at `path` now matches revision `rev` of the server's copy: forget everything that
    /// said otherwise (a refusal, an unanswered push, first-push extras).
    mutating func markSynced(rev: Int, hash: String?, path: String? = nil) {
        let (name, folder) = SyncEngine.nameAndFolder(of: path ?? self.path)
        if let path { self.path = path }
        self.rev = rev
        syncedStamp = nil                // callers that know the file's stamp set it after
        syncedHash = hash ?? ""          // nil: the file has moved on since what was pushed, so it is still unsynced
        syncedName = name
        syncedFolder = folder
        forkedFrom = nil; note = nil; failedKey = nil; failedMessage = nil; inflight = nil
    }
}

/// What a push was carrying: the notation's content as a canonical hash (so it can be recognised in
/// the server's re-serialised copy), and its name and folder.
struct InFlight: Codable, Equatable {
    var hash: String
    var name: String
    var folder: String
}

/// A delete made here that the server hasn't heard yet.
struct PendingDelete: Codable, Equatable {
    var docID: UUID
    var rev: Int
    var scope: SyncScope
    var name: String
    var folder: String
    /// Edits made here since the last sync, which the delete would otherwise leave only in the Trash:
    /// sent with the delete so the server's last version is the one you last saw.
    var content: Data?
}

struct SyncState: Codable, Equatable {
    /// The server this state is about. A cache used against another one (a development server) starts
    /// over rather than sending one server's revision numbers to the other.
    var server: String = ""
    /// False until the first full pull has completed. (A cursor of 0 can't say: an account with nothing
    /// on the server never advances it.) Before that, files already here are adopted, not re-uploaded.
    var hasPulled: Bool? = nil
    /// Highest change-feed position applied. 0 re-reads everything.
    var cursor: Int64 = 0
    /// Keyed by the notation's id.
    var entries: [String: SyncEntry] = [:]
    var pendingDeletes: [PendingDelete] = []

    /// The saved state, or a fresh one. A file that can't be read is set aside as `sync.json.corrupt`
    /// rather than overwritten; starting over is safe because the first pass adopts files that match
    /// what the server has instead of uploading them again.
    static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        if let s = try? JSONDecoder().decode(SyncState.self, from: data) { return s }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return SyncState()
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
