import AVFoundation
import Foundation

/// What the contract is *not* allowed to decide about playback.
///
/// The contract names a source. Which rendition is preferred, whether the source is
/// acceptable, and what happens when it is not, are all resolved here — invariant 4 lives
/// at this boundary.
enum PlaybackService {

    struct Resolved: Equatable {
        let url: URL
        /// Which rendition was chosen, for the diagnostics log.
        let rendition: String

        /// An HLS manifest: the `hls` rendition or a Jetstream VOD. Only HLS offers a Quality
        /// picker (awe#6868); an MP4 rendition never fetches a playlist.
        var isHLS: Bool { rendition == "hls" || Jetstream.prefixes[rendition] != nil }
    }

    /// Rendition preference, highest quality first. HLS is preferred on tvOS because it
    /// adapts and supports live; progressive MP4 is the fallback. Also the self-hosted set: the
    /// providers whose stored value IS the stream url (mobile `SELF_HOSTED`), so a change here
    /// changes both roles, and `fallbackOrder` too.
    static let renditions = ["hls", "mp4-hd", "mp4-sd"]

    /// The `mediaLinks` keys tried, in this order, when the served provider resolves nothing. A
    /// Jetstream VOD is stored under `jetstream` (`DEFAULT_VIDEO_PROVIDERS`); a `jsl:` id there
    /// still resolves nothing.
    static let fallbackOrder = ["jetstream"] + renditions

    /// The full-screen request for a channel's livestream, or nil when it has no https source.
    /// The one path for every live entry point: Select on the `LivestreamPlayer` card, and
    /// the on-air `ScheduleLive` row (awe#5044). A live request keeps no watch progress.
    /// `schedule` feeds the player's Schedule tab (awe#6553).
    static func liveRequest(_ channel: JSONValue?, images: ImageConfig, schedule: [ScheduleModel.Entry]? = nil) -> PlaybackRequest? {
        guard let url = ContractValidator.playableURL(livestreamSource(channel)) else { return nil }
        return PlaybackRequest(url: url, metadata: .livestream(channel ?? .null, images: images), recordsProgress: false,
                               schedule: schedule, isHLS: true)
    }

    /// The livestream source of a `channel` resource.
    static func livestreamSource(_ channel: JSONValue?) -> String? {
        #if DEBUG
        // Simulator aid: the staging channel's CDN host does not resolve from public
        // resolvers. Launch with `-playback-override-url <https url>` to exercise the
        // same code path with a reachable stream.
        if let override = UserDefaults.standard.string(forKey: "playback-override-url"), !override.isEmpty {
            return override
        }
        #endif
        return channel?["hls"].text
    }

    /// The `episodePlayer` or `moviePlayer` resource: `{ provider, id or link, poster, mediaLinks? }`.
    /// The served provider plays when it resolves, else the first `fallbackOrder` entry of
    /// `mediaLinks` that resolves (`resolve`). A non-https source never resolves.
    static func episodeSource(_ resource: JSONValue) -> Resolved? {
        resolve(provider: resource["provider"].text, link: resource["link"].text ?? resource["id"].text,
                mediaLinks: resource["mediaLinks"])
    }

    /// One `episodePlayer.playlist` item (awe#6550), with no fetch: is it worth offering? Its
    /// Episode Screen plays by `episodeSource`, so the item takes the same rule over its own
    /// `provider` and link-only `mediaLinks`. Never the item `id`: it is the episode ObjectId,
    /// and the Jetstream allowlist would accept it as a media id.
    static func playlistItemSource(_ item: JSONValue) -> Resolved? {
        let provider = item["provider"].text
        let links = item["mediaLinks"]
        return resolve(provider: provider, link: provider.flatMap { link(links[$0]) }, mediaLinks: links)
    }

    /// The one playback rule: the served provider and its link, else the first entry of
    /// `mediaLinks` that resolves, in `fallbackOrder`. Each candidate goes through `source`, so the
    /// Jetstream allowlist and the https rule hold for both steps.
    private static func resolve(provider: String?, link: String?, mediaLinks: JSONValue) -> Resolved? {
        if let provider, let served = source(provider: provider, link: link) { return served }
        return pick(from: mediaLinks)
    }

    /// A `mediaLinks` entry: a string, or `{ link }`.
    private static func link(_ entry: JSONValue) -> String? {
        entry.text ?? entry["link"].text
    }

