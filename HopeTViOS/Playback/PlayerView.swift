import AVKit
import SwiftUI

/// Native full-screen playback. The contract got as far as naming a source; everything
/// from here is the client's.
struct PlayerView: View {
    let request: PlaybackRequest

    @Environment(WatchProgressStore.self) private var progress
    @Environment(MemberAccount.self) private var account
    @Environment(ContractStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Likes.self) private var likes
    @Environment(\.appTheme) private var theme

    @State private var player: AVPlayer?
    @State private var observer: Any?
    /// Signed in with an episode or movie id: the server reports (awe#6564), with their pause and end hooks.
    @State private var reporter: MemberProgressReporter?
    @State private var pauseObservation: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?
    @State private var artwork: Task<Void, Never>?
    /// Up Next for this episode, decided once when it starts (`router.autoStarts` is read then).
    @State private var offer: UpNext.Offer?
    /// This item's Quality picker, once its master playlist offers two heights or more (awe#6868).
    @State private var quality: QualityLadder?
    @State private var qualityCap = QualityPreference().cap
    @State private var qualityTask: Task<Void, Never>?
    #if DEBUG
    /// Debug builds log each variant switch, so a run can prove the cap (`[tv] quality:` lines).
    @State private var accessLogObserver: NSObjectProtocol?
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                PlayerController(
                    player: player,
                    actions: PlayerInfoAction.actions(for: request, canOpen: router.canOpenCard),
                    tabs: PlayerTab.tabs(for: request, canOpen: router.canOpenCard),
                    offer: offer,
                    qualityOptions: quality?.options(cap: qualityCap),
                    // Read here, so a press redraws the item as "Liked" (awe#6871).
                    liked: request.likeItem.map(likes.isLiked),
                    theme: theme,
                    router: router,
                    onCard: { target in
                        stop()
                        router.leavePlayback(openingCard: target)
                    },
                    onEpisode: { id, automatic in router.playFromPlayer(episodeId: id, automatic: automatic) },
                    // Back on an offer after the item ended: Back to the screen under the cover.
                    onClose: { dismiss() },
                    onQuality: { chooseQuality($0) },
                    onLike: { [likes] in
                        guard let item = request.likeItem else { return }
                        Task { await likes.toggle(item) }
                    }
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.accent)
            }
        }
        .accessibilityIdentifier("full-screen-player")
        // The UI tests read which episode plays.
        .accessibilityValue(request.title)
        .task { await start() }
        // Signed in with an unknown Like state (the list did not load, or a cut page): ask
        // `/contains` once, as the detail button does (awe#6871). Otherwise it sends nothing.
        .task(id: request.likeItem?.id) {
            guard let item = request.likeItem else { return }
            await likes.list.check(item.itemType, item.itemId)
        }
        .onDisappear { stop() }
        .onExitCommand { dismiss() }
    }

    private func start() async {
        let item = AVPlayerItem(url: request.url)
        // The transport bar and the Info panel read this. The artwork follows once it loads.
        item.externalMetadata = request.metadata.metadataItems()
        let player = AVPlayer(playerItem: item)
        if request.isHLS { loadQuality(for: item) }

        // Signed in, the member's server copy by episode or movie; else the device store (awe#6564).
        if let fraction = WatchHistorySource(progress: progress, account: account).resumeFraction(for: request) {
            // Resume where the viewer left off. Seeking needs a known duration, so this
            // waits for the item to report one.
            let duration = try? await item.asset.load(.duration)
            if let duration, duration.isNumeric, duration.seconds > 0 {
                await player.seek(to: CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600))
            }
        }

        #if DEBUG
        // `-playback-seek-to-end <seconds>`: start that long before the end, so a run reaches Up
        // Next without watching the episode.
        if let lead = DebugLaunch.playbackSeekToEnd, let duration = try? await item.asset.load(.duration), duration.isNumeric {
            await player.seek(to: CMTime(seconds: max(0, duration.seconds - lead), preferredTimescale: 600))
        }
        #endif

        // Back during the awaits above already ran `stop()` with no player to stop. Starting
        // now would leave a hidden player running under the Episode Screen.
        guard Self.isStillWanted(request, showing: router.playback, cancelled: Task.isCancelled) else { return }

        if request.recordsProgress {
            if let reporter = MemberProgressReporter(request: request, account: account, progress: progress) {
                observeReports(player, item: item, reporter: reporter)
            } else {
                observeProgress(player)
            }
        }
        offer = UpNext.offer(in: playlist, autoStarts: router.autoStarts)
        self.player = player
        player.play()
        store.diagnostics.log(.ok, "Playing \(request.title)", request.recordsProgress ? "on demand" : "without watch progress (live or trailer)")
        loadArtwork(into: item)
        await propose(on: item)
    }

    /// The season list for Up Next, when an item can open. A livestream and a trailer carry none.
    private var playlist: Playlist? {
        guard let playlist = request.playlist, PlayerTab.canOpenEpisode(playlist.items.first?.id, canOpen: router.canOpenCard) else { return nil }
        return playlist
    }

    /// Sets the Up Next proposal on the item, `UpNext.offerLead` before its end. It needs the
    /// duration, so it runs after playback starts and never delays the stream.
    private func propose(on item: AVPlayerItem) async {
        guard let offer, let duration = try? await item.asset.load(.duration), duration.isNumeric, duration.seconds > 0,
              !Task.isCancelled else { return }
        // A resume point can be past the usual offer time; the offer then shows 1 s from now.
        let offerTime = UpNext.offerTime(duration: duration.seconds, now: item.currentTime().seconds)
        let time = CMTime(seconds: offerTime, preferredTimescale: 600)
        item.nextContentProposal = AVContentProposal(contentTimeForTransition: time, title: offer.item.title, previewImage: nil)
    }

    /// True while this request is still the one on screen and its task still runs.
    static func isStillWanted(_ request: PlaybackRequest, showing: PlaybackRequest?, cancelled: Bool) -> Bool {
        !cancelled && showing?.id == request.id
    }

    /// Reads the variants of the item's own asset beside playback, so it never delays the start and
    /// never fetches the master a second time (awe#6879). Only a stream with two heights or more gets
    /// the stored cap and the menu; a failure changes nothing.
    private func loadQuality(for item: AVPlayerItem) {
        qualityTask = Task {
            guard let ladder = await QualityLadder.load(from: item.asset), !Task.isCancelled else { return }
            QualityLadder.apply(ladder.constraint(cap: qualityCap), to: item)
            quality = ladder
            // Labels only: the stream URL can carry a token.
            let labels = ladder.variants.map { QualityLadder.label(height: $0.height) }.joined(separator: ", ")
            store.diagnostics.log(.info, "Quality picker", "\(labels); cap \(qualityCap)")
            #if DEBUG
            accessLogObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.newAccessLogEntryNotification, object: item, queue: .main
            ) { _ in
                guard let event = item.accessLog()?.events.last else { return }
                NSLog("[tv] quality: indicated %.0f bit/s, presentation %@", event.indicatedBitrate,
                      "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))")
            }
            #endif
        }
    }

    /// A menu choice: stored on the device for every next item, and applied to this one now.
    private func chooseQuality(_ cap: Int) {
        QualityPreference().cap = cap
        qualityCap = cap
        guard let quality, let item = player?.currentItem else { return }
        QualityLadder.apply(quality.constraint(cap: cap), to: item)
        store.diagnostics.log(.info, "Quality cap", "\(cap)")
    }

    /// Fetched after playback starts, so a slow image host never delays the stream.
    private func loadArtwork(into item: AVPlayerItem) {
        guard let url = request.metadata.artworkURL else { return }
        let metadata = request.metadata
        artwork = Task {
            guard let (data, type) = await ArtworkLoader.load(url), !Task.isCancelled else { return }
            item.externalMetadata = metadata.metadataItems(artwork: data, artworkType: type)
        }
    }

    /// Record position every five seconds, so a crash or a forced quit still leaves a
    /// usable resume point.
    private func observeProgress(_ player: AVPlayer) {
        let id = request.progressId
        let title = request.title
        // The "Keep watching" card draws the show name, artwork and duration from this record.
        let subtitle = request.metadata.showName ?? ""
        let imageURL = request.metadata.artworkURL
        let episodeId = request.metadata.episodeId
        let movieId = request.metadata.movieId
        let progress = progress
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) {
            [weak player] time in
            guard let duration = player?.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
            MainActor.assumeIsolated {
                progress.record(time.seconds / duration.seconds, for: id, title: title, subtitle: subtitle, imageURL: imageURL,
                                episodeId: episodeId, movieId: movieId, duration: duration.seconds)
            }
        }
    }

    /// Signed in with an episode or movie id (awe#6564): report to the member's server copy instead of
    /// the device store. A 1 s tick feeds the 10 s throttle; pause and the item's end report at once.
    private func observeReports(_ player: AVPlayer, item: AVPlayerItem, reporter: MemberProgressReporter) {
        self.reporter = reporter
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) {
            [weak player] time in
            let duration = Self.seconds(player?.currentItem?.duration)
            MainActor.assumeIsolated { _ = reporter.tick(position: time.seconds, duration: duration) }
        }
        pauseObservation = player.observe(\.timeControlStatus, options: [.new]) { observed, _ in
            guard observed.timeControlStatus == .paused else { return }
            let position = observed.currentTime().seconds
            let duration = Self.seconds(observed.currentItem?.duration)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = reporter.paused(position: position, duration: duration) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { _ in
            let duration = Self.seconds(item.duration)
            MainActor.assumeIsolated { _ = reporter.ended(duration: duration) }
        }
    }

    /// A media time in seconds, or nil when it is not a known positive length.
    private static func seconds(_ time: CMTime?) -> Double? {
        guard let time, time.isNumeric, time.seconds > 0 else { return nil }
        return time.seconds
    }

    private func stop() {
        artwork?.cancel()
        artwork = nil
        qualityTask?.cancel()
        qualityTask = nil
        #if DEBUG
        if let accessLogObserver {
            NotificationCenter.default.removeObserver(accessLogObserver)
        }
        accessLogObserver = nil
        #endif
        // Exit report first, then drop the pause hook, so the pause below sends no second report.
        if let reporter, let player {
            reporter.exited(position: player.currentTime().seconds, duration: Self.seconds(player.currentItem?.duration))
        }
        reporter = nil
        pauseObservation?.invalidate()
        pauseObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        player?.pause()
        player = nil
    }

    /// Back returns to the screen Play was pressed on: the stack under the cover is unchanged.
    private func dismiss() {
        stop()
        router.endPlayback()
    }
}

