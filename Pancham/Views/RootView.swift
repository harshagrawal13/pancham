import SwiftUI

enum RootRoute {
    case picker
    case onboarding   // add-new-user flow
    case editor
}

/// Top-level router.
///   - no saved users    → onboarding (first user)
///   - saved, no active  → user picker
///   - active user       → library + editor
struct RootView: View {
    @Bindable var prefs: Preferences
    @State private var explicitRoute: RootRoute? = nil

    var body: some View {
        Group {
            if prefs.isSignedIn, let folder = prefs.activeFolder, let user = prefs.activeUser {
                LibraryEditor(prefs: prefs, root: folder, user: user)
                    .id(user.id)
            } else if explicitRoute == .onboarding || !prefs.hasAnyUsers {
                OnboardingView(prefs: prefs, onComplete: {
                    explicitRoute = nil
                }, onCancel: prefs.hasAnyUsers ? { explicitRoute = nil } : nil)
            } else {
                UserPickerView(prefs: prefs, onAddNew: { explicitRoute = .onboarding })
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        // The whole UI is a fixed cream "paper" design with hard-coded colours.
        // Pin light appearance so system-tinted controls (the Sa/BPM menus,
        // default button text) don't render white-on-cream under macOS dark mode.
        .preferredColorScheme(.light)
    }
}

struct LibraryEditor: View {
    @Bindable var prefs: Preferences
    let root: URL
    let user: PanchamUser

    @State private var library: Library
    @State private var selectedURL: URL?
    /// Which URL is currently reflected in `composition`. Saves only run when
    /// this matches `selectedURL`, so a mid-switch `composition` change can't
    /// write stale content to the new file.
    @State private var loadedURL: URL?
    @State private var composition: Composition = Composition()
    @State private var isRenderMode: Bool = false
    @State private var playback = PlaybackEngine()
    @State private var creatingFile: Bool = false
    @State private var newFileName: String = ""
    @State private var newFileTargetFolder: LibraryFolder? = nil
    @State private var renameTarget: RenameTarget?
    @State private var newFolderSheet: Bool = false
    @State private var folderName: String = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var showNowPlaying: Bool = false

    init(prefs: Preferences, root: URL, user: PanchamUser) {
        _prefs = Bindable(prefs)
        self.root = root
        self.user = user
        _library = State(initialValue: Library(root: root))
    }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(
                library: library,
                username: user.name,
                selectedURL: $selectedURL,
                onNewFile: {
                    newFileTargetFolder = nil
                    creatingFile = true
                },
                onNewFolder: { newFolderSheet = true },
                onNewFileIn: { folder in
                    newFileTargetFolder = folder
                    creatingFile = true
                },
                onRename: { target in renameTarget = target },
                onDelete: { url in deleteURL(url) },
                onSwitchUser: { prefs.deactivate() }
            )
            EditorPane(
                selectedURL: $selectedURL,
                composition: composition,
                isRenderMode: $isRenderMode,
                library: library,
                playback: playback,
                onNewFile: { creatingFile = true },
                onPerform: { showNowPlaying = true }
            )
        }
        .background(Theme.canvas)
        .overlay {
            if showNowPlaying {
                NowPlayingView(
                    composition: composition,
                    playback: playback,
                    onClose: { showNowPlaying = false }
                )
                .transition(.move(edge: .bottom))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showNowPlaying)
        .onChange(of: selectedURL) { _, newURL in
            playback.stop()
            showNowPlaying = false
            loadSelected(newURL)
        }
        .onAppear {
            if selectedURL == nil {
                selectedURL = library.looseFiles.first?.url
                    ?? library.folders.flatMap(\.files).first?.url
            }
            loadSelected(selectedURL)
        }
        .sheet(isPresented: $creatingFile) {
            NameSheet(
                eyebrow: newFileTargetFolder.map { "New notation · \($0.name)" } ?? "New notation",
                title: "Name this bandish",
                subtitle: newFileTargetFolder == nil
                    ? "Choose a name for your new composition. You can rename it later."
                    : "This bandish will live inside \(newFileTargetFolder!.name). You can rename it later.",
                placeholder: "यमन — विलम्बित",
                initial: "",
                confirmLabel: "Create",
                onConfirm: { value in
                    if let url = library.createFile(named: value, in: newFileTargetFolder) { selectedURL = url }
                    creatingFile = false
                    newFileTargetFolder = nil
                },
                onCancel: {
                    creatingFile = false
                    newFileTargetFolder = nil
                }
            )
        }
        .sheet(isPresented: $newFolderSheet) {
            NameSheet(
                eyebrow: "New folder",
                title: "Name this folder",
                subtitle: "Folders live inside your library. Use them to group bandishes by raga, laya, or style.",
                placeholder: "Yaman",
                initial: "",
                confirmLabel: "Create",
                onConfirm: { value in
                    _ = library.createFolder(named: value)
                    newFolderSheet = false
                },
                onCancel: { newFolderSheet = false }
            )
        }
        .sheet(item: $renameTarget) { target in
            NameSheet(
                eyebrow: target.isFolder ? "Rename folder" : "Rename notation",
                title: target.isFolder ? "Rename this folder" : "Rename this bandish",
                subtitle: target.isFolder
                    ? "The folder on disk will be renamed. Files inside keep their names."
                    : "The file on disk will be renamed.",
                placeholder: target.originalName,
                initial: target.originalName,
                confirmLabel: "Rename",
                onConfirm: { value in
                    if let newURL = library.rename(target.url, to: value) {
                        if selectedURL == target.url { selectedURL = newURL }
                    }
                    renameTarget = nil
                },
                onCancel: { renameTarget = nil }
            )
        }
    }

    private func loadSelected(_ url: URL?) {
        saveTask?.cancel()
        guard let url else {
            composition = Composition()
            loadedURL = nil
            return
        }
        if loadedURL == url { return }
        Task.detached(priority: .userInitiated) {
            let loaded = CompositionStore.load(from: url)
            await MainActor.run {
                guard selectedURL == url else { return }
                composition = loaded
                loadedURL = url
                installAutoSave()
            }
        }
    }

    /// Subscribe to the composition's observable tree. Tracking is one-shot,
    /// so we re-install only after the debounce save fires — keystrokes during
    /// the save window do no observation work, since the first keystroke
    /// already consumed the subscription.
    private func installAutoSave() {
        let comp = composition
        withObservationTracking {
            // Touch every observable field once to subscribe.
            _ = comp.title; _ = comp.raga; _ = comp.taal; _ = comp.samOffset
            _ = comp.laya; _ = comp.bpm; _ = comp.notes
            for s in comp.sections {
                _ = s.name
                for l in s.lines {
                    _ = l.type
                    _ = l.label
                    for box in l.cells { _ = box.text }
                }
            }
        } onChange: { [weak comp] in
            Task { @MainActor [weak comp] in
                guard let comp, comp === self.composition else { return }
                self.scheduleSave()
            }
        }
    }

    private func scheduleSave() {
        guard let url = selectedURL, url == loadedURL else { return }
        let comp = composition
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await Task.detached(priority: .utility) {
                try? CompositionStore.save(comp, to: url)
            }.value
            // Re-arm tracking only after the save completes. Coalesces the
            // re-subscribe (which walks every cell) to once per debounce
            // window instead of once per keystroke.
            guard !Task.isCancelled, comp === self.composition else { return }
            self.installAutoSave()
        }
    }