    /// A Jetstream VOD id, or a self-hosted https url. Every other provider resolves nothing.
    private static func source(provider: String, link: String?) -> Resolved? {
        var source = link
        if let prefix = Jetstream.prefixes[provider] {
            source = Jetstream.vodManifest(link, prefix: prefix)
        } else if !renditions.contains(provider) {
            return nil
        }
        guard let url = ContractValidator.playableURL(source) else { return nil }
        return Resolved(url: url, rendition: provider)
    }

    /// A show's `trailer`: `{ provider, videoId }`. It resolves by the same rules as an
    /// episode: a Jetstream VOD id plays, YouTube and Vimeo play nothing.
    static func trailerSource(_ trailer: JSONValue) -> Resolved? {
        guard let provider = trailer["provider"].text, let videoId = trailer["videoId"].text else { return nil }
        return episodeSource(.object(["provider": .string(provider), "id": .string(videoId)]))
    }

    /// The full-screen request for a trailer, or nil when it cannot play here. A trailer keeps
    /// no watch progress, so it never becomes a "Keep watching" card that opens nothing.
    static func trailerRequest(_ trailer: JSONValue, title: String, description: String?, artworkURL: URL?) -> PlaybackRequest? {
        guard let resolved = trailerSource(trailer) else { return nil }
        let metadata = PlaybackMetadata(title: title, description: description, showName: nil, artworkURL: artworkURL)
        return PlaybackRequest(url: resolved.url, metadata: metadata, recordsProgress: false, isHLS: resolved.isHLS)
    }

    /// Jetstream VOD, ported from `apps/mobile/src/player/playerSource.ts` (`jetstreamSource`).
    /// Live (`jsl:`) and audio (`jsa:`) have no derivable manifest, and tvOS has no web view for
    /// the embed page, so they resolve nothing.
    private enum Jetstream {
        private static let host = "https://jstre.am"
        private static let stagingHost = "https://stage.jstre.am"

        /// The type prefix each Jetstream provider stores (`providers.js` `idPrefix`).
        static let prefixes = ["jetstream": "jsv", "jetstream-audio": "jsa", "jetstream-live": "jsl"]

        /// Only a short id addresses media. Core cuts a longer v1 id the same way
        /// (`getJetstreamId`, `apis/core/utils/jetstream.js`).
        private static let idLength = 15
        private static let stagingIdLength = 21

        /// An allowlist, not an escape: the id lands in a url path, so an id that could add a
        /// path segment or a query is refused.
        private static let id = #/js[avl]:(?:stage:)?[A-Za-z0-9_-]+/#
        /// The embed url the editor also accepts. Group 1 is the `stage.` host, group 2 the id,
        /// bounded to one path segment.
        private static let embed = #/(?:https?:\/\/)?(?:www\.)?(stage\.)?jstre\.am\/embed\/([^\/?#]+)\/?/#

        /// The HLS manifest of a stored Jetstream link, or nil when it is not a VOD id.
        static func vodManifest(_ link: String?, prefix: String) -> String? {
            let link = link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !link.isEmpty else { return nil }

            let match = link.wholeMatch(of: embed)
            let raw = match.map { String($0.output.2) } ?? link
            // A bare id takes the provider's prefix; a prefixed id keeps its own.
            let prefixed = raw.prefixMatch(of: #/js[avl]:/#) != nil ? raw : "\(prefix):\(raw)"
            let cut = prefixed.contains(":stage:") ? stagingIdLength : idLength
            let shortId = String(prefixed.prefix(cut))

            guard shortId.wholeMatch(of: id) != nil, shortId.hasPrefix("jsv:") else { return nil }
            // The host reads the cut id, as mobile does: a `:stage:` the cut dropped is gone.
            let base = shortId.contains(":stage:") || match?.output.1 != nil ? stagingHost : host
            return "\(base)/videos/\(shortId)/hls/main.m3u8"
        }
    }