/// The artwork fetch, bounded like `AppContractClient.fetch`: its own ephemeral session with no
/// cookies or credentials, a 15 s budget, HTTP 200 only, the declared length checked before the
/// body, and a running cap while it streams. No contract header travels with it.
enum ArtworkLoader {
    static let maxBytes = 5 * 1024 * 1024

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// A negative declared length means none was sent; the running cap then decides.
    static func accepts(statusCode: Int, declaredLength: Int64) -> Bool {
        statusCode == 200 && declaredLength <= Int64(maxBytes)
    }

    /// The image Worker negotiates the format. Only JPEG and PNG become artwork.
    static func dataType(mime: String?) -> String? {
        switch mime {
        case "image/jpeg": return kCMMetadataBaseDataType_JPEG as String
        case "image/png": return kCMMetadataBaseDataType_PNG as String
        default: return nil
        }
    }

    /// The bytes and their `kCMMetadataBaseDataType_*`, or nil on any refusal.
    static func load(_ url: URL) async -> (Data, String)? {
        var request = URLRequest(url: url)
        request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  accepts(statusCode: http.statusCode, declaredLength: http.expectedContentLength),
                  let type = dataType(mime: http.mimeType) else { return nil }

            var buffer = [UInt8]()
            buffer.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), maxBytes))
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count > maxBytes { return nil }
            }
            return (Data(buffer), type)
        } catch {
            return nil
        }
    }
}

