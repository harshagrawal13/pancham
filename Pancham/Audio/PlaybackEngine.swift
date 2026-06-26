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
/// if present, else one of two system General-MIDI voices the user picks
/// between — soft strings (Synth Strings 1) or a reedy harmonium (Reed Organ).
/// Both have a gentle attack; the `sustain` control then rings each note past
/// its matra so notes blend into the next.
@MainActor
@Observable
final class PlaybackEngine {
    /// Where an instrument's samples come from.
    enum Sound {
        /// System General-MIDI program (melodic bank, MSB 0x79).
        case gm(UInt8)
        /// A bundled SoundFont resource name (without the `.sf2` extension).
        case soundFont(String)
    }

    /// Selectable melodic voice. The VSCO entries are real recorded samples
    /// (Versilian Studios Chamber Orchestra 2 CE) bundled as compact SoundFonts;
    /// the others fall back to the system GM bank.
    enum Instrument: String, CaseIterable, Identifiable {
        case vscoStrings
        case vscoOrgan
        case softStrings
        case harmonium

        var id: String { rawValue }
        var label: String {
            switch self {
            case .vscoStrings: return "Strings (VSCO)"
            case .vscoOrgan:   return "Organ (VSCO)"
            case .softStrings: return "Soft strings"
            case .harmonium:   return "Harmonium"
            }
        }
        var sound: Sound {
            switch self {
            case .vscoStrings: return .soundFont("vsco-strings")
            case .vscoOrgan:   return .soundFont("vsco-organ")
            case .softStrings: return .gm(50)   // Synth Strings 1 — bowed, sustained
            case .harmonium:   return .gm(20)   // Reed Organ — reedy, harmonium-like
            }
        }
    }

    /// True while a piece is sounding.
    var isPlaying = false
    /// The matra cell currently sounding, for the visual cursor. `nil` when idle.
    var current: CellLocation?
    /// MIDI note for Sa. Default 60 (C4). Selectable 55…67.
    var tonicMidi: Int = 60
    /// Tempo override in BPM. `nil` uses the score's own `bpm`.
    var tempoOverride: Double?
    /// Melodic voice. Change is applied to the live sampler via `reloadInstrument()`.
    var instrument: Instrument = .softStrings
    /// 0…1. Extra ring added past each note's matra so notes sustain and blend
    /// into the next. 0 = stop at the matra boundary.
    var sustain: Double = 0.4
    /// 0…0.5. Per-note volume shaping: ramp up over the first `fade` of the
    /// note's span and down over the last `fade`, so each note swells in and
    /// decays out. 0 = no shaping (full volume throughout).
    var fade: Double = 0
    /// 0…1 level for the melodic voice (strings / harmonium / …).
    var instrumentVolume: Double = 1.0
    /// 0…1 level for the tabla theka.
    var tablaVolume: Double = 1.0
    /// Whether the tabla theka plays under the melody, locked to the same beat.
    var tablaEnabled: Bool = false
    /// Lead-in counter (3→2→1) shown before audio starts; `nil` when not counting.
    var countdown: Int?
    /// True while playback is paused at a playhead, ready to resume in place.
    var isPaused = false

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// Separate voice for the tabla theka so it keeps its own patch.
    private let tablaSampler = AVAudioUnitSampler()
    /// Per-voice submixers, so melody and tabla have independent volume.
    private let melodyMix = AVAudioMixerNode()
    private let tablaMix = AVAudioMixerNode()
    private var soundLoaded = false
    private var task: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    private static let velocity: UInt8 = 100
    private static let channel: UInt8 = 0
    /// CC11 = expression, honoured by Apple's sampler, for the fade envelope.
    /// Note: it's applied globally (not per-channel) on AUSampler, so the fade
    /// is one shared envelope and only works on non-overlapping notes — which
    /// is why fade articulates the line (skips the sustain ring) when engaged.
    private static let expression: UInt8 = 11
    /// Steps per fade ramp — enough to sound smooth, few enough to stay cheap.
    private static let fadeSteps = 8
    /// Tempo used when the score carries no usable `bpm`, so Play always sounds.
    static let defaultBPM: Double = 120
    /// Ring time (seconds) added past a note's matra at `sustain == 1`.
    private static let maxRing: Double = 1.4

