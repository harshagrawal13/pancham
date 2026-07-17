import SwiftUI

/// Full-window "riyaz" screen: a continuous tanpura drone plus a live vocal
/// tuner, in the app's cream paper look. Pick where Sa sits (shown plainly as
/// note name + harmonium key + Hz), drone Pa or Ma, and watch a line ride a
/// vertical ladder of swaras — green when you land in tune. Tap a swara to
/// hold it against a timer. Start a session and, when you end it, get a
/// per-swara report and a time-agnostic score (the fraction of your sung time
/// that was in tune).
struct TanpuraView: View {
    @Bindable var tuner: TunerEngine
    let onClose: () -> Void

    @State private var summary: RiyazSummary?

    // In-tune / off-pitch accents tuned for the light paper background.
    private let green = Color(hex: 0x2E7D46)
    private let gold  = Color(hex: 0xA9762A)

    /// Ladder spans mandra Sa … taar Sa (two octaves around Sa).
    private let lo = -12
    private let hi = 12

    private var rungs: [Swara] { (lo...hi).map { Swara(semitone: $0) } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.paper, Theme.canvas],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    ladder
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    sidePanel
                        .frame(width: 300)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 28)
                }
            }

            if let summary {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture {}   // block taps behind the card
                SummaryCard(summary: summary, green: green) {
                    self.summary = nil
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: summary != nil)
        .onAppear { tuner.begin() }
        .onDisappear { tuner.end() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("Tanpura")
                    .font(Theme.display(24, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("तानपुरा · रियाज़")
                    .font(Theme.deva(15))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            scaleControls
            sessionButton
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.ink.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }

    /// Sa pitch (spelled out: note, harmonium key, Hz), Pa/Ma, drone toggle.
    private var scaleControls: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("SA = \(Self.noteName(tuner.saMidi)) · \(Self.harmoniumKey(tuner.saMidi))")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(String(format: "%.1f Hz", Self.hz(tuner.saMidi)))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                }
                Stepper("", value: $tuner.saMidi, in: 45...72)
                    .labelsHidden()
            }

            Picker("", selection: $tuner.useMa) {
                Text("Pa").tag(false)
                Text("Ma").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)

            Button(action: tuner.toggleDrone) {
                HStack(spacing: 6) {
                    Image(systemName: tuner.isDroning ? "waveform" : "play.fill")
                    Text(tuner.isDroning ? "Drone on" : "Drone")
                }
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(tuner.isDroning ? Theme.paper : Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tuner.isDroning ? Theme.ink : Theme.ink.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 6)
    }

    private var sessionButton: some View {
        Button {
            if tuner.sessionActive {
                summary = tuner.endSession()
            } else {
                tuner.startSession()
            }
        } label: {
            HStack(spacing: 6) {
                if tuner.sessionActive {
                    Circle().fill(Theme.danger).frame(width: 7, height: 7)
                    Text("End session")
                } else {
                    Text("Start session")
                }
            }
            .font(Theme.ui(12, weight: .medium))
            .foregroundStyle(tuner.sessionActive ? Theme.danger : Theme.paper)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(tuner.sessionActive ? Theme.danger.opacity(0.1) : Theme.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(tuner.sessionActive ? Theme.danger.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Ladder

    private var ladder: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = Double(hi - lo)
            let labelX: CGFloat = 118
            let y: (Double) -> CGFloat = { semis in
                CGFloat((Double(hi) - semis) / span) * h
            }

            ZStack(alignment: .topLeading) {
                // Rungs + tappable swara labels.
                ForEach(rungs) { sw in
                    let yy = y(Double(sw.semitone))
                    let isNearest = tuner.nearestSemitone == sw.semitone && tuner.confident
                    let isTarget = tuner.targetSemitone == sw.semitone
                    let inTune = isNearest && abs(tuner.cents) <= TunerEngine.inTuneCents

                    // rung line
                    Rectangle()
                        .fill(Theme.ink.opacity(sw.pitchClass == 0 ? 0.22 : 0.08))
                        .frame(height: sw.pitchClass == 0 ? 1.5 : 1)
                        .frame(maxWidth: .infinity)
                        .position(x: geo.size.width / 2, y: yy)

                    // A plain tap gesture, not a Button: these labels are
                    // rebuilt ~20×/s while singing, and clicking a SwiftUI
                    // Button mid-invalidation crashed in gesture dispatch.
                    rungLabel(sw, active: isNearest, inTune: inTune, target: isTarget)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tuner.setTarget(isTarget ? nil : sw.semitone)
                        }
                        .position(x: labelX / 2 + 12, y: yy)
                }

                // Live pitch line.
                if let midi = tuner.midiFloat {
                    let semis = midi - Double(tuner.saMidi)
                    let clamped = min(max(semis, Double(lo)), Double(hi))
                    let yy = y(clamped)
                    let inTune = abs(tuner.cents) <= TunerEngine.inTuneCents
                    let color = inTune ? green : gold

                    ZStack(alignment: .trailing) {
                        Rectangle()
                            .fill(color)
                            .frame(height: 2.5)
                            .shadow(color: color.opacity(0.45), radius: 6)
                        Circle()
                            .fill(color)
                            .frame(width: 13, height: 13)
                            .shadow(color: color.opacity(0.5), radius: 7)
                            .overlay(Circle().stroke(Theme.paper, lineWidth: 2))
                            .offset(x: 6)
                    }
                    .frame(maxWidth: .infinity)
                    .position(x: geo.size.width / 2, y: yy)
                    .animation(.interpolatingSpring(stiffness: 220, damping: 22), value: yy)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
    }

    private func rungLabel(_ sw: Swara, active: Bool, inTune: Bool, target: Bool) -> some View {
        HStack(spacing: 8) {
            if target {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(gold)
            }
            Text(sw.roman)
                .font(Theme.mono(active ? 17 : 13, weight: active ? .bold : .regular))
                .foregroundStyle(inTune ? green : (active ? Theme.ink : Theme.muted))
                .komalUnderline(sw.isKomal, color: inTune ? green : (active ? Theme.ink : Theme.muted))
            Text(sw.glyph)
                .font(Theme.deva(active ? 18 : 14))
                .foregroundStyle(inTune ? green : (active ? Theme.ink.opacity(0.9) : Theme.muted.opacity(0.8)))
            octaveDots(sw.octave)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Theme.ink.opacity(0.05) : .clear)
        )
        .scaleEffect(active ? 1.06 : 1, anchor: .leading)
        .animation(.easeOut(duration: 0.12), value: active)
    }

    private func octaveDots(_ octave: Int) -> some View {
        Group {
            if octave < 0 {
                Circle().fill(Theme.muted).frame(width: 3, height: 3).offset(y: 5)
            } else if octave > 0 {
                Circle().fill(Theme.muted).frame(width: 3, height: 3).offset(y: -5)
            }
        }
        .frame(width: 5)
    }

    // MARK: Side panel — readout + hold

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            readout
            Divider().overlay(Theme.ruleFaint)
            holdPanel
            Spacer()
            hint
        }
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOU'RE SINGING")
                .font(Theme.ui(10, weight: .semibold)).tracking(2.5)
                .foregroundStyle(Theme.muted)

            if tuner.confident, let semis = tuner.nearestSemitone {
                let sw = Swara(semitone: semis)
                let inTune = abs(tuner.cents) <= TunerEngine.inTuneCents
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sw.glyph)
                        .font(Theme.deva(56, weight: .medium))
                        .foregroundStyle(inTune ? green : Theme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sw.roman)
                            .font(Theme.mono(20, weight: .semibold))
                            .foregroundStyle(inTune ? green : Theme.ink)
                            .komalUnderline(sw.isKomal, color: inTune ? green : Theme.ink)
                        Text(centsText)
                            .font(Theme.mono(13))
                            .foregroundStyle(inTune ? green : gold)
                    }
                }
                centsBar(inTune: inTune)
                if let hz = tuner.pitchHz {
                    Text(String(format: "%.1f Hz", hz))
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted.opacity(0.7))
                }
            } else {
                Text("—")
                    .font(Theme.deva(56, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.15))
                Text(tuner.micDenied ? "Microphone access denied" : "Sing a note")
                    .font(Theme.display(14, italic: true))
                    .foregroundStyle(Theme.muted)
                if tuner.micDenied {
                    Text("Enable it in System Settings ▸ Privacy ▸ Microphone.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var centsText: String {
        let c = Int(tuner.cents.rounded())
        if abs(c) <= 3 { return "in tune" }
        return c > 0 ? "+\(c)¢ sharp" : "\(c)¢ flat"
    }

    /// A little −50…+50 cents meter with a moving tick.
    private func centsBar(inTune: Bool) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = (min(max(tuner.cents, -50), 50) + 50) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.08)).frame(height: 4)
                Rectangle().fill(green.opacity(0.35))
                    .frame(width: w * CGFloat(TunerEngine.inTuneCents / 50), height: 4)
                    .position(x: w / 2, y: 2)
                Capsule()
                    .fill(inTune ? green : gold)
                    .frame(width: 3, height: 14)
                    .position(x: w * CGFloat(frac), y: 2)
                    .animation(.easeOut(duration: 0.08), value: tuner.cents)
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder private var holdPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOLD")
                .font(Theme.ui(10, weight: .semibold)).tracking(2.5)
                .foregroundStyle(Theme.muted)

            if let target = tuner.targetSemitone {
                let sw = Swara(semitone: target)
                HStack(spacing: 8) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(gold)
                    Text("Target \(sw.roman)")
                        .font(Theme.mono(15, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(sw.glyph).font(Theme.deva(16)).foregroundStyle(Theme.ink.opacity(0.85))
                }
                Text(tuner.onTarget
                     ? String(format: "held %.1fs", tuner.holdSeconds)
                     : "sing it and hold steady")
                    .font(Theme.mono(13))
                    .foregroundStyle(tuner.onTarget ? green : Theme.muted)
                holdBar
                // Tap gesture, not Button — this panel rebuilds at pitch rate.
                Text("Clear target")
                    .font(Theme.ui(11)).foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { tuner.setTarget(nil) }
            } else {
                Text("Tap a swara on the ladder to hold it.")
                    .font(Theme.display(13, italic: true))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fills up as you hold; a 4-second hold reads as a full bar.
    private var holdBar: some View {
        GeometryReader { g in
            let frac = min(tuner.holdSeconds / 4.0, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.08))
                Capsule().fill(green)
                    .frame(width: g.size.width * CGFloat(frac))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.1), value: tuner.holdSeconds)
    }

    private var hint: some View {
        Text("Wear headphones so the drone doesn't leak into the mic.")
            .font(Theme.ui(11))
            .foregroundStyle(Theme.muted.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func noteName(_ midi: Int) -> String {
        "\(noteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    /// Harmonium key name for a pitch class — the white (safed) / black (kali)
    /// numbering singers actually use to name their scale.
    private static let harmoniumKeys = [
        "safed 1", "kali 1", "safed 2", "kali 2", "safed 3", "safed 4",
        "kali 3", "safed 5", "kali 4", "safed 6", "kali 5", "safed 7",
    ]
    static func harmoniumKey(_ midi: Int) -> String {
        harmoniumKeys[((midi % 12) + 12) % 12]
    }

    static func hz(_ midi: Int) -> Double {
        440 * pow(2, (Double(midi) - 69) / 12)
    }
}

// MARK: - Session summary card

/// End-of-session report: the score up top, then a per-swara table — time sung,
/// time in tune, best hold — with shaky (missed) swaras called out.
private struct SummaryCard: View {
    let summary: RiyazSummary
    let green: Color
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSION REPORT")
                .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                .foregroundStyle(Theme.muted).padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("\(summary.score)")
                    .font(Theme.display(56, weight: .medium))
                    .foregroundStyle(scoreColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("out of 100")
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    Text(scoreLine)
                        .font(Theme.display(13, italic: true))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.time(summary.duration))
                        .font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("sung \(Self.time(summary.voicedSeconds)) · in tune \(Self.time(summary.inTuneSeconds))")
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.bottom, 18)

            if summary.stats.isEmpty {
                Text("No singing detected — start the drone, take a breath, and try again.")
                    .font(Theme.display(14, italic: true))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 20)
            } else {
                statTable
                if !summary.shaky.isEmpty {
                    shakyLine.padding(.top, 14)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(.init(top: 26, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 560)
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }

    private var scoreColor: Color {
        summary.score >= 70 ? green : (summary.score >= 40 ? Color(hex: 0xA9762A) : Theme.danger)
    }

    private var scoreLine: String {
        switch summary.score {
        case 85...: return "beautifully steady — the swaras sat true"
        case 70..<85: return "solid riyaz — mostly in tune"
        case 40..<70: return "getting there — keep leaning on the drone"
        default: return "rough today — slow down, one swara at a time"
        }
    }

    private var statTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SWARA").frame(width: 90, alignment: .leading)
                Text("SUNG").frame(width: 70, alignment: .trailing)
                Text("IN TUNE").frame(width: 90, alignment: .trailing)
                Text("BEST HOLD").frame(width: 90, alignment: .trailing)
                Spacer()
            }
            .font(Theme.ui(9, weight: .semibold)).tracking(1.5)
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 6)

            ForEach(summary.stats.prefix(8)) { stat in
                HStack {
                    HStack(spacing: 6) {
                        Text(stat.swara.roman)
                            .font(Theme.mono(13, weight: .medium))
                        Text(stat.swara.glyph)
                            .font(Theme.deva(13))
                        if stat.swara.octave != 0 {
                            Text(stat.swara.octave < 0 ? "mandra" : "taar")
                                .font(Theme.ui(9)).foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(stat.isShaky ? Theme.danger : Theme.ink)
                    .frame(width: 90, alignment: .leading)

                    Text(Self.time(stat.sungSeconds))
                        .frame(width: 70, alignment: .trailing)
                        .foregroundStyle(Theme.ink)
                    Text("\(Int((stat.accuracy * 100).rounded()))%")
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(stat.isShaky ? Theme.danger : (stat.accuracy >= 0.7 ? green : Theme.ink))
                    Text(Self.time(stat.bestHoldSeconds))
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                }
                .font(Theme.mono(12))
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.ruleFaint.opacity(0.5)).frame(height: 0.5)
                }
            }
        }
    }

    private var shakyLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.danger)
            Text("Needs work: " + summary.shaky.map { $0.swara.roman }.joined(separator: ", "))
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(Theme.danger)
        }
    }

    static func time(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
}

/// Komal swaras are drawn with an underline, matching the notation grid.
private extension View {
    @ViewBuilder func komalUnderline(_ on: Bool, color: Color) -> some View {
        if on {
            self.overlay(alignment: .bottom) {
                Rectangle().fill(color).frame(height: 1).offset(y: 2)
            }
        } else {
            self
        }
    }
}
