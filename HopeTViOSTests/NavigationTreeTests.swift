import XCTest
@testable import HopeTViOS

/// A manifest of static Screens, except the ids in `templates`. `l1` is the default layout. Each
/// layout is `(id, tab screen ids)`; each screen is `(id, layoutId)`. `entryParam` is written
/// only when set, so a nil one is the key missing, as on an older server.
private func navigationManifest(
    entry: String?,
    entryParam: String? = nil,
    templates: Set<String> = [],
    layouts: [(String, [String])],
    screens: [(String, String?)]
) throws -> AppManifest {
    let layoutRows = layouts.map { layout in
        let tabs = layout.1.map { "{ \"screenId\": \"\($0)\", \"label\": \"\($0)\" }" }
        return "{ \"id\": \"\(layout.0)\", \"content\": {}, \"navigation\": { \"tabs\": [\(tabs.joined(separator: ", "))] } }"
    }
    let screenRows = screens.map { screen in
        "{ \"id\": \"\(screen.0)\", \"kind\": \"\(templates.contains(screen.0) ? "template" : "static")\", \"layoutId\": \(screen.1.map { "\"\($0)\"" } ?? "null") }"
    }

    return try ContractDecoder.manifest(Data("""
    {
      "contractVersion": 1,
      "app": { "design": "tv" },
      "entryScreenId": \(entry.map { "\"\($0)\"" } ?? "null"),
      \(entryParam.map { "\"entryParam\": \"\($0)\"," } ?? "")
      "defaultLayoutId": "l1",
      "layouts": [\(layoutRows.joined(separator: ", "))],
      "screens": [\(screenRows.joined(separator: ", "))],
      "preset": {}
    }
    """.utf8))
}

/// Where the App opens (awe#4521). The same rule as `apps/mobile`'s `resolveInitialRoute`: an
/// Entry Screen that is a tab opens on its layout's tab bar, on that tab. The Screen's own
/// layout is checked first, then the default layout. Only a Screen on no tab bar opens bare.
@MainActor
final class EntryScreenRouteTests: XCTestCase {

    /// `l1` is the default layout. Each layout is `(id, tab screen ids)`; each screen is
    /// `(id, layoutId)`.
    private func tree(
        entry: String?,
        layouts: [(String, [String])] = [("l1", ["home", "browse", "live"])],
        screens: [(String, String?)] = [("home", nil), ("browse", nil), ("live", nil)]
    ) throws -> NavigationTree {
        NavigationTree(manifest: try navigationManifest(entry: entry, layouts: layouts, screens: screens))
    }

