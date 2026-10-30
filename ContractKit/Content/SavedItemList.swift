import Foundation
import Observation

/// A list of saved items that a member route serves (ADR-0259 §2). The raw value is the route
/// segment (`/member/watchlist`, `/member/likes`).
enum SavedList: String {
    case watchlist
    /// Likes (awe#6871): episodes and movies only. `Likes` adds the Umami event to each press.
    case likes

    /// The device list's `UserDefaults` key.
    var deviceKey: String { "saved-list-\(rawValue)-v1" }
}

/// The source switch for one saved list (ADR-0259 §3, awe#6869). The shelf, the card menu and
/// the detail toggle read and write through it.
///
/// - Signed out: the device list (`DeviceItemListStore`).
/// - Signed in: the member list, in memory only. Nothing writes it to `UserDefaults` or disk, and
///   a signed-in save never writes the device list. So after sign-out no account item is left.
/// - The member copy belongs to one session token. Another token reads as not loaded, so a late
///   answer or a second member never shows the first member's list.
@MainActor
@Observable
final class SavedItemList {
    let list: SavedList
    @ObservationIgnored let device: DeviceItemListStore
    @ObservationIgnored private let account: MemberAccount

    /// The member copy for one session.
    private struct MemberCopy {
        var token: String?
        /// The first page (newest first, at most 100). nil: not loaded.
        var items: [SavedItem]?
        /// False when the server served a `nextCursor`: an item not on the page can still be saved.
        var complete = true
        /// Saved state that a save, a remove or `/contains` answered, by `SavedItem.id`.
        var known: [String: Bool] = [:]
    }

    private var member = MemberCopy()
    /// The session whose device import started: one import per sign-in.
    @ObservationIgnored private var importedToken: String?
    /// Items with a save or a remove in flight. A second press on the same item does nothing then.
    @ObservationIgnored private var pending = Set<String>()
    /// Counts the saves and removes the server accepted. A load that sees it move did not read them.
    @ObservationIgnored private var writes = 0
    /// How many times a load asks again when a write ended while it ran.
    static let loadAttempts = 3

    init(list: SavedList, account: MemberAccount, device: DeviceItemListStore? = nil) {
        self.list = list
        self.account = account
        self.device = device ?? DeviceItemListStore(key: list.deviceKey)
    }

    private var service: MemberService { account.service }

    /// The shelf, newest first.
    var items: [SavedItem] {
        guard let token = account.session?.token else { return device.items }
        return member.token == token ? member.items ?? [] : []
    }

    /// nil: not known yet. Signed in, that is a list that did not load, or an item that is not on
    /// a cut page (`nextCursor` served). The card menu then offers "Watch later": a `PUT` of a
    /// saved item answers 200 and changes nothing. The detail toggle asks `/contains` (`check`).
    func isSaved(_ itemType: SavedItem.ItemType, _ itemId: String) -> Bool? {
        guard let token = account.session?.token else { return device.contains(itemType, itemId) }
        guard member.token == token else { return nil }
        let id = SavedItem.id(itemType, itemId)
        if let known = member.known[id] { return known }
        guard let items = member.items else { return nil }
        if items.contains(where: { $0.id == id }) { return true }
        return member.complete ? false : nil
    }

    /// A save or a remove of this item is in flight (signed in). A press then does nothing.
    func isPending(_ itemType: SavedItem.ItemType, _ itemId: String) -> Bool {
        pending.contains(SavedItem.id(itemType, itemId))
    }

    /// Saves the item with the time of the save.
    func save(_ item: SavedItem) async {
        var item = item
        item.savedAt = Date()
        guard let token = account.session?.token else {
            device.add(item)
            return
        }
        guard pending.insert(item.id).inserted else { return }
        defer { pending.remove(item.id) }
        let result = await service.save(list, token: token, itemType: item.itemType, itemId: item.itemId)
        guard account.session?.token == token else { return }
        switch result {
        case .success:
            writes += 1
            copy(for: token)
            member.known[item.id] = true
            if let items = member.items, !items.contains(where: { $0.id == item.id }) {
                member.items = [item] + items
            }
        case .failure(.signedOut):
            account.sessionRejected(token: token)
        case .failure:
            break
        }
    }

