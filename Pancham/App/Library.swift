import Foundation

/// A folder in the library. Contains subfolders and `.pancham` files.
struct LibraryFolder: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    var subtitle: String?  // first raga found inside, for flavor
    var files: [LibraryFile]
    // Keep it flat for v1 — no nested folders.
}

struct LibraryFile: Identifiable, Hashable {
    let id: URL
    let url: URL
    var displayName: String
    var raga: String
    var taal: String
    var laya: String
}

@Observable
final class Library {
    var folders: [LibraryFolder] = []
    var looseFiles: [LibraryFile] = []  // files directly under base folder
    var totalCount: Int = 0

    let root: URL

    init(root: URL) {
        self.root = root
        reload()
    }

    func reload() {
        folders.removeAll()
        looseFiles.removeAll()
        totalCount = 0

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let kids = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else {
            return
        }
        let sorted = kids.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for url in sorted {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                folders.append(scanFolder(url))
            } else if url.pathExtension.lowercased() == "pancham" || url.pathExtension.lowercased() == "json" {
                if let lf = loadFileSummary(url) {
                    looseFiles.append(lf)
                    totalCount += 1
                }
            }
        }
        totalCount += folders.reduce(0) { $0 + $1.files.count }
    }

    private func scanFolder(_ url: URL) -> LibraryFolder {
        let fm = FileManager.default
        var files: [LibraryFile] = []
        if let kids = try? fm.contentsOfDirectory(at: url,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) {
            for f in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where f.pathExtension.lowercased() == "pancham" || f.pathExtension.lowercased() == "json" {
                if let lf = loadFileSummary(f) { files.append(lf) }
            }
        }
        let firstRaga = files.first(where: { !$0.raga.isEmpty })?.raga
        return LibraryFolder(id: url, url: url,
                             name: url.lastPathComponent,
                             subtitle: firstRaga,
                             files: files)
    }

    private func loadFileSummary(_ url: URL) -> LibraryFile? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let comp = try? JSONDecoder().decode(Composition.self, from: data) else {
            return LibraryFile(id: url, url: url, displayName: name,
                               raga: "", taal: "", laya: "")
        }
        let title = comp.title.isEmpty ? name : comp.title
        let taal = comp.taal.name
        return LibraryFile(id: url, url: url,
                           displayName: title,
                           raga: comp.raga,
                           taal: taal,
                           laya: comp.laya)
    }

    // MARK: - Mutations

    @discardableResult
    func createFile(named: String, in folder: LibraryFolder?) -> URL? {
        let dir = folder?.url ?? root
        let base = sanitize(named.isEmpty ? "Untitled" : named)
        var url = dir.appendingPathComponent(base).appendingPathExtension("pancham")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("pancham")
            n += 1
        }
        do {
            let comp = Composition(title: named)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(comp)
            try data.write(to: url, options: [.atomic])
            reload()
            return url
        } catch {
            return nil
        }
    }

    /// Import an external `.pancham` file (e.g. opened from Finder). Files
    /// already inside the library just get rescanned and returned; files from
    /// elsewhere are copied into the library root (disambiguating the name).
    /// Returns the URL to open, or `nil` on failure.
    @discardableResult
    func importFile(_ url: URL) -> URL? {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let incoming = url.standardizedFileURL
        if incoming.path == rootPath || incoming.path.hasPrefix(rootPath + "/") {
            reload()
            return url
        }
        let base = sanitize(url.deletingPathExtension().lastPathComponent)
        var dest = root.appendingPathComponent(base).appendingPathExtension("pancham")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = root.appendingPathComponent("\(base) \(n)").appendingPathExtension("pancham")
            n += 1
        }
        do {
            try fm.copyItem(at: incoming, to: dest)
            reload()
            return dest
        } catch {
            return nil
        }
    }

    @discardableResult
    func createFolder(named: String) -> URL? {
        let url = root.appendingPathComponent(sanitize(named), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            reload()
            return url
        } catch {
            return nil
        }
    }

    /// Rename a file or folder. For files, preserves the `.pancham` extension.
    /// Returns the new URL on success.
    @discardableResult
    func rename(_ url: URL, to newName: String) -> URL? {
        let fm = FileManager.default
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let cleaned = sanitize(newName)
        guard !cleaned.isEmpty else { return nil }

        let parent = url.deletingLastPathComponent()
        let target: URL = {
            if isDir {
                return parent.appendingPathComponent(cleaned, isDirectory: true)
            } else {
                let ext = url.pathExtension.isEmpty ? "pancham" : url.pathExtension
                return parent.appendingPathComponent(cleaned).appendingPathExtension(ext)
            }
        }()

        if target == url {
            return url
        }
        // If something else already lives at the target, append a disambiguator.
        var final = target
        var n = 2
        while fm.fileExists(atPath: final.path) {
            if isDir {
                final = parent.appendingPathComponent("\(cleaned) \(n)", isDirectory: true)
            } else {
                let ext = url.pathExtension.isEmpty ? "pancham" : url.pathExtension
                final = parent.appendingPathComponent("\(cleaned) \(n)").appendingPathExtension(ext)
            }
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: final)
            reload()
            return final
        } catch {
            return nil
        }
    }

    /// Move a file or folder to the Trash.
    func delete(_ url: URL) {
        var resulting: NSURL?
        try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        reload()
    }

    private func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { !banned.contains($0) }))
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

// Read/write for a single composition at a URL.
enum CompositionStore {
    static func load(from url: URL) -> Composition {
        guard let data = try? Data(contentsOf: url),
              var comp = try? JSONDecoder().decode(Composition.self, from: data) else {
            return Composition()
        }
        comp.normalize()
        return comp
    }

    static func save(_ comp: Composition, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(comp)
        try data.write(to: url, options: [.atomic])
    }
}
