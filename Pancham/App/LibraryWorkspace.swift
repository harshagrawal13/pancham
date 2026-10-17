import Foundation
import Observation

/// Everything behind the library window that isn't drawing: the two libraries (private and global),
/// the sync engine, which notation is open, and the editor's save path. `LibraryEditor` is the layout.
///
/// The save path is where sync's safety rests, so it lives here, in one place:
///  * edits are written to the notation's file 350 ms after the last keystroke (`scheduleSave`);
///  * `flushEdits` writes them *now*, synchronously. The sync engine calls it right before it reads or
///    replaces a file, and leaving a notation calls it too, so typed text is never invisible to a sync
///    and never lost to a reload.
@MainActor @Observable
final class LibraryWorkspace {
    let account: Account
    let engine: SyncEngine
    let library: Library          // your private notations
    let global: Library           // the shared ones

    var selectedURL: URL?
    private(set) var composition = Composition()
    private(set) var notice: String?

    /// Which file `composition` currently reflects. Saves only run for it, so a notation that is
    /// mid-switch can't write stale content into the new file.
    @ObservationIgnored private var loadedURL: URL?
    /// The file the editor holds typed-but-unsaved text for (nil: everything typed is on disk).
    @ObservationIgnored private var unsavedURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(session: AuthSession, account: Account) {
        self.account = account
        let storage = AccountStorage(account: account)
        engine = SyncEngine(session: session, storage: storage)
        library = Library(root: storage.libraryRoot)
        global = Library(root: storage.globalRoot)
        for lib in [library, global] { lib.onEvent = { [weak engine] in engine?.libraryEvent($0) } }
        engine.flushEdits = { [weak self] in self?.flushEdits() }
    }

    // MARK: Lifecycle

    func start() {
        engine.start()
        if selectedURL == nil {
            selectedURL = library.looseFiles.first?.url ?? library.folders.flatMap(\.files).first?.url
        }
        loadSelected()
    }

    func stop() { engine.stop() }

    // MARK: What the open notation allows

    func isGlobal(_ url: URL) -> Bool { engine.storage.isGlobal(url) }

    func owner(of url: URL) -> Library { isGlobal(url) ? global : library }

    /// A global notation you can't change: shown rendered, never saved.
    var isReadOnly: Bool { selectedURL.map { !canEdit($0) } ?? false }

    private func canEdit(_ url: URL) -> Bool { account.canEdit(engine.storage.scope(of: url)) }

    // MARK: Library actions

    func delete(_ url: URL) {
        if selectedURL == url || (selectedURL?.path.hasPrefix(url.path + "/") ?? false) { selectedURL = nil }
        owner(of: url).delete(url)
    }

    func addToLibrary(_ url: URL) {
        guard let copy = try? engine.addToLibrary(url) else { return }
        library.reload()
        selectedURL = copy
        flash("Added to library.")
    }

    func publish(_ url: URL) {
        guard let copy = try? engine.publish(url) else { return }
        global.reload()
        flash("Published “\(copy.deletingPathExtension().lastPathComponent)” to the global library.")
    }

    func rename(_ target: RenameTarget, to name: String) {
        guard let newURL = owner(of: target.url).rename(target.url, to: name) else { return }
        if selectedURL == target.url { selectedURL = newURL }
        // A selected file inside a renamed folder moves with it.
        if let sel = selectedURL, sel.path.hasPrefix(target.url.path + "/") {
            selectedURL = newURL.appendingPathComponent(sel.lastPathComponent)
        }
    }

    /// Import + select a `.pancham` file opened from Finder, if one is waiting.
    func openPending(from prefs: Preferences) {
        guard let url = prefs.pendingOpenURL else { return }
        prefs.pendingOpenURL = nil
        if let dest = library.importFile(url) {
            selectedURL = dest
            engine.kick()
        }
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == message { notice = nil }
        }
    }

    // MARK: Sync

    /// A pull wrote, moved or removed files: refresh the sidebar, and the open notation if it changed.
    func filesChangedBySync(_ urls: [URL]) {
        library.reload()
        global.reload()
        guard let selected = selectedURL else { return }
        if !FileManager.default.fileExists(atPath: selected.path) {
            selectedURL = nil
        } else if urls.contains(selected) {
            flushEdits()                  // before forgetting which file is loaded, or the guard drops it
            loadedURL = nil
            loadSelected()
        }
    }

    // MARK: Opening, autosaving

    /// Make `composition` the notation at `selectedURL`.
    func loadSelected() {
        flushEdits()                      // leaving a notation: what was typed in the last moment goes with it
        saveTask?.cancel()
        guard let url = selectedURL else {
            composition = Composition()
            loadedURL = nil
            return
        }
        if loadedURL == url { return }
        Task.detached(priority: .userInitiated) {
            let loaded = CompositionStore.load(from: url)
            await MainActor.run {
                guard self.selectedURL == url else { return }
                self.composition = loaded
                self.loadedURL = url
                self.installAutoSave()
            }
        }
    }

    /// Subscribe to the composition's observable tree. Tracking is one-shot, so it is re-installed only
    /// after a save: keystrokes during the save window do no observation work, since the first one
    /// already consumed the subscription.
    private func installAutoSave() {
        let comp = composition
        withObservationTracking {
            // Touch every observable field once to subscribe.
            _ = comp.title; _ = comp.raga; _ = comp.taal; _ = comp.form; _ = comp.samOffset
            _ = comp.laya; _ = comp.bpm; _ = comp.notes; _ = comp.performance
            for s in comp.sections {
                _ = s.name
                for l in s.lines {
                    _ = l.type
                    _ = l.label
                    for box in l.cells { _ = box.text }
                }
            }
        } onChange: { [weak self, weak comp] in
            Task { @MainActor [weak self, weak comp] in
                guard let self, let comp, comp === self.composition else { return }
                self.scheduleSave()
            }
        }
    }

    private func scheduleSave() {
        guard let url = selectedURL, url == loadedURL, canEdit(url) else { return }
        unsavedURL = url
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            flushEdits()
            engine.kick()      // the file is on disk; let the server have it a moment later
        }
    }

    /// Write typed-but-unsaved text to its file now, and re-arm change tracking (which walks every cell,
    /// so it happens once per save rather than once per keystroke).
    func flushEdits() {
        guard let url = unsavedURL else { return }
        unsavedURL = nil
        saveTask?.cancel()
        guard url == loadedURL else { return }
        try? CompositionStore.save(composition, to: url)
        installAutoSave()
    }
}