    func remove(_ itemType: SavedItem.ItemType, _ itemId: String) async {
        guard let token = account.session?.token else {
            device.remove(itemType, itemId)
            return
        }
        let id = SavedItem.id(itemType, itemId)
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        let result = await service.unsave(list, token: token, itemType: itemType, itemId: itemId)
        guard account.session?.token == token else { return }
        switch result {
        case .success:
            writes += 1
            copy(for: token)
            member.known[id] = false
            member.items?.removeAll { $0.id == id }
        case .failure(.signedOut):
            account.sessionRejected(token: token)
        case .failure:
            break
        }
    }

    /// Loads the member's first page: at launch with a session, after sign-in, and on a return to
    /// the foreground. A failure other than a 401 keeps what the copy has.
    ///
    /// A save or a remove that the server accepted while the page loaded may be missing from the
    /// page, and the page would undo it. So the load asks again, at most `loadAttempts` times in
    /// all. When writes keep coming, the copy it has stays.
    func load() async {
        guard let token = account.session?.token else { return }
        for _ in 0..<Self.loadAttempts {
            let started = writes
            let result = await service.savedItems(list, token: token)
            guard account.session?.token == token else { return }
            switch result {
            case let .success(page):
                guard writes == started else { continue }
                member = MemberCopy(token: token, items: page.items, complete: !page.hasMore)
                return
            case .failure(.signedOut):
                account.sessionRejected(token: token)
                return
            case .failure:
                return
            }
        }
    }

    /// Asks `/contains` for one item when its state is not known (the list did not load).
    /// Signed out, or with a known state, it sends nothing.
    func check(_ itemType: SavedItem.ItemType, _ itemId: String) async {
        guard let token = account.session?.token, isSaved(itemType, itemId) == nil,
              ContractValidator.isObjectId(itemId) else { return }
        let result = await service.savedIds(list, token: token, itemType: itemType, ids: [itemId])
        guard account.session?.token == token else { return }
        switch result {
        case let .success(ids):
            copy(for: token)
            member.known[SavedItem.id(itemType, itemId)] = ids.contains(itemId)
        case .failure(.signedOut):
            account.sessionRejected(token: token)
        case .failure:
            break
        }
    }

    /// The sign-in cover closed signed in (as `MemberAccount.signInCoverClosed`). Continue
    /// imports the device list first, so the member list loads with the imported items.
    func signInCoverClosed(continued: Bool) async {
        guard account.session != nil else { return }
        if continued {
            await importDeviceList()
        }
        await load()
    }

    /// The one-time import of the device list, once per sign-in. A failure is not retried until
    /// the next sign-in, and it keeps the device copy. After any 2xx the device copy goes, refused
    /// items too: no member can save them (awe#6869). An empty list sends nothing.
    ///
    /// An entry whose id is no ObjectId (a damaged store) is never sent: the server would refuse
    /// the whole batch on every sign-in, and the device copy would never clear. No member can save
    /// it, so it goes with the rest after a 2xx, or at once when nothing else is left to send.
    func importDeviceList() async {
        guard let token = account.session?.token, importedToken != token else { return }
        importedToken = token
        let snapshot = device.items
        guard !snapshot.isEmpty else { return }
        let sent = snapshot.filter { ContractValidator.isObjectId($0.itemId) }
        guard !sent.isEmpty else {
            device.removeImported(Set(snapshot.map(\.id)))
            return
        }
        let result = await service.importSaved(list, token: token, items: sent)
        guard account.session?.token == token else { return }
        switch result {
        case .success:
            device.removeImported(Set(snapshot.map(\.id)))
        case .failure(.signedOut):
            account.sessionRejected(token: token)
        case .failure:
            break
        }
    }

    /// Starts a new copy when the session changed since the last answer.
    private func copy(for token: String) {
        if member.token != token {
            member = MemberCopy(token: token)
        }
    }
}