extension PlaybackRequest {
    /// What the transport bar's Like item likes (awe#6871): the on-demand episode, else the movie,
    /// by its ObjectId. A livestream and a trailer have none.
    var likeItem: SavedItem? {
        guard recordsProgress, let item = metadata.historyItem, ContractValidator.isObjectId(item.itemId) else { return nil }
        return SavedItem(itemType: item.itemType == .movie ? .movie : .episode, itemId: item.itemId, title: metadata.title,
                         imageURL: metadata.artworkURL, savedAt: .distantPast)
    }
}

/// The transport bar's Like item (awe#6871, ADR-0259 §5): "Like", or "Liked" with a filled heart.
/// A press toggles it.
enum TransportLike {
    static func action(liked: Bool, toggle: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: ChromeText.string(liked ? .liked : .like), image: UIImage(systemName: liked ? "heart.fill" : "heart"),
                              state: liked ? .on : .off) { _ in toggle() }
        // The UI tests find it by this id, not by the served label.
        action.accessibilityIdentifier = "player-like"
        return action
    }
}

/// The actions this renderer adds to the player's Info panel, after the system ones ("Play from
/// beginning"). Pure, so the rule is testable.
enum PlayerInfoAction: Equatable {
    /// Close the player and open the episode's show, like a show card.
    case goToShow(CardTarget)

    /// On-demand episodes only, only when the served record names the show, and only when the
    /// show can open (`AppRouter.canOpenCard`). A livestream and a trailer carry no show id.
    static func actions(for request: PlaybackRequest, canOpen: (CardTarget) -> Bool) -> [PlayerInfoAction] {
        guard request.recordsProgress, let target = request.metadata.showTarget, canOpen(target) else { return [] }
        return [.goToShow(target)]
    }

    var title: String {
        switch self {
        case .goToShow: return ChromeText.string(.goToShow)
        }
    }
}

/// The custom tabs beside the system Info tab (`customInfoViewControllers`). Pure, so the rule is
/// testable.
enum PlayerTab: Equatable {
    case episodes(Playlist)
    case related(RelatedEpisodes)
    case schedule([ScheduleModel.Entry])

