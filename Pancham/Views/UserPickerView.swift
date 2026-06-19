import SwiftUI

/// Shown on launch when there's at least one saved user but no active one.
/// Lists existing users as buttons plus an "Add new →" option.
struct UserPickerView: View {
    @Bindable var prefs: Preferences
    let onAddNew: () -> Void

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            // Corner marks
            VStack {
                HStack {
                    Text("Pancham · पंचम")
                    Spacer()
                    Text("Bhātkhaṇḍe Notation")
                }
                .font(Theme.ui(10))
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(28)
                Spacer()
            }
            card.frame(width: 460)
        }
        .frame(minWidth: 720, minHeight: 720)
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text("A Manuscript for Riyaz")
                .font(Theme.ui(10))
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 18)

            PanchamStackedLockup(markSize: 84)

            Rectangle().fill(Theme.ink).frame(width: 40, height: 1).padding(.vertical, 22)

            Text("Who's practicing today?")
                .font(Theme.display(15))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 24)

            VStack(spacing: 10) {
                ForEach(prefs.users) { user in
                    userRow(user)
                }
                addNewRow
            }
        }
        .padding(.init(top: 52, leading: 56, bottom: 44, trailing: 56))
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.14), radius: 50, y: 16)
    }

    @ViewBuilder
    private func userRow(_ user: PanchamUser) -> some View {
        Button(action: { prefs.activate(userID: user.id) }) {
            HStack(spacing: 14) {
                // Initial in a small paper-over-ink monogram
                Text(String(user.name.prefix(1)).uppercased())
                    .font(Theme.display(18, weight: .medium))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 36, height: 36)
                    .background(Theme.ink)
                Text(user.name)
                    .font(Theme.display(18, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("→")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1))
        }
        .buttonStyle(PickerRowStyle())
        .contextMenu {
            Button("Remove user", role: .destructive) { prefs.removeUser(user.id) }
        }
    }

    private var addNewRow: some View {
        Button(action: onAddNew) {
            HStack(spacing: 14) {
                Text("+")
                    .font(Theme.display(20, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1))
                Text("Add new")
                    .font(Theme.display(18, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("→")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Theme.ink))
        }
        .buttonStyle(PickerRowStyle())
    }
}

private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.ink.opacity(0.06) : .clear)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
