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
}
