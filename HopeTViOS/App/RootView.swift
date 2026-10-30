import SwiftUI

/// The app shell: the root (the initial route's `TabView`, or the bare Entry Screen), a stack
/// above it for pushed screens and a layout frame, and the layout chrome around every screen.
///
/// Back is the native `NavigationStack` pop of `router.state.stack`, so it follows
/// `NavigationState.goBack`: a pushed Screen pops, then a layout frame closes (it is one path
/// element), then Back on the root leaves the app. This matches `apps/mobile`.
struct RootView: View {
    @Environment(ContractStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(WatchProgressStore.self) private var progress
    @Environment(MemberAccount.self) private var account
    @Environment(SavedItemList.self) private var watchLater
    @Environment(Likes.self) private var likes
    @Environment(\.scenePhase) private var scenePhase
    @State private var foreground = ForegroundTrigger()

    private var theme: AppTheme { AppTheme(preset: store.manifest.preset) }

    var body: some View {
        @Bindable var router = router

        Group {
            if let refusal = store.refusal {
                RefusalView(reason: refusal)
            } else if store.awaitingFirstManifest {
                LoadingView()
            } else if let rootScreenId = router.tree.rootScreenId {
                NavigationStack(path: $router.state.stack) {
                    Group {
                        if case let .layout(layoutId, _) = router.tree.initialRoute {
                            LayoutTabs(layoutId: layoutId, selection: $router.state.tabScreenId) { tab in
                                router.tree.rootEntry(screenId: tab)
                            }
                        } else {
                            LayoutHost(
                                entry: router.tree.rootEntry(screenId: rootScreenId),
                                layoutId: router.tree.chromeLayoutId(for: .entry)
                            )
                        }
                    }
                    .navigationDestination(for: StackEntry.self) { entry in
                        if let layoutId = entry.layoutId {
                            // A frame's tab that fails says "press Back", as a pushed screen does.
                            LayoutTabs(layoutId: layoutId, selection: frameSelection(entry), pushed: true) { tab in
                                entry.frameTab(tab)
                            }
                        } else {
                            LayoutHost(
                                entry: entry,
                                layoutId: router.tree.chromeLayoutId(for: .pushed(screenId: entry.screenId)),
                                pushed: true
                            )
                        }
                    }
                }
            } else {
                RefusalView(reason: .transport(ChromeText.string(.noTabs)))
            }
        }
        .environment(\.appTheme, theme)
        .tint(theme.accent)
        .background(theme.background)
        // One cover for the whole playback. A new request (the Episodes tab, Up Next) replaces the
        // player inside it: `.id` stops the old `PlayerView` (`onDisappear`) and starts a new one,
        // with no dismiss that shows the screen under it. `item:` would dismiss and present again.
        .fullScreenCover(isPresented: Binding(get: { router.playback != nil }, set: { if !$0 { router.endPlayback() } })) {
            if let request = router.playback {
                PlayerView(request: request)
                    .id(request.id)
                    .environment(\.appTheme, theme)
            } else {
                // Back: the cover slides out black, as the player drew, not on the system background.
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            await store.refreshManifest()
            router.rebuild(with: store.manifest)
            #if DEBUG
            DebugLaunch.apply(to: router)
            await DebugLaunch.holdTab(on: router)
            #endif
        }
        .onChange(of: router.isAtSafeBoundary, initial: true) { _, safe in
            store.isAtSafeBoundary = safe
        }
        // Back from the background (awe#5398): refetch the manifest once its ttl ran out. It
        // activates through the same safe-boundary path, so the `manifestGeneration` onChange below
        // rebuilds the tree.
        // A stored session loads the member's server copy at launch (awe#6564). Signed out it
        // sends nothing.
        .task {
            await account.loadHistory()
        }
        // The member's Watch later list, by the same rule (awe#6869).
        .task {
            await watchLater.load()
        }
        // And the member's likes (awe#6871).
        .task {
            await likes.list.load()
        }
        .onChange(of: scenePhase) { _, phase in
            guard foreground.fires(on: phase) else { return }
            Task { await store.refreshManifestIfStale() }
            Task { await account.loadHistory() }
            Task { await watchLater.load() }
            Task { await likes.list.load() }
        }
        // A held manifest activates later, from the safe-boundary `didSet`. The tree has to
        // move with it, or the tab bar keeps routing against the manifest it replaced.
        .onChange(of: store.manifestGeneration) { _, _ in
            router.rebuild(with: store.manifest)
        }
    }
}

/// The tab selection of a layout frame. It opens on the frame's own tab.
private extension RootView {
    func frameSelection(_ frame: StackEntry) -> Binding<String> {
        Binding(
            get: { router.state.frameTabScreenId ?? frame.screenId },
            set: { router.state.frameTabScreenId = $0 }
        )
    }
}

/// A layout's tab bar: the initial route's root, or a layout frame. Each tab draws this
/// layout's chrome. The root tab bar ends with the platform Account tab when the Manifest flag
/// is on (awe#6563); a layout frame never gets it.
///
/// The `TabView` keeps the state and VoiceOver. `FloatingTabBar` draws over it, so the system bar
/// is hidden and the bar's height comes in as a safe-area inset.
private struct LayoutTabs: View {
    let layoutId: String
    @Binding var selection: String
    var pushed = false
    let entry: (String) -> StackEntry

    @Environment(AppRouter.self) private var router

    private var showsAccount: Bool { !pushed && router.tree.showsAccountTab }

    private var items: [FloatingTabBar.Item] {
        var items = router.tree.tabs(ofLayout: layoutId).map {
            FloatingTabBar.Item(id: $0.screenId, label: $0.label, symbol: TabIcon.symbol(for: $0.icon))
        }
        if showsAccount {
            items.append(FloatingTabBar.Item(id: AccountTab.tag, label: ChromeText.string(.account), symbol: "person"))
        }
        return items
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(router.tree.tabs(ofLayout: layoutId), id: \.screenId) { tab in
                LayoutHost(entry: entry(tab.screenId), layoutId: router.tree.chromeLayoutId(for: .tab(layoutId: layoutId)), pushed: pushed)
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Text(tab.label) }
                    .tag(tab.screenId)
            }
            if showsAccount {
                AccountView()
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Text(ChromeText.string(.account)) }
                    .tag(AccountTab.tag)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(items: items, selection: $selection)
        }
        // The hero runs under the status bar. A pushed frame keeps its Back button.
        .toolbar(pushed ? .automatic : .hidden, for: .navigationBar)
    }
}

