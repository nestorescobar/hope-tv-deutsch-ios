import Foundation

/// Manifest → navigation tree. Pure logic, so the whole shape is asserted against the
/// fixture manifest. Same rules as the DOM renderer, in Swift.
struct TabRoute: Equatable {
    let screenId: String
    let label: String
    let icon: String?
}

struct LayoutRoute: Equatable {
    let id: String
    let tabs: [TabRoute]
}

/// Where the root stack starts. `layout` opens that layout's tab bar on the tab `screenId`;
/// `screen` opens a Screen on no tab bar. `empty` is the degraded case: nothing is authored yet.
enum InitialRoute: Equatable {
    case screen(screenId: String, layoutId: String?)
    case layout(layoutId: String, screenId: String)
    case empty
}

/// The platform "Account" tab (awe#6563). It is chrome, not a Screen: its tag is no 24-hex id, so
/// it never reaches a screen route.
enum AccountTab {
    static let tag = "member-account"
}

/// Where a Screen draws, for its chrome (`NavigationTree.chromeLayoutId`).
enum ScreenSlot: Equatable {
    /// A tab root on the tab bar of `layoutId`: the `.layout` route, or a layout frame.
    case tab(layoutId: String)
    /// The bare Entry Screen at the root.
    case entry
    /// A Screen pushed above a root.
    case pushed(screenId: String)
}

struct NavigationTree {
    let initialRoute: InitialRoute
    let defaultLayoutId: String?
    let layouts: [String: LayoutRoute]
    let screens: [String: ManifestScreen]
    /// The param of each root Screen (`rootEntry`), by Screen id. Empty unless a Template Entry
    /// Screen opened with the manifest's `entryParam`.
    let rootParams: [String: String]
    /// Authoring gaps found while mapping. Logged, never thrown.
    let issues: [String]
    /// The Manifest's `memberSignIn.enabled` hint.
    let memberSignIn: Bool

    init(manifest: AppManifest) {
        var issues: [String] = []
        var screens: [String: ManifestScreen] = [:]

        for screen in manifest.screens {
            screens[screen.id] = screen
        }

        var layouts: [String: LayoutRoute] = [:]

        for layout in manifest.layouts {
            var tabs: [TabRoute] = []

            for tab in layout.navigation.tabs {
                guard screens[tab.screenId] != nil else {
                    issues.append("Layout \(layout.id) has a tab for unknown screen \(tab.screenId)")
                    continue
                }
                // A tab bar cannot carry the same screen twice; the first tab wins.
                guard !tabs.contains(where: { $0.screenId == tab.screenId }) else {
                    issues.append("Layout \(layout.id) lists screen \(tab.screenId) more than once; the later tab is dropped")
                    continue
                }
                tabs.append(TabRoute(screenId: tab.screenId, label: tab.label, icon: tab.icon))
            }

            layouts[layout.id] = LayoutRoute(id: layout.id, tabs: tabs)
        }

        let defaultLayoutId = manifest.defaultLayoutId.flatMap { layouts[$0] != nil ? $0 : nil }

        if let declared = manifest.defaultLayoutId, defaultLayoutId == nil {
            issues.append("Default layout \(declared) is not in the manifest")
        }

        for screen in manifest.screens where screen.layoutId != nil && layouts[screen.layoutId!] == nil {
            issues.append("Screen \(screen.id) names layout \(screen.layoutId!), which is not in the manifest")
        }

        self.initialRoute = NavigationTree.resolveInitialRoute(
            manifest: manifest,
            screens: screens,
            layouts: layouts,
            defaultLayoutId: defaultLayoutId,
            issues: &issues
        )
        self.defaultLayoutId = defaultLayoutId
        self.layouts = layouts
        self.screens = screens
        self.rootParams = NavigationTree.resolveRootParams(
            manifest: manifest, screens: screens, layouts: layouts, initialRoute: initialRoute
        )
        self.issues = issues
        #if DEBUG
        self.memberSignIn = manifest.memberSignIn || DebugMemberSignIn.forcesFlag
        #else
        self.memberSignIn = manifest.memberSignIn
        #endif
    }

