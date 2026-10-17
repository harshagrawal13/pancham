import Foundation
import SwiftUI

/// App-wide state that isn't the signed-in account's.
@Observable
final class Preferences {
    static let shared = Preferences()

    /// A `.pancham` file opened from Finder, waiting to be imported + shown by
    /// the library once it's on screen. Cleared after it's consumed.
    var pendingOpenURL: URL?

    private init() {}

    // MARK: - Libraries from before sign-in existed

    /// A folder of notations from the old local-folder app, found in its saved settings.
    struct LegacyLibrary: Identifiable {
        let folder: URL
        /// The notations in it, with the folder each sits in ("" for the top level).
        let files: [(source: URL, folder: String)]
        var id: URL { folder }
    }

    /// The library folders the app used to keep per local "user" (`pancham.users.v3`), with their
    /// notations, so the first sign-in can offer to bring them along. Folders that are gone or empty
    /// are left out.
    static func legacyLibraries(defaults: UserDefaults = .standard) -> [LegacyLibrary] {
        struct Old: Decodable { let folderPath: String }
        guard let data = defaults.data(forKey: "pancham.users.v3"),
              let users = try? JSONDecoder().decode([Old].self, from: data) else { return [] }
        let fm = FileManager.default
        func isNotation(_ u: URL) -> Bool { ["pancham", "json"].contains(u.pathExtension.lowercased()) }
        var seen = Set<String>()
        return users.compactMap { u -> LegacyLibrary? in
            let root = URL(fileURLWithPath: u.folderPath)
            guard seen.insert(root.standardizedFileURL.path).inserted,
                  let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
            var files: [(URL, String)] = []
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let inner = (try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
                    files += inner.filter(isNotation).sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { ($0, k.lastPathComponent) }
                } else if isNotation(k) {
                    files.append((k, ""))
                }
            }
            return files.isEmpty ? nil : LegacyLibrary(folder: root, files: files)
        }
    }
}
