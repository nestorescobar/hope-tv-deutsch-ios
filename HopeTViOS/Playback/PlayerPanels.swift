// cspell:ignore autoresizing Subview
import AVKit
import SwiftUI

/// The player's Episodes tab (awe#6550, spec §5.3): the season list, beside the system Info tab
/// (`customInfoViewControllers`). Select starts an item through `AppRouter.playFromPlayer`.
enum EpisodesTab {
    /// The tab height. The system caps it; this fits a card, its lift and two title lines.
    ///
    /// Each tab sets `safeAreaRegions = []`. AVKit sizes a panel that opens again from the view's
    /// fitting size, and that size adds the safe-area inset the view has then (measured 342 pt at
    /// the bottom), so the panel grew and left empty space under the row.
    static let height: CGFloat = 400

    @MainActor
    static func controller(_ playlist: Playlist, theme: AppTheme, onSelect: @escaping (Playlist.Item) -> Void) -> UIViewController {
        let host = UIHostingController(rootView: AnyView(EpisodesTabView(playlist: playlist, onSelect: onSelect).environment(\.appTheme, theme)))
        // The tab title.
        host.title = ChromeText.string(.episodesLabel)
        host.safeAreaRegions = []
        host.preferredContentSize = CGSize(width: 1920, height: height)
        host.view.backgroundColor = .clear
        return host
    }
}

/// The player's Related tab (awe#7391): the cross-show `relatedEpisodes`, after the Episodes tab.
/// Select starts an item as the Episodes tab does. The current episode is never in the list, so
/// no item is "Now playing".
enum RelatedTab {
    @MainActor
    static func controller(_ related: RelatedEpisodes, theme: AppTheme, onSelect: @escaping (RelatedEpisodes.Item) -> Void) -> UIViewController {
        let host = UIHostingController(rootView: AnyView(RelatedTabView(related: related, onSelect: onSelect).environment(\.appTheme, theme)))
        // The tab title.
        host.title = ChromeText.string(.relatedLabel)
        host.safeAreaRegions = []
        host.preferredContentSize = CGSize(width: 1920, height: EpisodesTab.height)
        host.view.backgroundColor = .clear
        return host
    }
}

/// The live player's Schedule tab (awe#6553): "On now", then the next broadcasts, in the info
/// panel (`customInfoViewControllers`). The rows are the `ScheduleLive` rows, for information only: Select does
/// nothing, so no row leaves the player. Every row still takes focus, so the D-pad scrolls.
enum ScheduleTab {
    /// The tab height. It fits the on-air row (`ScheduleRowMetrics`) and its focus border.
    static let height: CGFloat = 400

    /// The rows at `now`, by the `ScheduleLive` clock rule: an ended row drops and "On now"
    /// moves. No target and no live action: every row is an information row. Empty: no tab.
    static func rows(_ schedule: [ScheduleModel.Entry]?, at now: Date) -> [ScheduleModel.Entry] {
        ScheduleModel.entries(schedule ?? [], at: now, live: nil).map { entry in
            var row = entry
            row.target = nil
            return row
        }
    }

    @MainActor
    static func controller(_ schedule: [ScheduleModel.Entry], theme: AppTheme, router: AppRouter) -> UIViewController {
        let clock = ScheduleTabClock()
        let view = ScheduleTabView(schedule: schedule, clock: clock).environment(\.appTheme, theme).environment(router)
        let host = ScheduleTabController(rootView: AnyView(view), clock: clock)
        // The tab title.
        host.title = ChromeText.string(.scheduleLabel)
        host.safeAreaRegions = []
        host.preferredContentSize = CGSize(width: 1920, height: height)
        host.view.backgroundColor = .clear
        return host
    }
}

/// The time the Schedule tab draws. The controller sets it each time the tab shows.
@Observable
final class ScheduleTabClock {
    var now = Date()
}

/// Reads the clock each time AVKit shows the tab, so "On now" moves while the player stays open.
final class ScheduleTabController: UIHostingController<AnyView> {
    /// Internal so a test can read it.
    let clock: ScheduleTabClock

    init(rootView: AnyView, clock: ScheduleTabClock) {
        self.clock = clock
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        clock.now = Date()
    }
}

private struct ScheduleTabView: View {
    let schedule: [ScheduleModel.Entry]
    let clock: ScheduleTabClock

    @Environment(\.appTheme) private var theme
    @FocusState private var focused: String?

    var body: some View {
        let rows = ScheduleTab.rows(schedule, at: clock.now)
        if rows.isEmpty {
            // Every row ended while the player was open.
            Text(ChromeText.string(.noSchedule))
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 80)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 32) {
                    ForEach(rows) { entry in
                        ScheduleRow(entry: entry, now: clock.now, focus: $focused)
                            .accessibilityIdentifier("schedule-tab-item")
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, rows.first?.id)
        }
    }
}