    private static func resolveInitialRoute(
        manifest: AppManifest,
        screens: [String: ManifestScreen],
        layouts: [String: LayoutRoute],
        defaultLayoutId: String?,
        issues: inout [String]
    ) -> InitialRoute {
        if let entryId = manifest.entryScreenId, let entry = screens[entryId] {
            // An Entry Screen that is a tab opens on its layout's tab bar, on that tab (same rule
            // as `apps/mobile`). The tab is usually on the default layout, as the Screen's own
            // `layoutId` is often null. Only a Screen on no tab bar gets the bare `screen` route.
            let tabLayoutId = [entry.layoutId, defaultLayoutId].compactMap { $0 }.first { id in
                layouts[id]?.tabs.contains { $0.screenId == entry.id } ?? false
            }
            if let tabLayoutId {
                return .layout(layoutId: tabLayoutId, screenId: entry.id)
            }
            let layoutId = entry.layoutId.flatMap { layouts[$0] != nil ? $0 : nil }
            return .screen(screenId: entry.id, layoutId: layoutId)
        }

        issues.append(manifest.entryScreenId.map { "Entry screen \($0) is not in the manifest" } ?? "App has no entry screen")

        // A tab-less layout builds no tab bar, so opening on one would draw nothing.
        if let defaultLayoutId, let firstTab = layouts[defaultLayoutId]?.tabs.first {
            return .layout(layoutId: defaultLayoutId, screenId: firstTab.screenId)
        }

        issues.append(
            defaultLayoutId.map { "Default layout \($0) has no tabs, so it cannot stand in for the entry screen" }
                ?? "App has no default layout either — the shell opens on the empty state"
        )

        return .empty
    }

    /// The fixed record of a Template Entry Screen (awe#5244). It applies only when the entry
    /// opened as itself, not when the entry id was unknown and a fallback tab opened. A static
    /// entry ignores it. On a tab bar, each template tab inherits it, as a link to a template
    /// inherits the param of the Screen on show (`resolveTarget`); a static tab takes none.
    private static func resolveRootParams(
        manifest: AppManifest,
        screens: [String: ManifestScreen],
        layouts: [String: LayoutRoute],
        initialRoute: InitialRoute
    ) -> [String: String] {
        guard let param = manifest.entryParam, !param.isEmpty,
              let entryId = manifest.entryScreenId, screens[entryId]?.kind == .template else { return [:] }

        switch initialRoute {
        case let .screen(screenId, _) where screenId == entryId:
            return [entryId: param]
        case let .layout(layoutId, screenId) where screenId == entryId:
            let tabs = layouts[layoutId]?.tabs ?? []
            return Dictionary(uniqueKeysWithValues: tabs.filter { screens[$0.screenId]?.kind == .template }.map { ($0.screenId, param) })
        default:
            return [:]
        }
    }

    /// The root stack entry of a Screen: the bare entry, or a tab of the root tab bar.
    func rootEntry(screenId: String) -> StackEntry {
        StackEntry(screenId: screenId, param: rootParams[screenId])
    }

    /// The Screen the app opens on, and the ONE root the back key exits from.
    var rootScreenId: String? {
        switch initialRoute {
        case let .screen(screenId, _), let .layout(_, screenId):
            return screenId
        case .empty:
            return nil
        }
    }

    /// The root tab bar. Only the `.layout` route has one: a bare entry draws no tab bar.
    var tabs: [TabRoute] {
        switch initialRoute {
        case let .layout(layoutId, _):
            return layouts[layoutId]?.tabs ?? []
        case .screen, .empty:
            return []
        }
    }

