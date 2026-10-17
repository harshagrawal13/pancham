import XCTest

/// The editor's save path: typed text reaches its file when a sync (or leaving the notation) needs it.
@MainActor
final class WorkspaceTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pn-ws-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func workspace() -> (LibraryWorkspace, URL) {
        let account = Account(id: UUID(), email: "w@test.dev", isAdmin: false)
        let session = AuthSession(config: ServerConfig(authURL: URL(string: "http://127.0.0.1:9")!,
                                                       restURL: URL(string: "http://127.0.0.1:9")!), directory: base)
        let ws = LibraryWorkspace(session: session, account: account)
        let file = ws.library.root.appendingPathComponent("Song.pancham")
        try? CompositionStore.save(Composition(title: "Song"), to: file)
        ws.library.reload()
        ws.selectedURL = file
        return (ws, file)
    }

    private func loaded(_ ws: LibraryWorkspace) async {
        ws.loadSelected()
        for _ in 0..<100 where ws.composition.title.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testTypedTextIsWrittenWhenAFlushIsAskedFor() async throws {
        let (ws, file) = workspace()
        await loaded(ws)
        ws.composition.title = "Retitled while typing"                  // observed; the debounced save is 350 ms away
        try await Task.sleep(for: .milliseconds(50))
        ws.flushEdits()                                                 // what a sync does before it reads the file
        XCTAssertEqual(CompositionStore.load(from: file).title, "Retitled while typing")
    }

    func testLeavingANotationSavesWhatWasTypedInTheLastMoment() async throws {
        let (ws, file) = workspace()
        await loaded(ws)
        let other = ws.library.root.appendingPathComponent("Other.pancham")
        try CompositionStore.save(Composition(title: "Other"), to: other)
        ws.composition.title = "Typed just before switching"
        try await Task.sleep(for: .milliseconds(50))
        ws.selectedURL = other
        ws.loadSelected()
        XCTAssertEqual(CompositionStore.load(from: file).title, "Typed just before switching")
    }

    func testTheDebouncedSaveWritesOnItsOwn() async throws {
        let (ws, file) = workspace()
        await loaded(ws)
        ws.composition.title = "Saved by the timer"
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(CompositionStore.load(from: file).title, "Saved by the timer")
    }

    func testNothingIsWrittenForANotationTheAccountCannotEdit() async throws {
        let (ws, _) = workspace()
        let shared = ws.global.root.appendingPathComponent("Shared.pancham")
        try CompositionStore.save(Composition(title: "Shared"), to: shared)
        ws.global.reload()
        ws.selectedURL = shared
        await loaded(ws)
        XCTAssertTrue(ws.isReadOnly)
        ws.composition.title = "defaced"
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(CompositionStore.load(from: shared).title, "Shared")
    }
}