    /// The first `mediaLinks` entry that resolves, in `fallbackOrder`.
    private static func pick(from links: JSONValue) -> Resolved? {
        for provider in fallbackOrder {
            if let resolved = source(provider: provider, link: link(links[provider])) { return resolved }
        }
        return nil
    }
}

/// What the transport bar and the Info panel show for one on-demand episode.
struct PlaybackMetadata: Hashable {
    let title: String
    let description: String?
    let showName: String?
    let artworkURL: URL?
    /// The bound Episode's id, kept with watch progress so a "Keep watching" card can open it.
    var episodeId: String? = nil
    /// The bound Movie's id (awe#6270), kept with watch progress for the same reason. Signed in, a
    /// movie play reports to the server as an episode play does.
    var movieId: String? = nil
    /// The episode's show, from the served record (`episodeDetail.show._id`, else the Episode's
    /// own `show` ref). Only an on-demand episode sets it; a livestream and a trailer never do.
    var showId: String? = nil
    /// The primary age rating's text, from the same `episodeDetail` (awe#6867). The Info panel
    /// draws it in its meta line, after the duration. The language has no slot there (measured
    /// 2026-10-14, `commonIdentifierLanguage` drew nothing), so it shows on the detail screen only.
    var contentRating: String? = nil
    /// A movie's first genre title (ruled 2026-10-15, awe#6870), the first part of the Info panel
    /// meta line: "Drama • 1h 52m • FSK 12". An episode sets none.
    var genre: String? = nil

    /// "Go to show" in the player's Info panel: the show by the card convention, as the
    /// `EpisodeDetail` button opens it. nil draws no action.
    var showTarget: CardTarget? { .show(id: showId) }

    /// The member watch history item of this play: the episode, else the movie. nil for a
    /// livestream or a trailer.
    var historyItem: WatchHistoryItem? {
        episodeId.map(WatchHistoryItem.episode) ?? movieId.map(WatchHistoryItem.movie)
    }

    /// Built from the Episode Screen. `resources.Episode` is the screen's bound record, so it
    /// gives the title, the abstract and the image. Its `show` is only an id, so the show name
    /// comes from an `episodeDetail` block resource for the SAME episode, when the screen has
    /// one. The artwork is the episode image, else the player's https `poster`.
    static func episode(
        _ episode: JSONValue,
        blockResources: [String: [String: JSONValue]],
        poster: String?,
        images: ImageConfig
    ) -> PlaybackMetadata {
        let episodeId = episode["_id"].text ?? episode["id"].text
        let detail = blockResources.values.lazy.compactMap { $0["episodeDetail"] }.first {
            episodeId != nil && ($0["_id"].text ?? $0["id"].text) == episodeId
        }
        let image = ImageFile(episode["image"]) ?? ImageCatalog.pick(episode["images"])
        // A served id only: an ObjectId from the record, never free text.
        let showId = [detail?["show"]["_id"].text, episode["show"]["_id"].text, episode["show"].text]
            .compactMap { $0 }
            .first(where: ContractValidator.isObjectId)
        return PlaybackMetadata(
            title: episode["title"].text ?? ChromeText.string(.episode),
            description: episode["abstract"].text,
            showName: detail?["show"]["title"].text,
            // The same https rule as a stream: a poster the contract serves over http never loads.
            artworkURL: images.url(image, width: 1280) ?? ContractValidator.playableURL(poster),
            episodeId: episodeId,
            showId: showId,
            // Already resolved Episode → Show on the server.
            contentRating: detail.flatMap { AgeRatingFormat.primaryLabel($0["ageRatings"]) }
        )
    }

    /// Built from the movie Template Screen (awe#6270), as `episode(...)`: the bound
    /// `resources.Movie` gives the title, the abstract and the image; the `movieDetail` for the
    /// same movie gives the age rating and the first genre (`moviePlayer` serves no genres, and
    /// `movieDetail` serves them titled). A movie has no show, so no show name and no "Go to show".
    static func movie(
        _ movie: JSONValue,
        blockResources: [String: [String: JSONValue]],
        poster: String?,
        images: ImageConfig
    ) -> PlaybackMetadata {
        let movieId = movie["_id"].text ?? movie["id"].text
        let detail = blockResources.values.lazy.compactMap { $0["movieDetail"] }.first {
            movieId != nil && ($0["_id"].text ?? $0["id"].text) == movieId
        }
        return PlaybackMetadata(
            title: movie["title"].text ?? ChromeText.string(.untitled),
            description: movie["abstract"].text,
            showName: nil,
            artworkURL: images.url(ImageCatalog.pick(movie["images"]), width: 1280) ?? ContractValidator.playableURL(poster),
            // An ObjectId only: it becomes a card target and a Watch later id.
            movieId: movieId.flatMap { ContractValidator.isObjectId($0) ? $0 : nil },
            contentRating: detail.flatMap { AgeRatingFormat.primaryLabel($0["ageRatings"]) },
            genre: detail?["genres"].array.first?["title"].text
        )
    }

