import SwiftUI

/// The list under the player in portrait (docs/PORTING.md Section 4): the title and Go to show,
/// then the tabs that tvOS draws in the Info panel. A select starts an item through
/// `AppRouter.playFromPlayer`, as on tvOS.
struct PlayerDetails: View {
    let request: PlaybackRequest
    let tabs: [PlayerTab]
    let actions: [PlayerInfoAction]
    let onCard: (CardTarget) -> Void
    let onEpisode: (_ id: String) -> Void

    @Environment(\.appTheme) private var theme
    @State private var selected = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let show = request.metadata.showName {
                        Text(show.uppercased())
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                    Text(request.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
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
                    tabContent(tabs[selected])
                }
            }
            .padding(Layout.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: PlayerTab) -> some View {
        switch tab {
        case let .episodes(playlist):
            let currentId = playlist.currentIndex.map { playlist.items[$0].id }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(playlist.items) { item in
                    let isCurrent = item.id == currentId
                    PlayerItemRow(title: item.title, subtitle: nil, posterURL: item.posterURL, isCurrent: isCurrent) {
                        // The episode on show keeps playing.
                        if !isCurrent { onEpisode(item.id) }
                    }
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
