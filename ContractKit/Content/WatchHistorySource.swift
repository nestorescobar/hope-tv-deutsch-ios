// cspell:ignore uniquing
import Foundation

/// Which watch history the "Keep watching" shelf and Play / Resume read (awe#6564, decision 5).
///
/// - Signed out: the device store (`WatchProgressStore`), every entry, keyed by media URL.
/// - Signed in: the server copy, keyed by episode or movie (`WatchHistoryItem`), plus the
///   device-only entries (the server answered `recorded: false` for them). The server wins for
///   the same item. A device entry from before sign-in does not show.
///
/// A play with no episode or movie id stays device-local, signed in or out. Pure, so it is testable.
struct WatchHistorySource {
    /// The shelf, newest first.
    let entries: [WatchProgressStore.Entry]
    /// Device resume points by progress key (the media URL).
    let resumePoints: [String: Double]
    /// Signed in: resume points by episode or movie. nil signed out.
    let memberResumePoints: [WatchHistoryItem: Double]?

    /// `local` is the device store's resumable entries. `server` is the member's copy by item, or
    /// nil when signed out (signed in with nothing loaded yet is `[:]`).
    init(local: [WatchProgressStore.Entry], server: [WatchHistoryItem: WatchProgressStore.Entry]?, limit: Int = 12) {
        resumePoints = Dictionary(local.map { ($0.playableId, $0.fraction) }, uniquingKeysWith: { first, _ in first })
        guard let server else {
            entries = Array(local.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
            memberResumePoints = nil
            return
        }
        let deviceOnly = local.filter { entry in
            guard entry.deviceOnly == true, let item = entry.historyItem else { return false }
            return server[item] == nil
        }
        let shown = server.values.filter(\.isResumable) + deviceOnly
        entries = Array(shown.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))

        var byItem: [WatchHistoryItem: Double] = [:]
        for entry in deviceOnly {
            if let item = entry.historyItem { byItem[item] = entry.fraction }
        }
        for (item, entry) in server where entry.isResumable {
            byItem[item] = entry.fraction
        }
        memberResumePoints = byItem
    }

    /// The device store and the member account, as the views read them.
    @MainActor
    init(progress: WatchProgressStore, account: MemberAccount, limit: Int = 12) {
        self.init(local: progress.resumable(limit: .max), server: account.session == nil ? nil : account.history, limit: limit)
    }

    /// The point the player seeks to, or nil. A request that keeps no progress never resumes.
    func resumeFraction(for request: PlaybackRequest) -> Double? {
        request.resumeFraction(resumePoints: resumePoints, memberResumePoints: memberResumePoints)
    }
}
