import Foundation

/// What the UI asks of sync besides "keep going": a notation's history, restoring a version, bringing
/// deleted notations back, and moving notations between the private and global libraries.
extension SyncEngine {
    /// The server's id for a file, if it has one yet.
    func docID(for url: URL) -> UUID? {
        guard let rel = storage.relative(url) else { return nil }
        return state.entries.values.first { $0.path == rel && $0.rev > 0 }?.docID
    }

    func history(for url: URL) async throws -> [RevisionInfo] {
        await syncAndWait()
        guard let id = docID(for: url) else { throw RemoteError.notFound }
        return try await api.history(of: id)
    }

    /// Make revision `rev` the notation's newest: a new revision with its content, so nothing is lost.
    func restore(_ url: URL, toRevision rev: Int) async throws {
        guard let rel = storage.relative(url), let docID = docID(for: url) ?? state.entries.values.first(where: { $0.path == rel })?.docID
        else { throw RemoteError.notFound }
        let content = try await api.content(of: docID, rev: rev)
        await syncAndWait()                       // push edits first, so they stay in the history
        await beginExclusive(); defer { endExclusive() }       // no sync pass between here and the end
        flushEdits?()
        guard let rel = storage.relative(url),
              let (key, e) = state.entries.first(where: { $0.value.path == rel }), e.rev > 0 else { throw RemoteError.notFound }
        let (name, folder) = Self.nameAndFolder(of: e.path)
        let before = (try? Data(contentsOf: url)).map(Self.hash)
        let saved = try await api.save(id: e.docID, base: e.rev, name: name, folder: folder, content: content,
                                       scope: e.scope, note: "restored from revision \(rev)")
        // Typing during that round trip is on disk now; keep it as a copy rather than replace it unseen.
        flushEdits?()
        if let before, let now = (try? Data(contentsOf: url)).map(Self.hash), now != before, let cur = state.entries[key] {
            keepAsConflictedCopy(cur)
        }
        try content.write(to: url, options: .atomic)
        state.entries[key]?.markSynced(rev: saved.rev, hash: Self.hash(content))
        state.entries[key]?.syncedStamp = AccountStorage.stamp(url)
        persist()
        announce([url])
    }

    func deletedNotations() async throws -> [RemoteDoc] {
        try await api.deletedDocs(includeGlobal: isAdmin)
    }

    func undelete(_ doc: RemoteDoc) async throws {
        await beginExclusive()
        defer { endExclusive() }
        try await api.save(id: doc.id, base: doc.rev, name: doc.name, folder: doc.folder, deleted: false,
                           scope: doc.scope, note: "restored after delete")
        endExclusive()
        await syncAndWait()
    }

    /// Copy a global notation into your own library. Returns the new file.
    @discardableResult
    func addToLibrary(_ url: URL) throws -> URL {
        guard let rel = storage.relative(url), let e = state.entries.values.first(where: { $0.path == rel }),
              e.scope == .global else { throw RemoteError.notFound }
        let data = try Data(contentsOf: url)
        let (name, folder) = Self.nameAndFolder(of: e.path)
        let target = uniqueURL(in: storage.directory(storage.libraryRoot, folder: folder), base: name)
        try storage.write(data, to: target)
        register(newFile: target, scope: .private, forkedFrom: e.docID, note: "added from the global library")
        return target
    }

    /// Admins: copy one of your notations into the global library. Returns the new file.
    @discardableResult
    func publish(_ url: URL) throws -> URL {
        guard isAdmin, let rel = storage.relative(url), let e = state.entries.values.first(where: { $0.path == rel }),
              e.scope == .private else { throw RemoteError.forbidden("Only admins publish to the global library.") }
        let data = try Data(contentsOf: url)
        let (name, folder) = Self.nameAndFolder(of: e.path)
        let target = uniqueURL(in: storage.directory(storage.globalRoot, folder: folder), base: name)
        try storage.write(data, to: target)
        register(newFile: target, scope: .global, forkedFrom: nil, note: "published from a private notation")
        return target
    }

    /// Bring files from outside (an old library folder) in as new notations.
    func importFiles(_ files: [(source: URL, folder: String)], note: String) -> [URL] {
        var made: [URL] = []
        for (source, folder) in files {
            guard let data = try? Data(contentsOf: source) else { continue }
            let base = sanitizeFileName(source.deletingPathExtension().lastPathComponent)
            let target = uniqueURL(in: storage.directory(storage.libraryRoot, folder: folder), base: base)
            guard (try? storage.write(data, to: target)) != nil else { continue }
            register(newFile: target, scope: .private, forkedFrom: nil, note: note)
            made.append(target)
        }
        return made
    }
}