    /// The root tab bar ends with the Account tab when the Manifest flag is on. A bare Entry
    /// Screen has no tab bar, so it gets no Account (ruling 1, slice 1).
    var showsAccountTab: Bool {
        guard memberSignIn, case .layout = initialRoute else { return false }
        return true
    }

    func tabs(ofLayout layoutId: String) -> [TabRoute] {
        layouts[layoutId]?.tabs ?? []
    }

    /// A Screen's layout: its own when the manifest carries it, else the default
    /// (`resolveScreenTarget` in `apps/mobile`).
    private func layoutId(of screenId: String) -> String? {
        screens[screenId]?.layoutId.flatMap { layouts[$0] != nil ? $0 : nil } ?? defaultLayoutId
    }

    /// The layout whose tab bar carries `screenId`, for a layout frame: the Screen's layout
    /// (`layoutId(of:)`). nil when that layout has no such tab, or the Screen is unknown.
    func tabLayoutId(of screenId: String) -> String? {
        guard screens[screenId] != nil, let layoutId = layoutId(of: screenId) else { return nil }
        return tabs(ofLayout: layoutId).contains { $0.screenId == screenId } ? layoutId : nil
    }

    /// The layout whose content tree draws around a Screen. nil draws the Screen with no chrome.
    /// A tab draws its tab bar's layout. The bare entry draws its own layout, or none. A pushed
    /// Screen draws its own layout, else the default layout.
    func chromeLayoutId(for slot: ScreenSlot) -> String? {
        switch slot {
        case let .tab(layoutId):
            return layouts[layoutId] != nil ? layoutId : nil
        case .entry:
            if case let .screen(_, layoutId) = initialRoute { return layoutId }
            return nil
        case let .pushed(screenId):
            return layoutId(of: screenId)
        }
    }

    /// Whether this tree can keep the navigation on show after a new manifest. The `.layout`
    /// route keeps the selected tab while it is still a tab, so a changed entry applies on the
    /// next launch. A bare route keeps its entry, and an open frame while its layout still
    /// carries the frame's tabs. A frame exists only above a bare entry.
    func keeps(_ state: NavigationState) -> Bool {
        switch initialRoute {
        case .layout:
            return state.frame == nil
                && (tabs.contains { $0.screenId == state.tabScreenId } || (showsAccountTab && state.tabScreenId == AccountTab.tag))
        case let .screen(entryId, _):
            guard state.tabScreenId == entryId else { return false }
            guard let frame = state.frame else { return true }
            let selected = state.frameTabScreenId ?? frame.screenId
            return tabLayoutId(of: frame.screenId) == frame.layoutId
                && tabs(ofLayout: frame.layoutId ?? "").contains { $0.screenId == selected }
        case .empty:
            return false
        }
    }

    /// Every Template Screen that declares `resourceType`.
    ///
    /// The card convention needs the COUNT, not the first hit: zero or several candidates is a
    /// no-op, never a guess (see `AppRouter.openCard`).
    func templates(for resourceType: String) -> [ManifestScreen] {
        screens.values
            .filter { $0.kind == .template && $0.resourceType == resourceType }
            .sorted { $0.id < $1.id }
    }

    /// Resolves "open this screen". An unknown screen id, or a template with no param,
    /// answers nil — the caller then does nothing and logs. It never falls back to
    /// another screen.
    func resolveTarget(screenId: String?, param: String?, currentParam: String?) -> StackEntry? {
        guard let screenId, let screen = screens[screenId] else { return nil }

        switch screen.kind {
        case .static:
            return StackEntry(screenId: screenId, param: nil)
        case .template:
            // A template inherits the current param, so every tab of a bound layout stays
            // on the same record. With no param at all the contract answers 400.
            guard let bound = param ?? currentParam, !bound.isEmpty else { return nil }
            return StackEntry(screenId: screenId, param: bound)
        case .unsupported:
            // Fails closed: an unrecognized kind never opens.
            return nil
        }
    }
}
