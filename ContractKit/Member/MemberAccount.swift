// cspell:ignore uniquing
import Foundation
import Observation

/// The member signed in on this TV, or none (awe#6563). The Account tab reads it.
///
/// It also holds the member's server copy of watch history (awe#6564): in memory only, never
/// `UserDefaults`, `ContractCache` or disk. Sign-out and a 401 from any member route clear it.
@MainActor
@Observable
final class MemberAccount {
    private(set) var session: MemberSession?
    /// The server copy by item: unfinished episodes and movies only. Empty when signed out.
    private(set) var history: [WatchHistoryItem: WatchProgressStore.Entry] = [:]
    /// `watchHistoryHint.site` from `GET /member/settings`: watch history is off for this member
    /// under `optIn`. nil draws no hint line.
    private(set) var watchHistoryHint: String?

    @ObservationIgnored let service: MemberService
    /// A `var` only so `debugSignIn` can swap in a memory store.
    @ObservationIgnored private var store: SessionStoring
    /// The session whose device history import started (awe#6565): one import per sign-in.
    @ObservationIgnored private var importedToken: String?

    /// The server refuses an import of more than 100 entries as a whole (422 `TOO_MANY`).
    static let importLimit = 100

    /// What happened to one progress report.
    enum ReportOutcome: Equatable {
        /// `recorded: true`: the server copy holds it.
        case recorded
        /// `recorded: false`: the caller keeps it on the device.
        case notRecorded
        /// No session when the report started: the caller writes it as signed out.
        case noSession
        /// A transport or server failure, a 401, or a session change while the call ran:
        /// dropped, never retried and never written to the device.
        case dropped
    }

    /// Reads the stored session. An expired one is signed out and its item removed.
    init(service: MemberService, store: SessionStoring, now: () -> Date = Date.init) {
        self.service = service
        self.store = store
        if let stored = store.load() {
            if stored.expires > now() {
                session = stored
            } else {
                store.delete()
            }
        }
    }

    #if DEBUG
    /// `-member-session <name>`: a fake session for this launch only, never saved.
    /// The real store (the Keychain) is swapped for a memory store first, so a sign-out or the
    /// 401 that follows the fake token deletes nothing on disk.
    func debugSignIn(name: String) {
        store = DebugMemoryStore()
        session = MemberSession(token: "debug-member-session", expires: Date().addingTimeInterval(86_400), name: name)
    }
    #endif

    /// Loads the server copy: at launch with a session, after sign-in, on return to the foreground.
    /// A failure other than a 401 keeps the copy it has.
    func loadHistory() async {
        guard let token = session?.token else { return }
        let result = await service.watchHistory(token: token)
        // Signed out (or signed in again) while the call ran: the answer is not this session's.
        guard session?.token == token else { return }
        switch result {
        case let .success(entries):
            history = Dictionary(entries.compactMap { entry in entry.historyItem.map { ($0, entry) } },
                                 uniquingKeysWith: { first, second in first.updatedAt >= second.updatedAt ? first : second })
        case .failure(.signedOut):
            endSession()
        case .failure:
            break
        }
    }

    /// The sign-in cover closed signed in (awe#6565, decision 17). Continue imports the device
    /// history first, then the server copy loads, so it holds the imported rows. Back from the
    /// confirm screen only loads the server copy.
    func signInCoverClosed(continued: Bool, progress: WatchProgressStore) async {
        guard session != nil else { return }
        if continued {
            await importDeviceHistory(from: progress)
        }
        await loadHistory()
    }

    /// The one-time import of device history (decision 16), once per sign-in: a second call for
    /// the same session sends nothing, and a failure is not retried until the next sign-in.
    /// No entry to send: no call, nothing cleared. After a 2xx the device copy goes, except the
    /// refused items (`WatchProgressStore.finishImport`). A failure leaves it untouched; a 401
    /// signs out on this TV.
    func importDeviceHistory(from progress: WatchProgressStore) async {
        guard let token = session?.token, importedToken != token else { return }
        importedToken = token
        let snapshot = progress.savedAt
        let entries = progress.importEntries(limit: Self.importLimit)
        guard !entries.isEmpty else { return }
        let result = await service.importHistory(token: token, entries: entries)
        // Signed out (or signed in again) while the call ran: the answer is not this session's.
        guard session?.token == token else { return }
        switch result {
        case let .success(refused):
            progress.finishImport(refused: refused, snapshot: snapshot)
        case .failure(.signedOut):
            endSession()
        case .failure:
            break
        }
    }

    /// Reads the `optIn` hint line for the Account tab.
    func loadSettings() async {
        guard let token = session?.token else { return }
        let result = await service.settings(token: token)
        guard session?.token == token else { return }
        switch result {
        case let .success(site):
            watchHistoryHint = site
        case .failure(.signedOut):
            endSession()
        case .failure:
            break
        }
    }

