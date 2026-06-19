import Foundation
import AVFoundation

/// Harmonium playback for a `Composition`.
///
/// No MIDI file is involved — pitch and timing come straight from the notation:
/// each cell is one matra (`60 / bpm` seconds); space-separated tokens subdivide
/// a matra equally; `s` / `-` sustain (extend) the previous note; empty cells are
/// rests. Pitch is the swara's semitone offset from Sa, added to a user-chosen
/// tonic. This mirrors the `tokenToMidi` / `buildEvents` reference converter.
///
/// Sound comes from `AVAudioUnitSampler`. We prefer a bundled `harmonium.sf2`
/// if present. Otherwise we layer two system General-MIDI voices for a fuller
/// harmonium: a Reed Organ lead (free-reed attack and clarity) over a String
/// Ensemble pad (body and sustain).
@MainActor
@Observable
final class PlaybackEngine {
    /// True while a piece is sounding.
    var isPlaying = false
    /// The matra cell currently sounding, for the visual cursor. `nil` when idle.
    var current: CellLocation?
    /// MIDI note for Sa. Default 60 (C4). Selectable 55…67.
    var tonicMidi: Int = 60
    /// Tempo override in BPM. `nil` uses the score's own `bpm`.
    var tempoOverride: Double?

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    /// Lead reed voice — clear attack and definition.
    private let sampler = AVAudioUnitSampler()
    /// String-ensemble pad layered under the reed for body. Silent when a
    /// bundled `harmonium.sf2` is used instead (it already sounds full).
    private let pad = AVAudioUnitSampler()
    private var layered = false
    private var soundLoaded = false
    private var task: Task<Void, Never>?

    private static let velocity: UInt8 = 100
    /// Pad sits a little under the reed so the attack stays crisp.
    private static let padVelocity: UInt8 = 78
    private static let channel: UInt8 = 0
    /// Tempo used when the score carries no usable `bpm`, so Play always sounds.
    static let defaultBPM: Double = 120

    init() {
        engine.attach(sampler)
        engine.attach(pad)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.connect(pad, to: engine.mainMixerNode, format: nil)
    }

    /// Effective tempo for the given score under the current override. Falls
    /// back to `defaultBPM` when neither the override nor the score gives a
    /// positive tempo (empty, "0", or non-numeric `bpm`), so Play is never a
    /// silent no-op.
    func effectiveBPM(for composition: Composition) -> Double {
        if let o = tempoOverride, o > 0 { return o }
        if let b = Double(composition.bpm), b > 0 { return b }
        return Self.defaultBPM
    }

    // MARK: Transport

    func play(_ composition: Composition) {
        stop()

        let bpm = effectiveBPM(for: composition)
        guard bpm > 0 else { return }
        let timeline = Self.buildTimeline(for: composition, tonic: tonicMidi, bpm: bpm)
        guard !timeline.cells.isEmpty else { return }

        loadSoundIfNeeded()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }

        // Flatten everything into one time-sorted action list so a single loop
        // drives both audio and the visual cursor off the same clock.
        enum Action { case noteOn(UInt8), noteOff(UInt8), highlight(CellLocation), end }
        var actions: [(time: Double, order: Int, action: Action)] = []
        for n in timeline.notes {
            let m = UInt8(clamping: n.midi)
            actions.append((n.start, 1, .noteOn(m)))           // on after off at a tie
            actions.append((n.start + n.dur, 0, .noteOff(m)))  // off first at a tie
        }
        for c in timeline.cells {
            actions.append((c.start, 2, .highlight(c.loc)))
        }
        actions.append((timeline.total, 3, .end))
        actions.sort { ($0.time, $0.order) < ($1.time, $1.order) }

