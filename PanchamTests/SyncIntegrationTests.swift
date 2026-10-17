import XCTest

/// The app's sync layer against a real backend: Postgres + PostgREST built from db/migrations and
/// the sign-in server, started fresh for every test by server/dev_stack.py (never kamaji). Each
/// "device" is its own cache folder and session, the way two Macs would be.
@MainActor
final class SyncIntegrationTests: XCTestCase {
    private var backend: Backend!
    private var tmp: URL!
    private var devices: [Device] = []

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pn-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        backend = try Backend(admin: ["admin@test.dev"], allow: ["me@test.dev", "friend@test.dev"])
    }

    override func tearDown() async throws {
        devices.forEach { $0.engine.stop() }
        devices = []
        backend?.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Tests

    func testANotationIsPushedAndEveryChangeIsARevision() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Yaman/Aaj Ibaadat.pancham")
        try write("v1", to: file)
        await a.engine.syncAndWait()
        XCTAssertEqual(a.engine.status, .idle)

        var docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.map(\.name), ["Aaj Ibaadat"])
        XCTAssertEqual(docs[0].folder, "Yaman")
        XCTAssertEqual(docs[0].rev, 1)
        XCTAssertEqual(docs[0].scope, .private)

        try write("v2", to: file)
        await a.engine.syncAndWait()
        await a.engine.syncAndWait()                                    // nothing changed: no new revision
        docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs[0].rev, 2)
        XCTAssertEqual(try title(of: XCTUnwrap(docs[0].content)), "v2")
        let history = try await a.api.history(of: docs[0].id)
        XCTAssertEqual(history.map(\.rev), [2, 1])
        let first = try await a.api.content(of: docs[0].id, rev: 1)
        XCTAssertEqual(try title(of: first), "v1")                      // the old version is still there
    }

    func testAnotherDeviceReceivesItAndEditsFlowBack() async throws {
        let a = try await device("me@test.dev")
        let b = try await device("me@test.dev")
        try write("from A", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()

        await b.engine.syncAndWait()
        XCTAssertEqual(try title(of: Data(contentsOf: b.library("Song.pancham"))), "from A")

        try write("edited on B", to: b.library("Song.pancham"))
        await b.engine.syncAndWait()
        await a.engine.syncAndWait()
        XCTAssertEqual(try title(of: Data(contentsOf: a.library("Song.pancham"))), "edited on B")
        XCTAssertEqual(a.engine.fileChanges.urls, [a.library("Song.pancham")])   // the editor is told to reload it
    }

    func testEditingInTwoPlacesKeepsBothVersions() async throws {
        let a = try await device("me@test.dev")
        let b = try await device("me@test.dev")
        try write("start", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        await b.engine.syncAndWait()

        try write("A's edit", to: a.library("Song.pancham"))
        try write("B's edit", to: b.library("Song.pancham"))
        await a.engine.syncAndWait()
        await b.engine.syncAndWait()                                    // B finds A got there first

        XCTAssertEqual(try title(of: Data(contentsOf: b.library("Song.pancham"))), "A's edit")
        let copies = try FileManager.default.contentsOfDirectory(atPath: b.storage.libraryRoot.path)
            .filter { $0.contains("conflicted copy") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try title(of: Data(contentsOf: b.library(copies[0]))), "B's edit")

        await b.engine.syncAndWait()
        let docs = try await b.api.feed(after: 0)
        XCTAssertEqual(docs.count, 2)                                   // the copy reached the server too
        XCTAssertEqual(Set(try docs.map { try title(of: XCTUnwrap($0.content)) }), ["A's edit", "B's edit"])
        await a.engine.syncAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.storage.libraryRoot.path).count, 2)
    }

    func testRenamingAndMovingKeepsTheSameNotationAndItsHistory() async throws {
        let a = try await device("me@test.dev")
        let old = a.library("Old name.pancham")
        try write("v1", to: old)
        await a.engine.syncAndWait()
        let id = try XCTUnwrap(a.engine.docID(for: old))

        let renamed = a.library("New name.pancham")
        try FileManager.default.moveItem(at: old, to: renamed)
        a.engine.libraryEvent(.renamed(from: old, to: renamed))
        await a.engine.syncAndWait()

        let moved = a.library("Evening/New name.pancham")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: renamed, to: moved)
        a.engine.libraryEvent(.renamed(from: renamed, to: moved))
        await a.engine.syncAndWait()

        XCTAssertEqual(a.engine.docID(for: moved), id)
        let headDoc = try await a.api.head(of: id)
        let head = try XCTUnwrap(headDoc)
        XCTAssertEqual([head.name, head.folder, "\(head.rev)"], ["New name", "Evening", "3"])
        let history = try await a.api.history(of: id)
        XCTAssertEqual(history.map(\.name), ["New name", "New name", "Old name"])
        let all = try await a.api.feed(after: 0)
        XCTAssertEqual(all.count, 1)
    }

    func testRenamingAFolderMovesEverythingInIt() async throws {
        let a = try await device("me@test.dev")
        try write("one", to: a.library("Yaman/One.pancham"))
        try write("two", to: a.library("Yaman/Two.pancham"))
        await a.engine.syncAndWait()
        let from = a.library("Yaman"), to = a.library("Bhoopali")
        try FileManager.default.moveItem(at: from, to: to)
        a.engine.libraryEvent(.renamed(from: from, to: to))
        await a.engine.syncAndWait()
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(Set(docs.map(\.folder)), ["Bhoopali"])
        XCTAssertEqual(Set(docs.map(\.rev)), [2])
    }

    func testADeleteReachesOtherDevicesAndCanBeUndone() async throws {
        let a = try await device("me@test.dev")
        let b = try await device("me@test.dev")
        try write("precious", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        await b.engine.syncAndWait()

        try FileManager.default.removeItem(at: a.library("Song.pancham"))
        a.engine.libraryEvent(.deleted(a.library("Song.pancham")))
        await a.engine.syncAndWait()
        await b.engine.syncAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.library("Song.pancham").path))

        let gone = try await a.engine.deletedNotations()
        XCTAssertEqual(gone.map(\.name), ["Song"])
        try await a.engine.undelete(gone[0])
        XCTAssertEqual(try title(of: Data(contentsOf: a.library("Song.pancham"))), "precious")
        await b.engine.syncAndWait()
        XCTAssertEqual(try title(of: Data(contentsOf: b.library("Song.pancham"))), "precious")
        let id = gone[0].id
        let history = try await a.api.history(of: id)
        XCTAssertEqual(history.map(\.deleted), [false, true, false])
    }

    func testAFileDeletedBehindTheAppsBackIsFetchedAgainNotDeleted() async throws {
        let a = try await device("me@test.dev")
        try write("keep", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        try FileManager.default.removeItem(at: a.library("Song.pancham"))   // Finder, or a cleared cache
        await a.engine.syncAndWait()
        XCTAssertEqual(try title(of: Data(contentsOf: a.library("Song.pancham"))), "keep")
        let docs = try await a.api.feed(after: 0)
        XCTAssertFalse(docs[0].deleted)
    }

    func testRestoringAnEarlierVersionAddsARevisionOnTop() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Song.pancham")
        try write("good", to: file)
        await a.engine.syncAndWait()
        try write("oops", to: file)
        await a.engine.syncAndWait()

        let history = try await a.engine.history(for: file)
        XCTAssertEqual(history.map(\.rev), [2, 1])
        try await a.engine.restore(file, toRevision: 1)
        XCTAssertEqual(try title(of: Data(contentsOf: file)), "good")
        let after = try await a.engine.history(for: file)
        XCTAssertEqual(after.map(\.rev), [3, 2, 1])
        XCTAssertEqual(after[0].note, "restored from revision 1")
    }

    func testGlobalNotationsAreAdminsToMakeAndEveryonesToRead() async throws {
        let admin = try await device("admin@test.dev")
        let friend = try await device("friend@test.dev")
        try write("Raag Yaman", to: admin.library("Yaman.pancham"))
        await admin.engine.syncAndWait()
        let published = try admin.engine.publish(admin.library("Yaman.pancham"))
        XCTAssertTrue(published.path.hasPrefix(admin.storage.globalRoot.path))
        await admin.engine.syncAndWait()

        await friend.engine.syncAndWait()
        let theirs = friend.storage.globalRoot.appendingPathComponent("Yaman.pancham")
        XCTAssertEqual(try title(of: Data(contentsOf: theirs)), "Raag Yaman")
        XCTAssertFalse(FileManager.default.fileExists(atPath: friend.library("Yaman.pancham").path), "the admin's private copy stays private")

        // A friend can't change it: even if the file is altered, nothing is pushed.
        try write("defaced", to: theirs)
        await friend.engine.syncAndWait()
        let seenByAdmin = try await admin.api.feed(after: 0).first { $0.scope == .global }
        XCTAssertEqual(try title(of: XCTUnwrap(seenByAdmin?.content)), "Raag Yaman")
        XCTAssertThrowsError(try friend.engine.publish(friend.library("Nope.pancham")))

        // ...but may copy it into their own library, which then belongs to them.
        let copy = try friend.engine.addToLibrary(theirs)
        try write("my take", to: copy)
        await friend.engine.syncAndWait()
        let mine = try await friend.api.feed(after: 0).first { $0.scope == .private }
        XCTAssertEqual(mine?.forkedFrom, seenByAdmin?.id)
        XCTAssertEqual(try title(of: XCTUnwrap(mine?.content)), "my take")
        let adminSees = try await admin.api.feed(after: 0).filter { $0.scope == .private }.map(\.name)
        XCTAssertEqual(adminSees, ["Yaman"], "friend's private copy is invisible to the admin")

        // The admin changes the global one; the friend receives it.
        let adminGlobal = admin.storage.globalRoot.appendingPathComponent("Yaman.pancham")
        try write("Raag Yaman v2", to: adminGlobal)
        await admin.engine.syncAndWait()
        await friend.engine.syncAndWait()
        XCTAssertEqual(try title(of: Data(contentsOf: theirs)), "Raag Yaman v2")
    }

    func testPrivateNotationsAreNotSharedBetweenAccounts() async throws {
        let me = try await device("me@test.dev")
        let friend = try await device("friend@test.dev")
        try write("secret", to: me.library("Mine.pancham"))
        await me.engine.syncAndWait()
        await friend.engine.syncAndWait()
        let friendFiles = try FileManager.default.contentsOfDirectory(atPath: friend.storage.libraryRoot.path)
        XCTAssertEqual(friendFiles, [])
        let seen = try await friend.api.feed(after: 0)
        XCTAssertTrue(seen.isEmpty)
    }

    func testOfflineWorkIsKeptAndSyncedWhenTheServerIsBack() async throws {
        let a = try await device("me@test.dev")
        // Same signed-in session, but the REST server is unreachable.
        let offlineSession = AuthSession(config: ServerConfig(authURL: backend.authURL,
                                                              restURL: URL(string: "http://127.0.0.1:9")!),
                                         directory: a.dir)
        let offline = SyncEngine(session: offlineSession, storage: a.storage)
        try write("written offline", to: a.library("Song.pancham"))
        await offline.syncNow()
        XCTAssertEqual(offline.status, .offline)
        XCTAssertEqual(try title(of: Data(contentsOf: a.library("Song.pancham"))), "written offline")
        offline.stop()                                                   // releases its hold on the cache

        await a.engine.syncAndWait()                                     // back online
        XCTAssertEqual(a.engine.status, .idle)
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.map(\.name), ["Song"])
    }

    func testSigningOutEndsOnlyThatMacsSession() async throws {
        let a = try await device("me@test.dev")
        let other = try await device("me@test.dev")
        await other.session.signOut()
        _ = try await a.session.accessToken(forceRefresh: true)           // the other Mac signing out didn't touch this one
        XCTAssertEqual(a.session.account?.email, "me@test.dev")
    }

    func testARevokedSessionSignsTheAppOut() async throws {
        let a = try await device("me@test.dev")
        // Revoke a's session behind its back (as signing out of it elsewhere would).
        let stored = try JSONDecoder.iso.decode(StoredSession.self, from: Data(contentsOf: a.dir.appendingPathComponent("session.json")))
        var req = URLRequest(url: backend.authURL.appendingPathComponent("auth/v1/logout"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": stored.refreshToken])
        _ = try await URLSession.shared.data(for: req)
        do {
            _ = try await a.session.accessToken(forceRefresh: true)
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? RemoteError, .signedOut)
        }
        XCTAssertNil(a.session.account)
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .signedOut)
    }

    func testSigningInNeedsAnAllowedEmailAndTheRightCode() async throws {
        let session = AuthSession(config: ServerConfig(authURL: backend.authURL, restURL: backend.restURL),
                                  directory: tmp.appendingPathComponent("s"))
        do {
            try await session.requestCode(email: "stranger@test.dev")
            XCTFail("expected a refusal")
        } catch RemoteError.rejected(let code, _) {
            XCTAssertEqual(code, "email_not_allowed")
        }
        try await session.requestCode(email: "me@test.dev")
        do {
            try await session.verify(email: "me@test.dev", code: "000001")
            XCTFail("expected a refusal")
        } catch RemoteError.rejected(let code, _) {
            XCTAssertEqual(code, "otp_expired")
        }
        XCTAssertNil(session.account)
        try await session.verify(email: "me@test.dev", code: try backend.code(for: "me@test.dev"))
        XCTAssertEqual(session.account?.email, "me@test.dev")
        XCTAssertEqual(session.account?.isAdmin, false)

        // Launching again stays signed in without the network.
        let relaunched = AuthSession(config: ServerConfig(authURL: URL(string: "http://127.0.0.1:9")!,
                                                          restURL: URL(string: "http://127.0.0.1:9")!),
                                     directory: tmp.appendingPathComponent("s"))
        XCTAssertEqual(relaunched.account, session.account)
        let mode = try FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("s/session.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testPathsAreComparedByTheirRealLocationNotTheirSpelling() throws {
        // /tmp is /private/tmp: both spellings must mean the same folder, and /private must not be dropped.
        let base = URL(fileURLWithPath: "/tmp/pn-paths-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let account = Account(id: UUID(), email: "x@test.dev", isAdmin: false)
        let storage = AccountStorage(account: account, base: base)
        let global = storage.globalRoot.appendingPathComponent("Yaman/Raag.pancham")
        let alias = URL(fileURLWithPath: global.path.replacingOccurrences(of: "/private/tmp", with: "/tmp"))
        let other = URL(fileURLWithPath: global.path.replacingOccurrences(of: "/tmp", with: "/private/tmp")
            .replacingOccurrences(of: "/private/private", with: "/private"))
        for spelling in [global, alias, other] {
            XCTAssertTrue(storage.isGlobal(spelling), spelling.path)
            XCTAssertEqual(storage.relative(spelling), "global/Yaman/Raag.pancham", spelling.path)
        }
        XCTAssertFalse(storage.isGlobal(storage.libraryRoot.appendingPathComponent("Raag.pancham")))
        XCTAssertNil(storage.relative(URL(fileURLWithPath: "/tmp/elsewhere.pancham")))
    }

    // MARK: Failure handling (from the independent review)

    func testOnlyTheDatabasesOwnRefusalsAreHeldAgainstANotation() throws {
        func outcome(_ status: Int, _ body: String) -> RemoteError? {
            do { _ = try PanchamAPI.interpret(status, Data(body.utf8)); return nil } catch { return error as? RemoteError }
        }
        // The road, not the database: Cloudflare's pages, gateways, an expired Access token. Never permanent.
        for (status, body) in [(403, "<html>Access denied</html>"), (429, "Too many requests"), (502, ""), (503, "<html/>"),
                               (403, "{\"error\": \"nope\"}")] {
            guard case .server = outcome(status, body) else { return XCTFail("\(status) \(body)") }
        }
        // The database speaking.
        XCTAssertEqual(outcome(409, #"{"code":"PT409","message":"conflict","details":"7"}"#), .conflict(headRev: 7))
        XCTAssertEqual(outcome(404, #"{"code":"PT404","message":"no such notation"}"#), .notFound)
        XCTAssertEqual(outcome(403, #"{"code":"PT403","message":"only admins change global notations"}"#),
                       .forbidden("only admins change global notations"))
        if case .rejected(let code, _) = outcome(400, #"{"code":"23514","message":"check violation"}"#) { XCTAssertEqual(code, "23514") }
        else { XCTFail("a check violation is a rejection") }
        // A missing function or table is a deployment problem, not "this notation doesn't exist".
        guard case .server = outcome(404, #"{"code":"PGRST202","message":"no function"}"#) else { return XCTFail("PGRST202") }
        XCTAssertNil(outcome(200, "[]"))
    }

    func testANotationTheServerRefusesIsReportedAndTheRestStillSync() async throws {
        let a = try await device("me@test.dev")
        let tooLong = String(repeating: "x", count: 201)                  // the database limits names to 200
        try write("good", to: a.library("Good.pancham"))
        try write("long", to: a.library("\(tooLong).pancham"))
        await a.engine.syncAndWait()

        guard case .failed(let message) = a.engine.status else { return XCTFail("must not say Synced: \(a.engine.status)") }
        XCTAssertTrue(message.contains("couldn't be synced"), message)
        var docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.map(\.name), ["Good"])                         // the good one went through regardless

        await a.engine.syncAndWait()                                     // refused bytes aren't retried, but it keeps saying so
        guard case .failed = a.engine.status else { return XCTFail("still failing") }

        let long = a.library("\(tooLong).pancham"), short = a.library("Fixed.pancham")
        try FileManager.default.moveItem(at: long, to: short)
        a.engine.libraryEvent(.renamed(from: long, to: short))
        await a.engine.syncAndWait()
        XCTAssertEqual(a.engine.status, .idle)
        docs = try await a.api.feed(after: 0)
        XCTAssertEqual(Set(docs.map(\.name)), ["Good", "Fixed"])
    }

    func testDeletingKeepsEditsMadeSinceTheLastSync() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Song.pancham")
        try write("synced version", to: file)
        await a.engine.syncAndWait()
        try write("typed just before deleting", to: file)                // never synced
        a.engine.libraryEvent(.willDelete(file))                         // what Library.delete does, in order
        try FileManager.default.removeItem(at: file)
        a.engine.libraryEvent(.deleted(file))
        await a.engine.syncAndWait()

        let gone = try await a.engine.deletedNotations()
        let head = try await a.api.head(of: XCTUnwrap(gone.first).id)
        XCTAssertEqual(try title(of: XCTUnwrap(head?.content)), "typed just before deleting")
        try await a.engine.undelete(gone[0])
        XCTAssertEqual(try title(of: Data(contentsOf: file)), "typed just before deleting")
    }

    func testAnAnswerLostInTransitIsNotAConflictWithYourself() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Song.pancham")
        try write("v1", to: file)
        await a.engine.syncAndWait()

        try write("v2", to: file)
        a.engine.debugDropNextSaveResult = true                          // the push lands; its answer doesn't
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .offline)

        try write("v3", to: file)                                        // more typing before the next attempt
        await a.engine.syncAndWait()
        XCTAssertEqual(a.engine.status, .idle)
        let names = try FileManager.default.contentsOfDirectory(atPath: a.storage.libraryRoot.path)
        XCTAssertEqual(names, ["Song.pancham"], "no conflicted copy")
        XCTAssertEqual(try title(of: Data(contentsOf: file)), "v3")
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(try title(of: XCTUnwrap(docs[0].content)), "v3")
        let history = try await a.api.history(of: docs[0].id)
        XCTAssertEqual(history.map(\.rev), [3, 2, 1])
    }

    func testTextTypedJustBeforeAPullIsKeptNotOverwritten() async throws {
        let a = try await device("me@test.dev")
        let b = try await device("me@test.dev")
        try write("start", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        await b.engine.syncAndWait()
        try write("B's edit", to: b.library("Song.pancham"))
        await b.engine.syncAndWait()

        // On A the editor holds text that has been typed but not yet written to the file; the engine
        // asks the editor to write it before it looks at anything.
        var flushes = 0
        a.engine.flushEdits = {                                          // like the editor: writes only once, while text is unsaved
            flushes += 1
            if flushes == 1 { try? self.write("typed on A, unsaved", to: a.library("Song.pancham")) }
        }
        await a.engine.syncAndWait()
        XCTAssertGreaterThan(flushes, 0)

        let files = try FileManager.default.contentsOfDirectory(atPath: a.storage.libraryRoot.path).sorted()
        XCTAssertEqual(files.count, 2, "\(files)")
        let copy = try XCTUnwrap(files.first { $0.contains("conflicted copy") })
        XCTAssertEqual(try title(of: Data(contentsOf: a.library(copy))), "typed on A, unsaved")
        XCTAssertEqual(try title(of: Data(contentsOf: a.library("Song.pancham"))), "B's edit")
    }

    func testLosingTheSyncStateDoesNotDuplicateTheLibrary() async throws {
        let a = try await device("me@test.dev")
        try write("one", to: a.library("One.pancham"))
        try write("two", to: a.library("Raag/Two.pancham"))
        await a.engine.syncAndWait()
        let before = try await a.api.feed(after: 0).map(\.id)
        a.engine.stop()

        try Data("{ this is not json".utf8).write(to: a.storage.stateFile)          // corrupted
        let again = SyncEngine(session: a.session, storage: a.storage)
        await again.syncAndWait()
        XCTAssertEqual(again.status, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.storage.stateFile.appendingPathExtension("corrupt").path))
        let after = try await a.api.feed(after: 0)
        XCTAssertEqual(Set(after.map(\.id)), Set(before), "no new notations were made")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.storage.libraryRoot.path).sorted(), ["One.pancham", "Raag"])

        try write("one, edited", to: a.library("One.pancham"))                     // and the next edit is a revision, not a new notation
        await again.syncAndWait()
        let revs = try await a.api.feed(after: 0).filter { $0.name == "One" }.map(\.rev)
        XCTAssertEqual(revs, [2])
        again.stop()
    }

    func testACacheLastUsedWithAnotherServerStartsOverWithoutDuplicating() async throws {
        let a = try await device("me@test.dev")
        try write("kept", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        a.engine.stop()

        var state = SyncState.load(from: a.storage.stateFile)
        XCTAssertEqual(state.server, backend.restURL.absoluteString)
        state.server = "https://pancham-api.example.com"                    // as if this cache last met production
        state.cursor = 4242
        state.save(to: a.storage.stateFile)

        let again = SyncEngine(session: a.session, storage: a.storage)
        await again.syncAndWait()
        XCTAssertEqual(again.status, .idle)
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.storage.libraryRoot.path), ["Song.pancham"])
        again.stop()
    }

    func testANotationTheServerHasNeverHeardOfBecomesANewOne() async throws {
        let a = try await device("me@test.dev")
        try write("orphan", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        a.engine.stop()

        var state = SyncState.load(from: a.storage.stateFile)               // pretend we synced it with a server that's gone
        let (key, entry) = try XCTUnwrap(state.entries.first)
        var ghost = entry
        ghost.docID = UUID(); ghost.rev = 3; ghost.syncedHash = "stale"; ghost.syncedStamp = nil
        state.entries = [ghost.docID.uuidString: ghost]
        state.save(to: a.storage.stateFile)
        XCTAssertNotEqual(key, ghost.docID.uuidString)

        let again = SyncEngine(session: a.session, storage: a.storage)
        await again.syncAndWait()
        XCTAssertEqual(again.status, .idle, "one unknown notation must not block syncing")
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.count, 2, "the old record, and the file re-created as its own notation")
        again.stop()
    }

    func testOnlyOneEngineSyncsACacheAtATime() async throws {
        let a = try await device("me@test.dev")
        try write("x", to: a.library("Song.pancham"))
        await a.engine.syncAndWait()
        XCTAssertEqual(a.engine.status, .idle)

        let second = SyncEngine(session: a.session, storage: a.storage)     // e.g. a second window or process
        await second.syncNow()
        XCTAssertEqual(second.status, .failed("Pancham is already open for this account"))

        a.engine.stop()                                                     // the first lets go
        await second.syncAndWait()
        XCTAssertEqual(second.status, .idle)
        second.stop()
    }

    func testAStaleDeleteStashIsNotSentWithALaterDelete() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Song.pancham")
        try write("synced", to: file)
        await a.engine.syncAndWait()
        try write("edited, then trash failed", to: file)
        a.engine.libraryEvent(.willDelete(file))                         // ...and no .deleted followed
        try write("synced", to: file)                                    // edited back to what the server has
        _ = try? Data(contentsOf: file)
        await a.engine.syncAndWait()
        a.engine.libraryEvent(.willDelete(file))
        try FileManager.default.removeItem(at: file)
        a.engine.libraryEvent(.deleted(file))
        await a.engine.syncAndWait()
        let gone = try await a.engine.deletedNotations()
        let head = try await a.api.head(of: XCTUnwrap(gone.first).id)
        XCTAssertEqual(try title(of: XCTUnwrap(head?.content)), "synced")
    }

    func testNamesCannotWalkOutOfTheCacheFolder() {
        for bad in ["..", ".", "...", "  ..  ", ""] { XCTAssertEqual(sanitizeFileName(bad), "Untitled", bad) }
        XCTAssertEqual(sanitizeFileName("../x"), "..x")                      // slashes are already removed
        XCTAssertEqual(sanitizeFileName("Raag Yaman"), "Raag Yaman")
    }

    func testOnlyTheFirstAccountOnAMacIsOfferedTheOldLibrary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pn-legacy-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = AccountStorage(account: Account(id: UUID(), email: "a@test.dev", isAdmin: true), base: base)
        let second = AccountStorage(account: Account(id: UUID(), email: "b@test.dev", isAdmin: false), base: base)
        XCTAssertTrue(first.claimsLegacyLibrary())
        XCTAssertFalse(second.claimsLegacyLibrary())
        XCTAssertTrue(first.claimsLegacyLibrary())
    }

    func testAnEmptyAccountPullsOnceNotOnEveryPass() async throws {
        let a = try await device("me@test.dev")
        await a.engine.syncAndWait()
        XCTAssertEqual(SyncState.load(from: a.storage.stateFile).hasPulled, true)
        XCTAssertEqual(SyncState.load(from: a.storage.stateFile).cursor, 0)
    }

    func testAnUnchangedFileIsNotReadAgain() async throws {
        let a = try await device("me@test.dev")
        let file = a.library("Song.pancham")
        try write("v1", to: file)
        await a.engine.syncAndWait()
        await a.engine.syncAndWait()                                     // stamp recorded after the first full read
        let state = SyncState.load(from: a.storage.stateFile)
        XCTAssertEqual(state.entries.values.first?.syncedStamp, AccountStorage.stamp(file))
        try write("v2", to: file)                                        // a changed file is noticed by its stamp
        await a.engine.syncAndWait()
        let docs = try await a.api.feed(after: 0)
        XCTAssertEqual(docs.first?.rev, 2)
    }

    // MARK: Helpers

    struct Device {
        let dir: URL
        let session: AuthSession
        let storage: AccountStorage
        let engine: SyncEngine
        let api: PanchamAPI
        func library(_ path: String) -> URL { storage.libraryRoot.appendingPathComponent(path) }
    }

    private func device(_ email: String) async throws -> Device {
        let dir = tmp.appendingPathComponent("device-\(devices.count)")
        let session = AuthSession(config: ServerConfig(authURL: backend.authURL, restURL: backend.restURL), directory: dir)
        try await session.requestCode(email: email)
        try await session.verify(email: email, code: try backend.code(for: email))
        let storage = AccountStorage(account: try XCTUnwrap(session.account), base: dir)
        let d = Device(dir: dir, session: session, storage: storage,
                       engine: SyncEngine(session: session, storage: storage), api: PanchamAPI(session: session))
        devices.append(d)
        return d
    }

    private func write(_ title: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = ["title": title, "raga": "Yaman",
                                   "sections": [["name": "Sthayi", "lines": [["type": "notation", "cells": ["S", "R", "G"]]]]]]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func title(of data: Data) throws -> String {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(o["title"] as? String)
    }
}