    // MARK: Playback model
    //
    // The piece is compiled once into a time-sorted `actions` list plus the
    // note spans (for re-striking on resume). A single loop walks `actions`
    // from a playhead offset; pause records the offset, resume restarts the
    // loop from it. `origin` is the clock instant that maps to offset 0.

    private enum Action {
        case noteOn(UInt8)
        case noteOff(UInt8)
        case expr(UInt8)
        case tabla(note: UInt8, velocity: UInt8)
        case highlight(CellLocation)
        case end
    }
    private let clock = ContinuousClock()
    private var actions: [(time: Double, order: Int, action: Action)] = []
    private var noteSpans: [(m: UInt8, start: Double, off: Double)] = []
    private var totalDuration: Double = 0
    private var origin: ContinuousClock.Instant?
    /// Playhead in seconds, valid while paused (or as a resume point).
    private var elapsed: Double = 0
    /// The piece currently loaded, so timing tweaks can recompile in place.
    private var loadedComposition: Composition?
    /// BPM the current `actions` were compiled at, so a tempo change can map
    /// the playhead by beat fraction rather than raw seconds.
    private var currentBPM: Double = defaultBPM

    init() {
        engine.attach(sampler)
        engine.attach(tablaSampler)
        engine.attach(melodyMix)
        engine.attach(tablaMix)
        engine.connect(sampler, to: melodyMix, format: nil)
        engine.connect(melodyMix, to: engine.mainMixerNode, format: nil)
        engine.connect(tablaSampler, to: tablaMix, format: nil)
        engine.connect(tablaMix, to: engine.mainMixerNode, format: nil)
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

    /// Compile the piece into the time-sorted `actions` list and note spans.
    ///
    /// When `fade` is 0, each note rings `ring` seconds past its matra (the
    /// sustain control) so notes blend; a tail is clamped so it never cuts the
    /// next strike of the same pitch. When `fade` is engaged it instead shapes
    /// each note with a CC11 expression envelope (swell in, decay to 0 before
    /// the next) — and since that envelope is global on Apple's sampler, fade
    /// drops the ring so notes don't overlap and fight one shared envelope.
    /// Order at a shared instant: note-off, expression, note-on, highlight, end.
    private func compile(_ composition: Composition, bpm: Double) {
        let timeline = Self.buildTimeline(for: composition, tonic: tonicMidi, bpm: bpm)
        var acts: [(time: Double, order: Int, action: Action)] = []
        var spans: [(m: UInt8, start: Double, off: Double)] = []
        let fadeFrac = max(0, min(0.5, fade))
        let ring = fadeFrac > 0 ? 0 : Self.maxRing * max(0, min(1, sustain))
        let notes = timeline.notes
        for i in notes.indices {
            let n = notes[i]
            let m = UInt8(clamping: n.midi)
            var off = n.start + n.dur + ring
            if ring > 0 {
                for j in (i + 1)..<notes.count where notes[j].midi == n.midi {
                    off = min(off, notes[j].start)   // don't let a tail cut the same pitch
                    break
                }
            }
            off = max(off, n.start + n.dur)
            acts.append((n.start, 3, .noteOn(m)))
            acts.append((off, 0, .noteOff(m)))
            spans.append((m, n.start, off))

            if fadeFrac > 0 {
                let span = off - n.start
                let edge = span * fadeFrac
                acts.append((n.start, 1, .expr(0)))   // start silent
                for s in 1...Self.fadeSteps {
                    let f = Double(s) / Double(Self.fadeSteps)
                    acts.append((n.start + edge * f, 1, .expr(UInt8((127 * f).rounded()))))
                    acts.append((off - edge + edge * f, 1, .expr(UInt8((127 * (1 - f)).rounded()))))
                }
            }
        }
        for c in timeline.cells {
            acts.append((c.start, 4, .highlight(c.loc)))
        }

        // Tabla theka: one bol per matra, cycling the taal's pattern across the
        // whole piece on the same clock — so it locks to tempo and pause/resume
        // for free. Sam (cycle head) hits a touch harder.
        // Theka only plays for a taal we actually support (Teentaal for now),
        // so a notation can't be played to a mismatched taal.
        if tablaEnabled && composition.taal.hasTheka {
            let beat = 60.0 / bpm
            let matras = composition.matras
            let pattern = Theka.pattern(for: composition.taal)
            let slots = Int((timeline.total / beat).rounded())
            let tuned = UInt8(clamping: tonicMidi)
            for k in 0..<slots where !pattern.isEmpty {
                let bol = pattern[k % min(matras, pattern.count)]
                let vel: UInt8 = (k % matras == 0) ? 120 : 92
                for stroke in bol.strokes {
                    let note: UInt8
                    switch stroke {
                    case .fixed(let key): note = key
                    case .tuned:          note = tuned
                    }
                    acts.append((Double(k) * beat, 2, .tabla(note: note, velocity: vel)))
                }
            }
        }

        acts.append((timeline.total, 5, .end))
        acts.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        actions = acts
        noteSpans = spans
        totalDuration = timeline.total
        currentBPM = bpm
    }

    func play(_ composition: Composition) {
        stop()
        let bpm = effectiveBPM(for: composition)
        guard bpm > 0 else { return }
        compile(composition, bpm: bpm)
        guard totalDuration > 0 else { return }
        loadedComposition = composition
        loadSoundIfNeeded()
        applyVolumes()
        elapsed = 0
        runLoop(from: 0)
    }

    /// Apply the per-voice volumes to their submixers (linear 0…1). Safe anytime.
    func applyVolumes() {
        melodyMix.outputVolume = Float(max(0, min(1, instrumentVolume)))
        tablaMix.outputVolume = Float(max(0, min(1, tablaVolume)))
    }

    /// All-notes-off, and restore expression to full so a note left mid-fade
    /// doesn't leave the next one silent.
    private func silenceAllChannels() {
        sampler.sendController(123, withValue: 0, onChannel: Self.channel)
        sampler.sendController(Self.expression, withValue: 127, onChannel: Self.channel)
        tablaSampler.sendController(123, withValue: 0, onChannel: 0)
    }

    /// Drive the action loop from `offset` seconds. Notes that should already
    /// be sounding at `offset` (i.e. a resume mid-note) are re-struck first.
    private func runLoop(from offset: Double) {
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        isPlaying = true
        isPaused = false
        // Re-strike (at full expression) notes that should already be sounding.
        sampler.sendController(Self.expression, withValue: 127, onChannel: Self.channel)
        for span in noteSpans where span.start <= offset && offset < span.off {
            sampler.startNote(span.m, withVelocity: Self.velocity, onChannel: Self.channel)
        }
        let startInstant = clock.now.advanced(by: .seconds(-offset))
        origin = startInstant
        let acts = actions
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in acts where step.time >= offset {
                let deadline = startInstant.advanced(by: .seconds(step.time))
                try? await self.clock.sleep(until: deadline, tolerance: nil)
                if Task.isCancelled { return }
                switch step.action {
                case .noteOn(let m):
                    self.sampler.startNote(m, withVelocity: Self.velocity, onChannel: Self.channel)
                case .noteOff(let m):
                    self.sampler.stopNote(m, onChannel: Self.channel)
                case .expr(let value):
                    self.sampler.sendController(Self.expression, withValue: value, onChannel: Self.channel)
                case .tabla(let note, let velocity):
                    self.tablaSampler.startNote(note, withVelocity: velocity, onChannel: 0)
                case .highlight(let loc):
                    self.current = loc
                case .end:
                    break
                }
            }
            self.finish()
        }
    }

