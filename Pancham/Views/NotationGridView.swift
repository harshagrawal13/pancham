import SwiftUI

struct NotationGridView: View {
    let section: CompositionSection
    let sectionIndex: Int
    let taal: TaalID
    let isRenderMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Taal markers row
            HStack(spacing: 0) {
                ForEach(0..<taal.matras, id: \.self) { i in
                    let marker = i < taal.markers.count ? taal.markers[i] : ""
                    Text(marker.isEmpty ? "·" : marker)
                        .font(Theme.deva(12, weight: .medium))
                        .foregroundStyle(marker.isEmpty ? .clear : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .overlay(dividerTrailing(i: i))
                }
            }
            .background(Theme.taalBg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.ink).frame(height: 1)
            }

            // Matra numbers row
            HStack(spacing: 0) {
                ForEach(0..<taal.matras, id: \.self) { i in
                    Text("\(i + 1)")
                        .font(Theme.ui(9, weight: .regular))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .overlay(dividerTrailing(i: i))
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.ink).frame(height: 1)
            }

            // Lines
            ForEach(Array(section.lines.enumerated()), id: \.element.id) { li, line in
                LineRow(
                    line: line,
                    lineIndex: li,
                    sectionIndex: sectionIndex,
                    taal: taal,
                    isRenderMode: isRenderMode,
                    isLast: li == section.lines.count - 1
                )
            }
        }
        .background(Theme.gridBg)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1))
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
    let line: Line
    let lineIndex: Int
    let sectionIndex: Int
    let taal: TaalID
    let isRenderMode: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(line.cells.enumerated()), id: \.element.id) { ci, box in
                CellView(
                    cell: box,
                    type: line.type,
                    isRenderMode: isRenderMode,
                    location: CellLocation(section: sectionIndex, line: lineIndex, cell: ci),
                    onAdvance: { _ in }
                )
                .frame(maxWidth: .infinity, minHeight: 42)
                .overlay(dividerTrailing(i: ci))
            }
        }
        .background(line.type == .lyric ? Theme.lyricBg : .clear)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Theme.gridRule).frame(height: 1)
            }
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
