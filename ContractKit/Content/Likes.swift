import Foundation
import Observation

/// Likes (awe#6871, ADR-0259 §4–§5): the `likes` saved list plus one Umami event per press.
///
/// The list follows the Watch later rules (`SavedItemList`): the device list signed out, the member
/// list signed in, one import per sign-in. Each press sends `like` or `unlike` with
/// `{ itemType, itemId, title }`, signed in or out, before the save or the remove. The import sends
/// none. Only an episode or a movie can be liked. A separate type, so the environment holds it
/// beside the Watch later `SavedItemList`.
@MainActor
@Observable
final class Likes {
    let list: SavedItemList
    /// Read at each press: the manifest can change, and nil sends no event.
    @ObservationIgnored private let analytics: @MainActor () -> AnalyticsConfig?
    @ObservationIgnored private let sender: UmamiSending
    @ObservationIgnored private let language: String
    @ObservationIgnored private let screen: String
    @ObservationIgnored private let userAgent: String

    init(list: SavedItemList, analytics: @escaping @MainActor () -> AnalyticsConfig?, sender: UmamiSending,
         language: String, screen: String, userAgent: String) {
        self.list = list
        self.analytics = analytics
        self.sender = sender
        self.language = language
        self.screen = screen
        self.userAgent = userAgent
    }

    nonisolated static func canLike(_ itemType: SavedItem.ItemType) -> Bool { itemType != .show }

    /// Items with a press in flight (its `/contains` check or its write).
    @ObservationIgnored private var pressing = Set<String>()

    /// What a control draws. An unknown state (signed in, the list did not load, or a cut page)
    /// draws as not liked; a press resolves it first (`toggle`).
    func isLiked(_ item: SavedItem) -> Bool {
        list.isSaved(item.itemType, item.itemId) == true
    }

    /// One press. Every like counts once (ADR-0259), so:
    /// - An unknown state asks `/contains` before anything else. Already liked: no event and no
    ///   write; the control redraws as liked. A failed check falls back to `like` and a `PUT`.
    ///   Watch later can read unknown as not saved, because it sends no event and its `PUT` is
    ///   idempotent.
    /// - A press while this item's check or write is in flight does nothing.
    func toggle(_ item: SavedItem) async {
        guard Self.canLike(item.itemType), !list.isPending(item.itemType, item.itemId),
              pressing.insert(item.id).inserted else { return }
        defer { pressing.remove(item.id) }
        if list.isSaved(item.itemType, item.itemId) == nil {
            await list.check(item.itemType, item.itemId)
            // The press offered "Like": a like the server already holds is not counted again.
            if list.isSaved(item.itemType, item.itemId) == true { return }
        }
        let liked = isLiked(item)
        send(liked ? "unlike" : "like", item)
        if liked {
            await list.remove(item.itemType, item.itemId)
        } else {
            await list.save(item)
        }
    }

    /// Fire-and-forget: the sender never waits for Umami.
    private func send(_ name: String, _ item: SavedItem) {
        guard let config = analytics() else {
            #if DEBUG
            NSLog("[tv] analytics: %@ not sent, the manifest has no analytics", name)
            #endif
            return
        }
        guard let request = Umami.eventRequest(
                  config, name: name,
                  data: ["itemType": item.itemType.rawValue, "itemId": item.itemId, "title": item.title],
                  url: "/\(item.itemType.rawValue)/\(item.itemId)", language: language, screen: screen, userAgent: userAgent
              ) else { return }
        #if DEBUG
        NSLog("[tv] analytics: %@ %@ %@", name, item.itemType.rawValue, item.itemId)
        #endif
        sender.send(request)
    }
}
