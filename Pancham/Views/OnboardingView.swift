import SwiftUI
import AppKit

/// Add-new-user screen. Creates a user record and activates them.
struct OnboardingView: View {
    @Bindable var prefs: Preferences
    let onComplete: () -> Void
    let onCancel: (() -> Void)?

    @State private var name: String = ""
    @State private var folder: URL?
    @State private var error: String = ""

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack {
                HStack {
                    Text("Pancham · पंचम")
                    Spacer()
                    Text("Bhātkhaṇḍe Notation")
                }
                .font(Theme.ui(10)).tracking(3).textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(28)
                Spacer()
            }

            card.frame(width: 480)

            // Back link when there's an existing user list behind us
            if let onCancel {
                VStack {
                    HStack {
                        Button(action: onCancel) {
                            HStack(spacing: 4) {
                                Text("←")
                                Text("Back")
                            }
                            .font(Theme.ui(11))
                            .tracking(1.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 28)
                        .padding(.top, 56)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 720)
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text("A Manuscript for Riyaz")
                .font(Theme.ui(10)).tracking(3).textCase(.uppercase)
                .foregroundStyle(Theme.muted).padding(.bottom, 18)

            PanchamStackedLockup(markSize: 84)

            Rectangle().fill(Theme.ink).frame(width: 40, height: 1).padding(.vertical, 22)

            Text("Write Hindustani classical notations in the Bhatkhande system — a quiet, typeset home for your bandishes.")
                .font(Theme.display(15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 340)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your name")
                    .font(Theme.ui(10)).tracking(2).textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.ink).frame(height: 1)
                    }
            }
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 8) {
                Text("Library folder")
                    .font(Theme.ui(10)).tracking(2).textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 12) {
                    Text(folder?.path ?? "Choose a folder to store your notations…")
                        .font(Theme.display(14))
                        .foregroundStyle(folder == nil ? Theme.muted : Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: pickFolder)
                        .buttonStyle(OutlineButtonStyle())
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.ink).frame(height: 1)
                }
            }

            if !error.isEmpty {
                Text(error)
                    .font(Theme.ui(11)).foregroundStyle(Theme.danger)
                    .padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: begin) {
                HStack(spacing: 0) {
                    Spacer()
                    Text("Begin Riyaz").tracking(2.5)
                    Text("  →")
                    Spacer()
                }
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(Theme.paper)
                .textCase(.uppercase)
                .padding(.vertical, 13)
                .padding(.horizontal, 20)
                .background(canBegin ? Theme.ink : Theme.ink.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canBegin)
            .padding(.top, 28)
        }
        .padding(.init(top: 52, leading: 56, bottom: 44, trailing: 56))
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.14), radius: 50, y: 16)
    }

    private var canBegin: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && folder != nil
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library Folder"
        panel.message = "Pick a folder where your .pancham files will live."
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            error = ""
        }
    }

    private func begin() {
        guard let folder, canBegin else { return }
        if prefs.addUser(name: name, folder: folder) {
            onComplete()
        } else {
            error = "Could not save user."
        }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(11, weight: .medium))
            .tracking(1.5).textCase(.uppercase)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
