import CryptoKit
import Foundation
import Observation

/// A change made through the library UI that the engine can't see by looking at files: a rename
/// or move keeps the notation's identity (and so its history), a delete must reach the server.
enum LibraryEvent {
    case renamed(from: URL, to: URL)   // a file or a folder
    case willDelete(URL)               // about to go to the Trash: last chance to read what is in it
    case deleted(URL)                  // a file or a folder, already gone from disk
}

/// A file or folder name with the characters filesystems dislike removed.
func sanitizeFileName(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
    let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { !banned.contains($0) }))
    // "." and ".." survive the character filter but would walk out of the cache folder.
    return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "Untitled" : cleaned
}

/// Keeps the local cache and the server in step, without ever losing an edit.
///
/// Editing only ever touches local files, so it is as fast as before and works offline. Every
/// 30 seconds, and shortly after anything changes, a pass pushes what changed here and pulls what
/// changed there:
///
///  * **push**: a file whose bytes, name or folder differ from what was last synced becomes a new
///    revision. A file with no entry is a new notation. A delete made in the app becomes a
///    tombstone revision.
///  * **pull**: the server's change feed (everything newer than `cursor`) is written into the
///    cache. Where both sides changed the same notation, the local version is kept as a new
///    "conflicted copy" notation and the server's version takes the original's place. Nothing is
///    discarded: the server keeps every revision either way.
///
/// The server is the truth and the cache is disposable: a file that goes missing from the cache
/// is fetched again rather than treated as a delete. Deletes happen through the app.
@MainActor @Observable
final class SyncEngine {
    enum Status: Equatable {
        case idle
        case syncing
        case offline
        case signedOut
        case failed(String)
    }

    /// One line for the footer: what sync is doing, or what is wrong.
    var statusText: String {
        switch status {
        case .idle: return lastSynced == nil ? "Not synced yet" : "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline · will sync"
        case .signedOut: return "Signed out"
        case .failed(let message): return message
        }
    }

    var hasProblem: Bool {
        if case .failed = status { return true }
        return status == .signedOut
    }

    /// Worth a word in the toolbar only when it isn't simply fine.
    var toolbarText: String? { status == .idle && lastSynced != nil ? nil : statusText }

    private(set) var status: Status = .idle
    private(set) var lastSynced: Date?
    /// Changes every time a pull or restore writes, moves or removes files; the UI watches it.
    private(set) var fileChanges = FileChanges()
    /// Set by the editor: write whatever has been typed but not yet saved to its file. The engine calls
    /// it right before it looks at, or replaces, a file, so unsaved typing is never invisible to a
    /// sync (it would be overwritten by a pull, or missed by a push).
    @ObservationIgnored var flushEdits: (() -> Void)?
    #if DEBUG
    /// Tests: let the next push reach the server, then behave as if the answer was lost.
    @ObservationIgnored var debugDropNextSaveResult = false
    #endif

    struct FileChanges: Equatable {
        var token = 0
        var urls: [URL] = []
    }

    @ObservationIgnored let storage: AccountStorage
    @ObservationIgnored let session: AuthSession
    @ObservationIgnored let api: PanchamAPI
    @ObservationIgnored var state: SyncState
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    /// What went wrong with individual notations in this pass, so the status never says "Synced"
    /// while one of them isn't.
    @ObservationIgnored private var problems: [String: String] = [:]
    /// Content of files about to be trashed, read in `.willDelete`, used by the `.deleted` that follows.
    @ObservationIgnored private var stashedForDelete: [UUID: Data] = [:]
    @ObservationIgnored private var lockFD: Int32 = -1

    static let interval: Duration = .seconds(30)

    init(session: AuthSession, storage: AccountStorage) {
        self.session = session
        self.storage = storage
        self.api = PanchamAPI(session: session)
        var loaded = SyncState.load(from: storage.stateFile)
        let server = session.config.restURL.absoluteString
        // This cache was last synced with a different server (a development one): its revision numbers
        // mean nothing here. Start over; the first pass adopts files that match, so nothing duplicates.
        if !loaded.server.isEmpty && loaded.server != server { loaded = SyncState() }
        loaded.server = server
        self.state = loaded
    }

    var isAdmin: Bool { session.account?.isAdmin ?? false }
    func canEdit(_ scope: SyncScope) -> Bool { session.account?.canEdit(scope) ?? false }