private struct EpisodesTabView: View {
    let playlist: Playlist
    let onSelect: (Playlist.Item) -> Void

    @Environment(\.appTheme) private var theme
    @FocusState private var focused: String?

    private var currentId: String? { playlist.currentIndex.map { playlist.items[$0].id } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(playlist.items) { item in
                        let isCurrent = item.id == currentId
                        VStack(alignment: .leading, spacing: 14) {
                            Button {
                                // The episode on show keeps playing.
                                if !isCurrent {
                                    onSelect(item)
                                }
                            } label: {
                                RemoteImage(url: item.posterURL, blurhash: nil)
                                    .frame(width: 384, height: 216)
                            }
                            .buttonStyle(.card)
                            .focused($focused, equals: item.id)
                            .accessibilityLabel(item.title)
                            .accessibilityValue(isCurrent ? ChromeText.string(.nowPlaying) : "")
                            .accessibilityIdentifier("episodes-tab-item")

                            if isCurrent {
                                // A filled badge, as a selected chip: accent text alone was hard to read on the video.
                                Text(ChromeText.string(.nowPlaying))
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 8))
                            }
                            // The panel draws on a system material, so the text uses its styles.
                            Text(item.title)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(width: 384, alignment: .leading)
                        }
                        .id(item.id)
                    }
                }
                // AVKit already insets the panel to the tab bar's edge, so a leading pad would
                // indent the first card past the Info content.
                .padding(.trailing, 80)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, currentId)
            .onAppear {
                if let currentId {
                    proxy.scrollTo(currentId, anchor: .leading)
                }
            }
        }
    }
}

/// The Episodes tab card layout, with the show name as one secondary line under the title.
private struct RelatedTabView: View {
    let related: RelatedEpisodes
    let onSelect: (RelatedEpisodes.Item) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 48) {
                ForEach(related.items) { item in
                    VStack(alignment: .leading, spacing: 14) {
                        Button {
                            onSelect(item)
                        } label: {
                            RemoteImage(url: item.posterURL, blurhash: nil)
                                .frame(width: 384, height: 216)
                        }
                        .buttonStyle(.card)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item.showTitle ?? "")
                        .accessibilityIdentifier("related-tab-item")

                        // The panel draws on a system material, so the text uses its styles.
                        Text(item.title)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(width: 384, alignment: .leading)
                        if let showTitle = item.showTitle {
                            Text(showTitle)
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 384, alignment: .leading)
                                .accessibilityIdentifier("related-tab-show")
                        }
                    }
                }
            }
            // No leading pad, as the Episodes tab.
            .padding(.trailing, 80)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}

/// The Up Next offer (awe#6550, spec §5.4): the platform's content proposal
/// (`AVPlayerViewController.contentProposalViewController`, ADR-0244). The player shrinks to
/// `preferredPlayerViewFrame` and keeps playing; the next item shows beside it.
///
/// In `.countdown` the item plays when `countdown` runs out, unless the viewer presses Back. In
/// `.stillWatching` nothing plays until the viewer presses.
final class UpNextProposalController: AVContentProposalViewController {
    let offer: UpNext.Offer
    private let countdown: TimeInterval
    private let theme: AppTheme
    private let clock = UpNextClock()
    private var timer: Timer?
    /// Set by an accept or by Back, for one showing. Later ticks and presses do nothing.
    private var decided = false
    private var viewerPressed = false
    /// Back on an offer whose item has ended: close the player (`PlayerView.dismiss`).
    private let closePlayer: () -> Void

    /// Back canceled the offer for the rest of this item (`ProposalDelegate.shouldPresent`). One
    /// controller serves one item, so it never resets.
    private(set) var canceled = false

    /// The item posted its own end (`didPlayToEndTimeNotification`). The time check alone misses
    /// a stream that stops short of its reported duration, and Back would then replay it from 0.
    private(set) var itemEnded = false
    /// Held, because the observer matches it by address: a freed item's address can come back as
    /// another item's.
    private let item: AVPlayerItem?

    /// True when the accept was the countdown's, not a press: `AppRouter.autoStarts` counts it.
    var startsByItself: Bool { offer.mode == .countdown && !viewerPressed }

