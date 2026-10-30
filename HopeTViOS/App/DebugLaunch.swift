import Foundation
import SwiftUI

#if DEBUG
/// Launch overrides for the simulator.
///
/// These arguments open a tab or a Screen directly, which is the only way to
/// capture evidence of a screen other than the first tab. `<bundle-id>` is the shell's
/// SHELL_BUNDLE_ID (`de.hopemedia.awe.hopetv` for the default shell):
///
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-tab-screen <tab screen id>
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-screen <id> -open-param <id>
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-tab-screen <tab screen id> -press-first-card 1
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-screen <id> -open-param <id> -press-play 1
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-tab-screen <Live screen id> -press-live-now 1
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-tab-screen <Live screen id> -press-live 1
///     xcrun simctl launch --console-pty <device> <bundle-id> -chrome-strings-file <path>
///     xcrun simctl launch --console-pty <device> <bundle-id> -open-screen <id> -open-param <id> -press-play 1 -playback-seek-to-end 20
///     xcrun simctl launch --console-pty <device> <bundle-id> -member-sign-in 1 -open-sign-in 1 -sign-in-override-file <path>
///
/// The sign-in args are in `DebugMemberSignIn` (`Member/MemberClient.swift`).
/// `-open-tab-screen` names the tab by its screen id, not its place: authors reorder tabs.
/// `-open-screen` is no substitute: it pushes the Screen above the tab on show.
/// `--console-pty` shows the `[tv] debug …` lines reliably; `--console` does not.
///
/// Debug builds only. It selects a route the manifest already carries; it cannot invent one.
enum DebugLaunch {
    @MainActor
    static func apply(to router: AppRouter) {
        let defaults = UserDefaults.standard

        if let id = askedTabScreenId {
            if let tab = tab(in: router) {
                router.state.selectTab(tab.screenId)
            } else {
                print("[tv] debug tab → no tab has the screen \(id)")
            }
        }

        if let screenId = defaults.string(forKey: "open-screen"), !screenId.isEmpty {
            router.open(screenId: screenId, param: defaults.string(forKey: "open-param"))
        }

        selectAccountTab(on: router)
    }

    /// `-open-account 1` (or `-open-sign-in 1`) selects the Account tab, when the tab bar has one.
    @MainActor
    static func selectAccountTab(on router: AppRouter) {
        guard DebugMemberSignIn.opensAccount else { return }
        guard router.tree.showsAccountTab else {
            print("[tv] debug account → this tab bar has no Account tab (flag off, or a bare entry)")
            return
        }
        router.state.selectTab(AccountTab.tag)
    }

    /// Selects the asked tab on the router built from the cached manifest, before the first
    /// frame. The TabView then opens on it, and the tab bar cannot pull it back to the first
    /// tab: that bounce started a Live inline player twice (awe#6410). `apply` runs again after
    /// the manifest refresh.
    @MainActor
    static func selectTabBeforeFirstFrame(on router: AppRouter) {
        selectAccountTab(on: router)
        guard askedTabScreenId != nil, let tab = tab(in: router) else { return }
        router.state.selectTab(tab.screenId)
    }

    /// `-seed-screen-cache <path>` writes that screen into last-known-good before anything
    /// loads, so the run paints it from the cache first (with `-screen-override-file` as the
    /// fresh copy, the cache is then not skipped).
    @MainActor
    static func seedScreenCache(_ store: ContractStore) {
        guard let path = UserDefaults.standard.string(forKey: "seed-screen-cache"), !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        store.seedCache(data)
        print("[tv] debug seeded the screen cache from \(path)")
    }

    /// `-open-tab-screen` can be undone while the tab bar still holds focus on its first tab:
    /// the TabView follows the focused tab item. Re-select the asked tab for a few seconds, while
    /// nothing is pushed. It measured about one launch in three on the simulator.
    @MainActor
    static func holdTab(on router: AppRouter) async {
        guard askedTabScreenId != nil, let tab = tab(in: router) else { return }
        for _ in 0..<6 {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            if router.state.stack.isEmpty, router.state.tabScreenId != tab.screenId {
                print("[tv] debug tab → re-selected \(tab.label)")
                router.state.selectTab(tab.screenId)
            }
        }
    }

    /// Presses the first card that carries a target, through the same `select` call the
    /// card Button makes (tap-to-play). It stands in for the remote press a script cannot send.
    @MainActor private static var pressed = false

