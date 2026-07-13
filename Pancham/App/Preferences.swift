import Foundation
import SwiftUI

struct PanchamUser: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var folderPath: String

    init(id: UUID = UUID(), name: String, folderPath: String) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath) }
}

/// Persisted multi-user preferences. The app is not sandboxed, so we just
/// store the library folder as a plain filesystem path — no security-scoped
/// bookmark dance required.
@Observable
final class Preferences {
    static let shared = Preferences()

    private let kUsers = "pancham.users.v3"

    private(set) var users: [PanchamUser]
    private(set) var activeUser: PanchamUser?

    /// A `.pancham` file opened from Finder, waiting to be imported + shown by
    /// the library once it's on screen. Cleared after it's consumed.
    var pendingOpenURL: URL?

    var activeFolder: URL? { activeUser?.folderURL }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: kUsers),
           let list = try? JSONDecoder().decode([PanchamUser].self, from: data) {
            self.users = list
            return
        }

        // Migration from the v2 bookmark-based store.
        if let data = d.data(forKey: "pancham.users.v2") {
            self.users = Self.migrateFromBookmarkStore(data)
            Self.persist(self.users, key: kUsers)
            d.removeObject(forKey: "pancham.users.v2")
            return
        }

        self.users = []
    }

    var hasAnyUsers: Bool { !users.isEmpty }
    var isSignedIn: Bool { activeUser != nil }

    // MARK: - Activation

    @discardableResult
    func activate(userID: UUID) -> Bool {
        guard let user = users.first(where: { $0.id == userID }) else { return false }
        // Basic sanity check — if the folder has vanished, refuse.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: user.folderPath, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        self.activeUser = user
        return true
    }

    /// Sign out — returns to the user picker (does NOT delete the user).
    func deactivate() { self.activeUser = nil }

    // MARK: - CRUD

    @discardableResult
    func addUser(name: String, folder: URL) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let user = PanchamUser(name: trimmed, folderPath: folder.path)
        users.append(user)
        Self.persist(users, key: kUsers)
        return activate(userID: user.id)
    }

    func removeUser(_ id: UUID) {
        if activeUser?.id == id { deactivate() }
        users.removeAll { $0.id == id }
        Self.persist(users, key: kUsers)
    }

    // MARK: - Internals

    private static func persist(_ users: [PanchamUser], key: String) {
        if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Resolve each v2 bookmark blob to a path and migrate to the path-based store.
    private static func migrateFromBookmarkStore(_ data: Data) -> [PanchamUser] {
        struct LegacyUser: Decodable { let id: UUID; let name: String; let bookmark: Data }
        guard let legacy = try? JSONDecoder().decode([LegacyUser].self, from: data) else {
            return []
        }
        return legacy.compactMap { u -> PanchamUser? in
            var stale = false
            if let url = try? URL(resolvingBookmarkData: u.bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return PanchamUser(id: u.id, name: u.name, folderPath: url.path)
            }
            return nil
        }
    }
}
