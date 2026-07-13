import SwiftUI
import AppKit

struct LibrarySidebar: View {
    @Bindable var library: Library
    let username: String
    @Binding var selectedURL: URL?
    let onNewFile: () -> Void
    let onNewFolder: () -> Void
    let onNewFileIn: (LibraryFolder) -> Void
    let onRename: (RenameTarget) -> Void
    let onDelete: (URL) -> Void
    let onSwitchUser: () -> Void

    @State private var expanded: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !library.looseFiles.isEmpty {
                        ForEach(library.looseFiles) { f in
                            fileRow(f).padding(.leading, 10)
                        }
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            .padding(.vertical, 6)
                    }
                    ForEach(library.folders) { folder in
                        folderNode(folder)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Library")
                    .font(Theme.display(18, weight: .medium))
                    .foregroundStyle(Theme.paper)
                Spacer()
                HStack(spacing: 4) {
                    sidebarIconButton("plus", help: "New notation", action: onNewFile)
                    sidebarIconButton("folder.badge.plus", help: "New folder", action: onNewFolder)
                }
            }
            Text(libraryCaption)
                .font(Theme.ui(11))
                .tracking(0.4).textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.init(top: 18, leading: 18, bottom: 14, trailing: 12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }

    private var libraryCaption: String {
        let c = library.totalCount
        let f = library.folders.count
        return "\(c) \(c == 1 ? "composition" : "compositions") · \(f) \(f == 1 ? "folder" : "folders")"
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
    private func folderNode(_ folder: LibraryFolder) -> some View {
        let isOpen = expanded.contains(folder.url) || folder.files.contains(where: { $0.url == selectedURL })
        VStack(alignment: .leading, spacing: 0) {
            FolderRow(
                folder: folder,
                isOpen: isOpen,
                onToggle: { toggle(folder.url) },
                onAdd: { onNewFileIn(folder) }
            )
            .contextMenu {
                Button("New notation in \(folder.name)") { onNewFileIn(folder) }
                Divider()
                Button("Rename…") {
                    onRename(RenameTarget(url: folder.url,
                                          originalName: folder.name,
                                          isFolder: true))
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                }
                Divider()
                Button("Move to Trash", role: .destructive) { onDelete(folder.url) }
            }

            if let sub = folder.subtitle, !sub.isEmpty, isOpen {
                Text(sub)
                    .font(Theme.ui(10)).tracking(0.4).textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.leading, 28).padding(.trailing, 10).padding(.bottom, 6)
            }
            if isOpen {
                ForEach(folder.files) { file in
                    fileRow(file).padding(.leading, 6)
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func fileRow(_ file: LibraryFile) -> some View {
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
            Button("Rename…") {
                onRename(RenameTarget(url: file.url,
                                      originalName: file.url.deletingPathExtension().lastPathComponent,
                                      isFolder: false))
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) { onDelete(file.url) }
        }
    }

    private func subtitle(_ f: LibraryFile) -> String {
        let parts = [f.taal, f.laya].filter { !$0.isEmpty }
        return parts.isEmpty ? (f.raga.isEmpty ? "—" : f.raga) : parts.joined(separator: " · ")
    }

    private func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    // MARK: Footer

    struct FolderRow: View {
        let folder: LibraryFolder
        let isOpen: Bool
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
                    if hovering {
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

    private var footer: some View {
        HStack {
            Text(username)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.paper)
            Spacer()
            Button(action: onSwitchUser) {
                HStack(spacing: 4) {
                    Text("Switch")
                    Text("→")
                }
                .font(Theme.ui(11))
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }
}