    /// The Hope TV case: a tab on the default layout, with the Screen's own `layoutId` null.
    func testAnEntryScreenThatIsADefaultLayoutTabOpensTheTabBarOnThatTab() throws {
        let tree = try tree(entry: "browse")

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "browse"))
        XCTAssertEqual(tree.rootScreenId, "browse")
        XCTAssertEqual(tree.tabs.map(\.screenId), ["home", "browse", "live"])
        XCTAssertTrue(tree.issues.isEmpty)

        // The shell selects the entry tab, and the back key exits from it.
        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        XCTAssertEqual(router.state.tabScreenId, "browse")
        router.state.selectTab("live")
        XCTAssertTrue(router.state.goBack(rootScreenId: "browse"))
        XCTAssertEqual(router.state.tabScreenId, "browse")
        XCTAssertFalse(router.state.goBack(rootScreenId: "browse"))
    }

    /// The Screen's own layout wins over the default layout, even when both carry the tab.
    func testAnEntryScreenThatIsATabOnItsOwnLayoutOpensThatLayout() throws {
        let tree = try tree(
            entry: "live",
            layouts: [("l1", ["home", "live"]), ("l2", ["news", "live"])],
            screens: [("home", nil), ("news", "l2"), ("live", "l2")]
        )

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l2", screenId: "live"))
        XCTAssertEqual(tree.rootScreenId, "live")
        XCTAssertEqual(tree.tabs.map(\.screenId), ["news", "live"])
    }

    /// A splash or onboarding Screen is on no tab bar. It is legal, and it gets the bare route.
    func testAnEntryScreenOnNoTabBarOpensBare() throws {
        let screens: [(String, String?)] = [("home", nil), ("splash", nil), ("intro", "l2")]
        let layouts = [("l1", ["home"]), ("l2", ["home"])]

        let unbound = try tree(entry: "splash", layouts: layouts, screens: screens)
        XCTAssertEqual(unbound.initialRoute, .screen(screenId: "splash", layoutId: nil))
        XCTAssertEqual(unbound.rootScreenId, "splash")

        let bound = try tree(entry: "intro", layouts: layouts, screens: screens)
        XCTAssertEqual(bound.initialRoute, .screen(screenId: "intro", layoutId: "l2"))
        XCTAssertEqual(bound.rootScreenId, "intro")
    }

    /// Mobile parity: the own layout is bound but does not carry the entry as a tab, so the
    /// default layout, which does, wins.
    func testAnEntryScreenFallsThroughToTheDefaultLayoutWhenItsOwnLayoutHasNoSuchTab() throws {
        let tree = try tree(
            entry: "browse",
            layouts: [("l1", ["home", "browse"]), ("l2", ["home"])],
            screens: [("home", nil), ("browse", "l2")]
        )

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "browse"))
    }

    /// An own `layoutId` that names no layout is dropped, on the bare route and on the tab route.
    func testAnEntryScreenWhoseOwnLayoutIsMissingIgnoresIt() throws {
        let bare = try tree(entry: "splash", screens: [("home", nil), ("splash", "gone")])
        XCTAssertEqual(bare.initialRoute, .screen(screenId: "splash", layoutId: nil))

        let tab = try tree(entry: "browse", screens: [("home", nil), ("browse", "gone")])
        XCTAssertEqual(tab.initialRoute, .layout(layoutId: "l1", screenId: "browse"))
    }

    /// An entry id that names no Screen falls back to the default layout's first tab, and reports.
    func testAnEntryScreenIdNotInTheManifestFallsBackAndRecordsTheGap() throws {
        let tree = try tree(entry: "gone")

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "home"))
        XCTAssertEqual(tree.issues, ["Entry screen gone is not in the manifest"])
    }

    /// A tab-less default layout would draw nothing, so with no entry Screen the route is empty.
    func testNoEntryScreenAndADefaultLayoutWithNoTabsOpensEmpty() throws {
        let tree = try tree(entry: nil, layouts: [("l1", [])], screens: [("home", nil)])

        XCTAssertEqual(tree.initialRoute, .empty)
        XCTAssertNil(tree.rootScreenId)
    }

    /// Unchanged: with no entry Screen, the default layout opens on its first tab.
    func testNoEntryScreenOpensTheDefaultLayoutOnItsFirstTab() throws {
        let tree = try tree(entry: nil)

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "home"))
        XCTAssertEqual(tree.rootScreenId, "home")
        XCTAssertEqual(tree.tabs.map(\.screenId), ["home", "browse", "live"])
    }
}

/// A fixed record on the entry (awe#5244). The manifest's `entryParam` is the id a Template Entry
/// Screen opens with. The tree carries it to the root entry, to `state.current` (the param a
/// template tab inherits) and to the tab entries of a layout. A static Screen never takes it.
@MainActor
final class EntryParamTests: XCTestCase {

    private let showId = "61975e24d9c698836400305c"

    private func tree(
        entry: String?,
        param: String?,
        templates: Set<String> = [],
        layouts: [(String, [String])] = [("l1", ["home"])],
        screens: [(String, String?)] = [("home", nil), ("splash", nil)]
    ) throws -> NavigationTree {
        NavigationTree(manifest: try navigationManifest(
            entry: entry, entryParam: param, templates: templates, layouts: layouts, screens: screens
        ))
    }

