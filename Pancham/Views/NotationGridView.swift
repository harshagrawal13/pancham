import SwiftUI

/// Width of the line-number column that sits *outside* the grid, to its left.
private let gutterWidth: CGFloat = 48

struct NotationGridView: View {
    let section: CompositionSection
    let sectionIndex: Int
    let taal: TaalID
    let isRenderMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerRow(markers: true)
            headerRow(markers: false)
            ForEach(Array(section.lines.enumerated()), id: \.element.id) { li, line in
                LineRow(
                    line: line,
                    lineIndex: li,
                    sectionIndex: sectionIndex,
                    taal: taal,
                    isRenderMode: isRenderMode,
                    isLast: li == section.lines.count - 1,
                    notationNumber: notationNumber(for: li)
                )
            }
        }
        // The border wraps only the cells; the number gutter is outside, to the left.
        .overlay(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Theme.ink, lineWidth: 1)
                .padding(.leading, gutterWidth)
        }
    }

    /// Taal markers row or matra-numbers row — cells only, gutter left blank.
    @ViewBuilder
    private func headerRow(markers: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth)
            HStack(spacing: 0) {
                ForEach(0..<taal.matras, id: \.self) { i in
                    Group {
                        if markers {
                            Text(i < taal.markers.count ? taal.markers[i] : "")
                                .font(Theme.display(13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                        } else {
                            Text("\(i + 1)")
                                .font(Theme.ui(9))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, markers ? 5 : 3)
                    .overlay(dividerTrailing(i: i))
                }
            }
            .background(markers ? Theme.taalBg : Theme.gridBg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.ink).frame(height: 1)
            }
        }
    }

    /// 1-based position of this line among the section's notation lines, or
    /// `nil` if it's a lyric line (which shares the line above's number).
    private func notationNumber(for li: Int) -> Int? {
        guard section.lines[li].type == .notation else { return nil }
        return section.lines[...li].reduce(0) { $0 + ($1.type == .notation ? 1 : 0) }
    }

    @ViewBuilder
    private func dividerTrailing(i: Int) -> some View {
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

/// One line of cells. Isolating this into its own view stops a cell-level
/// invalidation from propagating up to the section/editor bodies.
private struct LineRow: View {
    @Bindable var line: Line
    let lineIndex: Int
    let sectionIndex: Int
    let taal: TaalID
    let isRenderMode: Bool
    let isLast: Bool
    /// The line's notation number (for the gutter); `nil` for lyric lines.
    let notationNumber: Int?

    var body: some View {
        HStack(spacing: 0) {
            numberGutter
            HStack(spacing: 0) {
                ForEach(Array(line.cells.enumerated()), id: \.element.id) { ci, box in
                    CellView(
                        cell: box,
                        type: line.type,
                        isRenderMode: isRenderMode,
                        location: CellLocation(section: sectionIndex, line: lineIndex, cell: ci),
                        lineLength: line.cells.count
                    )
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .overlay(dividerTrailing(i: ci))
                }
            }
            .background(line.type == .lyric ? Theme.lyricBg : Theme.gridBg)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(Theme.gridRule).frame(height: 1)
                }
            }
        }
    }

    /// Line number / editable annotation, outside the grid. Lyric rows are blank
    /// so the number never sits beside a bol row.
    @ViewBuilder
    private var numberGutter: some View {
        if let notationNumber {
            TextField("\(notationNumber)", text: $line.label)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.muted.opacity(0.6))
                .padding(.trailing, 12)
                .frame(width: gutterWidth)
                .disabled(isRenderMode)
        } else {
            Color.clear.frame(width: gutterWidth)
        }
    }

    @ViewBuilder
    private func dividerTrailing(i: Int) -> some View {
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
