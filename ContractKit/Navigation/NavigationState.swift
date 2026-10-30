import Foundation
import Observation

/// One screen on the stack. `param` is set for a Template Screen only — the contract
/// answers 400 without it.
struct StackEntry: Hashable, Identifiable {
    let screenId: String
    let param: String?
    /// Set for a layout frame: the tab bar of this layout, opened on the tab `screenId`.
    var layoutId: String? = nil

    var id: String { "\(screenId)#\(param ?? "")" + (layoutId.map { "@\($0)" } ?? "") }

    /// The entry a tab of this layout frame draws. Only the tab the frame opened on keeps the param.
    func frameTab(_ screenId: String) -> StackEntry {
        StackEntry(screenId: screenId, param: screenId == self.screenId ? param : nil)
    }
}

/// The TV navigation stack: root stack → layout tabs → screen stack.
///
/// Pure, so the back key, a tab press and a `screen` link are one testable decision
/// instead of three handlers.
struct NavigationState: Equatable {
    /// The base of the stack: the active tab's Screen id, or the bare Entry Screen's id.
    var tabScreenId: String
    /// Screens pushed above the base, innermost last. It holds at most one layout frame.
    var stack: [StackEntry] = []
    /// The tab on show in the open layout frame. Read only while `frame` is set.
    var frameTabScreenId: String?
    /// The param of each root Screen (`NavigationTree.rootParams`), for `current`.
    var rootParams: [String: String] = [:]

    /// The open layout frame, if any (`StackEntry.layoutId`).
    var frame: StackEntry? { stack.first { $0.layoutId != nil } }

    /// Nothing is pushed: the root shows, or a layout frame opened right above the bare entry.
    var isAtRoot: Bool { stack.isEmpty || (stack.count == 1 && stack[0].layoutId != nil) }

    var current: StackEntry {
        guard let last = stack.last else { return StackEntry(screenId: tabScreenId, param: rootParams[tabScreenId]) }
        guard last.layoutId != nil else { return last }
        return last.frameTab(frameTabScreenId ?? last.screenId)
    }

    mutating func openFrame(_ frame: StackEntry) {
        stack.append(frame)
        frameTabScreenId = frame.screenId
    }

    /// Switching tabs resets the stack — a tab is a root, not a history entry.
    mutating func selectTab(_ screenId: String) {
        guard tabScreenId != screenId || !stack.isEmpty else { return }
        tabScreenId = screenId
        stack = []
    }

    mutating func push(_ entry: StackEntry) {
        stack.append(entry)
    }

    /// The back key. Pops a pushed screen; on any other tab root it returns to the ROOT
    /// tab; on the root tab's own root it answers false, which the shell turns into
    /// "leave the app". Both TV stores certify this.
    ///
    /// Above a bare Entry Screen, as in `apps/mobile`: a pushed Screen pops first. On any tab of
    /// a layout frame, Back closes the frame and returns to the Screen it opened from (the entry,
    /// or a Screen pushed above it). On the entry, Back leaves the app. On tvOS the native
    /// `NavigationStack` applies this: the frame is one element of its path (`RootView`).
    mutating func goBack(rootScreenId: String) -> Bool {
        if !stack.isEmpty {
            stack.removeLast()
            return true
        }
        if tabScreenId != rootScreenId {
            tabScreenId = rootScreenId
            return true
        }
        return false
    }
}

/// The router the views bind to.
@MainActor
@Observable
final class AppRouter {
    /// A change ends a tap-to-play press: the viewer moved on (Back, another tab, a push).
    var state: NavigationState {
        didSet { if selecting != nil, state != oldValue { endPress() } }
    }
    var tree: NavigationTree
    /// A full-screen playback intent. Nothing plays inline.
    var playback: PlaybackRequest?

    /// True when nothing is pushed and nothing is playing — the only point at which a
    /// structural contract change may be applied (invariant 3). A layout frame's tab root counts
    /// as not pushed: like the tab bar root, a viewer can stay on it for hours, and `rebuild`
    /// resets a frame the new manifest does not carry.
    var isAtSafeBoundary: Bool { state.isAtRoot && playback == nil }

    let diagnostics: Diagnostics
    /// One report per resource type, for the whole session.
    private var reportedCardTypes = Set<String>()

    init(tree: NavigationTree, diagnostics: Diagnostics) {
        self.tree = tree
        self.diagnostics = diagnostics
        self.state = NavigationState(tabScreenId: tree.rootScreenId ?? "", rootParams: tree.rootParams)
    }

    func rebuild(with manifest: AppManifest) {
        tree = NavigationTree(manifest: manifest)
        for issue in tree.issues {
            diagnostics.log(.warn, "Manifest authoring gap", issue)
        }
        // A new manifest may not carry the tab, the entry or the frame that was showing.
        if !tree.keeps(state) {
            state = NavigationState(tabScreenId: tree.rootScreenId ?? "", rootParams: tree.rootParams)
        } else {
            // A kept state still takes the entry param of the new manifest, so a cached
            // manifest from before `entryParam` does not keep the entry without its record.
            state.rootParams = tree.rootParams
        }
    }

