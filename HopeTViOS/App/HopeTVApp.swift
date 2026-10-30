import AVFoundation
import SwiftUI

@main
struct HopeTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var progress: WatchProgressStore
    @State private var store: ContractStore
    @State private var router: AppRouter
    @State private var account: MemberAccount
    @State private var watchLater: SavedItemList
    @State private var likes: Likes

    init() {
        // Sound plays with the ring switch off, on a locked screen and in Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        // AsyncImage goes through the shared URLCache. The default is small enough
        // that a grid of two dozen cards evicts its own artwork while it is still
        // scrolling, so give it room.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)

        let store = ContractStore(config: AppConfig.contract)
        let router = AppRouter(tree: NavigationTree(manifest: store.manifest), diagnostics: store.diagnostics)
        // Tap-to-play: an episode card loads its Episode Screen through the store.
        router.playRequest = { [weak store] entry in
            await store?.playRequest(screenId: entry.screenId, param: entry.param)
        }
        #if DEBUG
        DebugLaunch.seedScreenCache(store)
        DebugLaunch.selectTabBeforeFirstFrame(on: router)
        #endif
        _progress = State(initialValue: WatchProgressStore())
        _store = State(initialValue: store)
        _router = State(initialValue: router)
        let config = AppConfig.contract
        let keychain = SessionKeychain(service: Bundle.main.bundleIdentifier ?? "HopeTV", account: SessionKeychain.account(for: config))
        #if DEBUG
        // A UI test that answers the poll from a file never writes the real Keychain.
        let sessionStore = DebugMemberSignIn.sessionStore(real: keychain)
        #else
        let sessionStore: SessionStoring = keychain
        #endif
        let account = MemberAccount(service: MemberClient(contract: AppContractClient(config: config)), store: sessionStore)
        #if DEBUG
        if let name = DebugMemberHistory.sessionName {
            account.debugSignIn(name: name)
        }
        #endif
        _account = State(initialValue: account)
        _watchLater = State(initialValue: SavedItemList(list: .watchlist, account: account))
        // Likes (awe#6871): the Umami target is read from the manifest on show at each press.
        _likes = State(initialValue: Likes(
            list: SavedItemList(list: .likes, account: account),
            analytics: { [weak store] in
                #if DEBUG
                if let override = DebugLaunch.analyticsOverride { return override }
                #endif
                return store?.manifest.analytics
            },
            sender: UmamiSender(),
            language: config.language,
            // The device in points ("393x852").
            screen: Layout.screenName,
            userAgent: Umami.userAgent(osVersion: UIDevice.current.systemVersion,
                                       appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .environment(progress)
                .environment(account)
                .environment(watchLater)
                .environment(likes)
        }
    }
}

/// Build-time configuration. It comes from `Config/*.xcconfig` through the Info.plist, and
/// the contract response can never change it.
enum AppConfig {
    static var contract: ContractConfig {
        ContractConfig(
            apiBaseURL: URL(string: string("ApiBaseURL")) ?? URL(string: "https://frontend-staging-api.hopeplatform.org")!,
            clientToken: string("ClientToken"),
            appSlug: string("AppSlug"),
            entityId: string("EntityId"),
            language: string("ContentLanguage", default: "en"),
            imagesCDN: string("ImagesCDN"),
            imagesBucket: string("ImagesBucket")
        )
    }

    /// The shell's display name (`SHELL_DISPLAY_NAME`), for chrome that names the app.
    static var displayName: String {
        string("CFBundleDisplayName", default: string("CFBundleName", default: "TV"))
    }

    private static func string(_ key: String, default fallback: String = "") -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.isEmpty ? fallback : value
    }
}
