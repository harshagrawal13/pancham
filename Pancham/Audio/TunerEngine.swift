import Foundation
import AVFoundation
import QuartzCore

/// The audio brain of the tanpura / riyaz screen. One `AVAudioEngine` does two
/// jobs at once: it drones a tanpura through an `AVAudioUnitSampler`, and it taps
/// the microphone to detect the fundamental you're singing (YIN) so the tuner
/// can show how close you are to a swara.
///
/// Pitch is expressed relative to Sa: the detected frequency becomes a MIDI
/// float, we subtract Sa's MIDI, round to the nearest semitone (a swara), and the
/// remainder is the cents you're sharp/flat. A confidence + loudness gate keeps
/// silence and noise from jittering the readout.
///
/// The drone assumes headphones — the tanpura's own sound would otherwise bleed
/// into the mic and fight the detector.
@MainActor
@Observable
final class TunerEngine {

    // MARK: Tuning / drone settings

    /// MIDI note for Sa. Default 57 (A3) — a comfortable centre for many voices.
    /// The picker moves this; the drone and the whole ladder follow.
    var saMidi: Int = 57 {
        didSet { if isDroning { restartDrone() } }
    }
    /// Drone's melodic string: Pa (default) or Ma, the two classic tanpura tunings.
    var useMa: Bool = false {
        didSet { if isDroning { restartDrone() } }
    }
    /// Tanpura loudness, 0…1.
    var droneVolume: Double = 0.7 {
        didSet { droneMix.outputVolume = Float(max(0, min(1, droneVolume))) }
    }

    // MARK: Live state (published to the view)

    var isDroning = false
    var isListening = false
    /// Mic permission resolved to granted. `false` until the user allows it.
    var micAuthorized = false
    /// Set when the mic is denied, so the view can explain how to enable it.
    var micDenied = false

    /// Latest detected frequency in Hz, or `nil` when nothing confident is sung.
    var pitchHz: Double?
    /// Detected pitch as a continuous MIDI value (69 + 12·log2(hz/440)).
    var midiFloat: Double?
    /// Nearest swara as a semitone offset from Sa (can be negative / >11 across
    /// octaves). `nil` when no confident pitch.
    var nearestSemitone: Int?
    /// Cents away from that nearest swara, −50…+50.
    var cents: Double = 0
    /// True while a confident pitch is being tracked.
    var confident: Bool { midiFloat != nil }

    // MARK: Hold target

    /// A swara (semitone offset from Sa) the user tapped to practise holding.
    var targetSemitone: Int?
    /// Seconds the current pitch has stayed within `inTuneCents` of the target.
    var holdSeconds: Double = 0
    /// Whether the current pitch sits inside the in-tune window of the target.
    var onTarget = false
    /// Half-width of the "in tune" window, in cents.
    static let inTuneCents: Double = 12

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    /// One pluck sample, four strings. Each string is its own player→varispeed
    /// chain so up to four plucks ring at once (the tanpura's shimmer), and each
    /// chain is pitched independently to its string's exact frequency.
    private let players = (0..<4).map { _ in AVAudioPlayerNode() }
    private let varispeeds = (0..<4).map { _ in AVAudioUnitVarispeed() }
    private let droneMix = AVAudioMixerNode()
    private var droneBuffer: AVAudioPCMBuffer?
    private var graphBuilt = false
    private var droneTask: Task<Void, Never>?

    /// True once a mic tap is installed, so we don't double-install.
    private var tapInstalled = false
    /// Wall-clock of the last pitch frame, for integrating the hold timer.
    private var lastFrameTime: CFTimeInterval?

    /// Measured fundamental of the bundled `tanpura.wav` (C#3). Playback rate is
    /// `targetHz / nativeHz`, so the drone is tuned to equal temperament exactly
    /// — it can't drift against the tuner's own Sa reference.
    private static let nativeHz: Double = 138.307

    // MARK: - Lifecycle

    /// Ask for the mic (once) and start both listening and the drone. Safe to
    /// call repeatedly; it just ensures everything is running.
    func begin() {
        Task { @MainActor in
            let ok = await Self.ensureMicPermission()
            micAuthorized = ok
            micDenied = !ok
            buildGraphIfNeeded()
            if ok { startListening() }
            startDrone()
        }
    }

    /// Tear everything down when the screen closes.
    func end() {
        stopDrone()
        stopListening()
        if engine.isRunning { engine.stop() }
        resetPitch()
    }

    // MARK: - Mic permission

