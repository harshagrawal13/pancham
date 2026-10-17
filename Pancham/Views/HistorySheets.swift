import SwiftUI

/// A paper card for the history-ish sheets, matching `NameSheet`.
private struct SheetCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

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
                .lineSpacing(3).padding(.bottom, 16)
            content
        }
        .padding(.init(top: 28, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 520)
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// What both lists show while loading, when loading failed, and (optionally) when there is nothing.
private struct LoadPanel<Content: View>: View {
    let loading: Bool
    let error: String
    var empty: String? = nil
    var minHeight: CGFloat = 120
    @ViewBuilder let content: Content

    var body: some View {
        if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: minHeight)
        } else if !error.isEmpty {
            Text(error).font(Theme.ui(12)).foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        } else if let empty {
            Text(empty).font(Theme.display(14)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        } else {
            content
        }
    }
}

/// Every saved version of one notation. Restoring one adds it on top as a new revision, so
/// nothing in the list is ever lost.
struct HistoryView: View {
    let url: URL
    let engine: SyncEngine
    /// Global notations can be read but only changed by admins.
    let canRestore: Bool
    let onClose: () -> Void

    @State private var revisions: [RevisionInfo] = []
    @State private var loading = true
    @State private var error = ""
    @State private var restoring: Int?

    var body: some View {
        SheetCard(eyebrow: "History",
                  title: url.deletingPathExtension().lastPathComponent,
                  subtitle: "Every version that has been saved, newest first. Restoring one makes it the current version and keeps the others.") {
            LoadPanel(loading: loading, error: error) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(revisions.enumerated()), id: \.element.id) { i, r in
                            row(r, older: i + 1 < revisions.count ? revisions[i + 1] : nil, isCurrent: i == 0)
                        }
                    }
                }
                .frame(height: min(340, CGFloat(revisions.count) * 52 + 2))
                .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
            }
            HStack {
                Text("\(revisions.count) \(revisions.count == 1 ? "version" : "versions")")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Close", action: onClose).buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 20)
        }
        .task { await load() }
    }

    private func row(_ r: RevisionInfo, older: RevisionInfo?, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(Self.summary(r, older: older))
                        .font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    if isCurrent {
                        Text("Current").font(Theme.ui(9, weight: .medium)).tracking(1.5).textCase(.uppercase)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text([r.createdAt.formatted(date: .abbreviated, time: .shortened), r.device.map { "on \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if canRestore && !isCurrent && !r.deleted {
                Button(restoring == r.rev ? "Restoring…" : "Restore") { restore(r) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(restoring != nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleFaint.opacity(0.6)).frame(height: 1) }
    }

    static func summary(_ r: RevisionInfo, older: RevisionInfo?) -> String {
        if let note = r.note, !note.isEmpty { return note.prefix(1).uppercased() + note.dropFirst() }
        guard let older else { return "Created" }
        if r.deleted && !older.deleted { return "Deleted" }
        if !r.deleted && older.deleted { return "Brought back" }
        var parts: [String] = []
        if r.name != older.name { parts.append("Renamed from “\(older.name)”") }
        if r.folder != older.folder {
            parts.append(r.folder.isEmpty ? "Moved out of “\(older.folder)”" : "Moved to “\(r.folder)”")
        }
        return parts.isEmpty ? "Edited" : parts.joined(separator: " · ")
    }

    private func load() async {
        do { revisions = try await engine.history(for: url) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func restore(_ r: RevisionInfo) {
        restoring = r.rev
        Task {
            do {
                try await engine.restore(url, toRevision: r.rev)
                onClose()
            } catch {
                self.error = error.localizedDescription
                restoring = nil
            }
        }
    }
}

/// Notations deleted from the library. Deleting only hides one; this brings it back.
struct RecentlyDeletedView: View {
    let engine: SyncEngine
    let onClose: () -> Void

    @State private var docs: [RemoteDoc] = []
    @State private var loading = true
    @State private var error = ""
    @State private var restoring: UUID?

    var body: some View {
        SheetCard(eyebrow: "Recently deleted",
                  title: "Deleted notations",
                  subtitle: "Nothing you delete is gone for good. Restore one and it returns to your library with its whole history.") {
            LoadPanel(loading: loading, error: error, empty: docs.isEmpty ? "Nothing deleted." : nil) {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(docs, id: \.id, content: row) }
                }
                .frame(height: 300)
                .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
            }
            HStack {
                Spacer()
                Button("Close", action: onClose).buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 20)
        }
        .task {
            do { docs = try await engine.deletedNotations() }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func row(_ d: RemoteDoc) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink)
                Text([d.folder.isEmpty ? nil : d.folder,
                      "deleted " + d.updatedAt.formatted(date: .abbreviated, time: .shortened)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(restoring == d.id ? "Restoring…" : "Restore") {
                restoring = d.id
                Task {
                    do {
                        try await engine.undelete(d)
                        docs.removeAll { $0.id == d.id }
                    } catch { self.error = error.localizedDescription }
                    restoring = nil
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(restoring != nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleFaint.opacity(0.6)).frame(height: 1) }
    }
}

/// First sign-in on a Mac that has notations from before accounts existed.
struct LegacyImportSheet: View {
    let libraries: [Preferences.LegacyLibrary]
    let onImport: () -> Void
    let onSkip: () -> Void

    private var count: Int { libraries.reduce(0) { $0 + $1.files.count } }

    var body: some View {
        SheetCard(eyebrow: "Welcome",
                  title: "Bring your notations along?",
                  subtitle: "Pancham found \(count) \(count == 1 ? "notation" : "notations") saved on this Mac from before you signed in. Importing adds them to your account, where they're backed up with a full history and available on every Mac you sign in on. The originals aren't touched.") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(libraries) { lib in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Theme.muted)
                        Text((lib.folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(lib.files.count)").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(12)
            .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
            HStack {
                Spacer()
                Button("Not now", action: onSkip).buttonStyle(OutlineButtonStyle())
                Button("Import \(count)", action: onImport).buttonStyle(FilledButtonStyle())
            }
            .padding(.top, 22)
        }
    }
}
