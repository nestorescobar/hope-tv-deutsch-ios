// cspell:ignore Siri
import Foundation
import SwiftUI

/// The two result grids of one search answer. nil draws no grid for that group.
struct MediaSearchResults: Equatable {
    let episodes: ShelfModel?
    let shows: ShelfModel?
}

/// What a `MediaSearch` block draws below its field (awe#5947).
enum MediaSearchState: Equatable {
    /// No query of two characters or more, or one the server refused (400): nothing.
    case idle
    case results(MediaSearchResults)
    case noResults
    /// A 404: search is off for the App's Site, or the block is gone.
    case unavailable
    /// Any other failure. It draws the existing error chrome.
    case failed

    /// Reads one answer of the search route.
    init(_ result: Result<Data, RejectionReason>, nodeId: String, context: RenderContext) {
        switch result {
        case .failure(.httpStatus(404)):
            self = .unavailable
        case .failure(.httpStatus(400)):
            // The server refused the query (`VALIDATION_ERROR`). The device sends none it would
            // refuse, so it draws what a short query draws: nothing.
            self = .idle
        case .failure:
            self = .failed
        case let .success(data):
            guard let answer = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = answer else {
                self = .failed
                return
            }
            let results = BlockRegistry.searchResults(answer, nodeId: nodeId, context: context)
            self = results.episodes == nil && results.shows == nil ? .noResults : .results(results)
        }
    }

    /// The sentence drawn instead of results. nil draws none.
    var message: String? {
        switch self {
        case .idle, .results: return nil
        case .noResults: return ChromeText.string(.searchNoResults)
        case .unavailable: return ChromeText.string(.searchUnavailable)
        case .failed: return ChromeText.string(.contentUnavailable)
        }
    }
}

/// The field's request rules: wait 400 ms after the last change, send nothing below two
/// characters, and drop an answer when a newer query started after it.
@MainActor
@Observable
final class MediaSearchSession {
    static let debounce: Duration = .milliseconds(400)

    private(set) var state: MediaSearchState = .idle

    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The trimmed query of the last request, so a change that trims to it sends nothing.
    @ObservationIgnored private var query: String?
    @ObservationIgnored private var generation = 0

    /// `sleep` is the debounce wait. A test injects one it controls.
    init(sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func update(_ text: String, search: @escaping @MainActor (String) async -> MediaSearchState) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != self.query else { return }
        task?.cancel()
        generation += 1
        guard ContractLimits.searchQueryLength.contains(query.utf16.count) else {
            self.query = nil
            state = .idle
            return
        }
        self.query = query
        let ticket = generation
        task = Task { [weak self, sleep] in
            await sleep(Self.debounce)
            // A newer change canceled this one during the wait.
            guard !Task.isCancelled else { return }
            let answer = await search(query)
            // A newer query started while this one was in flight: its answer is stale.
            guard let self, self.generation == ticket else { return }
            self.state = answer
            self.task = nil
        }
    }

    /// Stops the search in flight when the view goes away. Its query is forgotten, so the next
    /// `update` with the same text (the view shows again) sends it again. Without one in flight,
    /// nothing changes and the shown answer stays.
    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        generation += 1
        query = nil
    }
}

/// The native tvOS search field (`.searchable`: the system keyboard and Siri dictation), then
/// an Episodes grid and a Shows grid. An empty field shows the Collection tiles instead
/// (awe#5956). A card or a tile opens like a list card: the served `screenLink` first, then the
/// convention (`AppRouter.select`, so an episode plays at once when it can).
struct MediaSearchView: View {
    let model: MediaSearchModel

    @Environment(\.appTheme) private var theme
    @Environment(\.mediaSearch) private var search
    @State private var text = ""
    @State private var session = MediaSearchSession()
    @State private var scrolled = false

    private var run: @MainActor (String) async -> MediaSearchState {
        { [search, nodeId = model.nodeId] query in await search?(nodeId, query) ?? .unavailable }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                if let tiles = model.tileGrid(for: text) {
                    ShelfView(model: tiles)
                } else if case let .results(results) = session.state {
                    if let episodes = results.episodes {
                        ShelfView(model: episodes)
                    }
                    if let shows = results.shows {
                        ShelfView(model: shows)
                    }
                } else if let message = session.state.message {
                    Text(message)
                        .font(.system(size: 26))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The results draw past the frame to the stage edges, as a screen does on every other
        // tab. Clipped, they stop 120 pt above the bottom edge and leave a blank band where the
        // tab bar was.
        .scrollClipDisabled()
        // Scrolled results hide the tab bar, as a scrolled screen does on every other tab. At
        // the top, the field is the first thing under the bar, so nothing draws under it.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, scrolled in
            self.scrolled = scrolled
        }
        .toolbar(scrolled ? .hidden : .automatic, for: .tabBar)
        .searchable(text: $text, prompt: ChromeText.string(.searchPrompt))
        // The search container sizes to its frame, not to its content: without a height it
        // draws the field and collapses the results to zero. It takes the screen's visible
        // height (the screen ScrollView's, inside the safe area) less `ScreenBody`'s padding.
        .containerRelativeFrame(.vertical) { length, _ in
            max(length - 2 * Layout.screenTopPadding, 0)
        }
        // The system lays out the field row and the keyboard for the full stage width, from the
        // view's leading edge. Inside `ScreenBody`'s side margins they ran past the right edge
        // (the dictation hint, the delete key). The system insets the results itself.
        .padding(.horizontal, -Layout.screenMargin)
        .onChange(of: text) { _, text in
            session.update(text, search: run)
        }
        // A search in flight stops with the view (another tab, a pushed screen) and runs again
        // when it shows.
        .onAppear { session.update(text, search: run) }
        .onDisappear { session.cancel() }
        // Results are not a paged list.
        .environment(\.loadNextPage, nil)
        #if DEBUG
        // `-search-query <text>` fills the field once, so a run can show results without a remote.
        .task {
            if text.isEmpty, let query = UserDefaults.standard.string(forKey: "search-query"), !query.isEmpty {
                print("[tv] debug search → \(query)")
                text = query
            }
        }
        #endif
    }
}

/// Runs one search of a node on the screen on show. Set by `ScreenBody`; nil searches nothing.
private struct MediaSearchKey: EnvironmentKey {
    static let defaultValue: (@MainActor (_ nodeId: String, _ query: String) async -> MediaSearchState)? = nil
}

extension EnvironmentValues {
    var mediaSearch: (@MainActor (_ nodeId: String, _ query: String) async -> MediaSearchState)? {
        get { self[MediaSearchKey.self] }
        set { self[MediaSearchKey.self] = newValue }
    }
}