/// server/dev_stack.py as a child process: it prints one JSON line when ready and cleans up when
/// its stdin closes.
final class Backend {
    let authURL: URL, restURL: URL, codes: URL
    private let process = Process()
    private let stdin = Pipe()

    init(admin: [String], allow: [String]) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", root.appendingPathComponent("server/dev_stack.py").path]
            + admin.flatMap { ["--admin", $0] } + allow.flatMap { ["--allow", $0] }
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()

        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }                                  // it exited before getting ready
            buffer.append(chunk)
        }
        guard let line = String(data: buffer, encoding: .utf8)?.split(separator: "\n").first,
              let info = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let auth = info["auth"].flatMap(URL.init(string:)), let rest = info["rest"].flatMap(URL.init(string:)),
              let codes = info["codes"]
        else {
            process.terminate()
            throw XCTSkip("server/dev_stack.py didn't start (needs: brew install postgresql@18 postgrest dbmate)")
        }
        (authURL, restURL, self.codes) = (auth, rest, URL(fileURLWithPath: codes))
    }

    /// The code the sign-in server would have emailed.
    func code(for email: String) throws -> String {
        let name = email.lowercased().replacingOccurrences(of: #"[^a-z0-9@._-]"#, with: "_", options: .regularExpression)
        return try String(contentsOf: codes.appendingPathComponent(name + ".txt"), encoding: .utf8)
    }

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