    private func deleteURL(_ url: URL) {
        if selectedURL == url { selectedURL = nil }
        library.delete(url)
    }
}

// MARK: - EditorPane

struct EditorPane: View {
    @Binding var selectedURL: URL?
    let composition: Composition
    @Binding var isRenderMode: Bool
    let library: Library
    @Bindable var playback: PlaybackEngine
    let onNewFile: () -> Void
    let onPerform: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if selectedURL == nil {
                emptyState
            } else {
                ScrollView {
                    EditorView(composition: composition, isRenderMode: isRenderMode)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                }
                .environment(playback)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // A tonic / tempo change while playing re-renders the piece transposed.
        // These handlers live in the always-mounted editor pane so they fire
        // whether the change comes from here or the now-playing overlay.
        // Every transport tweak applies live and keeps your place: tempo maps
        // by beat fraction; tonic/sustain/fade recompile timing in place;
        // instrument is a patch swap; volume is a mixer gain. None restart.
        .onChange(of: playback.tonicMidi) { _, _ in playback.applyTimingChange() }
        .onChange(of: playback.tempoOverride) { _, _ in playback.applyTempoChange() }
        .onChange(of: playback.instrument) { _, _ in playback.reloadInstrument() }
        .onChange(of: playback.sustain) { _, _ in playback.applyTimingChange() }
        .onChange(of: playback.fade) { _, _ in playback.applyTimingChange() }
        .onChange(of: playback.instrumentVolume) { _, _ in playback.applyVolumes() }
        .onChange(of: playback.tablaVolume) { _, _ in playback.applyVolumes() }
        .onChange(of: playback.tablaEnabled) { _, _ in playback.applyTimingChange() }
    }

    private func restartIfPlaying() {
        if playback.isPlaying { playback.play(composition) }
    }

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func noteName(_ midi: Int) -> String {
        "\(noteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text("Pancham")
                    .font(Theme.display(22, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("पंचम")
                    .font(Theme.deva(15))
                    .foregroundStyle(Theme.muted)
                    .tracking(0.5)
            }
            Spacer()
            if selectedURL != nil {
                playbackControls
                Text("· Saved")
                    .font(Theme.ui(11)).tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 4)
                Button("+ Section") { composition.sections.append(CompositionSection(matras: composition.matras)) }
                    .buttonStyle(ToolbarOutlineButton())
                Button(isRenderMode ? "Edit" : "Render") { isRenderMode.toggle() }
                    .buttonStyle(ToolbarOutlineButton())
                    .keyboardShortcut("r", modifiers: [.command])
            }
            Button("+ Notation") { onNewFile() }
                .buttonStyle(ToolbarPrimaryButton())
                .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            // Play opens the full-window now-playing screen (3-2-1 lead-in,
            // scrolling lyrics) rather than sounding inline. SF Symbol renders
            // regardless of the custom UI font (IBM Plex Sans has no ▶ glyph).
            Button(action: onPerform) {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
            }
            .buttonStyle(ToolbarOutlineButton())
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Menu("\(Int(playback.effectiveBPM(for: composition))) BPM") {
                Button("Score tempo (\(composition.bpm.isEmpty ? "—" : composition.bpm))") {
                    playback.tempoOverride = nil
                }
                Divider()
                ForEach([60, 80, 100, 120, 140, 160, 180, 200], id: \.self) { b in
                    Button("\(b) BPM") { playback.tempoOverride = Double(b) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("पंचम")
                .font(Theme.deva(64, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.12))
            Text("Choose a notation from the library, or create a new one.")
                .font(Theme.display(15))
                .foregroundStyle(Theme.muted)
            Button("+ New notation", action: onNewFile)
                .buttonStyle(ToolbarPrimaryButton())
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
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
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
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.ink)
            .opacity(configuration.isPressed ? 0.85 : 1)
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

struct RenameTarget: Identifiable {
    let url: URL
    let originalName: String
    let isFolder: Bool
    var id: URL { url }
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
