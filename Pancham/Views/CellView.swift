import SwiftUI

struct CellLocation: Hashable {
    let section: Int
    let line: Int
    let cell: Int
}

/// Which cell is currently being edited, shared across the whole grid via the
/// environment. This is the key to editor performance: only ONE `TextField`
/// (an NSTextField under the hood) is ever mounted — every other cell is cheap
/// static text. Hundreds of always-live text fields was the lag source.
@Observable
final class EditorFocus {
    var editing: CellLocation?
}

/// Single grid cell. Static rendered text until tapped, then a `TextField`.
struct CellView: View {
    @Bindable var cell: CellBox
    let type: LineType
    let isRenderMode: Bool
    let location: CellLocation
    /// Number of cells in this line, for Tab/Return advance.
    let lineLength: Int

    @Environment(EditorFocus.self) private var focus
    @FocusState private var fieldFocused: Bool

    private var isEditing: Bool { focus.editing == location }

    var body: some View {
        Group {
            if !isRenderMode && isEditing {
                editingField
            } else {
                rendered
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { if !isRenderMode { focus.editing = location } }
            }
        }
        .frame(minHeight: 42)
        .clipped()
    }

    private var editingField: some View {
        TextField("", text: $cell.text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(type == .notation ? Theme.mono(12) : Theme.deva(14))
            .foregroundStyle(type == .notation ? Theme.ink : Theme.muted)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }
            .onSubmit(advance)
            .onExitCommand { focus.editing = nil }
    }

    @ViewBuilder
    private var rendered: some View {
        if cell.text.isEmpty {
            Color.clear
        } else if type == .notation {
            RenderedCell(raw: cell.text)
        } else {
            Text(cell.text)
                .font(Theme.deva(14))
                .foregroundStyle(Theme.muted)
        }
    }

    private func advance() {
        if location.cell + 1 < lineLength {
            focus.editing = CellLocation(section: location.section,
                                         line: location.line,
                                         cell: location.cell + 1)
        } else {
            focus.editing = nil
        }
    }
}