    /// A channel's livestream: the channel title, and the channel's image when served (its
    /// `images` map, else its `logo`). No episode fields: a stream has no episode of its own.
    static func livestream(_ channel: JSONValue, images: ImageConfig) -> PlaybackMetadata {
        let image = ImageCatalog.pick(channel["images"]) ?? ImageFile(channel["logo"])
        return PlaybackMetadata(
            title: channel["title"].text ?? ChromeText.string(.onNow),
            description: nil,
            showName: nil,
            artworkURL: images.url(image, width: 1280)
        )
    }

    /// `AVPlayerItem.externalMetadata`. The artwork bytes arrive later, so they are optional.
    /// `artworkType` is a `kCMMetadataBaseDataType_*` value that names the image format.
    func metadataItems(artwork: Data? = nil, artworkType: String = kCMMetadataBaseDataType_JPEG as String) -> [AVMetadataItem] {
        var items = [Self.item(.commonIdentifierTitle, title as NSString)]
        if let description { items.append(Self.item(.commonIdentifierDescription, description as NSString)) }
        if let showName { items.append(Self.item(.iTunesMetadataTrackSubTitle, showName as NSString)) }
        if let contentRating { items.append(Self.item(.iTunesMetadataContentRating, contentRating as NSString)) }
        if let genre { items.append(Self.item(.quickTimeMetadataGenre, genre as NSString)) }
        if let artwork {
            let item = Self.item(.commonIdentifierArtwork, artwork as NSData)
            item.dataType = artworkType
            items.append(item)
        }
        return items
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }
}

/// One full-screen playback intent: an on-demand episode, a trailer, or a channel's livestream
/// (Select on the Live card or on the on-air schedule row, awe#5044).
struct PlaybackRequest: Identifiable, Hashable {
    let url: URL
    let metadata: PlaybackMetadata
    /// The key device-local progress is stored under: the media URL. The member's server copy
    /// keys by `metadata.historyItem` instead (awe#6564).
    let progressId: String
    /// False for a trailer and a livestream: the player never reads a resume point, never
    /// seeks to one, and never writes progress, so no "Keep watching" entry appears. The flag
    /// decides it, not the stream's duration: a live HLS with a DVR window reports one.
    let recordsProgress: Bool
    /// The season list of an on-demand episode, for the Episodes tab and Up Next (awe#6550). A
    /// livestream and a trailer carry none.
    let playlist: Playlist?
    /// The cross-show Related list of an on-demand episode, for the Related tab (awe#7391). A
    /// movie, a trailer and a livestream carry none.
    let related: RelatedEpisodes?
    /// The channel's broadcasts as served, `current` first, for the Schedule tab of a livestream
    /// (awe#6553). nil when the node serves no row (or no `broadcastsLive`, an old server): no tab.
    /// An episode and a trailer carry none.
    let schedule: [ScheduleModel.Entry]?
    /// The source is an HLS manifest, so the player looks for a Quality picker (awe#6868). False
    /// asks for none. Required, so a new call site cannot drop the menu by default.
    let isHLS: Bool

    var id: String { url.absoluteString }
    var title: String { metadata.title }

    init(url: URL, metadata: PlaybackMetadata, recordsProgress: Bool = true, playlist: Playlist? = nil,
         related: RelatedEpisodes? = nil, schedule: [ScheduleModel.Entry]? = nil, isHLS: Bool) {
        self.url = url
        self.metadata = metadata
        self.recordsProgress = recordsProgress
        self.playlist = playlist
        self.related = related
        self.schedule = schedule?.isEmpty == false ? schedule : nil
        self.isHLS = isHLS
        progressId = url.absoluteString
    }

    /// The point the player seeks to before it starts, or nil. A request that keeps no progress
    /// never reads one, whatever the store holds under its URL. Signed-out device store only;
    /// the player reads `WatchHistorySource`.
    @MainActor
    func resumeFraction(in store: WatchProgressStore) -> Double? {
        resumeFraction(resumePoints: store.resumePoints, memberResumePoints: nil)
    }

    /// The resume rule (awe#6564). Signed in (`memberResumePoints` set), a request with an episode
    /// or movie id reads the server copy by that item. Every other request reads the device store
    /// by URL.
    func resumeFraction(resumePoints: [String: Double], memberResumePoints: [WatchHistoryItem: Double]?) -> Double? {
        guard recordsProgress else { return nil }
        if let memberResumePoints, let item = metadata.historyItem {
            return memberResumePoints[item]
        }
        return resumePoints[progressId]
    }
}