    /// `item` is the episode this offer follows. Only its end counts: the previous player's item
    /// can still post after the next one starts.
    init(offer: UpNext.Offer, item: AVPlayerItem?, countdown: TimeInterval = UpNext.countdown, theme: AppTheme,
         closePlayer: @escaping () -> Void) {
        self.offer = offer
        self.countdown = countdown
        self.theme = theme
        self.closePlayer = closePlayer
        self.item = item
        super.init(nibName: nil, bundle: nil)
        if let item {
            // A selector observer is removed when the controller goes away.
            NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEnd),
                                                   name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }
    }

    /// AVFoundation can post on any thread.
    @objc nonisolated private func itemDidPlayToEnd(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.itemEnded = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The player, scaled down on the left half of the 1920 × 1080 stage.
    static let playerFrame = CGRect(x: 96, y: 252, width: 1024, height: 576)

    override var preferredPlayerViewFrame: CGRect { Self.playerFrame }

    override func viewDidLoad() {
        super.viewDidLoad()
        let view = UpNextView(offer: offer, clock: clock, leading: Self.playerFrame.maxX + 64) { [weak self] in
            self?.accept(byViewer: true)
        }
        let host = UIHostingController(rootView: AnyView(view.environment(\.appTheme, theme)))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// AVKit can show the same controller again (the header: a scrub back over the transition
    /// time). Each showing decides anew.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        decided = false
        viewerPressed = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The timer below is the only acceptor. AVKit's own automatic accept would bypass
        // `decided` and start the item twice, so it stays off; its interval also counts from the
        // END of the item, not from the offer.
        dateOfAutomaticAcceptance = nil
        guard offer.mode == .countdown else { return }
        let deadline = Date().addingTimeInterval(countdown)
        clock.secondsLeft = UpNext.secondsLeft(until: deadline, now: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.secondsLeft = UpNext.secondsLeft(until: deadline, now: Date())
                if self.clock.secondsLeft == 0 {
                    self.accept(byViewer: false)
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTimer()
    }

    /// Back cancels for the rest of this item: the offer goes away, the item plays on to its end,
    /// and the offer does not come back (a scrub back over the transition time would show it
    /// again). After the end, `.defer` would replay the item from the start and write its progress
    /// again, so Back closes the player instead.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }), !decided else {
            super.pressesBegan(presses, with: event)
            return
        }
        decided = true
        stopTimer()
        // The time check also covers the moment before the end notification reaches the main queue.
        let item = playerViewController?.player?.currentItem
        if itemEnded || item.map({ UpNext.hasEnded(currentTime: $0.currentTime().seconds, duration: $0.duration.seconds) }) == true {
            closePlayer()
            return
        }
        // The gate, not `nextContentProposal = nil`: the dismiss completion did not run (measured),
        // and AVKit asked to show the offer again after a scrub back.
        canceled = true
        dismissContentProposal(for: .defer, animated: true, completion: nil)
    }

    private func accept(byViewer: Bool) {
        guard !decided else { return }
        decided = true
        viewerPressed = byViewer
        stopTimer()
        dismissContentProposal(for: .accept, animated: true, completion: nil)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// The countdown the offer draws.
@Observable
final class UpNextClock {
    var secondsLeft: Int?
}

private struct UpNextView: View {
    let offer: UpNext.Offer
    let clock: UpNextClock
    /// Where the column starts: right of the scaled-down player.
    let leading: CGFloat
    let onPlay: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(ChromeText.string(offer.mode == .stillWatching ? .stillWatching : .upNext))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.accent)
                .accessibilityIdentifier(offer.mode == .stillWatching ? "still-watching" : "up-next")
            RemoteImage(url: offer.item.posterURL, blurhash: nil)
                .frame(width: 560, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(offer.item.title)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .accessibilityIdentifier("up-next-title")
            if offer.mode == .countdown, let seconds = clock.secondsLeft {
                Text(ChromeText.string(.upNextCountdown, ["seconds": "\(seconds)"]))
                    .font(.system(size: 28))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("up-next-countdown")
            }
            Button(action: onPlay) {
                Text(ChromeText.string(offer.mode == .stillWatching ? .continueWatching : .playNow))
            }
            .accessibilityIdentifier("up-next-play")
        }
        .frame(width: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, leading)
    }
}

/// The Up Next accept: it starts the offered item, and tells whether the countdown started it.
@MainActor
final class ProposalDelegate: NSObject, AVPlayerViewControllerDelegate {
    var onEpisode: ((_ id: String, _ automatic: Bool) -> Void)?
    /// The Quality menu rows on show (awe#6868), so an unrelated update does not rebuild the menu.
    var qualityOptions: [QualityLadder.Option]?
    /// The Like item's state on show (awe#6871), for the same reason.
    var liked: Bool?

    /// No offer again after Back canceled it for this item, also after a scrub back over the
    /// transition time.
    func playerViewController(_ playerViewController: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
        let canceled = (playerViewController.contentProposalViewController as? UpNextProposalController)?.canceled == true
        return !canceled
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal) {
        guard let upNext = playerViewController.contentProposalViewController as? UpNextProposalController else { return }
        onEpisode?(upNext.offer.item.id, upNext.startsByItself)
    }

    /// Nothing to do: Back defers, so the episode plays on.
    func playerViewController(_ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal) {}
}
