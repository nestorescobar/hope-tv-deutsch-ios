import SwiftUI

/// Ported from `jsontvapp/clients/appletv` (ADR-0164 point 2). Three changes: the placeholder
/// color comes from the theme seam instead of a compiled-in `DSColor`, `drawsPlaceholder` lets
/// the banner fallback layer a fit image over a blurred copy without hiding it, and a failed
/// load retries (`RemoteImageRetry`).
///
/// The blurhash average color is the placeholder while the image loads and the fallback
/// when the fetch fails, so a shelf never shows holes.
struct RemoteImage: View {
    let url: URL?
    let blurhash: String?
    var contentMode: ContentMode = .fill
    /// False for a layer drawn over another `RemoteImage` of the same file.
    var drawsPlaceholder = true

    @Environment(\.appTheme) private var theme
    /// Bumped to start a new load. `AsyncImage` loads once per identity, so a new id retries.
    @State private var attempt = 0

    private var placeholderColor: Color {
        blurhash.flatMap(BlurHash.averageColor(from:)) ?? theme.surface
    }

    var body: some View {
        ZStack {
            if drawsPlaceholder {
                placeholderColor
            }
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .empty:
                        Color.clear
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case let .failure(error):
                        // A load that started under the full-screen player is canceled, and
                        // `AsyncImage` never retries by itself: the card stayed blank.
                        Color.clear
                            .task(id: attempt) {
                                guard let delay = RemoteImageRetry.delay(after: error, attempt: attempt) else { return }
                                guard (try? await Task.sleep(for: delay)) != nil else { return }
                                attempt += 1
                            }
                    @unknown default:
                        Color.clear
                    }
                }
                .id(attempt)
            }
        }
        .clipped()
        // A new image starts with a fresh retry budget.
        .onChange(of: url) { _, _ in attempt = 0 }
    }
}

/// When a failed image load tries again. Pure, so the rule is testable.
enum RemoteImageRetry {
    /// Loads after the first one. Bounded, so a broken URL never loops.
    static let maxRetries = 3

    /// A canceled load (the view was covered or scrolled away) retries at once; any other
    /// failure waits a little longer each time. nil after `maxRetries`.
    static func delay(after error: Error, attempt: Int) -> Duration? {
        guard attempt < maxRetries else { return nil }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .milliseconds(100) }
        return .seconds(attempt + 1)
    }
}