    /// Episodes in a row that the Up Next countdown started (awe#6550). At
    /// `UpNext.stillWatchingAfter` the next offer asks "Still watching?". It lives here, not in a
    /// `PlayerView`, because each episode gets a new player view.
    private(set) var autoStarts = 0

    /// Play / Resume. The full-screen player sits above the stack, so dismissing it returns to
    /// the screen it was opened from (ruled 2026-09-23). `automatic` is true only for a start by
    /// the Up Next countdown; any start the viewer makes resets the count.
    func play(_ request: PlaybackRequest, automatic: Bool = false) {
        // Playback from anywhere ends a tap-to-play press, so its late answer cannot replace it.
        if selecting != nil { endPress() }
        autoStarts = automatic ? autoStarts + 1 : 0
        playback = request
    }

    /// Back from the player. It also ends a press the player started (Episodes tab, Up Next), so
    /// its late answer never opens a player again.
    func endPlayback() {
        if selecting != nil { endPress() }
        autoStarts = 0
        playback = nil
    }

    /// "Go to show" from the player's Info panel: close the player, then open the show the way
    /// a show card does. From Home → Episode, the show opens above the Episode screen and Back
    /// returns there. From Show → Episode, the Show screen is right under, so the Episode screen
    /// is popped and Back leaves the Show screen (see `push`).
    func leavePlayback(openingCard target: CardTarget) {
        endPlayback()
        openCard(target)
    }

    /// A Screen on no tab bar opens on its first action (`TakesDefaultFocus`): a pushed Screen,
    /// or the bare entry at the root. A tab root, in a layout frame too, keeps focus in its tab bar.
    func takesDefaultFocus(_ entry: StackEntry) -> Bool {
        if state.stack.last == entry { return true }
        guard case .screen = tree.initialRoute else { return false }
        return state.stack.isEmpty && state.current == entry
    }

    /// A `screen` link from a Button. An unknown screen id is a no-op plus one log line —
    /// never a fallback to another screen.
    func open(screenId: String?, param: String?) {
        guard let entry = tree.resolveTarget(screenId: screenId, param: param, currentParam: state.current.param) else {
            diagnostics.log(.reject, "Link refused", "screen \"\(screenId ?? "none")\" is not in the manifest")
            return
        }
        push(entry)
    }

    /// Opening the screen that sits right under the current one goes back to it instead of
    /// stacking a copy: Show → Episode → "Go to show" is Show again, not Show → Episode → Show.
    ///
    /// Above a bare Entry Screen no tab bar shows. There, a Screen that is a tab of its layout
    /// opens a layout frame: that tab bar, on that tab (`routeForTarget` in `apps/mobile`). Once
    /// a tab bar shows, a push stays a push.
    private func push(_ entry: StackEntry) {
        if case .screen = tree.initialRoute, state.frame == nil,
           let layoutId = tree.tabLayoutId(of: entry.screenId) {
            state.openFrame(StackEntry(screenId: entry.screenId, param: entry.param, layoutId: layoutId))
        } else if state.stack.dropLast().last == entry {
            state.stack.removeLast()
        } else {
            state.push(entry)
        }
    }

    /// A card press.
    ///
    /// A served Screen link (awe#4519) is the target when the item carries one: it names
    /// both the Screen and the param. Otherwise the renderer convention applies — a card
    /// opens the manifest's Template Screen whose `resourceType` equals the item's type,
    /// with `param` = the item's id. Exactly one candidate opens through the same route
    /// table as a `screen` link. Zero or several is a no-op plus one log per resource type —
    /// the renderer never builds a route from content, and never guesses across types.
    func openCard(_ target: CardTarget?) {
        guard let target else {
            reportCardOnce("none", "the pressed card carries no record id")
            return
        }
        if let entry = entry(for: target) {
            push(entry)
            return
        }

        // Refused. A served link fails closed: a Screen the manifest does not carry opens
        // nothing, and never falls back to the convention.
        if let link = target.link {
            reportCardOnce(
                "link:\(link.screenId)",
                "the served Screen link names \"\(link.screenId)\", which is not in the manifest"
            )
            return
        }
        let candidates = tree.templates(for: target.resourceType)
        reportCardOnce(
            target.resourceType,
            candidates.isEmpty
                ? "no Template Screen declares resourceType \"\(target.resourceType)\""
                : candidates.count > 1
                    ? "\(candidates.count) Template Screens declare resourceType \"\(target.resourceType)\""
                    : "the Template Screen for \"\(target.resourceType)\" refused the item id"
        )
    }

    /// Tap-to-play: loads a Template Screen and answers its Play request, or nil. The app sets it
    /// (`ContractStore.playRequest`). With none, an episode card opens its screen.
    var playRequest: (@MainActor (StackEntry) async -> PlaybackRequest?)?

    /// The card whose episode loads for tap-to-play. Its view shows a loading cue, and every other
    /// card press waits until it ends.
    private(set) var selecting: CardTarget?

