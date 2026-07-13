import SwiftUI

extension VerticalAlignment {
    private struct PrimaryLine: AlignmentID {
        static func defaultValue(in c: ViewDimensions) -> CGFloat {
            c[VerticalAlignment.firstTextBaseline]
        }
    }
    /// Shared baseline used to align the "primary" row across every meta column.
    static let metaPrimary = VerticalAlignment(PrimaryLine.self)
}

struct MetaHeaderView: View {
    @Bindable var composition: Composition
    let isRenderMode: Bool

    private static let folioFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Eyebrow — form picker + raga
            HStack(spacing: 6) {
                if isRenderMode {
                    Text(composition.form.name)
                        .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                } else {
                    Menu {
                        ForEach(CompositionForm.allCases) { f in
                            Button(f.name) { composition.form = f }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(composition.form.name)
                                .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if !composition.raga.isEmpty {
                    Text("· \(composition.raga)")
                        .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(folioLine)
                    .font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 6)

            // Title
            TextField("Composition Title", text: $composition.title)
                .textFieldStyle(.plain)
                .font(Theme.deva(32, weight: .medium))
                .foregroundStyle(Theme.ink)
                .disabled(isRenderMode)

            if !composition.title.isEmpty {
                Text(composition.title)
                    .font(Theme.display(15, italic: true))
                    .foregroundStyle(Theme.muted)
                    .tracking(0.3)
                    .padding(.top, 2)
            }

            // 4-column metadata grid. `metaPrimary` is a custom alignment guide
            // applied to each column's primary value, so Yaman / Teentaal / — / ♩=—
            // sit on the same baseline regardless of subtitle presence or glyph metrics.
            HStack(alignment: .metaPrimary, spacing: 0) {
                ragaCol
                divider
                taalCol
                divider
                layaCol
                divider
                bpmCol
            }
            .padding(.top, 22)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.ruleFaint).frame(height: 1)
                    .padding(.top, 14)
            }
            .padding(.bottom, 22)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
        .padding(.bottom, 28)
    }

    private var folioLine: String {
        "Folio 01 · " + Self.folioFormatter.string(from: Date())
    }

    // MARK: - Columns

    private var ragaCol: some View {
        metaColumn(label: "Rāga", isFirst: true) {
            primaryField(binding: $composition.raga,
                         placeholder: "Yaman",
                         renderFallback: "—")
        } subtitle: {
            EmptyLine()
        }
    }

    private var taalCol: some View {
        metaColumn(label: "Tāl", isFirst: false) {
            if isRenderMode {
                Text(taalPrimaryName)
                    .font(Theme.display(16, weight: .medium))
                    .foregroundStyle(Theme.ink)
            } else {
                Picker("", selection: $composition.taal) {
                    ForEach(TaalID.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(Theme.display(16, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            }
        } subtitle: {
            Text("\(composition.matras) मात्रा")
                .font(Theme.deva(12))
                .foregroundStyle(Theme.muted)
        }
    }

    private var layaCol: some View {
        metaColumn(label: "Laya", isFirst: false) {
            primaryField(binding: $composition.laya,
                         placeholder: "Madhya",
                         renderFallback: "—")
        } subtitle: {
            EmptyLine()
        }
    }

    private var bpmCol: some View {
        metaColumn(label: "Lay", isFirst: false) {
            HStack(spacing: 4) {
                Text("♩ =")
                    .font(Theme.display(16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if isRenderMode {
                    Text(composition.bpm.isEmpty ? "—" : composition.bpm)
                        .font(Theme.display(16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                } else {
                    TextField("80", text: $composition.bpm)
                        .textFieldStyle(.plain)
                        .font(Theme.display(16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 60)
                }
            }
        } subtitle: {
            Text("BPM")
                .font(Theme.ui(9)).tracking(2).textCase(.uppercase)
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - Layout helper

    /// Three-line column. The middle (primary) row carries a `.metaPrimary`
    /// alignment guide so every column's primary lands on the same baseline.
    @ViewBuilder
    private func metaColumn<Primary: View, Subtitle: View>(
        label: String,
        isFirst: Bool,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.ui(9)).tracking(2).textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            primary()
                .alignmentGuide(.metaPrimary) { d in d[VerticalAlignment.firstTextBaseline] }
            subtitle()
        }
        .padding(.leading, isFirst ? 0 : 18)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func primaryField(binding: Binding<String>,
                              placeholder: String,
                              renderFallback: String) -> some View {
        if isRenderMode {
            Text(binding.wrappedValue.isEmpty ? renderFallback : binding.wrappedValue)
                .font(Theme.display(16, weight: .medium))
                .foregroundStyle(Theme.ink)
        } else {
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .font(Theme.display(16, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

    /// Invisible subtitle that reserves a line so every column is the same height.
    private struct EmptyLine: View {
        var body: some View {
            Text(" ")
                .font(Theme.deva(12))
                .foregroundStyle(.clear)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.ruleFaint).frame(width: 1, height: 54)
    }

    private var taalPrimaryName: String {
        switch composition.taal {
        case .teentaal:        return "Teentaal"
        case .teentaal_khali:  return "Teentaal (Khali)"
        case .deepchandi:      return "Deepchandi"
        case .kaharwa:         return "Keherwa"
        }
    }
}
