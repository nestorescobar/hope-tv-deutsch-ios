import Foundation

/// Progress reports for one signed-in play of an episode or a movie (awe#6564, decision 10).
///
/// One report at most every `interval` seconds while playing, plus one on pause, on exit and on
/// the end (`ended: true`). A failed report is dropped; the next one replaces it. No outbox, no
/// retry. The answer decides where the progress lives:
///
/// - `recorded: true`: the account's server copy, never the device store. The item's
///   device-only entries go (ruled 2026-10-13).
/// - `recorded: false`: the device store, marked device-only.
/// - no session when the report was queued (signed out earlier in the play): the device store,
///   as signed out.
/// - a 401, or a session that ended or changed after it was queued: dropped, never written to
///   the device.
///
/// Reports go out one at a time, in order: each waits for the one before it. So a report still in
/// flight can never land after the end and put a finished item back in the copy.
@MainActor
final class MemberProgressReporter {
    static let interval: TimeInterval = 10
    /// A report below this position (periodic, pause or exit) is not sent until one report at or
    /// above it went out: buffering, or Back while it buffers, must not create a near-0 row. The
    /// end always reports. Mirrors `MIN_RESUME_SECONDS` in `packages/utils/src/media-library.ts`;
    /// keep both equal.
    static let minResumeSeconds: Double = 10

    private let request: PlaybackRequest
    private let item: WatchHistoryItem
    private let account: MemberAccount
    private let progress: WatchProgressStore
    private let now: () -> Date
    /// The first periodic report goes `interval` after the start, not at position 0.
    private var lastSent: Date
    private var ended = false
    private var exited = false
    /// True once a report at or above `minResumeSeconds` went out.
    private var gateOpen = false
    /// The last report, which the next one waits for.
    private var last: Task<Void, Never>?

    /// nil when the play stays device-local: signed out, no progress kept, or no episode or movie id.
    init?(request: PlaybackRequest, account: MemberAccount, progress: WatchProgressStore, now: @escaping () -> Date = Date.init) {
        guard request.recordsProgress, account.session != nil,
              let item = request.metadata.historyItem, ContractValidator.isObjectId(item.itemId) else { return nil }
        self.request = request
        self.item = item
        self.account = account
        self.progress = progress
        self.now = now
        lastSent = now()
    }

    /// The player's periodic time callback. Sends when `interval` has passed since the last report
    /// and the position passes the minimum gate.
    @discardableResult
    func tick(position: Double, duration: Double?) -> Task<Void, Never>? {
        guard !ended, !exited, now().timeIntervalSince(lastSent) >= Self.interval, worthSending(position) else { return nil }
        return send(position: position, duration: duration, ended: false)
    }

    @discardableResult
    func paused(position: Double, duration: Double?) -> Task<Void, Never>? {
        guard !ended, !exited, worthSending(position) else { return nil }
        return send(position: position, duration: duration, ended: false)
    }

    /// The player closes. Once only; nothing after the end, which already reported.
    @discardableResult
    func exited(position: Double, duration: Double?) -> Task<Void, Never>? {
        guard !ended, !exited else { return nil }
        exited = true
        guard worthSending(position) else { return nil }
        return send(position: position, duration: duration, ended: false)
    }

    /// A report below `minResumeSeconds` waits until one report at or above it went out: before
    /// that there is no row to update. The end is exempt.
    private func worthSending(_ position: Double) -> Bool {
        gateOpen || position >= Self.minResumeSeconds
    }

    @discardableResult
    func ended(duration: Double?) -> Task<Void, Never>? {
        guard !ended, !exited else { return nil }
        ended = true
        return send(position: duration ?? 0, duration: duration, ended: true)
    }

    private func send(position: Double, duration: Double?, ended: Bool) -> Task<Void, Never> {
        let sentAt = now()
        lastSent = sentAt
        // The session it was queued under: a report that runs after a sign-out must not read the
        // signed-out state of that later moment (R1).
        let token = account.session?.token
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let position = max(0, duration.map { min(position, $0) } ?? position)
        if position >= Self.minResumeSeconds {
            gateOpen = true
        }
        let fraction = duration.map { position / $0 }
        let entry = WatchProgressStore.Entry(
            playableId: item.playableId,
            showId: request.metadata.showId,
            episodeId: item.itemType == .episode ? item.itemId : nil,
            movieId: item.itemType == .movie ? item.itemId : nil,
            title: request.title,
            subtitle: request.metadata.showName ?? "",
            imageURL: request.metadata.artworkURL,
            fraction: fraction ?? 0,
            duration: duration,
            updatedAt: sentAt
        )
        let report = ProgressReport(position: position, duration: duration, ended: ended)
        let previous = last
        let task = Task { [account, progress, request, item] in
            await previous?.value
            let outcome = await account.report(entry, report: report, token: token)
            if outcome == .recorded {
                // The server copy now holds the item, and it wins: no stale device-only copy.
                progress.removeDeviceOnly(playableId: request.progressId, item: item)
                return
            }
            // A device write needs a fraction, as the signed-out writer does.
            guard let fraction else { return }
            switch outcome {
            case .notRecorded:
                Self.record(fraction, entry: entry, request: request, in: progress, deviceOnly: true)
            case .noSession:
                Self.record(fraction, entry: entry, request: request, in: progress, deviceOnly: false)
            case .recorded, .dropped:
                break
            }
        }
        last = task
        return task
    }

    private static func record(_ fraction: Double, entry: WatchProgressStore.Entry, request: PlaybackRequest,
                               in progress: WatchProgressStore, deviceOnly: Bool) {
        progress.record(fraction, for: request.progressId, title: entry.title, subtitle: entry.subtitle, imageURL: entry.imageURL,
                        showId: entry.showId, episodeId: entry.episodeId, movieId: entry.movieId, duration: entry.duration,
                        deviceOnly: deviceOnly)
    }
}