    /// How long a tap-to-play press waits for its answer before it opens the Episode Screen, which
    /// shows its own loading state (developer ruling 2026-10-10).
    static let tapToPlayTimeLimit: Duration = .seconds(3)
    /// `tapToPlayTimeLimit`; tests make it shorter.
    var tapToPlayTimeLimit = AppRouter.tapToPlayTimeLimit

    /// Names the press in progress. Each press, and each end of one, moves it on, so an answer
    /// or a time limit acts only for its own press.
    private var pressToken = 0

    private func endPress() {
        pressToken += 1
        selecting = nil
    }

    /// A card press, with tap-to-play (awe#6549, spec §5.1). A target that opens the episode
    /// Template Screen loads that screen and plays its `EpisodePlayer` source over the screen on
    /// show. A source this device cannot play, a failed load, or no answer within
    /// `tapToPlayTimeLimit` opens the Episode Screen as `openCard` does: it draws the "can't play"
    /// message, its error or its loading state. Any other target opens at once.
    ///
    /// The press ends when it acts, or when the viewer moves on (`state` changes) or playback
    /// starts from elsewhere; a late answer then does nothing. The returned task ends when the
    /// answer arrives (tests await it).
    @discardableResult
    func select(_ target: CardTarget?) -> Task<Void, Never>? {
        guard selecting == nil else { return nil }
        guard let target, let entry = entry(for: target), opensEpisode(entry), let playRequest else {
            openCard(target)
            return nil
        }
        return press(target, entry: entry, loader: playRequest, play: { self.play($0) }, fallback: { self.push(entry) })
    }

    /// A playlist item from the player: the Episodes tab, or Up Next (awe#6550). The same press as
    /// a card (`select`): it loads the item's Episode Template Screen and plays its Play request in
    /// place of the current one, so the stack under the player does not change and Back still
    /// returns there. A source this device cannot play, a failed load, or no answer within
    /// `tapToPlayTimeLimit` closes the player and opens that Episode Screen. `automatic` marks a
    /// start by the Up Next countdown (`autoStarts`).
    ///
    /// Ignored with no player up, or while another press waits.
    @discardableResult
    func playFromPlayer(episodeId: String, automatic: Bool) -> Task<Void, Never>? {
        guard playback != nil, selecting == nil else { return nil }
        let target = CardTarget(resourceType: "episode", itemId: episodeId)
        guard let entry = entry(for: target), opensEpisode(entry) else {
            reportCardOnce("episode", "a playlist item cannot open the episode Template Screen")
            return nil
        }
        let fallback = {
            self.endPlayback()
            self.push(entry)
        }
        guard let playRequest else {
            fallback()
            return nil
        }
        return press(target, entry: entry, loader: playRequest, play: { self.play($0, automatic: automatic) }, fallback: fallback)
    }

    /// One tap-to-play press: load `entry`, then `play` its request, or `fallback` on no request or
    /// at the time limit. Whatever comes first ends the press; the other does nothing.
    private func press(
        _ target: CardTarget,
        entry: StackEntry,
        loader: @escaping @MainActor (StackEntry) async -> PlaybackRequest?,
        play: @escaping @MainActor (PlaybackRequest) -> Void,
        fallback: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        selecting = target
        pressToken += 1
        let token = pressToken
        let limit = Task { [tapToPlayTimeLimit] in
            guard (try? await Task.sleep(for: tapToPlayTimeLimit)) != nil, token == pressToken else { return }
            endPress()
            fallback()
        }
        return Task {
            let request = await loader(entry)
            limit.cancel()
            guard token == pressToken else { return }
            endPress()
            if let request {
                play(request)
            } else {
                fallback()
            }
        }
    }

    /// The episode Template Screen: the one that hosts `EpisodePlayer`. Decided by the resolved
    /// screen, so a served link to any other screen opens as before.
    private func opensEpisode(_ entry: StackEntry) -> Bool {
        tree.templates(for: "episode").contains { $0.id == entry.screenId }
    }

    /// Whether a card press on `target` opens a screen. A control that can open nothing (no
    /// or several `show` Template Screens, for "Go to show") is not drawn. The same resolution
    /// as `openCard`, so the two can never disagree.
    func canOpenCard(_ target: CardTarget) -> Bool {
        entry(for: target) != nil
    }

    /// The one resolution of a card target: the served link, else exactly one Template Screen
    /// of the item's type, through the same route table as a `screen` link.
    private func entry(for target: CardTarget) -> StackEntry? {
        if let link = target.link {
            return tree.resolveTarget(screenId: link.screenId, param: link.param, currentParam: state.current.param)
        }
        let candidates = tree.templates(for: target.resourceType)
        guard candidates.count == 1, let screen = candidates.first else { return nil }
        return tree.resolveTarget(screenId: screen.id, param: target.itemId, currentParam: state.current.param)
    }

    private func reportCardOnce(_ key: String, _ detail: String) {
        guard reportedCardTypes.insert(key).inserted else { return }
        diagnostics.log(.reject, "Card press ignored", detail)
    }
}
