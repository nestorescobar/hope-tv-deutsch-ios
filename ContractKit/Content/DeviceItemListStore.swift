import Foundation
import Observation

/// One saved media-library item (ADR-0259 §3), for Watch later and Likes.
///
/// The snapshot is the type, the id, the title and the image (ruled D2: no screen link). A card
/// opens the item through the card convention: the one Template Screen of its type.
struct SavedItem: Codable, Equatable, Identifiable {
    enum ItemType: String, Codable, CaseIterable {
        case show, episode, movie
    }

    let itemType: ItemType
    let itemId: String
    var title: String
    var imageURL: URL?
    /// When the viewer saved it. A card model carries `.distantPast`: the save sets the time.
    var savedAt: Date

    /// Unique across the three types.
    var id: String { Self.id(itemType, itemId) }

    static func id(_ itemType: ItemType, _ itemId: String) -> String { "\(itemType.rawValue):\(itemId)" }
}

/// A device list of saved items, in `UserDefaults` under its own key (ADR-0259 §3). Signed out
/// only: signed in, the member list is the source, and nothing writes this list.
///
/// Newest first, at most `limit`. A save when the list is full drops the oldest entry. A save of
/// an item that is already in the list changes nothing: it keeps its place and its time, as the
/// server keeps its row (`PUT` answers 200).
@MainActor
@Observable
final class DeviceItemListStore {
    /// The server refuses an import of more than 100 entries, so the list never holds more.
    static let limit = 100

    private(set) var items: [SavedItem] = []

    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Stored].self, from: data) {
            items = decoded.compactMap(\.item)
        }
    }

    func contains(_ itemType: SavedItem.ItemType, _ itemId: String) -> Bool {
        let id = SavedItem.id(itemType, itemId)
        return items.contains { $0.id == id }
    }

    func add(_ item: SavedItem) {
        guard !contains(item.itemType, item.itemId) else { return }
        items = Array(([item] + items).prefix(Self.limit))
        persist()
    }

    func remove(_ itemType: SavedItem.ItemType, _ itemId: String) {
        let id = SavedItem.id(itemType, itemId)
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// The import answered 2xx: the entries it sent go. An entry saved since then stays.
    func removeImported(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    /// One stored entry. An entry this build cannot read (a type a later build added) is
    /// skipped, so it never empties the whole list.
    private struct Stored: Decodable {
        let item: SavedItem?

        init(from decoder: Decoder) throws {
            item = try? SavedItem(from: decoder)
        }
    }
}
