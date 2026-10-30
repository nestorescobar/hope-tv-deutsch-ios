import Foundation

/// The cross-show list the `EpisodePlayer` node serves as its own `relatedEpisodes` block resource,
/// beside `episodePlayer` (awe#7390). Read once into the request for the Related tab (awe#7391).
/// The server keeps its own order and caps it at 10. It ignores `playlistIndex` and
/// `autoplayEpisodes`.
struct RelatedEpisodes: Hashable {
    struct Item: Hashable, Identifiable {
        /// The episode ObjectId: the `param` of its Episode Template Screen.
        let id: String
        let title: String
        let posterURL: URL?
        /// One secondary line under the title. nil when the server sends no text.
        let showTitle: String?
    }

    let items: [Item]
}

extension RelatedEpisodes {
    /// nil when no item is left: an old server (no key), an empty list, or nothing to play. An
    /// item drops when its id is no ObjectId (its Episode Screen cannot open) or when this device
    /// cannot play it (`PlaybackService.playlistItemSource`). Bug awe#7655 can serve
    /// `provider: null` with empty `mediaLinks`.
    init?(_ list: JSONValue?) {
        let items = (list?.array ?? []).compactMap { entry -> Item? in
            guard let id = entry["id"].text, ContractValidator.isObjectId(id),
                  PlaybackService.playlistItemSource(entry) != nil else { return nil }
            return Item(
                id: id,
                title: entry["title"].text ?? ChromeText.string(.episode),
                // The same https rule as a stream.
                posterURL: ContractValidator.playableURL(entry["poster"].string),
                showTitle: entry["showTitle"].text
            )
        }
        guard !items.isEmpty else { return nil }
        self.init(items: items)
    }
}