    func announce(_ urls: [URL]) {
        fileChanges = FileChanges(token: fileChanges.token + 1, urls: urls)
    }

    // MARK: Running

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        kickTask?.cancel(); kickTask = nil
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }

    /// Sync soon: after an edit, or when the app comes to the front.
    func kick(after delay: TimeInterval = 1.5) {
        kickTask?.cancel()
        kickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One push-then-pull. Only one runs at a time; a request made during one runs again after it.
    func syncNow() async {
        if running { rerun = true; return }
        // One process syncs one account's cache: two would register the same new file as two notations.
        if lockFD < 0 {
            guard let fd = storage.acquireLock() else {
                status = .failed("Pancham is already open for this account")
                return
            }
            lockFD = fd
        }
        running = true
        defer { running = false }
        var passes = 0
        repeat {
            rerun = false
            passes += 1
            status = .syncing
            problems = [:]
            flushEdits?()
            do {
                // A fresh or reset cache: take what the server has first, adopting files that already
                // match it, before any local file is registered as new.
                if state.hasPulled != true { try await pull() }
                try await push()
                try await pull()
                if problems.isEmpty {
                    status = .idle
                    lastSynced = Date()
                } else {
                    let names = problems.values.sorted()
                    status = .failed(names.count == 1 ? names[0] : "\(names.count) notations couldn't sync")
                }
            } catch RemoteError.offline {
                status = .offline
            } catch RemoteError.signedOut {
                status = .signedOut
                return
            } catch {
                status = .failed(error.localizedDescription)
            }
        } while rerun && status != .offline && passes < 5
    }

    /// Wait out any pass already running, then run a full one.
    func syncAndWait() async {
        while running { try? await Task.sleep(for: .milliseconds(40)) }
        await syncNow()
    }

    // MARK: Library hooks

    func libraryEvent(_ event: LibraryEvent) {
        switch event {
        case .renamed(let from, let to):
            guard let f = storage.relative(from), let t = storage.relative(to) else { return }
            for (key, var e) in state.entries {
                if e.path == f { e.path = t }
                else if e.path.hasPrefix(f + "/") { e.path = t + e.path.dropFirst(f.count) }
                else { continue }
                state.entries[key] = e
            }
        case .willDelete(let url):
            // Edits not yet synced would otherwise exist only in the Trash.
            flushEdits?()
            guard let f = storage.relative(url) else { return }
            for e in state.entries.values where (e.path == f || e.path.hasPrefix(f + "/")) && e.rev > 0 {
                stashedForDelete[e.docID] = nil               // a stash left by a trash that failed is stale
                if let data = try? Data(contentsOf: storage.url(forRelative: e.path)), Self.hash(data) != e.syncedHash {
                    stashedForDelete[e.docID] = data
                }
            }
            return
        case .deleted(let url):
            guard let f = storage.relative(url) else { return }
            for (key, e) in state.entries where e.path == f || e.path.hasPrefix(f + "/") {
                if e.rev > 0 {
                    state.pendingDeletes.append(PendingDelete(docID: e.docID, rev: e.rev, scope: e.scope,
                                                              name: e.syncedName, folder: e.syncedFolder,
                                                              content: stashedForDelete.removeValue(forKey: e.docID)))
                }
                state.entries[key] = nil
            }
        }
        persist()
        kick()
    }

    // MARK: Push

    private func push() async throws {
        dropMissingEntries()
        scanLocalFiles()
        try await pushDeletes()
        for key in state.entries.keys.sorted() { try await pushEntry(key) }
    }

    private func pushDeletes() async throws {
        for p in state.pendingDeletes {
            do {
                do {
                    try await api.save(id: p.docID, base: p.rev, name: p.name, folder: p.folder, content: p.content,
                                       deleted: true, scope: p.scope)
                } catch RemoteError.conflict(let head) {
                    // It changed elsewhere meanwhile. The delete still stands; the other edit is in the history.
                    try await api.save(id: p.docID, base: head, name: p.name, folder: p.folder, content: p.content,
                                       deleted: true, scope: p.scope)
                }
            } catch let error as RemoteError {
                switch error.disposition {
                case .stopPass: throw error
                case .retryLater:
                    problems["delete \(p.docID)"] = "“\(p.name)” couldn't be deleted: \(error.localizedDescription)"
                    continue                                   // keep it queued; the rest carry on
                case .permanent: break                         // gone, not ours, or refused for good
                }
            }
            state.pendingDeletes.removeAll { $0 == p }
            persist()
        }
    }

    private func pushEntry(_ key: String, mayRebase: Bool = true) async throws {
        guard let e = state.entries[key] else { return }
        guard canEdit(e.scope) else { return }
        let url = storage.url(forRelative: e.path)
        let (name, folder) = Self.nameAndFolder(of: e.path)
        let stamp = AccountStorage.stamp(url)                  // taken BEFORE reading, so an edit during the read isn't skipped
        if e.rev > 0, let stamp, stamp == e.syncedStamp, name == e.syncedName, folder == e.syncedFolder { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let hash = Self.hash(data)
        if e.rev > 0, hash == e.syncedHash, name == e.syncedName, folder == e.syncedFolder { return }
        let failedKey = "\(hash)|\(name)|\(folder)"
        if e.failedKey == failedKey {                          // refused before, bytes unchanged: keep saying so
            problems[key] = e.failedMessage ?? "“\(name)” couldn't be synced"
            return
        }
        // Written down BEFORE the request, so if the answer never arrives we can tell, later, that
        // what the server holds is our own push and not someone else's edit.
        let sentNow = InFlight(hash: Self.canonicalHash(data), name: name, folder: folder)
        let recent = Array(((state.entries[key]?.inflight ?? []) + [sentNow]).suffix(5))
        state.entries[key]?.inflight = recent
        persist()
        do {
            let saved = try await api.save(id: e.docID, base: e.rev, name: name, folder: folder, content: data,
                                           scope: e.scope, forkedFrom: e.rev == 0 ? e.forkedFrom : nil,
                                           note: e.rev == 0 ? e.note : nil)
            #if DEBUG
            if debugDropNextSaveResult { debugDropNextSaveResult = false; throw RemoteError.offline }
            #endif
            guard state.entries[key] != nil else {
                // Deleted while its first push was in flight: it exists on the server now, so delete it there too.
                state.pendingDeletes.append(PendingDelete(docID: e.docID, rev: saved.rev, scope: e.scope,
                                                          name: name, folder: folder, content: nil))
                persist()
                return
            }
            // The file may have been edited or renamed while we waited: record what was PUSHED, so
            // whatever differs now is still seen as a change next time.
            state.entries[key]?.markSynced(rev: saved.rev, hash: hash)
            state.entries[key]?.syncedStamp = stamp
            state.entries[key]?.syncedName = name          // what was PUSHED, even if renamed while we waited
            state.entries[key]?.syncedFolder = folder
            persist()
        } catch RemoteError.conflict {
            try await resolveConflict(key, data: data, hash: hash, name: name, folder: folder, mayRebase: mayRebase)
        } catch RemoteError.notFound {
            // The server has no such notation (a different server, or a database restored from earlier):
            // this file becomes a new notation, with a new id.
            state.entries[key] = nil
            register(newFile: url, scope: e.scope, forkedFrom: nil, note: "re-created: the server had no record of it")
        } catch RemoteError.rejected(_, let message) {
            refuse(key, failedKey, "“\(name)” couldn't be synced: \(message)")
        } catch RemoteError.forbidden(let message) {
            refuse(key, failedKey, "“\(name)” couldn't be synced: \(message)")
        } catch RemoteError.server(_, let message) {
            problems[key] = "“\(name)” couldn't be synced: \(message)"       // transient: tried again next pass
        }
    }

    /// The server turned these exact bytes down for good. Say so, and don't ask again until they change.
    private func refuse(_ key: String, _ failedKey: String, _ message: String) {
        state.entries[key]?.failedKey = failedKey
        state.entries[key]?.failedMessage = message
        state.entries[key]?.inflight = nil
        problems[key] = message
        persist()
    }

    /// Someone saved this notation since we last synced it. If what they saved is what we have (a
    /// retry whose answer was lost) we are simply in step; if it is our own earlier push, this is a
    /// newer edit on top of it. Otherwise both versions are kept.
    private func resolveConflict(_ key: String, data: Data, hash: String, name: String, folder: String,
                                 mayRebase: Bool) async throws {
        guard let e = state.entries[key], let head = try await api.head(of: e.docID) else { return }
        if let theirs = head.content, !head.deleted, head.name == name, head.folder == folder, Self.sameJSON(theirs, data) {
            state.entries[key]?.markSynced(rev: head.rev, hash: hash)
            persist()
            return
        }
        if mayRebase, let theirs = head.content, !head.deleted,
           let sent = e.inflight?.first(where: { $0.name == head.name && $0.folder == head.folder
                                                 && $0.hash == Self.canonicalHash(theirs) }) {
            // Our earlier push did land (its answer was lost) and this file has moved on since. Start
            // from what the server holds and push the newer edit on top, instead of calling it a conflict.
            state.entries[key]?.markSynced(rev: head.rev, hash: nil)      // the file has moved on: still unsynced
            persist()
            try await pushEntry(key, mayRebase: false)
            return
        }
        flushEdits?()
        var changed: [URL] = []
        applyRemote(head, forceKeepingLocalCopy: true, changed: &changed)
        state.entries[key]?.inflight = nil
        persist()
        if !changed.isEmpty { announce(changed) }
    }

    // MARK: Pull

    private func pull() async throws {
        var changed: [URL] = []
        defer { if !changed.isEmpty { announce(changed) } }
        while true {
            let page = try await api.feed(after: state.cursor, limit: 50)
            // Typing that happened while we waited is written out first; from here to the end of the
            // loop there is no suspension, so no new typing can slip in between looking and replacing.
            flushEdits?()
            var stoppedAt: Int64?
            for doc in page where !applyRemote(doc, forceKeepingLocalCopy: false, changed: &changed) {
                stoppedAt = doc.seq - 1                       // couldn't write it: come back for it next time
                problems["pull \(doc.id)"] = "“\(doc.name)” couldn't be saved to this Mac"
                break
            }
            if let stoppedAt { state.cursor = max(state.cursor, stoppedAt); persist(); break }
            if let last = page.last { state.cursor = max(state.cursor, last.seq) }
            if page.count < 50 { state.hasPulled = true }
            persist()
            if page.count < 50 { break }
        }
    }

    /// Write one server notation into the cache. False if it couldn't be written (the cursor then
    /// stays before it, so it is fetched again).
    @discardableResult
    private func applyRemote(_ doc: RemoteDoc, forceKeepingLocalCopy: Bool, changed: inout [URL]) -> Bool {
        let key = doc.id.uuidString
        let root = doc.scope == .global ? storage.globalRoot : storage.libraryRoot
        guard var e = state.entries[key] else {
            guard !doc.deleted, let content = doc.content else { return true }
            let wanted = storage.directory(root, folder: doc.folder).appendingPathComponent(sanitizeFileName(doc.name))
                .appendingPathExtension("pancham")
            let claimed = Set(state.entries.values.map(\.path))
            if let rel = storage.relative(wanted), !claimed.contains(rel), let local = try? Data(contentsOf: wanted),
               Self.sameJSON(local, content) {
                // Already here, and nothing tracks it (the sync state was lost, or belongs to another
                // server): adopt the file instead of writing a second copy beside it.
                let (name, folder) = Self.nameAndFolder(of: rel)
                state.entries[key] = SyncEntry(docID: doc.id, scope: doc.scope, path: rel, rev: doc.rev,
                                               syncedHash: Self.hash(local), syncedName: name, syncedFolder: folder)
                return true
            }
            let target = uniqueURL(in: storage.directory(root, folder: doc.folder), base: sanitizeFileName(doc.name))
            guard (try? storage.write(content, to: target)) != nil, let rel = storage.relative(target) else { return false }
            let (name, folder) = Self.nameAndFolder(of: rel)
            state.entries[key] = SyncEntry(docID: doc.id, scope: doc.scope, path: rel, rev: doc.rev,
                                           syncedHash: Self.hash(content), syncedName: name, syncedFolder: folder)
            changed.append(target)
            return true
        }
        guard doc.rev > e.rev || forceKeepingLocalCopy else { return true }
        let oldURL = storage.url(forRelative: e.path)
        if forceKeepingLocalCopy || isDirty(e) {
            if doc.deleted && !forceKeepingLocalCopy {
                // Edited here, deleted elsewhere: the edits become a notation of their own.
                state.entries[key] = nil
                rerun = true
                return true
            }
            keepAsConflictedCopy(e)
        }
        if doc.deleted {
            try? FileManager.default.removeItem(at: oldURL)
            state.entries[key] = nil
            changed.append(oldURL)
            return true
        }
        guard let content = doc.content else { return true }
        let wanted = storage.directory(root, folder: doc.folder).appendingPathComponent(sanitizeFileName(doc.name))
            .appendingPathExtension("pancham")
        let target = wanted.standardizedFileURL.path == oldURL.standardizedFileURL.path
            ? oldURL : uniqueURL(in: storage.directory(root, folder: doc.folder), base: sanitizeFileName(doc.name))
        guard (try? storage.write(content, to: target)) != nil, let rel = storage.relative(target) else { return false }
        if target != oldURL { try? FileManager.default.removeItem(at: oldURL); changed.append(oldURL) }
        e.markSynced(rev: doc.rev, hash: Self.hash(content), path: rel)
        e.syncedStamp = AccountStorage.stamp(target)
        state.entries[key] = e
        changed.append(target)
        return true
    }

    /// Does the file hold edits the server hasn't seen?
    private func isDirty(_ e: SyncEntry) -> Bool {
        if !canEdit(e.scope) { return false }          // read-only here: the server wins
        guard let data = try? Data(contentsOf: storage.url(forRelative: e.path)) else { return false }
        let (name, folder) = Self.nameAndFolder(of: e.path)
        return Self.hash(data) != e.syncedHash || name != e.syncedName || folder != e.syncedFolder
    }

    func keepAsConflictedCopy(_ e: SyncEntry) {
        let url = storage.url(forRelative: e.path)
        guard let data = try? Data(contentsOf: url) else { return }
        let base = url.deletingPathExtension().lastPathComponent
        let target = uniqueURL(in: url.deletingLastPathComponent(),
                               base: "\(base) (conflicted copy \(Self.stamp.string(from: Date())))")
        guard (try? storage.write(data, to: target)) != nil else { return }
        register(newFile: target, scope: e.scope, forkedFrom: nil, note: "kept when \"\(base)\" changed in two places")
    }

    // MARK: Files

    /// A file with no entry is a new notation.
    private func scanLocalFiles() {
        var known = Set(state.entries.values.map(\.path))
        func scan(_ root: URL, _ scope: SyncScope) {
            for url in storage.noteFiles(in: root) {
                guard let rel = storage.relative(url), known.insert(rel).inserted else { continue }
                register(newFile: url, scope: scope, forkedFrom: nil, note: nil)
            }
        }
        scan(storage.libraryRoot, .private)
        if isAdmin { scan(storage.globalRoot, .global) }
    }

    /// An entry whose file is gone (someone deleted it in Finder, or the cache was cleared) is
    /// fetched again: the server is the truth, and deleting is done through the app.
    private func dropMissingEntries() {
        let fm = FileManager.default
        let missing = state.entries.filter { !fm.fileExists(atPath: storage.url(forRelative: $0.value.path).path) }
        guard !missing.isEmpty else { return }
        for key in missing.keys { state.entries[key] = nil }
        state.cursor = 0
        persist()
    }

    func register(newFile url: URL, scope: SyncScope, forkedFrom: UUID?, note: String?) {
        guard let rel = storage.relative(url) else { return }
        let id = UUID()
        state.entries[id.uuidString] = SyncEntry(docID: id, scope: scope, path: rel, rev: 0, syncedHash: "",
                                                 syncedName: "", syncedFolder: "", forkedFrom: forkedFrom, note: note)
        persist()
        rerun = true
        kick()
    }

    /// `dir/base.pancham` that no file and no entry has taken yet.
    func uniqueURL(in dir: URL, base: String) -> URL {
        storage.uniqueURL(in: dir, base: base, claimed: Set(state.entries.values.map(\.path)))
    }

    func persist() {
        state.save(to: storage.stateFile)
    }

    // MARK: Helpers

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// "library/Yaman/Aaj Ibaadat.pancham" -> ("Aaj Ibaadat", "Yaman"); a top-level file has folder "".
    nonisolated static func nameAndFolder(of relativePath: String) -> (name: String, folder: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        let file = parts.last ?? ""
        let name = (file as NSString).deletingPathExtension
        return (name, parts.count >= 3 ? parts[parts.count - 2] : "")
    }

    /// A hash of a notation's meaning, not its formatting: the same whether it is the file as the editor
    /// wrote it or the server's re-serialised copy.
    nonisolated static func canonicalHash(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return hash(data) }
        return hash(canonical)
    }

    nonisolated static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: a), let y = try? JSONSerialization.jsonObject(with: b)
        else { return false }
        return (x as AnyObject).isEqual(y)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
