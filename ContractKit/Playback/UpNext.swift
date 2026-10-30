import Foundation

/// The season list the `episodePlayer` resource serves (awe#6548, spec §5.6), read once into the
/// request. The server sends it in the Show's `episodeSorting` order and filters nothing for this
/// renderer, so each item carries its own playability.
struct Playlist: Hashable {
    struct Item: Hashable, Identifiable {
        /// The episode ObjectId: the `param` of its Episode Template Screen.
        let id: String
        let title: String
        let posterURL: URL?
        /// `PlaybackService.playlistItemSource` resolves: this device can play it.
        let isPlayable: Bool
    }

    let items: [Item]
    /// The episode on show, or nil (`playlistIndex: -1`, or an index the list does not hold).
    let currentIndex: Int?
    /// The Show's `autoplayEpisodes`. It gates Up Next only, never the Episodes tab.
    let autoplay: Bool
}

extension Playlist {
    /// nil when the resource serves no item. An item with no ObjectId cannot open its Episode
    /// Screen, so it drops; the current index follows the current item.
    init?(_ resource: JSONValue) {
        let served = resource["playlistIndex"].int
        var items: [Item] = []
        var current: Int?
        for (index, entry) in resource["playlist"].array.enumerated() {
            guard let id = entry["id"].text, ContractValidator.isObjectId(id) else { continue }
            if index == served {
                current = items.count
            }
            items.append(Item(
                id: id,
                title: entry["title"].text ?? ChromeText.string(.episode),
                // The same https rule as a stream.
                posterURL: ContractValidator.playableURL(entry["poster"].string),
                isPlayable: PlaybackService.playlistItemSource(entry) != nil
            ))
        }
        guard !items.isEmpty else { return nil }
        self.init(items: items, currentIndex: current, autoplay: resource["autoplayEpisodes"].bool == true)
    }
}

/// Up Next (awe#6550, spec §5.4). Fixed in the renderer: no CMS or viewer setting.
enum UpNext {
    /// Unplayable items Up Next may skip. A 4th one ends the search with no offer.
    static let maxSkips = 3
    /// Episodes in a row that started by themselves before the offer asks "Still watching?".
    static let stillWatchingAfter = 3
    /// The offer shows this long before the end of the episode.
    static let offerLead: TimeInterval = 15
    /// The countdown before the next episode plays. The web uses 5 s; a TV is watched from the
    /// couch with a remote, so it waits longer (spec decision 5).
    static let countdown: TimeInterval = 10

    enum Mode: Equatable {
        /// Plays the item when the countdown ends.
        case countdown
        /// Asks "Still watching?" and waits for a press.
        case stillWatching
    }

    struct Offer: Equatable {
        let item: Playlist.Item
        let mode: Mode
    }

    /// The offer for the episode on show, or nil. Only with `autoplayEpisodes`, only when the list
    /// holds the current episode, and only for a later item this device can play.
    static func offer(in playlist: Playlist?, autoStarts: Int) -> Offer? {
        guard let playlist, playlist.autoplay, let current = playlist.currentIndex else { return nil }
        var skips = 0
        for item in playlist.items.dropFirst(current + 1) {
            if item.isPlayable {
                return Offer(item: item, mode: autoStarts >= stillWatchingAfter ? .stillWatching : .countdown)
            }
            skips += 1
            if skips > maxSkips {
                return nil
            }
        }
        return nil
    }

    /// The content time the offer shows at, in seconds: `lead` before the end, but at least 1 s
    /// after `now`, because AVKit does not show a proposal whose time has passed (a short item
    /// resumed near its end). Never at or past the end.
    static func offerTime(duration: TimeInterval, now: TimeInterval = 0, lead: TimeInterval = offerLead) -> TimeInterval {
        min(max(duration - lead, now + 1), max(0, duration - 0.5))
    }

    /// The item is at its reported end. An unknown duration (NaN, live) is not an end. The fallback
    /// to the item's own end notification (`UpNextProposalController.itemEnded`), which also
    /// catches a stream that stops short of its duration.
    static func hasEnded(currentTime: TimeInterval, duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0 && currentTime >= duration - 0.5
    }

    /// Whole seconds left on the countdown, rounded up, so it reads 10 … 1.
    static func secondsLeft(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }
}
