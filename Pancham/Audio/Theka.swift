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

/// A tabla bol, resolved to its sample stroke(s). Dha and Dhin are both-drum
/// composites built from the ringing mmiron strokes so they match Tin/Ta's
/// mellow character:
///   Dha  = Ge (bayan) + Na-open (the ringing dayan rim stroke)
///   Dhin = Ge (bayan) + Tin (the ringing dayan, tuned to Sa)
/// Tin is the ringing dayan alone; Ta/Na are the rim stroke.
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
        case .dha:     return [.fixed(TablaKey.ghe), .fixed(TablaKey.naOpen)]
        case .dhin:    return [.fixed(TablaKey.ghe), .tuned]
        }
    }

    /// Extra lead (seconds) for this bol on top of the global tabla lead.
    var extraLead: Double { 0 }
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
            // Simplified: Dha Dhin Dhin Dha Dhin Dha Dhin — a 7-bol pattern
            // that cycles twice across the 14 matras (one bol per beat).
            return [.dha, .dhin, .dhin, .dha, .dhin, .dha, .dhin]
        }
    }
}