        isPlaying = true
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let origin = clock.now
            for step in actions {
                let deadline = origin.advanced(by: .seconds(step.time))
                try? await clock.sleep(until: deadline, tolerance: nil)
                if Task.isCancelled { return }
                guard let self else { return }
                switch step.action {
                case .noteOn(let m):
                    self.sampler.startNote(m, withVelocity: Self.velocity, onChannel: Self.channel)
                    if self.layered {
                        self.pad.startNote(m, withVelocity: Self.padVelocity, onChannel: Self.channel)
                    }
                case .noteOff(let m):
                    self.sampler.stopNote(m, onChannel: Self.channel)
                    if self.layered { self.pad.stopNote(m, onChannel: Self.channel) }
                case .highlight(let loc):
                    self.current = loc
                case .end:
                    break
                }
            }
            self?.isPlaying = false
            self?.current = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // All-notes-off on both voices, then silence the banks.
        sampler.sendController(123, withValue: 0, onChannel: Self.channel)
        pad.sendController(123, withValue: 0, onChannel: Self.channel)
        isPlaying = false
        current = nil
    }

    // MARK: Sound bank

    private func loadSoundIfNeeded() {
        guard !soundLoaded else { return }
        soundLoaded = true

        // Melodic bank select (GM): MSB 0x79, LSB 0x00.
        let melodicMSB: UInt8 = 0x79
        if let sf2 = Bundle.main.url(forResource: "harmonium", withExtension: "sf2") {
            try? sampler.loadSoundBankInstrument(at: sf2, program: 0,
                                                 bankMSB: melodicMSB, bankLSB: 0)
            layered = false
            return
        }
        // System General-MIDI bank, layered for a fuller harmonium voice:
        //   reed  → Reed Organ      (GM patch 21, program 20) — attack & clarity
        //   pad   → String Ensemble (GM patch 49, program 48) — body & sustain
        let dls = URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        try? sampler.loadSoundBankInstrument(at: dls, program: 20,
                                             bankMSB: melodicMSB, bankLSB: 0)
        try? pad.loadSoundBankInstrument(at: dls, program: 48,
                                         bankMSB: melodicMSB, bankLSB: 0)
        layered = true
    }

    // MARK: Timeline

    struct NoteEvent { var midi: Int; var start: Double; var dur: Double }
    struct CellStep  { var loc: CellLocation; var start: Double }
    struct Timeline  { var notes: [NoteEvent]; var cells: [CellStep]; var total: Double }

    /// Walk every notation cell (in section/line/cell order) into a timed event
    /// list plus a per-cell highlight schedule. Lyric lines are skipped but do
    /// not advance the clock.
    static func buildTimeline(for composition: Composition, tonic: Int, bpm: Double) -> Timeline {
        let beat = 60 / bpm
        var notes: [NoteEvent] = []
        var cells: [CellStep] = []
        var t = 0.0

        for (si, section) in composition.sections.enumerated() {
            for (li, line) in section.lines.enumerated() {
                guard line.type == .notation else { continue }
                for (ci, box) in line.cells.enumerated() {
                    cells.append(CellStep(loc: CellLocation(section: si, line: li, cell: ci),
                                          start: t))
                    let subs = box.text
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    let subDur = beat / Double(max(subs.count, 1))
                    for (j, tok) in subs.enumerated() {
                        let start = t + Double(j) * subDur
                        switch SwaraPitch.pitch(of: tok, tonic: tonic) {
                        case .sustain:
                            if !notes.isEmpty { notes[notes.count - 1].dur += subDur }
                        case .note(let m):
                            notes.append(NoteEvent(midi: m, start: start, dur: subDur))
                        case .rest:
                            break
                        }
                    }
                    t += beat
                }
            }
        }
        return Timeline(notes: notes, cells: cells, total: t)
    }
}

/// Maps a DSL token to a pitch. Independent of the glyph rendering in
/// `SwaraParser` so audio semantics stay self-contained; mirrors the reference
/// `tokenToMidi`. Octave prefixes stack (`.` = −12, `^` = +12); trailing `'`
/// is tivra (+1). `s` / `-` sustain; unknown/empty is a rest.
enum SwaraPitch {
    enum Result { case note(Int), sustain, rest }

    /// Semitone offset from Sa for each base letter.
    static let offset: [Character: Int] = [
        "S": 0, "r": 1, "R": 2, "g": 3, "G": 4, "M": 5,
        "P": 7, "d": 8, "D": 9, "n": 10, "N": 11,
    ]

    static func pitch(of raw: String, tonic: Int) -> Result {
        var tok = raw
        // Sustain is checked before any octave/tivra stripping.
        if tok == "s" || tok == "-" { return .sustain }

        var oct = 0
        while tok.first == "." { oct -= 12; tok.removeFirst() }
        while tok.first == "^" { oct += 12; tok.removeFirst() }

        var tivra = false
        if tok.hasSuffix("'") { tivra = true; tok.removeLast() }

        guard let base = tok.first, let semis = offset[base] else { return .rest }
        return .note(tonic + semis + (tivra ? 1 : 0) + oct)
    }
}