    func testTheManifestDecodesEntryParamWhenPresentAndNilWhenMissingOrNull() throws {
        let with = try navigationManifest(entry: "show", entryParam: showId, templates: ["show"], layouts: [], screens: [("show", nil)])
        XCTAssertEqual(with.entryParam, showId)

        let missing = try navigationManifest(entry: "show", layouts: [], screens: [("show", nil)])
        XCTAssertNil(missing.entryParam)

        let explicitNull = try ContractDecoder.manifest(Data("""
        { "contractVersion": 1, "app": {}, "entryScreenId": null, "entryParam": null,
          "layouts": [], "screens": [], "preset": {} }
        """.utf8))
        XCTAssertNil(explicitNull.entryParam)
        XCTAssertNil(explicitNull.entryScreenId)
    }

    func testABareTemplateEntryOpensWithTheParam() throws {
        let tree = try tree(entry: "splash", param: showId, templates: ["splash"])
        XCTAssertEqual(tree.initialRoute, .screen(screenId: "splash", layoutId: nil))
        XCTAssertEqual(tree.rootEntry(screenId: "splash"), StackEntry(screenId: "splash", param: showId))

        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: showId))
        XCTAssertTrue(tree.issues.isEmpty)
    }

    func testATemplateEntryWithNoParamKeepsTheTodayBehavior() throws {
        let tree = try tree(entry: "splash", param: nil, templates: ["splash"])

        XCTAssertEqual(tree.rootEntry(screenId: "splash"), StackEntry(screenId: "splash", param: nil))
        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: nil))
    }

    func testAStaticEntryIgnoresTheParam() throws {
        let tree = try tree(entry: "splash", param: showId)

        XCTAssertEqual(tree.rootEntry(screenId: "splash"), StackEntry(screenId: "splash", param: nil))
        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: nil))
    }

    func testATemplateEntryThatIsATabCarriesTheParamAndTemplateTabsInheritIt() throws {
        let tree = try tree(
            entry: "show",
            param: showId,
            templates: ["show", "extras"],
            layouts: [("l1", ["home", "show", "extras"])],
            screens: [("home", nil), ("show", nil), ("extras", nil)]
        )

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "show"))
        XCTAssertEqual(tree.rootEntry(screenId: "show"), StackEntry(screenId: "show", param: showId))
        XCTAssertEqual(tree.rootEntry(screenId: "extras"), StackEntry(screenId: "extras", param: showId))
        // A static tab never takes the record id.
        XCTAssertEqual(tree.rootEntry(screenId: "home"), StackEntry(screenId: "home", param: nil))

        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        XCTAssertEqual(router.state.current.param, showId)
        // A template link with no param of its own inherits the record from the entry tab.
        router.open(screenId: "extras", param: nil)
        XCTAssertEqual(router.state.current, StackEntry(screenId: "extras", param: showId))
    }

    func testTheCurrentEntryFollowsTheSelectedTab() throws {
        let tree = try tree(
            entry: "show", param: showId, templates: ["show"],
            layouts: [("l1", ["home", "show"])], screens: [("home", nil), ("show", nil)]
        )
        let router = AppRouter(tree: tree, diagnostics: Diagnostics())
        router.state.selectTab("home")
        XCTAssertEqual(router.state.current, StackEntry(screenId: "home", param: nil))
        router.state.selectTab("show")
        XCTAssertEqual(router.state.current, StackEntry(screenId: "show", param: showId))
    }

    func testTheParamIsDroppedWhenTheEntryScreenIsNotInTheManifest() throws {
        let tree = try tree(entry: "gone", param: showId)

        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l1", screenId: "home"))
        XCTAssertEqual(tree.rootEntry(screenId: "home"), StackEntry(screenId: "home", param: nil))
    }
}

