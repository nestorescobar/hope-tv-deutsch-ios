import Foundation
import Observation

/// Client-owned state.
///
/// `EpisodeWatchHistory` is a block the contract may place, but its contents never travel
/// in the contract — they are device-local (spec §8 Q4). Each entry keeps a small snapshot
/// of what was watched, so the shelf draws without re-fetching every episode it lists.
/// Signed in, the shelf reads the member's server copy instead (`WatchHistorySource`, awe#6564).
@MainActor
@Observable
final class WatchProgressStore {

    struct Entry: Codable, Identifiable {
        var playableId: String
        var showId: String?
        /// Opens the Episode Template Screen from a "Keep watching" card. Optional: entries
        /// saved before it existed still decode, and open nothing until watched again.
        var episodeId: String?
        /// Opens the movie Template Screen from a "Keep watching" card (awe#6270). Optional, as
        /// `episodeId`. Signed in, a movie reports and imports as an episode does.
        var movieId: String?
        var title: String
        var subtitle: String
        var imageURL: URL?
        var fraction: Double
        /// The media duration in seconds, as the player reports it. Optional: entries saved
        /// before it existed still decode, and draw no duration until watched again.
        var duration: Double?
        var updatedAt: Date
        /// Signed in, the server answered `recorded: false` for this item (awe#6564): it stays
        /// on this device and shows beside the server copy. Optional: older data still decodes.
        var deviceOnly: Bool? = nil

        var id: String { playableId }
        /// The member watch history item: the episode, else the movie. nil for neither.
        var historyItem: WatchHistoryItem? {
            episodeId.map(WatchHistoryItem.episode) ?? movieId.map(WatchHistoryItem.movie)
        }
        /// Started but not effectively finished.
        var isResumable: Bool { fraction > 0.01 && fraction < 0.95 }
    }

    private let key = "watch-progress-v2"
    private var entries: [String: Entry] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func fraction(for playableId: String) -> Double? {
        guard let entry = entries[playableId], entry.isResumable else { return nil }
        return entry.fraction
    }

    /// Resume points by progress key, for a render pass. The keys are the store's own, so the
    /// map can never hold a duplicate, and nothing is sorted.
    var resumePoints: [String: Double] {
        entries.compactMapValues { $0.isResumable ? $0.fraction : nil }
    }

    /// Most recently watched first.
    func resumable(limit: Int) -> [Entry] {
        entries.values
            .filter(\.isResumable)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    func record(
        _ fraction: Double,
        for playableId: String,
        title: String,
        subtitle: String = "",
        imageURL: URL? = nil,
        showId: String? = nil,
        episodeId: String? = nil,
        movieId: String? = nil,
        duration: Double? = nil,
        deviceOnly: Bool = false
    ) {
        // A livestream has no meaningful resume point.
        guard !playableId.isEmpty else { return }
        entries[playableId] = Entry(
            playableId: playableId,
            showId: showId,
            episodeId: episodeId ?? entries[playableId]?.episodeId,
            movieId: movieId ?? entries[playableId]?.movieId,
            title: title,
            subtitle: subtitle,
            imageURL: imageURL ?? entries[playableId]?.imageURL,
            fraction: min(max(fraction, 0), 1),
            duration: duration ?? entries[playableId]?.duration,
            updatedAt: Date(),
            deviceOnly: deviceOnly ? true : nil
        )
        persist()
    }

    /// The server recorded this item (awe#6564, ruled 2026-10-13): drop its device-only
    /// entries, under `playableId` or any other key with the same `historyItem`. A plain device
    /// entry stays.
    func removeDeviceOnly(playableId: String, item: WatchHistoryItem?) {
        let kept = entries.filter { key, entry in
            guard entry.deviceOnly == true else { return true }
            return key != playableId && (item == nil || entry.historyItem != item)
        }
        guard kept.count != entries.count else { return }
        entries = kept
        persist()
    }

    /// The largest position or duration the import route takes. Mirrors `MAX_SECONDS` in
    /// `apis/frontend/modules/media-library/validation/memberSchemas.js`; keep both equal. One
    /// number past it fails the whole batch.
    static let importMaxSeconds: Double = 7 * 24 * 60 * 60

    /// The one-time import after sign-in (awe#6565, decision 16): the newest `limit` mappable
    /// entries, one per episode or movie (its newest mappable key). An entry needs an ObjectId
    /// episode or movie id and a duration, and both numbers within the route's bounds. A position
    /// below `minResumeSeconds` is not sent, as the progress reports do not send one. A finished
    /// entry and a device-only entry are sent.
    func importEntries(limit: Int) -> [HistoryImportEntry] {
        var seen = Set<WatchHistoryItem>()
        var mapped: [HistoryImportEntry] = []
        for entry in entries.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard mapped.count < limit else { break }
            guard let item = entry.historyItem, ContractValidator.isObjectId(item.itemId), !seen.contains(item),
                  let duration = entry.duration, duration > 0, duration <= Self.importMaxSeconds else { continue }
            let position = entry.fraction * duration
            guard position >= MemberProgressReporter.minResumeSeconds, position <= Self.importMaxSeconds else { continue }
            seen.insert(item)
            mapped.append(HistoryImportEntry(itemType: item.itemType, episodeId: item.itemId, position: position,
                                             duration: duration, lastAt: entry.updatedAt))
        }
        return mapped
    }

    /// Each entry's `updatedAt` by key: the snapshot an import takes when it starts.
    var savedAt: [String: Date] {
        entries.mapValues(\.updatedAt)
    }

    /// The import answered 2xx (ruled 2026-10-13, option B): every entry still as it was in
    /// `snapshot` goes, except the `refused` episodes and movies (the server lists bare ids). Their
    /// entries stay, marked device-only, so they show beside the server copy. An entry added or
    /// changed since the snapshot (a play while the call ran) stays as it is. No clock is read, so
    /// a clock step cannot change the result.
    func finishImport(refused: Set<String>, snapshot: [String: Date]) {
        for (key, entry) in entries where snapshot[key] == entry.updatedAt {
            if let id = entry.historyItem?.itemId, refused.contains(id) {
                entries[key]?.deviceOnly = true
            } else {
                entries[key] = nil
            }
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
