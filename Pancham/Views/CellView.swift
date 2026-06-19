import SwiftUI

struct CellLocation: Hashable {
    let section: Int
    let line: Int
    let cell: Int
}

/// Single grid cell.
///
/// The `TextField` is always mounted while editing; we lay an opaque rendered
/// overlay on top when the cell is unfocused and non-empty. Tapping the
/// overlay sets `focused = true`, which both grants focus to the already-live
/// TextField *and* hides the overlay — no mount race, no flash of raw DSL.
struct CellView: View {
    @Bindable var cell: CellBox
    let type: LineType
    let isRenderMode: Bool
    let location: CellLocation
    let onAdvance: (CellLocation) -> Void

    @FocusState private var focused: Bool
    @Environment(PlaybackEngine.self) private var playback: PlaybackEngine?

    private var isPlayingHere: Bool { playback?.current == location }

    var body: some View {
        Group {
            if isRenderMode {
                renderedReadOnly
            } else {
                editableCell
            }
        }
        .frame(minHeight: 42)
        .clipped()   // keep the focused TextField from bleeding over neighbours
        // Translucent wash sits above the (opaque) rendered overlay so the
        // playback cursor shows in both edit and render modes.
        .overlay {
            if isPlayingHere {
                Theme.accent.opacity(0.16).allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.08), value: isPlayingHere)
    }

    // MARK: Edit mode

    private var editableCell: some View {
        ZStack {
            TextField("", text: $cell.text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(type == .notation ? Theme.mono(12) : Theme.deva(14))
                .foregroundStyle(type == .notation ? Theme.ink : Theme.muted)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit {
                    focused = false
                    onAdvance(location)
                }

            if showRendered {
                renderedOverlay
            }
        }
    }

    private var showRendered: Bool {
        !focused && !cell.text.isEmpty && cell.text.first != " "
    }

    private var renderedOverlay: some View {
        Group {
            if type == .notation {
                RenderedCell(raw: cell.text)
            } else {
                Text(cell.text)
                    .font(Theme.deva(14))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.gridBg)  // opaque — hides the TextField beneath
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    // MARK: Render mode (read-only)

    @ViewBuilder
    private var renderedReadOnly: some View {
        if type == .notation {
            RenderedCell(raw: cell.text)
        } else {
            Text(cell.text)
                .font(Theme.deva(14))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