/// The layout tree, with the screen rendered at its one `ContentPlaceholder`.
private struct LayoutHost: View {
    let entry: StackEntry
    /// The chrome to draw, from `NavigationTree.chromeLayoutId`. nil draws no chrome.
    let layoutId: String?
    var pushed = false

    @Environment(ContractStore.self) private var store
    @Environment(\.appTheme) private var theme

    var body: some View {
        let screen = AnyView(ScreenHost(entry: entry, pushed: pushed))

        if let layoutId, let layout = store.manifest.layouts.first(where: { $0.id == layoutId }),
           let node = BlockRegistry.evaluate(
               nodeId: CraftDocument.rootId,
               document: layout.content,
               context: RenderContext(
                   images: ImageConfig(cdn: store.config.imagesCDN, bucket: store.config.imagesBucket),
                   colors: PresetColorResolver(preset: store.manifest.preset)
               )
           ),
           node.first(where: { if case .contentSlot = $0.content { return true }; return false }) != nil {
            NodeView(node: node, slot: screen)
        } else {
            // No layout, or a layout with no content slot: the screen still opens.
            screen
        }
    }
}

/// One screen: fetch, then draw. A screen that has not landed yet shows a spinner, never a
/// blank root.
private struct ScreenHost: View {
    let entry: StackEntry
    /// A screen opened above a tab. Its failure is calm copy, not a refusal of the whole App.
    let pushed: Bool

    @Environment(ContractStore.self) private var store
    @Environment(WatchProgressStore.self) private var progress

    var body: some View {
        Group {
            switch store.screenEntry(id: entry.screenId, param: entry.param) {
            case let .ready(screen):
                ScreenBody(entry: entry, screen: screen)
            case let .failed(message):
                // The transport reason stays in the diagnostics log (`ContractStore.loadScreen`).
                if pushed {
                    RefusalView(message: .unavailable)
                } else {
                    RefusalView(reason: .transport(message))
                }
            case .loading, nil:
                LoadingView()
            }
        }
        .task(id: entry.id) {
            await store.loadScreen(id: entry.screenId, param: entry.param)
        }
    }
}

private struct ScreenBody: View {
    let entry: StackEntry
    let screen: AppScreen

    /// nil until measured, so a view that sizes by it can use a stable guess on the first layout.
    @State private var safeTop: CGFloat?

    @Environment(ContractStore.self) private var store
    @Environment(WatchProgressStore.self) private var progress
    @Environment(MemberAccount.self) private var account
    @Environment(SavedItemList.self) private var watchLater
    @Environment(AppRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.contentSlotColor) private var contentSlotColor

    var body: some View {
        let node = BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content, context: context)

