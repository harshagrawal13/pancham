import SwiftUI

// Layout constants shared by the sticky taal header and the scrolling rows so
// their columns line up exactly.
private let npGutter: CGFloat = 88
private let npContentWidth: CGFloat = 1040
private let npHPadding: CGFloat = 40

// MARK: - Karaoke model

/// One matra column: the note(s) written there and the lyric syllable sung on it.
struct KaraokeCell {
    let note: String
    let syllable: String
}

/// One karaoke line — a notation line plus its paired lyric line (the next
/// `.lyric` line in the same section). Cells are kept full-width (one per
/// matra) so the taal grid and beat are preserved, not collapsed to a phrase.
struct KaraokeLine: Identifiable {
    let id = UUID()
    let section: Int
    /// Index of the source notation line, matched against `CellLocation.line`.
    let notationLine: Int
    let sectionName: String
    let isSectionStart: Bool
    /// Label shown in the gutter — the line's annotation, or its auto number.
    let displayLabel: String
    /// One entry per matra (padded to the taal's matra count).
    let cells: [KaraokeCell]

    /// Walk a composition into karaoke lines, pairing each notation line with
    /// the lyric line that follows it and numbering notation lines per section.
    static func build(_ comp: Composition) -> [KaraokeLine] {
        let matras = comp.matras
        var out: [KaraokeLine] = []
        for (si, section) in comp.sections.enumerated() {
            let lines = section.lines
            var firstInSection = true
            var number = 0
            for (li, line) in lines.enumerated() where line.type == .notation {
                number += 1
                let lyric: Line? = (li + 1 < lines.count && lines[li + 1].type == .lyric)
                    ? lines[li + 1] : nil
                var cells: [KaraokeCell] = []
                for ci in 0..<matras {
                    let note = ci < line.cells.count
                        ? line.cells[ci].text.trimmingCharacters(in: .whitespaces) : ""
                    let syl: String = {
                        guard let lyric, ci < lyric.cells.count else { return "" }
                        return lyric.cells[ci].text.trimmingCharacters(in: .whitespaces)
                    }()
                    cells.append(KaraokeCell(note: note, syllable: syl))
                }
                let label = line.label.isEmpty ? "\(number)" : line.label
                out.append(KaraokeLine(section: si, notationLine: li,
                                       sectionName: section.name,
                                       isSectionStart: firstInSection,
                                       displayLabel: label, cells: cells))
                firstInSection = false
            }
        }
        return out
    }
}

// MARK: - Now Playing screen

/// Full-window "now playing" overlay: the notation scrolls vertically like
/// Apple Music while keeping its taal grid — a sticky beat header up top, one
/// full-width row per line, the active line bright and the rest dimmed, and the
/// current note + syllable highlighted. A 3-2-1 lead-in plays first.
struct NowPlayingView: View {
    let composition: Composition
    @Bindable var playback: PlaybackEngine
    let onClose: () -> Void

    @State private var lines: [KaraokeLine] = []
    @State private var showSettings = false

    private var taal: TaalID { composition.taal }
    private var current: CellLocation? { playback.current }

    private var activeLineID: UUID? {
        guard let cur = current else { return nil }
        return lines.first { $0.section == cur.section && $0.notationLine == cur.line }?.id
    }