/// A bare Entry Screen, and the layout frame a link opens above it (awe#5582). The rule matches
/// `apps/mobile`: the root is the Screen with no tab bar. A link or a card press to a Screen that
/// is a tab of its layout opens that layout's tab bar on that tab, above the Screen it came from.
/// Back pops pushed Screens, then closes the frame, then leaves the app.
@MainActor
final class LayoutFrameTests: XCTestCase {

    private let showId = "61975e24d9c698836400305c"

    /// `splash` is the bare entry. `l1` (the default) carries home, browse and promo; `l2` carries
    /// news and live. `promo` names `l2`, which does not carry it. `about` is on no tab bar.
    private let layouts = [("l1", ["home", "browse", "promo"]), ("l2", ["news", "live"])]
    private let screens: [(String, String?)] = [
        ("splash", nil), ("home", nil), ("browse", nil), ("promo", "l2"), ("news", "l2"), ("live", "l2"), ("about", nil),
    ]

    private func manifest(entry: String = "splash", layouts: [(String, [String])]? = nil) throws -> AppManifest {
        try navigationManifest(entry: entry, layouts: layouts ?? self.layouts, screens: screens)
    }

    private func router(entry: String = "splash") throws -> AppRouter {
        AppRouter(tree: NavigationTree(manifest: try manifest(entry: entry)), diagnostics: Diagnostics())
    }

    private func frame(_ screenId: String, _ layoutId: String) -> StackEntry {
        StackEntry(screenId: screenId, param: nil, layoutId: layoutId)
    }

