import SwiftUI

/// Full-window "riyaz" screen: a tanpura drone plus a live vocal tuner. A dark
/// focus stage (deliberately off-brand from the cream editor) so the glowing
/// pitch line reads clearly while you sing. Pick where Sa sits, drone Pa or Ma,
/// and watch a line ride a vertical ladder of swaras — it turns green and the
/// nearest swara glows when you land in tune. Tap a swara to hold it and a timer
/// counts how long you stay there.
struct TanpuraView: View {
    @Bindable var tuner: TunerEngine
    let onClose: () -> Void

    // Dark-stage palette (local — this screen owns its own look).
    private let bgTop     = Color(hex: 0x1B1518)
    private let bgBottom  = Color(hex: 0x0C090B)
    private let rung      = Color.white.opacity(0.07)
    private let rungSa    = Color.white.opacity(0.16)
    private let idleLabel = Color.white.opacity(0.42)
    private let liveLabel = Color(hex: 0xF3E9D8)
    private let gold      = Color(hex: 0xE0B15A)
    private let green     = Color(hex: 0x63D08A)

    /// Ladder spans mandra Sa … taar Sa (two octaves around Sa).
    private let lo = -12
    private let hi = 12

    private var rungs: [Swara] { (lo...hi).map { Swara(semitone: $0) } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { tuner.begin() }
        .onDisappear { tuner.end() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("Tanpura")
                    .font(Theme.display(24, weight: .medium))
                    .foregroundStyle(liveLabel)
                Text("तानपुरा · रियाज़")
                    .font(Theme.deva(15))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            scaleControls
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    /// Sa pitch, Pa/Ma drone, and the drone on/off + volume.
    private var scaleControls: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Text("SA").font(Theme.ui(10, weight: .semibold)).tracking(2)
                    .foregroundStyle(Color.white.opacity(0.4))
                Stepper(value: $tuner.saMidi, in: 45...72) {
                    Text(Self.noteName(tuner.saMidi))
                        .font(Theme.mono(14, weight: .medium))
                        .foregroundStyle(liveLabel)
                        .frame(minWidth: 44)
                }
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
                .foregroundStyle(tuner.isDroning ? bgBottom : liveLabel)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tuner.isDroning ? gold : Color.white.opacity(0.09))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 6)
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
                        .fill(sw.pitchClass == 0 ? rungSa : rung)
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
                            .shadow(color: color.opacity(0.8), radius: 8)
                        Circle()
                            .fill(color)
                            .frame(width: 13, height: 13)
                            .shadow(color: color.opacity(0.9), radius: 10)
                            .overlay(Circle().stroke(bgBottom, lineWidth: 2))
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
                .foregroundStyle(inTune ? green : (active ? liveLabel : idleLabel))
                .komalUnderline(sw.isKomal, color: inTune ? green : (active ? liveLabel : idleLabel))
            Text(sw.glyph)
                .font(Theme.deva(active ? 18 : 14))
                .foregroundStyle(inTune ? green : (active ? liveLabel.opacity(0.9) : idleLabel.opacity(0.8)))
            octaveDots(sw.octave)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.white.opacity(0.06) : .clear)
        )
        .scaleEffect(active ? 1.06 : 1, anchor: .leading)
        .animation(.easeOut(duration: 0.12), value: active)
    }

    private func octaveDots(_ octave: Int) -> some View {
        Group {
            if octave < 0 {
                Circle().fill(idleLabel).frame(width: 3, height: 3).offset(y: 5)
            } else if octave > 0 {
                Circle().fill(idleLabel).frame(width: 3, height: 3).offset(y: -5)
            }
        }
        .frame(width: 5)
    }

    // MARK: Side panel — readout + hold

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            readout
            Divider().overlay(Color.white.opacity(0.1))
            holdPanel
            Spacer()
            hint
        }
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOU'RE SINGING")
                .font(Theme.ui(10, weight: .semibold)).tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.35))

            if tuner.confident, let semis = tuner.nearestSemitone {
                let sw = Swara(semitone: semis)
                let inTune = abs(tuner.cents) <= TunerEngine.inTuneCents
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sw.glyph)
                        .font(Theme.deva(56, weight: .medium))
                        .foregroundStyle(inTune ? green : liveLabel)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sw.roman)
                            .font(Theme.mono(20, weight: .semibold))
                            .foregroundStyle(inTune ? green : liveLabel)
                            .komalUnderline(sw.isKomal, color: inTune ? green : liveLabel)
                        Text(centsText)
                            .font(Theme.mono(13))
                            .foregroundStyle(inTune ? green : gold)
                    }
                }
                centsBar(inTune: inTune)
                if let hz = tuner.pitchHz {
                    Text(String(format: "%.1f Hz", hz))
                        .font(Theme.mono(11)).foregroundStyle(Color.white.opacity(0.3))
                }
            } else {
                Text("—")
                    .font(Theme.deva(56, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.2))
                Text(tuner.micDenied ? "Microphone access denied" : "Sing a note")
                    .font(Theme.display(14, italic: true))
                    .foregroundStyle(Color.white.opacity(0.4))
                if tuner.micDenied {
                    Text("Enable it in System Settings ▸ Privacy ▸ Microphone.")
                        .font(Theme.ui(11)).foregroundStyle(Color.white.opacity(0.3))
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
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                Rectangle().fill(green.opacity(0.5))
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
                .foregroundStyle(Color.white.opacity(0.35))

            if let target = tuner.targetSemitone {
                let sw = Swara(semitone: target)
                HStack(spacing: 8) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(gold)
                    Text("Target \(sw.roman)")
                        .font(Theme.mono(15, weight: .medium)).foregroundStyle(liveLabel)
                    Text(sw.glyph).font(Theme.deva(16)).foregroundStyle(liveLabel.opacity(0.85))
                }
                Text(tuner.onTarget
                     ? String(format: "held %.1fs", tuner.holdSeconds)
                     : "sing it and hold steady")
                    .font(Theme.mono(13))
                    .foregroundStyle(tuner.onTarget ? green : Color.white.opacity(0.4))
                holdBar
                // Tap gesture, not Button — this panel rebuilds at pitch rate.
                Text("Clear target")
                    .font(Theme.ui(11)).foregroundStyle(gold.opacity(0.9))
                    .contentShape(Rectangle())
                    .onTapGesture { tuner.setTarget(nil) }
            } else {
                Text("Tap a swara on the ladder to hold it.")
                    .font(Theme.display(13, italic: true))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fills up as you hold; a 4-second hold reads as a full bar.
    private var holdBar: some View {
        GeometryReader { g in
            let frac = min(tuner.holdSeconds / 4.0, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
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
            .foregroundStyle(Color.white.opacity(0.28))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func noteName(_ midi: Int) -> String {
        "\(noteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
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