        let content = VStack(alignment: .leading, spacing: 24) {
            if let node {
                NodeView(node: node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.screenMargin)
        .padding(.top, Layout.screenTopPadding)
        .padding(.bottom, node?.holdsSearch == true ? 0 : Layout.screenBottomPadding)
        // A card sets its own style; every other button is a text action.
        .buttonStyle(ActionButtonStyle())

        Group {
            // A search screen scrolls its own results. Inside this scroll view too, the search
            // keyboard stopped moving right after the first typed character.
            if node?.holdsSearch == true {
                content
            } else {
                ScrollView { content }
            }
        }
        // A hero that leads the screen draws its art up by the top safe area plus the padding, so
        // the art starts at the screen top.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .environment(\.leadingHero, node.flatMap { node in
            node.leadingHeroId.map {
                LeadingHero(nodeId: $0, insets: node.leadingHeroInsets, screenTop: (safeTop ?? 0) + Layout.screenTopPadding)
            }
        })
        .environment(\.stackEntry, entry)
        .environment(\.loadNextPage) { [store, key = store.key(for: entry.screenId, param: entry.param)] nodeId in
            Task { await store.loadNextPage(key: key, nodeId: nodeId) }
        }
        .environment(\.mediaSearch) { [store, screenId = entry.screenId, context] nodeId, query in
            MediaSearchState(await store.search(screenId: screenId, nodeId: nodeId, query: query), nodeId: nodeId, context: context)
        }
        // The layout's `ContentPlaceholder` color, over the page color (awe#6239). The ShapeStyle
        // overload, like the page color: it fills the safe area too, so no page-color edge shows.
        .background(contentSlotColor.map(Color.init) ?? .clear)
        .background(theme.background)
        // A screen with a schedule refetches itself, so new broadcasts arrive. It goes through
        // `loadScreen`, so a replacement still waits for a safe boundary (invariant 3). Only
        // while it is the screen on show; the task ends with the view.
        // It sleeps first: `ScreenHost` already fetched the screen when it appeared.
        .task(id: node?.holdsSchedule == true) {
            guard node?.holdsSchedule == true else { return }
            await ScheduleRefresh.loop {
                guard router.state.current == entry, router.playback == nil else { return }
                await store.loadScreen(id: entry.screenId, param: entry.param)
            }
        }
        // Drawing is the health signal that promotes a document to last-known-good.
        // Keyed on the activation too: a replacement with the same id is promoted when it draws.
        .task(id: "\(screen.id)#\(store.activations[store.key(for: entry.screenId, param: entry.param)] ?? 0)") {
            store.markManifestRendered()
            store.markRendered(store.key(for: entry.screenId, param: entry.param))
            #if DEBUG
            if let node {
                DebugLaunch.pressFirstCard(in: node, router: router)
                DebugLaunch.pressPlay(in: node, router: router)
                DebugLaunch.pressLive(in: node, router: router)
            }
            #endif
        }
        // A manifest that activates mid-session (a foreground refresh) keeps the tab, so the
        // task above does not run again. Its own task promotes it once this screen draws under it.
        .task(id: store.manifestGeneration) {
            store.markManifestRendered()
        }
    }

    private var context: RenderContext {
        // Signed in, the member's server copy; signed out, the device store (awe#6564). A
        // snapshot read on the main actor: the evaluator is not main-actor isolated.
        let watch = WatchHistorySource(progress: progress, account: account)
        return RenderContext(
            // Page 1 plus the pages loaded since (memory only, awe#5318).
            blockResources: store.blockResources(for: store.key(for: entry.screenId, param: entry.param)),
            screenResources: screen.resources,
            images: ImageConfig(cdn: store.config.imagesCDN, bucket: store.config.imagesBucket),
            colors: PresetColorResolver(preset: store.manifest.preset),
            watchHistory: watch.entries,
            resumePoints: watch.resumePoints,
            memberResumePoints: watch.memberResumePoints,
            // Device or member list (awe#6869). Reading it here redraws the shelf after a save.
            watchLater: watchLater.items,
            canOpenCard: { [router] target in MainActor.assumeIsolated { router.canOpenCard(target) } }
        )
    }
}

/// What a screen says when it cannot draw.
struct FailureMessage: Equatable {
    let title: String
    let detail: String

    /// A pushed screen that did not load (a 404 Template Screen, for example). The viewer gets
    /// calm copy and a way back; the transport reason stays in the log.
    static var unavailable: FailureMessage {
        FailureMessage(title: ChromeText.string(.contentUnavailable), detail: ChromeText.string(.pressBackToReturn))
    }

    /// The whole App cannot render: another design, no tabs, a failed tab screen.
    static func refusal(_ reason: RejectionReason, appName: String) -> FailureMessage {
        FailureMessage(title: ChromeText.string(.cannotOpenApp, ["name": appName]), detail: reason.text)
    }
}

/// The spinner for content that has not landed yet: the launch manifest, or a screen.
private struct LoadingView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A visible refusal. The app never draws a blank screen instead of an explanation.
struct RefusalView: View {
    let message: FailureMessage

    @Environment(\.appTheme) private var theme

    init(message: FailureMessage) {
        self.message = message
    }

    init(reason: RejectionReason) {
        message = .refusal(reason, appName: AppConfig.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text(message.detail)
                .font(.system(size: 16))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(Layout.screenMargin * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(theme.background)
    }
}
