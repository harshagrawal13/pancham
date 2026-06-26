import Foundation

/// One articulation of a tabla bol against the bundled `tabla.sf2` voice.
/// `fixed` strokes play a recorded sample at its own key; `tuned` plays the
/// ringing dayan, transposed so it sounds at the chosen Sa.
enum TablaStroke {
    case fixed(UInt8)
    case tuned
}

/// Keys in `tabla.sf2` for the dry (un-pitched) strokes. Must match
/// `Tools/build_tabla_sf2.py`.
enum TablaKey {
    static let ghe:    UInt8 = 24
    static let ke:     UInt8 = 26
    static let te:     UInt8 = 28
    static let na:     UInt8 = 30
    static let naOpen: UInt8 = 32
    static let dha:    UInt8 = 34
    static let dhin:   UInt8 = 36
}

/// A tabla bol, resolved to its sample stroke(s). Dha and Dhin are dedicated
/// recorded strokes (already both-drum); Tin is the ringing dayan tuned to Sa;
/// Ta/Na are the rim stroke.
enum TablaBol {
    case dha, dhin, tin, ta, na, tit, ke, ge, rest

    var strokes: [TablaStroke] {
        switch self {
        case .rest:    return []
        case .ge:      return [.fixed(TablaKey.ghe)]
        case .ke:      return [.fixed(TablaKey.ke)]
        case .tit:     return [.fixed(TablaKey.te)]
        case .na, .ta: return [.fixed(TablaKey.na)]
        case .tin:     return [.tuned]
        case .dha:     return [.fixed(TablaKey.dha)]
        case .dhin:    return [.fixed(TablaKey.dhin)]
        }
    }
}

/// The theka (cyclic stroke pattern) for each taal. Length matches the taal's
/// matra count so matra `k` of any line maps to `pattern[k % matras]`.
enum Theka {
    static func pattern(for taal: TaalID) -> [TablaBol] {
        switch taal {
        case .teentaal, .teentaal_khali:
            // Dha Dhin Dhin Dha | Dha Dhin Dhin Dha | Dha Tin Tin Ta | Ta Dhin Dhin Dha
            return [.dha, .dhin, .dhin, .dha,
                    .dha, .dhin, .dhin, .dha,
                    .dha, .tin,  .tin,  .ta,
                    .ta,  .dhin, .dhin, .dha]
        case .deepchandi:
            // 14 matras (3+4+3+4): Dha Dhin – | Dha Dha Tin – | Ta Tin – | Dha Dha Dhin –
            return [.dha, .dhin, .rest,
                    .dha, .dha,  .tin, .rest,
                    .ta,  .tin,  .rest,
                    .dha, .dha,  .dhin, .rest]
        }
    }
}
