import SwiftUI

/// Sign in with an email and a one-time code. No password: the server emails a six-digit code to an
/// address on its list, and the code is good for 30 minutes, once.
struct LoginView: View {
    let session: AuthSession

    private enum Step { case email, code }
    private enum Field { case email, code }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
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
        .onAppear { focus = .email }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text("A Manuscript for Riyaz")
                .font(Theme.ui(10)).tracking(3).textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 18)

            PanchamStackedLockup(markSize: 84)

            Rectangle().fill(Theme.ink).frame(width: 40, height: 1).padding(.vertical, 22)

            switch step {
            case .email: emailStep
            case .code: codeStep
            }

            if !error.isEmpty {
                Text(error)
                    .font(Theme.ui(11)).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
            } else if !notice.isEmpty {
                Text(notice)
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    .padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.init(top: 52, leading: 56, bottom: 44, trailing: 56))
        .background(Theme.paper)
        .overlay(alignment: .top) { PaperTopRule().frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.14), radius: 50, y: 16)
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in to continue")
                .font(Theme.display(15)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).padding(.bottom, 24)
            fieldLabel("Your email")
            TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(Theme.muted.opacity(0.7)))
                .textFieldStyle(.plain)
                .textContentType(.emailAddress)
                .font(Theme.ui(15)).foregroundStyle(Theme.ink)
                .focused($focus, equals: .email)
                .disabled(busy)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) }
                .onSubmit(sendCode)
            Text("We'll email you a six-digit code. There's no password.")
                .font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.top, 10)
            primaryButton(busy ? "Sending…" : "Send me a code", enabled: canSend, action: sendCode)
                .padding(.top, 26)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Check your email")
                .font(Theme.display(15)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).padding(.bottom, 6)
            Text("We sent a code to \(cleanEmail).")
                .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).padding(.bottom, 24)
            fieldLabel("Six-digit code")
            TextField("", text: $code, prompt: Text("000000").foregroundStyle(Theme.muted.opacity(0.5)))
                .textFieldStyle(.plain)
                .font(Theme.mono(24, weight: .medium)).tracking(8).foregroundStyle(Theme.ink)
                .focused($focus, equals: .code)
                .disabled(busy)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) }
                .onSubmit(verify)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    if digits.count == 6 { verify() }
                }
            primaryButton(busy ? "Checking…" : "Sign in", enabled: code.count == 6 && !busy, action: verify)
                .padding(.top, 26)
            HStack {
                Button("Use a different email") { back() }
                Spacer()
                Button("Send a new code") { sendCode() }.disabled(busy)
            }
            .buttonStyle(.plain)
            .font(Theme.ui(11)).foregroundStyle(Theme.muted)
            .padding(.top, 16)
        }
    }

    // MARK: Pieces

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Theme.ui(10)).tracking(2.5).textCase(.uppercase)
            .foregroundStyle(Theme.muted).padding(.bottom, 2)
    }

    private func primaryButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Spacer()
                Text(label).tracking(2.5)
                Text("  →")
                Spacer()
            }
            .font(Theme.ui(12, weight: .medium))
            .foregroundStyle(Theme.paper)
            .textCase(.uppercase)
            .padding(.vertical, 13).padding(.horizontal, 20)
            .background(enabled ? Theme.ink : Theme.ink.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Actions

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var canSend: Bool { cleanEmail.contains("@") && cleanEmail.contains(".") && !busy }

    private func sendCode() {
        guard canSend || step == .code, !busy else { return }
        run {
            try await session.requestCode(email: cleanEmail)
            code = ""
            step = .code
            notice = "Sent. It can take a minute to arrive."
            focus = .code
        }
    }

    private func verify() {
        guard code.count == 6, !busy else { return }
        run {
            try await session.verify(email: cleanEmail, code: code)
            // RootView notices `session.account` and moves on.
        } onFailure: {
            code = ""
            focus = .code
        }
    }

    private func back() {
        step = .email
        code = ""
        error = ""
        notice = ""
        focus = .email
    }

    private func run(_ work: @escaping () async throws -> Void, onFailure: @escaping () -> Void = {}) {
        busy = true
        error = ""
        notice = ""
        Task {
            do { try await work() }
            catch {
                self.error = error.localizedDescription
                onFailure()
            }
            busy = false
        }
    }

}
