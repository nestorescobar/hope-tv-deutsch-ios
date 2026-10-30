import SwiftUI

/// The Account tab (awe#6563): "Sign in" when signed out, the member name and "Sign out" when
/// signed in. Sign in opens the code screen full screen; Back closes it and stops the polling.
struct AccountView: View {
    @Environment(MemberAccount.self) private var account
    @Environment(WatchProgressStore.self) private var progress
    @Environment(SavedItemList.self) private var watchLater
    @Environment(Likes.self) private var likes
    @Environment(\.appTheme) private var theme
    @State private var signingIn = false
    @State private var signingOut = false
    /// Continue on the confirm screen closed the cover: the device history import runs.
    @State private var continuedSignIn = false

    var body: some View {
        VStack(spacing: 20) {
            Text(ChromeText.string(.account))
                .font(.system(size: Layout.text(52), weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if let session = account.session {
                Text(ChromeText.string(.signedInAs, ["name": session.name]))
                    .font(.system(size: Layout.text(32)))
                    .foregroundStyle(theme.textPrimary)
                // Under `optIn` without consent: one line, no toggle, no link (decision 11).
                if let site = account.watchHistoryHint {
                    Text(ChromeText.string(.watchHistoryHint, ["site": site]))
                        .font(.system(size: Layout.text(28)))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("account-watch-history-hint")
                }
                Button(ChromeText.string(.signOut)) {
                    signingOut = true
                    Task {
                        await account.signOut()
                        signingOut = false
                    }
                }
                .font(.system(size: Layout.text(30), weight: .semibold))
                .disabled(signingOut)
                .accessibilityIdentifier("account-sign-out")
            } else {
                Text(ChromeText.string(.signInPrompt))
                    .font(.system(size: Layout.text(32)))
                    .foregroundStyle(theme.textSecondary)
                Button(ChromeText.string(.signIn)) { signingIn = true }
                    .font(.system(size: Layout.text(30), weight: .semibold))
                    .accessibilityIdentifier("account-sign-in")
            }
        }
        .multilineTextAlignment(.center)
        .buttonStyle(ActionButtonStyle())
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        // The code and confirm screen closed signed in (Continue, or Back from the confirm
        // screen): load the server copy, so Keep watching and Resume read it (awe#6564). Continue
        // imports the device history first (awe#6565); the task runs behind the Account tab.
        .fullScreenCover(isPresented: $signingIn, onDismiss: {
            let continued = continuedSignIn
            continuedSignIn = false
            guard account.session != nil else { return }
            Task { await account.signInCoverClosed(continued: continued, progress: progress) }
            // The Watch later list, by the same rule (awe#6869): Continue imports the device list.
            Task { await watchLater.signInCoverClosed(continued: continued) }
            // And the likes (awe#6871). The import sends no Umami event.
            Task { await likes.list.signInCoverClosed(continued: continued) }
        }) {
            SignInView(account: account, onContinue: { continuedSignIn = true })
                .environment(\.appTheme, theme)
        }
        // The hint line, each time the tab shows signed in (and after a new sign-in).
        .task(id: account.session?.token) {
            await account.loadSettings()
        }
        #if DEBUG
        .task {
            guard DebugMemberSignIn.opensSignIn, !DebugMemberSignIn.openedSignIn, account.session == nil else { return }
            DebugMemberSignIn.openedSignIn = true
            signingIn = true
        }
        #endif
    }
}

/// The code screen, then the confirm screen. One `SignInFlow` per cover; its loop runs in this
/// view's `.task`, so it ends when the cover closes.
struct SignInView: View {
    let account: MemberAccount
    /// Continue on the confirm screen, before the cover closes.
    let onContinue: () -> Void

    @State private var flow: SignInFlow
    /// "Get a new code" bumps it, which restarts the task with a new grant.
    @State private var attempt = 0
    @State private var signingOut = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    init(account: MemberAccount, onContinue: @escaping () -> Void) {
        self.account = account
        self.onContinue = onContinue
        _flow = State(initialValue: SignInFlow(service: account.service, account: account))
    }

    var body: some View {
        content
            .buttonStyle(ActionButtonStyle())
            .padding(Layout.screenMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .overlay(alignment: .topLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .accessibilityLabel(ChromeText.string(.remove))
                .accessibilityIdentifier("sign-in-close")
            }
            .task(id: attempt) { await flow.run() }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .starting:
            ProgressView()
                .controlSize(.large)
                .tint(theme.accent)
        case let .code(grant):
            CodePanel(grant: grant)
        case .expired:
            retry(ChromeText.string(.signInExpired))
        case .failed:
            retry(ChromeText.string(.signInFailed))
        case .unavailable:
            message(ChromeText.string(.signInUnavailable), detail: ChromeText.string(.pressBackToReturn))
        case let .approved(session):
            VStack(spacing: 24) {
                Text(ChromeText.string(.signedInAs, ["name": session.name]))
                    .font(.system(size: Layout.text(52), weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    // Continue confirms the account: the device history import runs after the
                    // cover closes (awe#6565). Off while Sign out runs: a refused account gets no import.
                    Button(ChromeText.string(.signInContinue)) {
                        onContinue()
                        dismiss()
                    }
                    .disabled(signingOut)
                    .accessibilityIdentifier("sign-in-continue")
                    Button(ChromeText.string(.signOut)) {
                        signingOut = true
                        Task {
                            await account.signOut()
                            dismiss()
                        }
                    }
                    .disabled(signingOut)
                    .accessibilityIdentifier("sign-in-sign-out")
                }
                .font(.system(size: Layout.text(30), weight: .semibold))
            }
        }
    }

    private func message(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: Layout.text(52), weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: Layout.text(28)))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func retry(_ title: String) -> some View {
        VStack(spacing: 24) {
            message(title)
            Button(ChromeText.string(.signInNewCode)) { attempt += 1 }
                .font(.system(size: Layout.text(30), weight: .semibold))
                .accessibilityIdentifier("sign-in-new-code")
        }
    }
}

/// The approval link, then the code and the address for another device. tvOS draws a QR here, but
/// a phone cannot scan its own screen: the link opens `verificationUriComplete`, which holds the
/// code, in the browser. `SignInFlow` keeps polling, so the viewer returns to a signed-in app.
/// Close leaves the screen: a phone has no Back button under a cover.
private struct CodePanel: View {
    let grant: SignInGrant

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ChromeText.string(.signIn))
                .font(.system(size: Layout.text(52), weight: .bold))
                .foregroundStyle(theme.textPrimary)
            // `MemberClient` refuses a grant whose URIs are not https.
            Link(destination: grant.verificationURIComplete) {
                Label(ChromeText.string(.signIn), systemImage: "safari")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
            .accessibilityIdentifier("sign-in-link")
            Text(ChromeText.string(.signInVisit, ["url": typedAddress]))
                .font(.system(size: Layout.text(32)))
                .foregroundStyle(theme.textSecondary)
            Text(grant.signInCode)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .tracking(2)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("sign-in-code")
            HStack(spacing: 20) {
                ProgressView()
                Text(ChromeText.string(.signInWaiting))
                    .font(.system(size: Layout.text(28)))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// The address without `https://`, so it is shorter to type. A browser adds it back.
    private var typedAddress: String {
        let text = grant.verificationURI.absoluteString
        return text.hasPrefix("https://") ? String(text.dropFirst("https://".count)) : text
    }
}
