import SwiftUI

struct NotesView: View {
    @Bindable var composition: Composition
    let isRenderMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.ruleFaint).frame(height: 1)
                .padding(.bottom, 14)
            TextEditor(text: $composition.notes)
                .font(Theme.display(14))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .frame(minHeight: 64)
                .padding(10)
                .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
                .disabled(isRenderMode)
        }
        .padding(.top, 32)
    }
}