    /// Pause at the current playhead, silencing held notes but keeping the
    /// cursor where it is so `resume()` can pick up in place.
    func pause() {
        guard isPlaying, !isPaused else { return }
        if let origin {
            elapsed = min(max(0, seconds(origin.duration(to: clock.now))), totalDuration)
        }
        task?.cancel()
        task = nil
        silenceAllChannels()
        isPlaying = false
        isPaused = true
    }

    /// Resume from the paused playhead.
    func resume() {
        guard isPaused else { return }
        runLoop(from: elapsed)
    }

    /// Recompile timing in place (e.g. the sustain slider moved) and continue
    /// from the current playhead, so a live tweak doesn't jump back to the top.
    func applyTimingChange() {
        guard let comp = loadedComposition, isPlaying || isPaused else { return }
        let wasPlaying = isPlaying
        let pos: Double = {
            if isPlaying, let origin {
                return min(seconds(origin.duration(to: clock.now)), totalDuration)
            }
            return elapsed
        }()
        task?.cancel()
        task = nil
        silenceAllChannels()
        compile(comp, bpm: effectiveBPM(for: comp))
        elapsed = min(pos, totalDuration)
        if wasPlaying {
            runLoop(from: elapsed)
        } else {
            isPaused = true
            isPlaying = false
        }
    }