    /// An on-demand episode: Episodes (a playlist), then Related (awe#7391). Either tab draws only
    /// when an episode card can open: a control that opens nothing is not drawn. A livestream: its
    /// Schedule, only when a row is left at open (awe#6553). A movie and a trailer: none.
    static func tabs(for request: PlaybackRequest, canOpen: (CardTarget) -> Bool, now: Date = Date()) -> [PlayerTab] {
        var tabs: [PlayerTab] = []
        if let playlist = request.playlist, canOpenEpisode(playlist.items.first?.id, canOpen: canOpen) {
            tabs.append(.episodes(playlist))
        }
        if let related = request.related, canOpenEpisode(related.items.first?.id, canOpen: canOpen) {
            tabs.append(.related(related))
        }
        if tabs.isEmpty, let schedule = request.schedule, !ScheduleTab.rows(schedule, at: now).isEmpty {
            tabs.append(.schedule(schedule))
        }
        return tabs
    }

    /// Every item opens its Episode Template Screen, so the first item stands for all.
    static func canOpenEpisode(_ id: String?, canOpen: (CardTarget) -> Bool) -> Bool {
        guard let id else { return false }
        return canOpen(CardTarget(resourceType: "episode", itemId: id))
    }
}

/// `AVPlayerViewController`, so the Info panel can take this renderer's actions
/// (`infoViewActions`), the Episodes, Related or Schedule tab (`customInfoViewControllers`), Up Next
/// (`contentProposalViewController`) and the Quality menu (`transportBarCustomMenuItems`). SwiftUI's
/// `VideoPlayer` does not expose them.
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let actions: [PlayerInfoAction]
    let tabs: [PlayerTab]
    let offer: UpNext.Offer?
    /// nil draws no Quality menu: an MP4, one height, or a playlist that did not load.
    let qualityOptions: [QualityLadder.Option]?
    /// The Like item's state; nil draws none (a livestream, a trailer).
    let liked: Bool?
    let theme: AppTheme
    let router: AppRouter
    let onCard: (CardTarget) -> Void
    let onEpisode: (_ id: String, _ automatic: Bool) -> Void
    let onClose: () -> Void
    let onQuality: (_ cap: Int) -> Void
    let onLike: () -> Void

    func makeCoordinator() -> ProposalDelegate { ProposalDelegate() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        context.coordinator.onEpisode = onEpisode
        controller.delegate = context.coordinator
        // Beside the system Info tab, which shows the title, show name and abstract (spec §5.3). Set
        // once: `PlayerView` is rebuilt per request (`.id(request.id)`).
        controller.customInfoViewControllers = tabs.map { tab in
            switch tab {
            case let .episodes(playlist):
                return EpisodesTab.controller(playlist, theme: theme) { onEpisode($0.id, false) }
            case let .related(related):
                return RelatedTab.controller(related, theme: theme) { onEpisode($0.id, false) }
            case let .schedule(schedule):
                // A livestream: "On now" and the next broadcasts (awe#6553).
                return ScheduleTab.controller(schedule, theme: theme, router: router)
            }
        }
        if let offer {
            controller.contentProposalViewController = UpNextProposalController(offer: offer, item: player.currentItem, theme: theme, closePlayer: onClose)
        }
        // Append: the system actions stay first.
        controller.infoViewActions += actions.map { action in
            switch action {
            case let .goToShow(target):
                let item = UIAction(title: action.title, image: UIImage(systemName: "rectangle.stack")) { _ in onCard(target) }
                // The UI tests find it by this id, not by the served label.
                item.accessibilityIdentifier = "info-go-to-show"
                return item
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // The playlist loads after the controller exists, so the menu arrives here. Rebuilt only
        // when its rows or the Like state change. Like first, then Quality, beside the system Audio
        // and Subtitles menus.
        if context.coordinator.qualityOptions != qualityOptions || context.coordinator.liked != liked {
            context.coordinator.qualityOptions = qualityOptions
            context.coordinator.liked = liked
            var items: [UIMenuElement] = liked.map { [TransportLike.action(liked: $0, toggle: onLike)] } ?? []
            items += qualityOptions.map { [Self.qualityMenu($0, choose: onQuality)] } ?? []
            controller.transportBarCustomMenuItems = items
        }
    }

    /// "Quality": Auto, then "Up to <height>" rows, with the current choice checked.
    private static func qualityMenu(_ options: [QualityLadder.Option], choose: @escaping (Int) -> Void) -> UIMenu {
        UIMenu(title: ChromeText.string(.quality), image: UIImage(systemName: "slider.horizontal.3"),
               options: .singleSelection, children: options.map { option in
                   UIAction(title: option.title, state: option.isOn ? .on : .off) { _ in choose(option.cap) }
               })
    }
}
