import SwiftUI

struct SectionView: View {
    @Bindable var section: CompositionSection
    let sectionIndex: Int
    let taal: TaalID
    let isRenderMode: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    let onAddNotation: () -> Void
    let onAddLyric: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Section")
                    .font(Theme.ui(10, weight: .regular))
                    .tracking(2.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)

                TextField("स्थायी", text: $section.name)
                    .textFieldStyle(.plain)
                    .font(Theme.deva(20, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                    .disabled(isRenderMode)

                Rectangle().fill(Theme.ruleFaint).frame(height: 1)

                if !isRenderMode && canRemove {
                    Button(action: onRemove) {
                        Text("Remove")
                            .font(Theme.ui(10))
                            .tracking(1.5)
                            .textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1)
                    )
                }
            }

            NotationGridView(
                section: section,
                sectionIndex: sectionIndex,
                taal: taal,
                isRenderMode: isRenderMode
            )

            if !isRenderMode {
                HStack(spacing: 8) {
                    Spacer()
                    Button("+ Notation row", action: onAddNotation)
                        .buttonStyle(SmallDashedButtonStyle())
                    Button("+ Lyric row", action: onAddLyric)
                        .buttonStyle(SmallDashedButtonStyle())
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }
}

struct SmallDashedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.ruleFaint)
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