    private func activeCell(for line: KaraokeLine) -> Int? {
        guard let cur = current,
              cur.section == line.section, cur.line == line.notationLine else { return nil }
        return cur.cell
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.paper, Theme.canvas],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                taalHeader
                linesScroll
                bottomBar
            }

            if let value = playback.countdown {
                CountdownView(value: value)
            }
        }
        .onAppear {
            lines = KaraokeLine.build(composition)
            if !taal.hasTheka { playback.tablaEnabled = false }
            playback.performWithCountdown(composition)
        }
        .onDisappear { playback.stop() }
    }

    // MARK: Scrolling lines

    private var linesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 120)
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 10) {
                            if line.isSectionStart && !line.sectionName.isEmpty {
                                Text(line.sectionName)
                                    .font(Theme.ui(12)).tracking(2.5).textCase(.uppercase)
                                    .foregroundStyle(Theme.muted)
                                    .padding(.leading, npGutter)
                                    .padding(.top, 14)
                            }
                            KaraokeRowView(line: line, taal: taal,
                                           activeCell: activeCell(for: line))
                        }
                        .frame(maxWidth: npContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, npHPadding)
                        .id(line.id)
                    }
                    Color.clear.frame(height: 360)
                }
            }
            .onChange(of: activeLineID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: Sticky taal header (markers + beat numbers)

    private var taalHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: npGutter)
                ForEach(0..<taal.matras, id: \.self) { i in
                    let marker = i < taal.markers.count ? taal.markers[i] : ""
                    Text(marker.isEmpty ? "·" : marker)
                        .font(Theme.deva(16, weight: .medium))
                        .foregroundStyle(marker.isEmpty ? .clear : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .overlay(GridDivider(i: i, taal: taal))
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: npGutter)
                ForEach(0..<taal.matras, id: \.self) { i in
                    Text("\(i + 1)")
                        .font(Theme.ui(15, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .overlay(GridDivider(i: i, taal: taal))
                }
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: npContentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, npHPadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(alignment: .center) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                    Text("Done")
                }
            }
            .buttonStyle(ToolbarOutlineButton())
            .keyboardShortcut(.cancelAction)

            Spacer()

            VStack(spacing: 2) {
                Text(composition.title.isEmpty ? "Untitled" : composition.title)
                    .font(Theme.display(16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !composition.raga.isEmpty {
                    Text(composition.raga)
                        .font(Theme.ui(10)).tracking(1.8).textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                }
            }

            Spacer()
            Color.clear.frame(width: 70, height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { showSettings.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Settings")
                }
            }
            .buttonStyle(ToolbarOutlineButton())
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                settingsPanel
            }

            Button { playback.tablaEnabled.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "metronome")
                    Text(taal.name)
                }
            }
            .buttonStyle(ToolbarToggleButton(on: playback.tablaEnabled && taal.hasTheka))
            .disabled(!taal.hasTheka)
            .help(taal.hasTheka ? "Play the \(taal.name) theka" : "Theka is available for Teentaal only, for now")

            tempoControl

            Spacer()

            Button { playback.performWithCountdown(composition) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Restart")
                }
            }
            .buttonStyle(ToolbarOutlineButton())

            Button(action: togglePause) {
                HStack(spacing: 5) {
                    Image(systemName: playback.isPaused ? "play.fill" : "pause.fill")
                    Text(playback.isPaused ? "Resume" : "Pause")
                }
            }
            .buttonStyle(ToolbarOutlineButton())
            .keyboardShortcut(.space, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.ruleFaint).frame(height: 1)
        }
    }

    /// Voice, scale (Sa) and the volume / sustain / fade shapers, behind the
    /// Settings button so the transport bar stays uncluttered.
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playback")
                .font(Theme.ui(11)).tracking(2).textCase(.uppercase)
                .foregroundStyle(Theme.muted)

            settingRow("Voice") {
                Menu(playback.instrument.label) {
                    ForEach(PlaybackEngine.Instrument.allCases) { ins in
                        Button(ins.label) { playback.instrument = ins }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            settingRow("Scale (Sa)") {
                Menu(EditorPane.noteName(playback.tonicMidi)) {
                    ForEach(55...67, id: \.self) { m in
                        Button(EditorPane.noteName(m)) { playback.tonicMidi = m }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            settingRow("\(taal.name) theka") {
                Toggle("", isOn: $playback.tablaEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .disabled(!taal.hasTheka)
            }

            Divider()

            sliderRow("Instrument volume", value: $playback.instrumentVolume, range: 0...1)
            sliderRow("Tabla volume", value: $playback.tablaVolume, range: 0...1)
            sliderRow("Sustain", value: $playback.sustain, range: 0...1)
            sliderRow("Fade", value: $playback.fade, range: 0...0.5)

            Text("Sustain rings each note past its beat. Fade swells each note in and out.")
                .font(Theme.ui(10))
                .foregroundStyle(Theme.muted)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 280)
    }

    private func settingRow<Control: View>(_ label: String,
                                           @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(Theme.ui(11)).foregroundStyle(Theme.ink)
            Spacer()
            control()
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.ui(11)).foregroundStyle(Theme.ink)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }

    /// Live tempo: −/+ nudge by 5 BPM and a preset menu. Setting `tempoOverride`
    /// drives the engine's beat-fraction recompile, so the playhead keeps place.
    private var tempoControl: some View {
        HStack(spacing: 6) {
            Button { nudgeTempo(-5) } label: { Image(systemName: "minus") }
                .buttonStyle(ToolbarOutlineButton())
            Menu("\(Int(playback.effectiveBPM(for: composition))) BPM") {
                Button("Score tempo (\(composition.bpm.isEmpty ? "—" : composition.bpm))") {
                    playback.tempoOverride = nil
                }
                Divider()
                ForEach([60, 80, 100, 120, 140, 160, 180, 200], id: \.self) { b in
                    Button("\(b) BPM") { playback.tempoOverride = Double(b) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { nudgeTempo(5) } label: { Image(systemName: "plus") }
                .buttonStyle(ToolbarOutlineButton())
        }
    }

    private func nudgeTempo(_ delta: Double) {
        let cur = playback.effectiveBPM(for: composition)
        playback.tempoOverride = min(300, max(20, cur + delta))
    }

    /// Space-bar / button transport. Resumes if paused, pauses if playing,
    /// and (if a piece has ended) starts it again with the lead-in.
    private func togglePause() {
        if playback.isPaused {
            playback.resume()
        } else if playback.isPlaying {
            playback.pause()
        } else if playback.countdown == nil {
            playback.performWithCountdown(composition)
        }
    }
}

// MARK: - One karaoke line as a grid row

private struct KaraokeRowView: View {
    let line: KaraokeLine
    let taal: TaalID
    /// Active matra column if this line is sounding, else `nil`.
    let activeCell: Int?

    private var isActive: Bool { activeCell != nil }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.displayLabel)
                .font(Theme.ui(11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: npGutter, alignment: .leading)
                .padding(.trailing, 8)

            ForEach(0..<taal.matras, id: \.self) { ci in
                KaraokeCellView(cell: line.cells[ci],
                                active: activeCell == ci,
                                lineActive: isActive)
                    .frame(maxWidth: .infinity)
                    .overlay(GridDivider(i: ci, taal: taal))
            }
        }
        .opacity(isActive ? 1 : 0.32)
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

private struct KaraokeCellView: View {
    let cell: KaraokeCell
    let active: Bool
    let lineActive: Bool

    var body: some View {
        VStack(spacing: 4) {
            noteView
            Text(cell.syllable.isEmpty ? " " : cell.syllable)
                .font(syllableFont)
                .foregroundStyle(active ? Theme.accent : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.vertical, 6)
        .background {
            if active {
                Rectangle().fill(Theme.accent.opacity(0.14))
            }
        }
        .animation(.easeOut(duration: 0.12), value: active)
    }

    @ViewBuilder
    private var noteView: some View {
        let tokens = SwaraParser.parse(cell: cell.note)
        HStack(spacing: 2) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, tok in
                SwaraView(tok: tok, baseSize: 15)
            }
        }
        .frame(height: 24)
        .opacity(cell.note.isEmpty ? 0 : 1)
    }

    private var syllableFont: Font {
        let isDevanagari = cell.syllable.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        let weight: Font.Weight = lineActive ? .semibold : .medium
        return isDevanagari ? Theme.deva(19, weight: weight) : Theme.display(20, weight: weight)
    }
}

/// Trailing vibhag divider for a matra column — heavy at a vibhag boundary,
/// light otherwise, none on the last column (the layout edge handles it).
private struct GridDivider: View {
    let i: Int
    let taal: TaalID

    var body: some View {
        let isLast = i == taal.matras - 1
        let isHeavy = taal.vibhagEndIndices.contains(i)
        if !isLast {
            HStack {
                Spacer()
                Rectangle()
                    .fill(isHeavy ? Theme.ink : Theme.gridRule)
                    .frame(width: 1)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Toggle button (filled when on)

struct ToolbarToggleButton: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12))
            .tracking(0.2)
            .foregroundStyle(on ? Theme.paper : Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(on ? Theme.accent : .clear)
            .overlay(Rectangle().strokeBorder(on ? Theme.accent : Theme.ruleFaint, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Lead-in counter

private struct CountdownView: View {
    let value: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.04).ignoresSafeArea()
            Text("\(value)")
                .font(Theme.display(140, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.9))
                .id(value)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
        }
        .animation(.easeOut(duration: 0.45), value: value)
    }
}