    /// A Collection card with a served link to `screen`, built by the registry.
    private func linkedCard(to screen: String) throws -> CardModel {
        let document = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "shelf": {
              "resources": {
                "collection": {
                  "title": "Featured",
                  "contentType": "shows",
                  "shows": [{ "_id": "\(showId)", "title": "Table Talk",
                              "screenLink": { "linkType": "screen", "screen": "\(screen)", "screenParam": "\(showId)" } }]
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["shelf"] },
            "shelf": {
              "type": { "resolvedName": "Collection" },
              "props": {}, "custom": { "type": "plugin", "resources": ["collection"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: document.content,
            context: TestRender.context(blockResources: document.blockResources)
        ))
        guard case let .shelf(model)? = node.first(where: { $0.key == .collection })?.content else {
            return try XCTUnwrap(nil as CardModel?, "Collection drew nothing")
        }
        return try XCTUnwrap(model.cards.first)
    }

    // MARK: - The bare entry

    func testABareEntryIsTheRootWithNoTabBar() throws {
        let router = try router()

        XCTAssertEqual(router.tree.initialRoute, .screen(screenId: "splash", layoutId: nil))
        XCTAssertEqual(router.tree.tabs, [], "no tab bar at the root: the default layout's tabs do not stand in")
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: nil))
        XCTAssertTrue(router.state.stack.isEmpty)
    }

    /// The "no tabs" refusal is for the `.empty` route only. A bare entry opens even when the
    /// default layout has no tabs.
    func testABareEntryOpensWhenTheDefaultLayoutHasNoTabs() throws {
        let tree = NavigationTree(manifest: try navigationManifest(entry: "splash", layouts: [("l1", [])], screens: [("splash", nil)]))

        XCTAssertEqual(tree.initialRoute, .screen(screenId: "splash", layoutId: nil))
        XCTAssertEqual(tree.rootScreenId, "splash")
        XCTAssertEqual(tree.tabs, [])
    }

    // MARK: - Opening a frame

    func testALinkToADefaultLayoutTabOpensThatTabBarOnThatTab() throws {
        let router = try router()

        router.open(screenId: "browse", param: nil)

        XCTAssertEqual(router.state.stack, [frame("browse", "l1")])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "browse", param: nil))
        XCTAssertEqual(router.tree.tabs(ofLayout: "l1").map(\.screenId), ["home", "browse", "promo"])
    }

    /// The Screen's own layout first, as `resolveScreenTarget` in `apps/mobile`.
    func testALinkToATabOfTheScreensOwnLayoutOpensThatLayout() throws {
        let router = try router()

        router.open(screenId: "live", param: nil)

        XCTAssertEqual(router.state.stack, [frame("live", "l2")])
    }

    /// `promo` names `l2`, which does not carry it. The default layout does, but the own layout
    /// decides, so it is a plain push. `about` is on no tab bar at all.
    func testALinkToAScreenThatIsNoTabOfItsLayoutIsAPlainPush() throws {
        let promo = try router()
        promo.open(screenId: "promo", param: nil)
        XCTAssertEqual(promo.state.stack, [StackEntry(screenId: "promo", param: nil)])

        let about = try router()
        about.open(screenId: "about", param: nil)
        XCTAssertEqual(about.state.stack, [StackEntry(screenId: "about", param: nil)])
    }

    /// A card press from a Screen pushed above the entry opens the frame above that Screen.
    func testACardPressFromAPushedScreenOpensTheFrameAboveIt() throws {
        let router = try router()
        router.open(screenId: "about", param: nil)

        router.openCard(try linkedCard(to: "browse").target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "about", param: nil), frame("browse", "l1")])
    }

    /// Once a tab bar shows, a link is a plain push, as on the `.layout` route today.
    func testInsideAFrameALinkToATabIsAPlainPush() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)
        router.state.frameTabScreenId = "home"
        XCTAssertEqual(router.state.current, StackEntry(screenId: "home", param: nil))

        router.open(screenId: "live", param: nil)

        XCTAssertEqual(router.state.stack, [frame("browse", "l1"), StackEntry(screenId: "live", param: nil)])
    }

    /// Unchanged: on the `.layout` route a link to a tab is a plain push.
    func testTheLayoutRouteKeepsAPlainPush() throws {
        let router = try router(entry: "home")
        XCTAssertEqual(router.tree.initialRoute, .layout(layoutId: "l1", screenId: "home"))

        router.open(screenId: "browse", param: nil)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "browse", param: nil)])
    }

    // MARK: - Back

    /// Pushed Screens pop first. Back on any tab of the frame closes it and returns to the entry.
    /// Back on the entry answers false: the shell leaves the app.
    func testBackPopsThenClosesTheFrameThenLeaves() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)
        router.state.frameTabScreenId = "home"
        router.open(screenId: "about", param: nil)

        XCTAssertTrue(router.state.goBack(rootScreenId: "splash"))
        XCTAssertEqual(router.state.stack, [frame("browse", "l1")])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "home", param: nil), "back lands on the frame's tab on show")

        XCTAssertTrue(router.state.goBack(rootScreenId: "splash"))
        XCTAssertEqual(router.state.stack, [])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: nil))

        XCTAssertFalse(router.state.goBack(rootScreenId: "splash"), "Back on the entry leaves the app")
    }

    // MARK: - Safe boundary

    /// A frame's tab root is a navigation root the viewer can stay on for hours, like the tab
    /// bar root. So it is a safe boundary.
    func testAFrameAtItsTabRootIsASafeBoundary() throws {
        let router = try router()
        router.open(screenId: "live", param: nil)
        XCTAssertTrue(router.isAtSafeBoundary)

        router.state.frameTabScreenId = "news"
        XCTAssertTrue(router.isAtSafeBoundary, "another tab of the frame")
    }

    /// A Screen pushed above the frame, or under it, is a pushed Screen: the boundary closes.
    func testAScreenPushedAboveOrUnderTheFrameClosesTheBoundary() throws {
        let above = try router()
        above.open(screenId: "browse", param: nil)
        above.open(screenId: "about", param: nil)
        XCTAssertFalse(above.isAtSafeBoundary)

        let under = try router()
        under.open(screenId: "about", param: nil)
        under.open(screenId: "browse", param: nil)
        XCTAssertEqual(under.state.stack.count, 2)
        XCTAssertFalse(under.isAtSafeBoundary)
    }

    // MARK: - Default focus

    /// A Screen on no tab bar opens on its first action: the bare entry and a pushed Screen. A tab
    /// root keeps focus in its tab bar, in a frame too.
    func testTheBareEntryAndAPushedScreenTakeDefaultFocusATabRootDoesNot() throws {
        let router = try router()
        let entry = StackEntry(screenId: "splash", param: nil)
        XCTAssertTrue(router.takesDefaultFocus(entry))

        router.open(screenId: "browse", param: nil)
        XCTAssertFalse(router.takesDefaultFocus(entry), "the entry is under the frame")
        XCTAssertFalse(router.takesDefaultFocus(StackEntry(screenId: "browse", param: nil)))

        router.open(screenId: "about", param: nil)
        XCTAssertTrue(router.takesDefaultFocus(StackEntry(screenId: "about", param: nil)))

        let tabs = try self.router(entry: "home")
        XCTAssertFalse(tabs.takesDefaultFocus(StackEntry(screenId: "home", param: nil)))
    }

    // MARK: - Rebuild

    func testARebuildKeepsTheEntryAndAnOpenFrame() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)
        router.state.frameTabScreenId = "home"

        router.rebuild(with: try manifest())

        XCTAssertEqual(router.state.stack, [frame("browse", "l1")])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "home", param: nil))
    }

    /// The frame's layout is gone, or no longer carries the tab: back to the entry.
    func testARebuildDropsAFrameItsLayoutNoLongerCarries() throws {
        let gone = try router()
        gone.open(screenId: "live", param: nil)
        gone.rebuild(with: try manifest(layouts: [("l1", ["home", "browse"])]))
        XCTAssertEqual(gone.state.stack, [])
        XCTAssertEqual(gone.state.current, StackEntry(screenId: "splash", param: nil))

        let dropped = try router()
        dropped.open(screenId: "browse", param: nil)
        dropped.state.frameTabScreenId = "home"
        dropped.rebuild(with: try manifest(layouts: [("l1", ["browse"]), ("l2", ["news", "live"])]))
        XCTAssertEqual(dropped.state.stack, [], "the tab on show is gone")
    }

    /// A bare entry is one root, so a changed entry applies at once.
    func testARebuildWithAnotherBareEntryOpensIt() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)

        router.rebuild(with: try manifest(entry: "about"))

        XCTAssertEqual(router.state.stack, [])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "about", param: nil))
    }

    /// The entry became a tab: the root is now its tab bar, and a frame exists only above a bare
    /// entry.
    func testARebuildThatMakesTheEntryATabDropsTheFrame() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)

        router.rebuild(with: try manifest(layouts: [("l1", ["splash", "home", "browse"]), ("l2", ["news", "live"])]))

        XCTAssertEqual(router.tree.initialRoute, .layout(layoutId: "l1", screenId: "splash"))
        XCTAssertEqual(router.state.stack, [])
        XCTAssertEqual(router.state.tabScreenId, "splash")
    }

    // MARK: - Edges (QA gate, awe#5582)

    /// Back closes a frame after the viewer switched tabs. The next frame opens on its own tab,
    /// not on the stale one (`openFrame` resets `frameTabScreenId`).
    func testAReopenedFrameOpensOnItsOwnTabNotTheStaleOne() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)
        router.state.frameTabScreenId = "promo"
        XCTAssertTrue(router.state.goBack(rootScreenId: "splash"))
        XCTAssertTrue(router.state.stack.isEmpty)

        router.open(screenId: "home", param: nil)

        XCTAssertEqual(router.state.stack, [frame("home", "l1")])
        XCTAssertEqual(router.state.frameTabScreenId, "home")
        XCTAssertEqual(router.state.current, StackEntry(screenId: "home", param: nil))
    }

    /// A link inside a frame to another tab of the SAME layout is one push, not a second frame.
    func testInsideAFrameALinkToATabOfTheSameLayoutIsAPlainPush() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)

        router.open(screenId: "home", param: nil)

        XCTAssertEqual(router.state.stack, [frame("browse", "l1"), StackEntry(screenId: "home", param: nil)])
        XCTAssertEqual(router.state.stack.filter { $0.layoutId != nil }.count, 1)
    }

    /// The new manifest moves the frame's Screen to another layout that carries it: the frame's
    /// `layoutId` is stale, so reset to the entry root.
    func testARebuildThatMovesTheFramesScreenToAnotherLayoutResetsToTheEntry() throws {
        let router = try router()
        router.open(screenId: "browse", param: nil)
        XCTAssertEqual(router.state.stack, [frame("browse", "l1")])

        let moved = try navigationManifest(
            entry: "splash",
            layouts: [("l1", ["home", "promo"]), ("l2", ["news", "live", "browse"])],
            screens: [("splash", nil), ("home", nil), ("browse", "l2"), ("promo", nil), ("news", "l2"), ("live", "l2"), ("about", nil)]
        )
        router.rebuild(with: moved)

        XCTAssertEqual(router.state.stack, [])
        XCTAssertEqual(router.state.current, StackEntry(screenId: "splash", param: nil))
    }

    /// A frame with a pushed Screen above it is reset too when the manifest drops its layout.
    func testARebuildResetsAFrameWithAScreenPushedAboveIt() throws {
        let router = try router()
        router.open(screenId: "live", param: nil)
        router.open(screenId: "about", param: nil)

        router.rebuild(with: try manifest(layouts: [("l1", ["home", "browse"])]))

        XCTAssertEqual(router.state.stack, [])
    }
}