    private static func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Graph

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }
        graphBuilt = true
        loadBuffer()
        let fmt = droneBuffer?.format
        engine.attach(droneMix)
        engine.connect(droneMix, to: engine.mainMixerNode, format: nil)
        for i in players.indices {
            engine.attach(players[i])
            engine.attach(varispeeds[i])
            engine.connect(players[i], to: varispeeds[i], format: fmt)
            engine.connect(varispeeds[i], to: droneMix, format: fmt)
        }
        droneMix.outputVolume = Float(droneVolume)
    }

    /// Read the bundled `tanpura.wav` (one plucked C#3) into a buffer we can
    /// re-trigger cheaply on every string.
    private func loadBuffer() {
        guard droneBuffer == nil,
              let url = Bundle.main.url(forResource: "tanpura", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return }
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try? file.read(into: buf)
        droneBuffer = buf
    }

    private func midiToHz(_ midi: Int) -> Double { 440 * pow(2, (Double(midi) - 69) / 12) }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    // MARK: - Drone

    /// The four tanpura strings as semitone offsets from Sa, in pluck order:
    /// first string (Pa or Ma, an octave down), Sa, Sa, mandra Sa.
    private var droneOffsets: [Int] {
        let first = useMa ? -7 : -5      // mandra Ma (5−12) or mandra Pa (7−12)
        return [first, 0, 0, -12]
    }

    /// Set each string's varispeed so it sounds its exact target frequency.
    private func applyRates() {
        let offsets = droneOffsets
        for i in players.indices {
            let hz = midiToHz(saMidi + offsets[i])
            varispeeds[i].rate = Float(min(max(hz / Self.nativeHz, 0.25), 4))
        }
    }

    func startDrone() {
        guard droneBuffer != nil || Bundle.main.url(forResource: "tanpura", withExtension: "wav") != nil else { return }
        guard !isDroning else { restartDrone(); return }
        buildGraphIfNeeded()
        guard droneBuffer != nil else { return }
        ensureEngineRunning()
        isDroning = true
        applyRates()
        runDroneLoop()
    }

    func stopDrone() {
        droneTask?.cancel()
        droneTask = nil
        for p in players { p.stop() }
        isDroning = false
    }

    func toggleDrone() { isDroning ? stopDrone() : startDrone() }

    /// Retune in place (Sa or Pa/Ma changed) and restart the pluck cycle cleanly.
    private func restartDrone() {
        guard isDroning else { return }
        droneTask?.cancel()
        for p in players { p.stop() }
        applyRates()
        runDroneLoop()
    }

    /// Pluck the strings in turn, letting each ring, looping forever. Each string
    /// keeps its own player (and rate), re-triggered one full cycle later, so the
    /// drone keeps a steady four-string shimmer.
    private func runDroneLoop() {
        guard let buffer = droneBuffer else { return }
        let interval: Duration = .milliseconds(560)
        let clock = ContinuousClock()
        droneTask = Task { @MainActor [weak self] in
            var next = clock.now
            var idx = 0
            while !Task.isCancelled {
                guard let self else { return }
                let p = self.players[idx % self.players.count]
                p.stop()
                p.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                p.play()
                idx += 1
                next = next.advanced(by: interval)
                try? await clock.sleep(until: next, tolerance: nil)
            }
        }
    }

    // MARK: - Listening (mic tap + YIN)

    func startListening() {
        guard micAuthorized, !isListening else { return }
        buildGraphIfNeeded()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let sampleRate = format.sampleRate
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let result = Self.analyze(buffer: buffer, sampleRate: sampleRate)
                Task { @MainActor [weak self] in self?.apply(result) }
            }
            tapInstalled = true
        }
        ensureEngineRunning()
        isListening = true
    }

    func stopListening() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isListening = false
        resetPitch()
    }

    private func resetPitch() {
        pitchHz = nil
        midiFloat = nil
        nearestSemitone = nil
        cents = 0
        onTarget = false
        holdSeconds = 0
        lastFrameTime = nil
    }

    /// Fold one analysis frame into the published state and integrate the hold
    /// timer against the target.
    private func apply(_ hz: Double?) {
        let now = CACurrentMediaTime()
        defer { lastFrameTime = now }

        guard let hz, hz > 0 else {
            pitchHz = nil; midiFloat = nil; nearestSemitone = nil; cents = 0
            onTarget = false; holdSeconds = 0
            return
        }
        let midi = 69 + 12 * log2(hz / 440)
        let fromSa = midi - Double(saMidi)
        let nearest = Int(fromSa.rounded())
        let centsOff = (fromSa - Double(nearest)) * 100

        pitchHz = hz
        midiFloat = midi
        nearestSemitone = nearest
        cents = centsOff

        if let target = targetSemitone {
            // Distance to the target swara in cents (handles octave too).
            let targetCents = (fromSa - Double(target)) * 100
            let hit = abs(targetCents) <= Self.inTuneCents
            onTarget = hit
            if hit, let last = lastFrameTime {
                holdSeconds += max(0, now - last)
            } else if !hit {
                holdSeconds = 0
            }
        } else {
            onTarget = false
            holdSeconds = 0
        }
    }

    // MARK: - Target

    func setTarget(_ semitone: Int?) {
        targetSemitone = semitone
        holdSeconds = 0
        onTarget = false
    }

    // MARK: - YIN pitch detection
    //
    // Classic YIN (de Cheveigné & Kawahara 2002): difference function → cumulative
    // mean normalized difference → absolute threshold → parabolic interpolation.
    // Tuned for the singing range (~70–1100 Hz). A loudness gate rejects silence;
    // an aperiodicity gate rejects unpitched noise.

    private nonisolated static let minHz: Double = 70
    private nonisolated static let maxHz: Double = 1100
    private nonisolated static let yinThreshold: Float = 0.15
    private nonisolated static let rmsGate: Float = 0.010

    /// Run YIN over a mic buffer (mono, uses channel 0). Returns a frequency in
    /// Hz, or `nil` if the frame is too quiet or too noisy to call a pitch.
    nonisolated static func analyze(buffer: AVAudioPCMBuffer, sampleRate: Double) -> Double? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        guard n >= 1024 else { return nil }

        // Loudness gate.
        var sumSq: Float = 0
        for i in 0..<n { sumSq += channel[i] * channel[i] }
        let rms = (sumSq / Float(n)).squareRoot()
        if rms < rmsGate { return nil }

        let maxTau = min(n / 2, Int(sampleRate / minHz))
        let minTau = max(2, Int(sampleRate / maxHz))
        guard maxTau > minTau + 2 else { return nil }

        // Difference function d(tau).
        var diff = [Float](repeating: 0, count: maxTau)
        for tau in 1..<maxTau {
            var sum: Float = 0
            var j = 0
            let limit = n - tau
            while j < limit {
                let delta = channel[j] - channel[j + tau]
                sum += delta * delta
                j += 1
            }
            diff[tau] = sum
        }

        // Cumulative mean normalized difference d'(tau).
        var cmnd = [Float](repeating: 1, count: maxTau)
        var running: Float = 0
        for tau in 1..<maxTau {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }

        // Absolute threshold: first dip below threshold, then walk to its local min.
        var tauEstimate = -1
        var tau = minTau
        while tau < maxTau {
            if cmnd[tau] < yinThreshold {
                while tau + 1 < maxTau && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        // No dip cleared the threshold → take the global minimum in range instead,
        // but only trust it if reasonably periodic.
        if tauEstimate == -1 {
            var best = minTau
            for t in (minTau + 1)..<maxTau where cmnd[t] < cmnd[best] { best = t }
            if cmnd[best] > 0.55 { return nil }   // too aperiodic to call
            tauEstimate = best
        }

        // Parabolic interpolation around the estimate for sub-sample precision.
        let betterTau: Double
        if tauEstimate > 0 && tauEstimate < maxTau - 1 {
            let s0 = Double(cmnd[tauEstimate - 1])
            let s1 = Double(cmnd[tauEstimate])
            let s2 = Double(cmnd[tauEstimate + 1])
            let denom = 2 * (2 * s1 - s2 - s0)
            betterTau = denom != 0 ? Double(tauEstimate) + (s2 - s0) / denom : Double(tauEstimate)
        } else {
            betterTau = Double(tauEstimate)
        }
        guard betterTau > 0 else { return nil }
        let hz = sampleRate / betterTau
        guard hz >= minHz && hz <= maxHz else { return nil }
        return hz
    }
}

