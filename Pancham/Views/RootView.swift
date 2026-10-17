import SwiftUI

/// Top-level router: signed out → email-code sign-in, signed in → library + editor.
/// A stored session counts as signed in even with no network, so the app opens straight onto
/// the local copy of your notations.
struct RootView: View {
    @Bindable var prefs: Preferences
    let session: AuthSession

    var body: some View {
        Group {
            if let account = session.account {
                LibraryEditor(prefs: prefs, session: session, account: account)
                    .id(account.id)
            } else {
                LoginView(session: session)
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        // The whole UI is a fixed cream "paper" design with hard-coded colours.
        // Pin light appearance so system-tinted controls (the Sa/BPM menus,
        // default button text) don't render white-on-cream under macOS dark mode.
        .preferredColorScheme(.light)
    }
}

private struct SheetURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// "New notation" / "New folder", and where: one value, so the sheet always shows what it will do.
private struct CreateRequest: Identifiable {
    enum Kind { case notation, folder }
    let id = UUID()
    let kind: Kind
    let library: Library
    /// For a notation: the folder it goes in (nil: the top level).
    var folder: LibraryFolder? = nil
}

struct LibraryEditor: View {
    @Bindable var prefs: Preferences
    /// Libraries, sync, the open notation and its autosave (App/LibraryWorkspace.swift).
    @State private var ws: LibraryWorkspace
    // What only this view cares about:
    @State private var isRenderMode: Bool = false
    @State private var playback = PlaybackEngine()
    @State private var createRequest: CreateRequest?
    @State private var renameTarget: RenameTarget?
    @State private var showNowPlaying: Bool = false
    @State private var tuner = TunerEngine()
    @State private var showTanpura: Bool = false
    @State private var historyTarget: SheetURL?
    @State private var showDeleted = false

    init(prefs: Preferences, session: AuthSession, account: Account) {
        _prefs = Bindable(prefs)
        _ws = State(initialValue: LibraryWorkspace(session: session, account: account))
    }

    var body: some View {
        let selection = Binding(get: { ws.selectedURL }, set: { ws.selectedURL = $0 })
        HStack(spacing: 0) {
            LibrarySidebar(
                library: ws.library,
                global: ws.global,
                account: ws.account,
                engine: ws.engine,
                selectedURL: selection,
                onNewFile: { lib in createRequest = CreateRequest(kind: .notation, library: lib) },
                onNewFolder: { lib in createRequest = CreateRequest(kind: .folder, library: lib) },
                onNewFileIn: { lib, folder in
                    createRequest = CreateRequest(kind: .notation, library: lib, folder: folder)
                },
                onRename: { target in renameTarget = target },
                onDelete: ws.delete,
                onAddToLibrary: ws.addToLibrary,
                onPublish: ws.publish,
                onRecentlyDeleted: { showDeleted = true },
                onSignOut: { Task { await ws.engine.session.signOut() } }
            )
            EditorPane(
                selectedURL: selection,
                composition: ws.composition,
                isRenderMode: $isRenderMode,
                library: ws.library,
                playback: playback,
                readOnly: ws.isReadOnly,
                isGlobal: ws.selectedURL.map(ws.isGlobal) ?? false,
                engine: ws.engine,
                notice: ws.notice,
                onNewFile: { createRequest = CreateRequest(kind: .notation, library: ws.library) },
                onPerform: { showNowPlaying = true },
                onTanpura: { showTanpura = true },
                onHistory: { if let url = ws.selectedURL { historyTarget = SheetURL(url: url) } },
                onAddToLibrary: { if let url = ws.selectedURL { ws.addToLibrary(url) } }
            )
        }
        .background(Theme.canvas)
        .overlay {
            if showNowPlaying {
                NowPlayingView(
                    composition: ws.composition,
                    playback: playback,
                    onClose: { showNowPlaying = false }
                )
                .transition(.move(edge: .bottom))
                .zIndex(10)
            }
        }
        .overlay {
            if showTanpura {
                TanpuraView(tuner: tuner, onClose: { showTanpura = false })
                    .transition(.move(edge: .bottom))
                    .zIndex(11)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showNowPlaying)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showTanpura)
        .onChange(of: ws.selectedURL) { _, _ in
            playback.stop()
            showNowPlaying = false
            ws.loadSelected()
        }
        .onChange(of: ws.engine.fileChanges) { _, changes in ws.filesChangedBySync(changes.urls) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ws.engine.kick(after: 0.2)
        }
        .onAppear {
            ws.start()
            ws.openPending(from: prefs)
        }
        .onDisappear { ws.stop() }
        .onChange(of: prefs.pendingOpenURL) { _, _ in ws.openPending(from: prefs) }
        .sheet(item: $createRequest) { request in
            if request.kind == .folder {
                NameSheet(
                    eyebrow: "New folder",
                    title: "Name this folder",
                    subtitle: "Folders live inside your library. Use them to group bandishes by raga, laya, or style.",
                    placeholder: "Yaman",
                    initial: "",
                    confirmLabel: "Create",
                    onConfirm: { value in
                        _ = request.library.createFolder(named: value)
                        createRequest = nil
                    },
                    onCancel: { createRequest = nil }
                )
            } else {
                let inGlobal = request.library === ws.global
                NameSheet(
                    eyebrow: request.folder.map { "New notation · \($0.name)" }
                        ?? (inGlobal ? "New global notation" : "New notation"),
                    title: "Name this bandish",
                    subtitle: request.folder.map { "This bandish will live inside \($0.name). You can rename it later." }
                        ?? (inGlobal ? "Everyone signed in will be able to read it. Only admins can change it."
                                     : "Choose a name for your new composition. You can rename it later."),
                    placeholder: "यमन — विलम्बित",
                    initial: "",
                    confirmLabel: "Create",
                    onConfirm: { value in
                        if let url = request.library.createFile(named: value, in: request.folder) {
                            ws.selectedURL = url
                            ws.engine.kick()
                        }
                        createRequest = nil
                    },
                    onCancel: { createRequest = nil }
                )
            }
        }
        .sheet(item: $renameTarget) { target in
            NameSheet(
                eyebrow: target.isFolder ? "Rename folder" : "Rename notation",
                title: target.isFolder ? "Rename this folder" : "Rename this bandish",
                subtitle: target.isFolder
                    ? "Files inside keep their names."
                    : "Its history stays with it.",
                placeholder: target.originalName,
                initial: target.originalName,
                confirmLabel: "Rename",
                onConfirm: { value in
                    ws.rename(target, to: value)
                    renameTarget = nil
                },
                onCancel: { renameTarget = nil }
            )
        }
        .sheet(item: $historyTarget) { target in
            HistoryView(url: target.url, engine: ws.engine, canRestore: !ws.isReadOnly) { historyTarget = nil }
        }
        .sheet(isPresented: $showDeleted) {
            RecentlyDeletedView(engine: ws.engine) {
                showDeleted = false
                ws.library.reload()
            }
        }
        .sheet(isPresented: Binding(get: { !ws.legacyLibraries.isEmpty }, set: { _ in })) {
            LegacyImportSheet(libraries: ws.legacyLibraries, onImport: ws.importLegacy, onSkip: ws.skipLegacy)
        }
    }

}

// MARK: - EditorPane

struct EditorPane: View {
    @Binding var selectedURL: URL?
    let composition: Composition
    @Binding var isRenderMode: Bool
    let library: Library
    @Bindable var playback: PlaybackEngine
    /// A global notation you may read but not change: always rendered, with no editing controls.
    let readOnly: Bool
    let isGlobal: Bool
    let engine: SyncEngine
    let notice: String?
    let onNewFile: () -> Void
    let onPerform: () -> Void
    let onTanpura: () -> Void
    let onHistory: () -> Void
    let onAddToLibrary: () -> Void

    @State private var showPerformance = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if selectedURL == nil {
                emptyState
            } else {
                ScrollView {
                    EditorView(composition: composition, isRenderMode: isRenderMode || readOnly)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .sheet(isPresented: $showPerformance) {
            PerformanceEditorView(composition: composition) { showPerformance = false }
        }
        // A tonic / tempo change while playing re-renders the piece transposed.
        // These handlers live in the always-mounted editor pane so they fire
        // whether the change comes from here or the now-playing overlay.
        // Every transport tweak applies live and keeps your place: tempo maps
        // by beat fraction; tonic/sustain/fade recompile timing in place;
        // instrument is a patch swap; volume is a mixer gain. None restart.
        .onChange(of: playback.tonicMidi) { _, _ in playback.recompileInPlace() }
        .onChange(of: playback.tempoOverride) { _, _ in playback.applyTempoChange() }
        .onChange(of: playback.instrument) { _, _ in playback.reloadInstrument() }
        .onChange(of: playback.instrumentVolume) { _, _ in playback.applyVolumes() }
        .onChange(of: playback.tablaVolume) { _, _ in playback.applyVolumes() }
        .onChange(of: playback.tablaEnabled) { _, _ in playback.recompileInPlace() }
    }

    private func restartIfPlaying() {
        if playback.isPlaying { playback.play(composition) }
    }

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func noteName(_ midi: Int) -> String {
        "\(noteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    /// Small build marker so the production (Release) app is distinguishable
    /// from a dev (Debug) build at a glance: dev shows "DEV", production shows
    /// the version (e.g. "v1.0").
    private var buildBadge: some View {
        #if DEBUG
        let text = "DEV"
        let fg = Theme.danger
        let bg = Theme.danger.opacity(0.12)
        #else
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let text = "v\(version)"
        let fg = Theme.muted
        let bg = Color.clear
        #endif
        return Text(text)
            .font(Theme.ui(9, weight: .medium)).tracking(1)
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fg.opacity(0.4), lineWidth: 1))
    }

    /// Quiet when all is well: the sidebar footer says "Synced". Worth a word here only when it isn't.
    private var toolbarStatus: String? {
        if let notice { return notice }
        if readOnly { return "Global · read only" }
        return engine.toolbarText
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("Pancham")
                    .font(Theme.display(22, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("पंचम")
                    .font(Theme.deva(15))
                    .foregroundStyle(Theme.muted)
                    .tracking(0.5)
                buildBadge
            }
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
            Spacer(minLength: 8)
            if selectedURL != nil {
                playbackControls
                if let status = toolbarStatus {
                    Text(status)
                        .font(Theme.ui(11)).tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                if readOnly {
                    Button("Add to my library", action: onAddToLibrary)
                        .buttonStyle(ToolbarOutlineButton())
                }
                Button("History", action: onHistory)
                    .buttonStyle(ToolbarOutlineButton())
                if composition.form.isStructured && !readOnly {
                    Button("Performance") { showPerformance = true }
                        .buttonStyle(ToolbarOutlineButton())
                }
                if !readOnly {
                    Button("+ Section") { composition.sections.append(CompositionSection(matras: composition.matras)) }
                        .buttonStyle(ToolbarOutlineButton())
                    Button(isRenderMode ? "Edit" : "Render") { isRenderMode.toggle() }
                        .buttonStyle(ToolbarOutlineButton())
                        .keyboardShortcut("r", modifiers: [.command])
                }
            }
            // Riyaz tool — available whether or not a notation is open.
            Button(action: onTanpura) {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                    Text("Tanpura")
                }
            }
            .buttonStyle(ToolbarOutlineButton())
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("+ Notation") { onNewFile() }
                .buttonStyle(ToolbarPrimaryButton())
                .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }

    private var playbackControls: some View {
        // Play opens the full-window now-playing screen (3-2-1 lead-in, scrolling
        // lyrics). Tempo / Sa / voice live there, not in the editor. SF Symbol
        // renders regardless of the custom UI font (IBM Plex Sans has no ▶ glyph).
        Button(action: onPerform) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                Text("Play")
            }
        }
        .buttonStyle(ToolbarOutlineButton())
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("पंचम")
                .font(Theme.deva(64, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.12))
            Text("Choose a notation from the library, or create a new one.")
                .font(Theme.display(15))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                Button("+ New notation", action: onNewFile)
                    .buttonStyle(ToolbarPrimaryButton())
                Button(action: onTanpura) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                        Text("Tanpura")
                    }
                }
                .buttonStyle(ToolbarOutlineButton())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Buttons & sheets

struct ToolbarOutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12))
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ToolbarPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12, weight: .medium))
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.ink)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(11, weight: .medium))
            .tracking(1.5).textCase(.uppercase)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(11, weight: .medium))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.ink)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Reusable sheet for name / rename / new-folder prompts. Matches the dialog
/// from the Hindustan Editorial design: paper card, 3px double top rule,
/// uppercase eyebrow, italic-style subtitle, underlined Devanagari input,
/// Cancel/Confirm outlined + filled pair.
struct NameSheet: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let placeholder: String
    let initial: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                .foregroundStyle(Theme.muted).padding(.bottom, 6)
            Text(title)
                .font(Theme.display(20, weight: .medium))
                .foregroundStyle(Theme.ink).padding(.bottom, 4)
            Text(subtitle)
                .font(Theme.display(13)).foregroundStyle(Theme.muted)
                .lineSpacing(3).padding(.bottom, 18)
            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(Theme.deva(17)).foregroundStyle(Theme.ink)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.ink).frame(height: 1)
                }
                .onSubmit { confirm() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(OutlineButtonStyle())
                Button(confirmLabel, action: confirm).buttonStyle(FilledButtonStyle())
            }
            .padding(.top, 28)
        }
        .padding(.init(top: 28, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 420)
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { value = initial }
    }

    private func confirm() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}