    /// Sends one progress report for `entry.historyItem`. `recorded: true` puts `entry` in the server
    /// copy (an ended report removes it: the item is finished).
    ///
    /// `token` is the session the report was queued under, read when the reporter queued it, not
    /// when it runs. nil: no session then, so `.noSession`. A session that ended or changed since
    /// then: `.dropped`, with no call.
    func report(_ entry: WatchProgressStore.Entry, report: ProgressReport, token: String?) async -> ReportOutcome {
        guard let token, let item = entry.historyItem else { return .noSession }
        guard session?.token == token else { return .dropped }
        let result = await service.reportProgress(token: token, item: item, report: report)
        // Signed out, or another member signed in, while the call ran: the answer belongs to no
        // one on this TV now. It must not become a signed-out device entry (decision 5).
        guard session?.token == token else { return .dropped }
        switch result {
        case .success(true):
            if report.ended {
                history[item] = nil
            } else {
                history[item] = entry
            }
            return .recorded
        case .success(false):
            return .notRecorded
        case .failure(.signedOut):
            endSession()
            return .dropped
        case .failure:
            return .dropped
        }
    }

    /// The poll answered `approved`. The session goes to the Keychain before the confirm screen
    /// shows. A failed save keeps it for this launch only.
    func signedIn(_ session: MemberSession) {
        do {
            try store.save(session)
        } catch {
            #if DEBUG
            NSLog("[tv] member: the Keychain refused the session: %@", "\(error)")
            #endif
        }
        self.session = session
    }

    /// Revokes the session on the server, then deletes the Keychain item whatever the answer.
    func signOut() async {
        if let token = session?.token {
            _ = await service.signOut(token: token)
        }
        endSession()
    }

    /// Another member route answered 401 for `token` (a saved list, awe#6869): sign out on this
    /// TV only, as above. A newer session stays.
    func sessionRejected(token: String) {
        guard session?.token == token else { return }
        endSession()
    }

    /// Signs out on this TV only: a 401 means the server already dropped the session, so no
    /// DELETE. The Keychain item, the server copy and the hint go.
    private func endSession() {
        store.delete()
        session = nil
        history = [:]
        watchHistoryHint = nil
    }
}

/// Time for the poll loop, so a test can drive it.
struct SignInClock {
    let now: @MainActor () -> Date
    let sleep: @MainActor (TimeInterval) async throws -> Void

    static let live = SignInClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// One code screen: start a grant, then poll until it is approved or runs out.
///
/// The loop runs in the screen's `.task`, so it ends when the screen goes away. It polls every
/// `interval` seconds; `slow_down` (and a 429) adds 5 s. `expired`, or the local `expiresIn`
/// deadline, stops it and offers a new code. A 404 stops it as unavailable. Any other failure keeps
/// it polling until the deadline.
@MainActor
@Observable
final class SignInFlow {
    enum Phase: Equatable {
        case starting
        case code(SignInGrant)
        case expired
        /// 404 at start: sign-in is off for this App.
        case unavailable
        case failed
        case approved(MemberSession)
    }

    private(set) var phase: Phase = .starting

    @ObservationIgnored private let service: MemberService
    @ObservationIgnored private let account: MemberAccount
    @ObservationIgnored private let clock: SignInClock

    static let slowDownStep: TimeInterval = 5

    init(service: MemberService, account: MemberAccount, clock: SignInClock = .live) {
        self.service = service
        self.account = account
        self.clock = clock
    }

    func run() async {
        phase = .starting
        let grant: SignInGrant
        switch await service.startSignIn() {
        case let .success(value):
            grant = value
        case .failure(.unavailable):
            phase = .unavailable
            return
        case .failure:
            phase = .failed
            return
        }
        phase = .code(grant)

        let deadline = clock.now().addingTimeInterval(grant.expiresIn)
        // Below 1 s reads as the RFC 8628 default, so a bad value never makes a tight loop.
        var interval = grant.interval >= 1 ? grant.interval : SignInGrant.defaultInterval
        while true {
            let remaining = deadline.timeIntervalSince(clock.now())
            guard remaining > 0 else {
                phase = .expired
                return
            }
            do {
                try await clock.sleep(min(interval, remaining))
            } catch {
                return // The screen went away.
            }
            guard !Task.isCancelled else { return }
            guard clock.now() < deadline else {
                phase = .expired
                return
            }
            // The poll runs in an unstructured task, so Back does not cancel the request in flight.
            // The server may already have spent the grant and minted the session; an approval must
            // still be read and stored.
            let service = service
            let secret = grant.pollingSecret
            switch await Task(operation: { await service.poll(secret: secret) }).value {
            case let .success(.approved(session)):
                account.signedIn(session)
                phase = .approved(session)
                return
            case .success(.expired):
                phase = .expired
                return
            case .failure(.unavailable):
                // 404: sign-in was turned off for this App. Polling on cannot succeed.
                phase = .unavailable
                return
            case .success(.slowDown), .failure(.rateLimited):
                interval += SignInFlow.slowDownStep
            case .success(.pending), .success(.unsupported), .failure:
                break
            }
            // The screen went away during the poll: send no further poll.
            guard !Task.isCancelled else { return }
        }
    }
}