// MARK: - Swara model for the ladder

/// A swara identified by its semitone offset from Sa. Renders the Devanagari
/// glyph (with komal underline / tivra tick handled by the view) and the roman
/// short-form used on the ladder.
struct Swara: Identifiable, Hashable {
    /// Semitone offset from Sa, absolute across octaves.
    let semitone: Int
    var id: Int { semitone }

    /// 0…11 pitch class within the octave.
    var pitchClass: Int { ((semitone % 12) + 12) % 12 }
    /// Octave register relative to Sa: 0 = madhya, −1 = mandra, +1 = taar.
    var octave: Int { Int(floor(Double(semitone) / 12.0)) }

    var isKomal: Bool { [1, 3, 8, 10].contains(pitchClass) }
    var isTivra: Bool { pitchClass == 6 }

    /// Roman short-form: uppercase shuddh, lowercase komal, `M'` tivra.
    var roman: String {
        let names = ["S", "r", "R", "g", "G", "M", "M", "P", "d", "D", "n", "N"]
        return pitchClass == 6 ? "M'" : names[pitchClass]
    }

    /// Devanagari glyph (no octave dots — position on the ladder encodes octave).
    var glyph: String {
        let g = ["सा", "रे", "रे", "ग", "ग", "म", "म", "प", "ध", "ध", "नि", "नि"]
        return g[pitchClass]
    }

    static let names12 = (0..<12).map { Swara(semitone: $0).roman }
}
