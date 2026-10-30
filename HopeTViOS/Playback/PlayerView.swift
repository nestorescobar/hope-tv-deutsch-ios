import AVKit
import SwiftUI

/// Native full-screen playback. The contract got as far as naming a source; everything
/// from here is the client's.
///
/// `AVPlayerViewController` draws the transport bar. In portrait the video sits at the top with
/// `PlayerDetails` under it; in landscape it fills the screen beside a thin rail. The one player
/// view stays in place across a rotation, so playback never restarts.
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
    /// The item's length, for the meta line under the player.
    @State private var mediaDuration: Double?
    /// The item's own end notification: a stream can stop short of its reported duration.
    @State private var itemEnded = false
    @State private var itemEndObserver: NSObjectProtocol?
    @State private var artwork: Task<Void, Never>?
    /// Up Next for this episode, decided once when it starts (`router.autoStarts` is read then).
    @State private var offer: UpNext.Offer?
    /// The playhead is past `UpNext.offerTime`, so the card shows.
    @State private var offerDue = false
    /// The viewer closed the card: it stays closed for the rest of this item.
    @State private var offerClosed = false
    @State private var offerObserver: Any?
    /// This item's Quality picker, once its master playlist offers two heights or more (awe#6868).
    @State private var quality: QualityLadder?
    @State private var qualityCap = QualityPreference().cap
    @State private var qualityTask: Task<Void, Never>?
    #if DEBUG
    /// Debug builds log each variant switch, so a run can prove the cap (`[tv] quality:` lines).
    @State private var accessLogObserver: NSObjectProtocol?
    #endif

    /// The width of the landscape rail, inside the black bars beside a 16:9 video.
    private static let railWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let videoHeight = landscape ? geometry.size.height : geometry.size.width * 9 / 16
            let topBar: CGFloat = landscape ? 0 : 52

            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                Group {
                    if let player {
                        PlayerController(player: player)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: geometry.size.width - (landscape ? Self.railWidth : 0), height: videoHeight)
                .offset(x: landscape ? Self.railWidth : 0, y: topBar)

                if landscape {
                    VStack(spacing: 8) { chrome }
                        .frame(width: Self.railWidth)
                } else {
                    HStack(spacing: 8) { chrome }
                        .padding(.horizontal, 8)
                        .frame(height: topBar)
                    PlayerDetails(request: request,
                                  duration: mediaDuration,
                                  tabs: PlayerTab.tabs(for: request, canOpen: router.canOpenCard),
                                  actions: PlayerInfoAction.actions(for: request, canOpen: router.canOpenCard),
                                  onCard: { target in
                                      stop()
                                      router.leavePlayback(openingCard: target)
                                  },
                                  onEpisode: { router.playFromPlayer(episodeId: $0, automatic: false) })
                        .padding(.top, topBar + videoHeight)
                }
            }
            .overlay(alignment: landscape ? .bottomTrailing : .bottom) {
                if let offer, offerDue, !offerClosed {
                    UpNextCard(offer: offer,
                               onPlay: { router.playFromPlayer(episodeId: offer.item.id, automatic: $0) },
                               onClose: closeOffer)
                        .frame(maxWidth: 420)
                        .padding(Layout.screenMargin)
                }
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
        .onAppear { OrientationLock.set(.allButUpsideDown) }
        .onDisappear {
            stop()
            // A new request replaces this view inside the cover; only the end of playback turns back.
            if router.playback == nil { OrientationLock.set(.portrait) }
        }
    }

    /// Close, then From Beginning, Like and Quality when this item has them.
    @ViewBuilder
    private var chrome: some View {
        Button {
            dismiss()
        } label: {
            glyph("xmark")
        }
        .accessibilityLabel(ChromeText.string(.remove))
        .accessibilityIdentifier("player-close")

        Spacer(minLength: 0)

        // AVKit draws "From Beginning" in the tvOS Info panel and offers nothing like it on iOS.
        // The contract has no string for it, so the button is a glyph and reads as Play. It waits
        // for the player: until then a resume seek runs and a press would do nothing.
        if request.recordsProgress, player != nil {
            Button {
                startOver()
            } label: {
                glyph("backward.end.fill")
            }
            .accessibilityLabel(ChromeText.string(.play))
            .accessibilityIdentifier("player-from-beginning")
        }

        // Read here, so a press redraws the item as "Liked" (awe#6871).
        if let item = request.likeItem {
            let liked = likes.isLiked(item)
            Button {
                Task { await likes.toggle(item) }
            } label: {
                glyph(liked ? "heart.fill" : "heart")
            }
            .accessibilityLabel(ChromeText.string(liked ? .liked : .like))
            .accessibilityIdentifier("player-like")
        }

        if let options = quality?.options(cap: qualityCap) {
            Menu {
                ForEach(options, id: \.cap) { option in
                    Button {
                        chooseQuality(option.cap)
                    } label: {
                        if option.isOn {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                glyph("slider.horizontal.3")
            }
            .accessibilityLabel(ChromeText.string(.quality))
            .accessibilityIdentifier("player-quality")
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 44, height: 44)
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
        itemEndObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                                 queue: .main) { _ in
            MainActor.assumeIsolated { itemEnded = true }
        }
        // A live stream with a DVR window reports a length too, and it means nothing.
        if request.recordsProgress, let duration = try? await item.asset.load(.duration) {
            mediaDuration = Self.seconds(duration)
        }
        await propose(on: item)
    }

    /// Plays this item again from the start. The progress observers carry on and write the new point.
    private func startOver() {
        itemEnded = false
        player?.seek(to: .zero)
        player?.play()
    }

    /// The Up Next card's close. Before the end the item plays on. After the end nothing is left
    /// to watch, so the player closes, as on tvOS (awe#6550).
    private func closeOffer() {
        offerClosed = true
        guard let item = player?.currentItem else { return }
        if Self.closesAfterOffer(itemEnded: itemEnded, currentTime: item.currentTime().seconds, duration: item.duration.seconds) {
            dismiss()
        }
    }

    /// `UpNext.hasEnded` covers the moment before the end notification reaches the main queue.
    static func closesAfterOffer(itemEnded: Bool, currentTime: TimeInterval, duration: TimeInterval) -> Bool {
        itemEnded || UpNext.hasEnded(currentTime: currentTime, duration: duration)
    }

    /// The season list for Up Next, when an item can open. A livestream and a trailer carry none.
    private var playlist: Playlist? {
        guard let playlist = request.playlist, PlayerTab.canOpenEpisode(playlist.items.first?.id, canOpen: router.canOpenCard) else { return nil }
        return playlist
    }

    /// Shows the Up Next card `UpNext.offerLead` before the end. It needs the duration, so it runs
    /// after playback starts and never delays the stream. A scrub back before the offer time
    /// hides the card again.
    private func propose(on item: AVPlayerItem) async {
        guard offer != nil, let player, let duration = try? await item.asset.load(.duration), duration.isNumeric,
              duration.seconds > 0, !Task.isCancelled else { return }
        // A resume point can be past the usual offer time; the offer then shows 1 s from now.
        let offerTime = UpNext.offerTime(duration: duration.seconds, now: item.currentTime().seconds)
        offerObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated { offerDue = time.seconds >= offerTime }
        }
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
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = nil
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        if let offerObserver, let player {
            player.removeTimeObserver(offerObserver)
        }
        offerObserver = nil
        player?.pause()
        player = nil
    }

    /// Close returns to the screen Play was pressed on: the stack under the cover is unchanged.
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

/// The actions this renderer adds under the player. Pure, so the rule is testable.
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

/// The lists under the player (`PlayerDetails`). Pure, so the rule is testable.
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

/// `AVPlayerViewController` for the transport bar, the rate and audio menus, AirPlay and Picture in
/// Picture. `allowsPictureInPicturePlayback` is on by default; the automatic start is not.
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
