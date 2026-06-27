import Foundation

enum TaalID: String, Codable, CaseIterable, Identifiable, Hashable {
    case teentaal
    case teentaal_khali
    case deepchandi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teentaal:        return "Teentaal (16)"
        case .teentaal_khali:  return "Teentaal — from Khali (16)"
        case .deepchandi:      return "Deepchandi (14)"
        }
    }

    /// Short taal name, for the theka toggle in the player.
    var name: String {
        switch self {
        case .teentaal, .teentaal_khali: return "Teentaal"
        case .deepchandi:                return "Deepchandi"
        }
    }

    /// Whether a playable tabla theka exists for this taal. A notation is only
    /// ever played to its own taal's theka.
    var hasTheka: Bool {
        switch self {
        case .teentaal, .teentaal_khali: return true
        case .deepchandi:                return true
        }
    }

    var matras: Int {
        switch self {
        case .teentaal, .teentaal_khali: return 16
        case .deepchandi:                return 14
        }
    }

    var markers: [String] {
        switch self {
        case .teentaal:        return ["X","","","","2","","","","0","","","","3","","",""]
        case .teentaal_khali:  return ["0","","","","3","","","","X","","","","2","","",""]
        case .deepchandi:      return ["X","","","2","","","","0","","","3","","",""]
        }
    }

    /// Vibhag lengths, summing to `matras`. Used to draw the heavy dividers.
    var vibhags: [Int] {
        switch self {
        case .teentaal, .teentaal_khali: return [4, 4, 4, 4]
        case .deepchandi:                return [3, 4, 3, 4]
        }
    }

    /// Set of cell indices (0-based) that end a vibhag (i.e. get a heavy right border).
    /// Excludes the final cell since the outer border handles it.
    var vibhagEndIndices: Set<Int> {
        var ends = Set<Int>()
        var sum = 0
        for len in vibhags.dropLast() {
            sum += len
            ends.insert(sum - 1)
        }
        return ends
    }
}
