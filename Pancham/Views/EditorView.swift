import SwiftUI

/// The paper page itself — meta header, sections, notes.
struct EditorView: View {
    @Bindable var composition: Composition
    let isRenderMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaHeaderView(composition: composition, isRenderMode: isRenderMode)

            VStack(alignment: .leading, spacing: 32) {
                ForEach(Array(composition.sections.enumerated()), id: \.element.id) { idx, section in
                    SectionView(
                        section: section,
                        sectionIndex: idx,
                        taal: composition.taal,
                        isRenderMode: isRenderMode,
                        canRemove: composition.sections.count > 1,
                        onRemove: { removeSection(id: section.id) },
                        onAddNotation: { addLine(sectionId: section.id, type: .notation) },
                        onAddLyric:    { addLine(sectionId: section.id, type: .lyric) }
                    )
                }
            }
            .padding(.top, 28)

            if !isRenderMode {
                LegendView()
                    .padding(.top, 28)
            }

            NotesView(composition: composition, isRenderMode: isRenderMode)
        }
        .padding(.init(top: 52, leading: 64, bottom: 48, trailing: 64))
        .frame(maxWidth: 860)
        .paperBackground()
    }

    private func removeSection(id: UUID) {
        composition.sections.removeAll { $0.id == id }
        if composition.sections.isEmpty {
            composition.sections = [CompositionSection(matras: composition.matras)]
        }
    }

    private func addLine(sectionId: UUID, type: LineType) {
        guard let i = composition.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let m = composition.matras
        composition.sections[i].lines.append(
            Line(type: type, cells: Array(repeating: "", count: m))
        )
    }
}
