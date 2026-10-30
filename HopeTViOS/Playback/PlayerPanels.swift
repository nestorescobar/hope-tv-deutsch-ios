import SwiftUI

/// The details under the player in portrait (docs/PORTING.md Section 4): what the tvOS Info panel
/// shows (the description and the meta line), Go to show, then the tabs. The header stays in place
/// and only the list scrolls, so an episode far down a season keeps its title and description on
/// screen. A select starts an item through `AppRouter.playFromPlayer`, as on tvOS.
struct PlayerDetails: View {
    let request: PlaybackRequest
    /// The item's length, once it loads.
    let duration: Double?
    let tabs: [PlayerTab]
    let actions: [PlayerInfoAction]
    let onCard: (CardTarget) -> Void
    let onEpisode: (_ id: String) -> Void

    /// The height of a description that a tap opened. The rest of it scrolls, so the list stays.
    private static let openDescriptionHeight: CGFloat = 180

    @Environment(\.appTheme) private var theme
    @State private var selected = 0
    @State private var descriptionOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let show = request.metadata.showName {
                    Text(show.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
                Text(request.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if let line = request.metadata.metaLine(duration: duration) {
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("player-meta")
                }
            }
            description
            ForEach(actions, id: \.title) { action in
                switch action {
                case let .goToShow(target):
                    Button {
                        onCard(target)
                    } label: {
                        Label(action.title, systemImage: "rectangle.stack")
                    }
                    .buttonStyle(ActionButtonStyle())
                    .accessibilityIdentifier("info-go-to-show")
                }
            }
            if tabs.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button(tab.title) { selected = index }
                            .buttonStyle(ActionButtonStyle(prominent: index == selected))
                    }
                }
            }
            if tabs.indices.contains(selected) {
                ScrollViewReader { proxy in
                    ScrollView {
                        tabContent(tabs[selected])
                            .padding(.bottom, Layout.screenMargin)
                    }
                    // tvOS starts focus on the current item (awe#6550). A list that opens at the
                    // top would hide it in a long season.
                    .task(id: selected) {
                        if case let .episodes(playlist) = tabs[selected], let id = playlist.currentItemId {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
        }
        .padding([.horizontal, .top], Layout.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Two lines, and a tap opens the rest. With no list below (a movie) it has the space to open.
    @ViewBuilder
    private var description: some View {
        if let text = request.metadata.description, !text.isEmpty {
            let open = descriptionOpen || tabs.isEmpty
            let label = Text(text)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if open {
                    ScrollView { label }
                        .frame(maxHeight: tabs.isEmpty ? .infinity : Self.openDescriptionHeight)
                } else {
                    label.lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { descriptionOpen.toggle() }
            .accessibilityIdentifier("player-description")
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: PlayerTab) -> some View {
        switch tab {
        case let .episodes(playlist):
            let currentId = playlist.currentItemId
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(playlist.items) { item in
                    let isCurrent = item.id == currentId
                    PlayerItemRow(title: item.title, subtitle: nil, posterURL: item.posterURL, isCurrent: isCurrent) {
                        // The episode on show keeps playing.
                        if !isCurrent { onEpisode(item.id) }
                    }
                    .id(item.id)
                    .accessibilityIdentifier("episodes-tab-item")
                }
            }
        case let .related(related):
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(related.items) { item in
                    PlayerItemRow(title: item.title, subtitle: item.showTitle, posterURL: item.posterURL, isCurrent: false) {
                        onEpisode(item.id)
                    }
                    .accessibilityIdentifier("related-tab-item")
                }
            }
        case let .schedule(schedule):
            ScheduleTabList(schedule: schedule)
        }
    }
}

extension Playlist {
    /// The episode on show. nil when the list does not hold it.
    var currentItemId: String? { currentIndex.map { items[$0].id } }
}

extension PlaybackMetadata {
    /// The tvOS Info panel meta line (awe#6867): "Drama • 1h 52m • FSK 12". AVKit draws it there,
    /// but on iOS no system view shows these values. nil when nothing is known.
    func metaLine(duration: Double?) -> String? {
        let parts = [genre, DurationFormatter.short(seconds: duration), contentRating].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

extension PlayerTab {
    /// The label of the tab's chip.
    var title: String {
        switch self {
        case .episodes: return ChromeText.string(.episodesLabel)
        case .related: return ChromeText.string(.relatedLabel)
        case .schedule: return ChromeText.string(.scheduleLabel)
        }
    }
}

/// An episode in the Episodes or Related list.
private struct PlayerItemRow: View {
    let title: String
    let subtitle: String?
    let posterURL: URL?
    let isCurrent: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                RemoteImage(url: posterURL, blurhash: nil)
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    if isCurrent {
                        Text(ChromeText.string(.nowPlaying))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.background)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityValue(isCurrent ? ChromeText.string(.nowPlaying) : "")
    }
}

/// The live player's schedule (awe#6553): "On now", then the next broadcasts, for information only.
enum ScheduleTab {
    /// The rows at `now`, by the `ScheduleLive` clock rule: an ended row drops and "On now"
    /// moves. No target and no live action: every row is an information row. Empty: no tab.
    static func rows(_ schedule: [ScheduleModel.Entry]?, at now: Date) -> [ScheduleModel.Entry] {
        ScheduleModel.entries(schedule ?? [], at: now, live: nil).map { entry in
            var row = entry
            row.target = nil
            return row
        }
    }
}

private struct ScheduleTabList: View {
    let schedule: [ScheduleModel.Entry]

    @Environment(\.appTheme) private var theme
    @State private var now = Date()

    var body: some View {
        let rows = ScheduleTab.rows(schedule, at: now)
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                // Every row ended while the player was open.
                Text(ChromeText.string(.noSchedule))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(rows) { entry in
                ScheduleRow(entry: entry, now: now)
                    .accessibilityIdentifier("schedule-tab-item")
            }
        }
        .task { await ScheduleClock.run { now = $0 } }
    }
}

/// The Up Next offer (awe#6550, spec §5.4). tvOS shows it through AVKit's content proposal, which
/// iOS does not have, so this card draws over the player and `PlayerView` shows it at
/// `UpNext.offerTime`. The player keeps playing under it.
///
/// In `.countdown` the item plays when `countdown` runs out, unless the viewer closes the card. In
/// `.stillWatching` nothing plays until the viewer presses.
struct UpNextCard: View {
    let offer: UpNext.Offer
    var countdown: TimeInterval = UpNext.countdown
    /// `automatic` is true when the countdown started the item: `AppRouter.autoStarts` counts it.
    let onPlay: (_ automatic: Bool) -> Void
    let onClose: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var secondsLeft: Int?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: offer.item.posterURL, blurhash: nil)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(ChromeText.string(offer.mode == .stillWatching ? .stillWatching : .upNext))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityIdentifier(offer.mode == .stillWatching ? "still-watching" : "up-next")
                Text(offer.item.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("up-next-title")
                if offer.mode == .countdown, let secondsLeft {
                    Text(ChromeText.string(.upNextCountdown, ["seconds": "\(secondsLeft)"]))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("up-next-countdown")
                }
                Button(ChromeText.string(offer.mode == .stillWatching ? .continueWatching : .playNow)) {
                    onPlay(false)
                }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .accessibilityIdentifier("up-next-play")
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(ChromeText.string(.remove))
        }
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .task {
            guard offer.mode == .countdown else { return }
            let deadline = Date().addingTimeInterval(countdown)
            while !Task.isCancelled {
                let left = UpNext.secondsLeft(until: deadline, now: Date())
                secondsLeft = left
                if left == 0 {
                    onPlay(true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
