import SwiftUI
import AppKit

/// One of the two libraries the sidebar lists, and what the signed-in account may do in it.
private struct SidebarSection {
    let library: Library
    let scope: SyncScope
    let title: String
    var isGlobal: Bool { scope == .global }
}

/// Your library on top, the global library (shared, made by admins) below it.
struct LibrarySidebar: View {
    @Bindable var library: Library
    @Bindable var global: Library
    let account: Account
    let engine: SyncEngine
    @Binding var selectedURL: URL?
    let onNewFile: (Library) -> Void
    let onNewFolder: (Library) -> Void
    let onNewFileIn: (Library, LibraryFolder) -> Void
    let onRename: (RenameTarget) -> Void
    let onDelete: (URL) -> Void
    let onAddToLibrary: (URL) -> Void
    let onPublish: (URL) -> Void
    let onRecentlyDeleted: () -> Void
    let onSignOut: () -> Void

    @State private var expanded: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section(SidebarSection(library: library, scope: .private, title: "Library"),
                            caption: libraryCaption(library))
                    section(SidebarSection(library: global, scope: .global, title: "Global library"),
                            caption: globalCaption)
                        .padding(.top, 6)
                }
            }
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: 248)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ sec: SidebarSection, caption: String) -> some View {
        let lib = sec.library, isGlobal = sec.isGlobal
        VStack(alignment: .leading, spacing: 0) {
            header(sec, caption: caption)
            VStack(alignment: .leading, spacing: 0) {
                if lib.totalCount == 0 && lib.folders.isEmpty {
                    Text(isGlobal ? "Nothing shared yet." : "No notations yet.")
                        .font(Theme.display(13)).italic()
                        .foregroundStyle(Color.white.opacity(0.45))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
                if !lib.looseFiles.isEmpty {
                    ForEach(lib.looseFiles) { f in
                        fileRow(f, in: sec).padding(.leading, 10)
                    }
                    if !lib.folders.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 6)
                    }
                }
                ForEach(lib.folders) { folder in
                    folderNode(folder, in: sec)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private func header(_ sec: SidebarSection, caption: String) -> some View {
        let lib = sec.library, title = sec.title, isGlobal = sec.isGlobal, editable = account.canEdit(sec.scope)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(Theme.display(isGlobal ? 16 : 18, weight: .medium))
                    .foregroundStyle(Theme.paper)
                Spacer()
                if editable {
                    HStack(spacing: 4) {
                        sidebarIconButton("plus", help: isGlobal ? "New global notation" : "New notation") { onNewFile(lib) }
                        sidebarIconButton("folder.badge.plus", help: "New folder") { onNewFolder(lib) }
                    }
                }
            }
            Text(caption)
                .font(Theme.ui(11))
                .tracking(0.4).textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.init(top: isGlobal ? 14 : 18, leading: 18, bottom: 12, trailing: 12))
        .overlay(alignment: .top) {
            if isGlobal { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }

    private func libraryCaption(_ lib: Library) -> String {
        let c = lib.totalCount
        let f = lib.folders.count
        return "\(c) \(c == 1 ? "composition" : "compositions") · \(f) \(f == 1 ? "folder" : "folders")"
    }

    private var globalCaption: String {
        let c = global.totalCount
        return account.isAdmin ? "\(c) shared · you manage these" : "\(c) shared · read only"
    }

    private func sidebarIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.paper.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Folder / File rows

    @ViewBuilder
    private func folderNode(_ folder: LibraryFolder, in sec: SidebarSection) -> some View {
        let lib = sec.library, editable = account.canEdit(sec.scope)
        let isOpen = expanded.contains(folder.url) || folder.files.contains(where: { $0.url == selectedURL })
        VStack(alignment: .leading, spacing: 0) {
            FolderRow(
                folder: folder,
                isOpen: isOpen,
                canAdd: editable,
                onToggle: { toggle(folder.url) },
                onAdd: { onNewFileIn(lib, folder) }
            )
            .contextMenu {
                if editable {
                    Button("New notation in \(folder.name)") { onNewFileIn(lib, folder) }
                    Divider()
                    Button("Rename…") {
                        onRename(RenameTarget(url: folder.url, originalName: folder.name, isFolder: true))
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { onDelete(folder.url) }
                }
            }

            if let sub = folder.subtitle, !sub.isEmpty, isOpen {
                Text(sub)
                    .font(Theme.ui(10)).tracking(0.4).textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.leading, 28).padding(.trailing, 10).padding(.bottom, 6)
            }
            if isOpen {
                ForEach(folder.files) { file in
                    fileRow(file, in: sec).padding(.leading, 6)
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func fileRow(_ file: LibraryFile, in sec: SidebarSection) -> some View {
        let editable = account.canEdit(sec.scope), isGlobal = sec.isGlobal
        let isActive = selectedURL == file.url
        Button(action: { selectedURL = file.url }) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(Theme.ui(12.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                Text(subtitle(file))
                    .font(Theme.ui(10)).tracking(0.3)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.white.opacity(0.08) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? Theme.accent : .clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isGlobal {
                Button("Add to my library") { onAddToLibrary(file.url) }
            } else if account.isAdmin {
                Button("Publish a copy to the global library") { onPublish(file.url) }
                Divider()
            }
            if editable {
                Button("Rename…") {
                    onRename(RenameTarget(url: file.url,
                                          originalName: file.url.deletingPathExtension().lastPathComponent,
                                          isFolder: false))
                }
                Divider()
                Button("Move to Trash", role: .destructive) { onDelete(file.url) }
            }
        }
    }

    private func subtitle(_ f: LibraryFile) -> String {
        let parts = [f.taal, f.laya].filter { !$0.isEmpty }
        return parts.isEmpty ? (f.raga.isEmpty ? "—" : f.raga) : parts.joined(separator: " · ")
    }

    private func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    struct FolderRow: View {
        let folder: LibraryFolder
        let isOpen: Bool
        let canAdd: Bool
        let onToggle: () -> Void
        let onAdd: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 8) {
                    Text(isOpen ? "▾" : "▸")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 10)
                    Text(folder.name)
                        .font(Theme.display(14, weight: .medium))
                        .foregroundStyle(Theme.paper)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering && canAdd {
                        Button(action: onAdd) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.paper.opacity(0.85))
                                .frame(width: 18, height: 18)
                                .overlay(Rectangle()
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("New notation in \(folder.name)")
                    } else {
                        Text("\(folder.files.count)")
                            .font(Theme.ui(10))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle()
                        .fill(engine.hasProblem ? Theme.danger : Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text(engine.statusText)
                        .font(Theme.ui(10)).tracking(0.3)
                        .foregroundStyle(engine.hasProblem ? Color(hex: 0xE0A0A0) : Color.white.opacity(0.55))
                        .lineLimit(1)
                        .help(engine.statusText)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if account.isAdmin { Text("Admin") }
                Button("Recently deleted…", action: onRecentlyDeleted)
                Divider()
                Button("Sign out", action: onSignOut)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.paper.opacity(0.8))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }
}