    /// Recompile after a tempo change and continue from the same *musical*
    /// position — the playhead is mapped by beat fraction, so speeding up or
    /// slowing down keeps you on the same matra rather than the same second.
    func applyTempoChange() {
        guard let comp = loadedComposition, isPlaying || isPaused else { return }
        let wasPlaying = isPlaying
        let oldBeat = 60.0 / currentBPM
        let posSeconds: Double = {
            if isPlaying, let origin {
                return min(seconds(origin.duration(to: clock.now)), totalDuration)
            }
            return elapsed
        }()
        let beatFraction = oldBeat > 0 ? posSeconds / oldBeat : 0
        task?.cancel()
        task = nil
        silenceAllChannels()
        compile(comp, bpm: effectiveBPM(for: comp))
        let newBeat = 60.0 / currentBPM
        elapsed = min(beatFraction * newBeat, totalDuration)
        if wasPlaying {
            runLoop(from: elapsed)
        } else {
            isPaused = true
            isPlaying = false
        }
    }

    private func finish() {
        isPlaying = false
        isPaused = false
        current = nil
        elapsed = 0
        origin = nil
    }

    /// Seconds in a `Duration`, for measuring the playhead off the clock.
    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Show a soft 3→2→1 lead-in, then start playing. Used by the now-playing
    /// screen so the player has a beat to get ready before the first matra.
    func performWithCountdown(_ composition: Composition) {
        stop()
        let start = 3
        countdown = start
        countdownTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            for n in stride(from: start, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.countdown = n
                try? await clock.sleep(until: clock.now.advanced(by: .seconds(0.7)),
                                       tolerance: nil)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.countdown = nil
            self.countdownTask = nil
            self.play(composition)
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        task?.cancel()
        task = nil
        countdown = nil
        silenceAllChannels()
        isPlaying = false
        isPaused = false
        elapsed = 0
        origin = nil
        current = nil
    }

    // MARK: Sound bank

    private func loadSoundIfNeeded() {
        guard !soundLoaded else { return }
        soundLoaded = true
        loadInstrumentSound()
        // Real bols: bundled tabla.sf2 (CC0 mmiron pack). Dry strokes sit on
        // fixed keys; the ringing dayan has a wide zone so playing Sa tunes it.
        if let sf2 = Bundle.main.url(forResource: "tabla", withExtension: "sf2") {
            try? tablaSampler.loadSoundBankInstrument(at: sf2, program: 0,
                                                      bankMSB: 0x79, bankLSB: 0)
        } else {
            // Fallback: GM Melodic Tom so the theka still ticks.
            let dls = URL(fileURLWithPath:
                "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
            try? tablaSampler.loadSoundBankInstrument(at: dls, program: 117,
                                                      bankMSB: 0x79, bankLSB: 0)
        }
    }

    /// Swap the live sampler to the current `instrument`. No-op until the bank
    /// is first loaded (the initial `loadSoundIfNeeded` picks it up).
    func reloadInstrument() {
        guard soundLoaded else { return }
        loadInstrumentSound()
    }

    /// Load the current instrument's samples into the sampler — a bundled
    /// SoundFont for the VSCO voices, else the system GM bank. Melodic bank
    /// select is MSB 0x79, LSB 0x00 in both cases; bundled SoundFonts carry a
    /// single preset at program 0.
    private func loadInstrumentSound() {
        let melodicMSB: UInt8 = 0x79
        switch instrument.sound {
        case .gm(let program):
            let dls = URL(fileURLWithPath:
                "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
            try? sampler.loadSoundBankInstrument(at: dls, program: program,
                                                 bankMSB: melodicMSB, bankLSB: 0)
        case .soundFont(let resource):
            guard let url = Bundle.main.url(forResource: resource, withExtension: "sf2") else { return }
            try? sampler.loadSoundBankInstrument(at: url, program: 0,
                                                 bankMSB: melodicMSB, bankLSB: 0)
        }
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