/// Which layout's content tree draws around a Screen (awe#5582).
final class ChromeLayoutTests: XCTestCase {

    private let layouts = [("l1", ["home", "browse"]), ("l2", ["news", "live"])]

    private func tree(entry: String, screens: [(String, String?)]) throws -> NavigationTree {
        NavigationTree(manifest: try navigationManifest(entry: entry, layouts: layouts, screens: screens))
    }

    /// A tab draws the layout of its own tab bar, not the default layout.
    func testATabDrawsItsTabBarsLayout() throws {
        let tree = try tree(entry: "live", screens: [("home", nil), ("news", "l2"), ("live", "l2")])
        XCTAssertEqual(tree.initialRoute, .layout(layoutId: "l2", screenId: "live"))

        XCTAssertEqual(tree.chromeLayoutId(for: .tab(layoutId: "l2")), "l2")
        XCTAssertEqual(tree.chromeLayoutId(for: .tab(layoutId: "l1")), "l1")
        XCTAssertNil(tree.chromeLayoutId(for: .tab(layoutId: "gone")))
    }

    /// A bare entry draws its own layout. No layout, or one the manifest does not carry, draws no
    /// chrome: the default layout never stands in.
    func testABareEntryDrawsItsOwnLayoutOrNone() throws {
        let screens: [(String, String?)] = [("home", nil), ("intro", "l2"), ("splash", nil), ("lost", "gone")]

        XCTAssertEqual(try tree(entry: "intro", screens: screens).chromeLayoutId(for: .entry), "l2")
        XCTAssertNil(try tree(entry: "splash", screens: screens).chromeLayoutId(for: .entry))
        XCTAssertNil(try tree(entry: "lost", screens: screens).chromeLayoutId(for: .entry))
    }

    /// A pushed Screen draws its own layout. A missing or null one falls back to the default.
    func testAPushedScreenDrawsItsOwnLayoutElseTheDefault() throws {
        let tree = try tree(entry: "home", screens: [("home", nil), ("news", "l2"), ("lost", "gone")])

        XCTAssertEqual(tree.chromeLayoutId(for: .pushed(screenId: "news")), "l2")
        XCTAssertEqual(tree.chromeLayoutId(for: .pushed(screenId: "home")), "l1")
        XCTAssertEqual(tree.chromeLayoutId(for: .pushed(screenId: "lost")), "l1")
    }
}