    @MainActor
    static func pressFirstCard(in node: EvaluatedNode, router: AppRouter) {
        guard UserDefaults.standard.bool(forKey: "press-first-card"), !pressed, router.state.stack.isEmpty else { return }
        // The tab the run asked for, so a press never fires from a tab rendered underneath.
        guard router.state.tabScreenId == tab(in: router)?.screenId else {
            return
        }
        guard let shelf = node.first(where: { shelfCard($0) != nil }), let card = shelfCard(shelf) else { return }

        pressed = true
        print("[tv] debug press → \(card.title) target=\(String(describing: card.target))")
        router.select(card.target)
        print("[tv] debug stack → \(router.state.stack)")
    }

    /// Presses the first Play on a pushed screen, through the same `router.play` the button
    /// calls. Once per launch, so Back from the player stays on the screen.
    @MainActor private static var played = false

    @MainActor
    static func pressPlay(in node: EvaluatedNode, router: AppRouter) {
        guard UserDefaults.standard.bool(forKey: "press-play"), !played, !router.state.stack.isEmpty else { return }
        guard let action = node.first(where: {
            if case let .playAction(model) = $0.content { return model.request != nil }
            return false
        }), case let .playAction(model) = action.content, let request = model.request else { return }

        played = true
        print("[tv] debug play → \(request.title)")
        router.play(request)
    }

    /// Presses the first Live card, through the same `router.play` the card calls.
    /// `-press-live 1`, once per launch. With `-playback-override-url` it opens that stream.
    @MainActor private static var pressedInlineLive = false

    @MainActor
    static func pressLive(in node: EvaluatedNode, router: AppRouter) {
        guard UserDefaults.standard.bool(forKey: "press-live"), !pressedInlineLive,
              let found = node.first(where: { if case .player = $0.content { return true }; return false }),
              case let .player(model) = found.content else { return }
        pressedInlineLive = true
        print("[tv] debug live → \(model.request.title) \(model.request.url.absoluteString)")
        router.play(model.request)
    }

    /// Presses the on-air schedule row, through the same `router.play` its button calls.
    /// `-press-live-now 1`, once per launch.
    @MainActor private static var pressedLive = false

    @MainActor
    static func pressLiveNow(in rows: [ScheduleModel.Entry], router: AppRouter) {
        guard UserDefaults.standard.bool(forKey: "press-live-now"), !pressedLive,
              case let .live(request)? = rows.first(where: \.isCurrent)?.kind else { return }
        pressedLive = true
        print("[tv] debug live now → \(request.title)")
        router.play(request)
    }

    /// `-chrome-strings-file <path>`: a flat JSON object of chrome strings merged over the served
    /// ones, so a translation can be checked before it is published. Non-string values are
    /// dropped, as in the manifest decode. It also logs what the manifest served.
    static func chromeStrings(over served: [String: String]) -> [String: String] {
        let tvKeys = served.keys.filter { $0.hasPrefix("tv") }.count
        let sample = served.keys.sorted().prefix(2).map { "\($0)=\(served[$0] ?? "")" }.joined(separator: ", ")
        print("[tv] chrome strings served: \(served.count) (\(tvKeys) tv keys) \(sample)")
        guard let path = UserDefaults.standard.string(forKey: "chrome-strings-file"), !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let override = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return served }
        print("[tv] debug chrome strings from \(path): \(override.count) keys")
        return served.merging(override.compactMapValues(\.string)) { _, new in new }
    }

    /// `-analytics-override-file <path>`: a manifest `analytics` object (`{"provider":"umami",
    /// "websiteId":…,"host":"https://…"}`) that wins over the served one, so a run can send the like
    /// events to a test Umami site (awe#6871). nil when not asked or unusable.
    static var analyticsOverride: AnalyticsConfig? {
        guard let path = UserDefaults.standard.string(forKey: "analytics-override-file"), !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(AnalyticsConfig.self, from: data)
    }

    /// `-playback-seek-to-end <seconds>`: the full-screen player starts that long before the end of
    /// each item, so a run reaches Up Next at once. nil when not asked.
    static var playbackSeekToEnd: Double? {
        let seconds = UserDefaults.standard.double(forKey: "playback-seek-to-end")
        return seconds > 0 ? seconds : nil
    }

    /// `-open-tab-screen <screen id>`, or `nil` when the run does not ask for a tab.
    private static var askedTabScreenId: String? {
        UserDefaults.standard.string(forKey: "open-tab-screen")
    }

    /// The tab every tab arg acts on, so the select, the hold and the press guards agree: the
    /// asked tab, or the first tab when none is asked. An id that is no tab gives `nil`.
    @MainActor
    private static func tab(in router: AppRouter) -> TabRoute? {
        guard let id = askedTabScreenId else { return router.tree.tabs.first }
        return router.tree.tabs.first { $0.screenId == id }
    }

    private static func shelfCard(_ node: EvaluatedNode) -> CardModel? {
        guard case let .shelf(model) = node.content else { return nil }
        return model.cards.first { $0.target != nil }
    }
}

#endif
