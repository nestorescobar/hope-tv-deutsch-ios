import SwiftUI
import UIKit
import WebKit

/// A YouTube source in an iframe. Pure parts here; the view is `YouTubeEmbedView`.
///
/// The player belongs to YouTube, so a viewer gets no resume point, no Keep watching entry and no
/// Up Next. It draws on the Episode or Movie Screen, a pushed screen, so a replacement screen
/// already waits (contract invariant 3): `AppRouter.isAtSafeBoundary` is false while it shows.
enum YouTubeEmbed {
    /// An allowlist, not an escape: the id lands in the URL and in the page.
    private static let id = #/[A-Za-z0-9_-]{11}/#
    private static let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "www.youtube-nocookie.com", "youtube-nocookie.com"]

    /// The video of an `episodePlayer` or `moviePlayer` resource: the served provider, else the
    /// `mediaLinks` entry. nil when neither names YouTube.
    static func videoId(_ resource: JSONValue) -> String? {
        var links: [String?] = []
        if resource["provider"].text == "youtube" {
            links += [resource["link"].text, resource["videoId"].text, resource["id"].text]
        }
        let entry = resource["mediaLinks"]["youtube"]
        links += [entry.text, entry["link"].text]
        return links.compactMap { $0 }.lazy.compactMap(videoId(fromLink:)).first
    }

    /// A bare id, or a watch, share, embed, Shorts or live URL.
    static func videoId(fromLink link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: id) != nil { return text }
        guard let parts = URLComponents(string: text), let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if hosts.contains(host) {
            if path.first == "watch" {
                candidate = parts.queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["embed", "shorts", "live", "v"].contains(path[0]) {
                candidate = path[1]
            }
        }
        return candidate.flatMap { $0.wholeMatch(of: id) != nil ? $0 : nil }
    }

    /// Through `playableURL`, as every other source (contract invariant 4). The no-cookie host
    /// sets no tracking cookie before the viewer presses play.
    static func embedURL(videoId: String) -> URL? {
        guard videoId.wholeMatch(of: id) != nil else { return nil }
        return ContractValidator.playableURL("https://www.youtube-nocookie.com/embed/\(videoId)?playsinline=1&rel=0")
    }

    /// The page around the iframe.
    static func page(embedURL: URL) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(embedURL.absoluteString)" allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; web-share"
                allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }

    /// YouTube refuses an embed with no referrer (error 153), and a page from a string has none.
    /// Its identity for a mobile app is the app id as an https origin.
    static var origin: URL? {
        URL(string: "https://\((Bundle.main.bundleIdentifier ?? "app").lowercased())")
    }
}

/// The iframe in a web view. A link out of the player opens in the browser, never in this view.
/// The app stays portrait, so full screen allows the turn only while it lasts.
struct YouTubeEmbedView: UIViewRepresentable {
    let videoId: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.observe(view)
        if let url = YouTubeEmbed.embedURL(videoId: videoId) {
            view.loadHTMLString(YouTubeEmbed.page(embedURL: url), baseURL: YouTubeEmbed.origin)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.pauseAllMediaPlayback()
        view.loadHTMLString("", baseURL: nil)
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var fullscreen: NSKeyValueObservation?

        func observe(_ view: WKWebView) {
            fullscreen = view.observe(\.fullscreenState, options: [.new]) { view, _ in
                let full = view.fullscreenState == .inFullscreen
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { OrientationLock.set(full ? .allButUpsideDown : .portrait) }
                }
            }
        }

        func stop() {
            fullscreen = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false else {
                decisionHandler(.allow)
                return
            }
            if let url = action.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }

        /// A `target="_blank"` link, such as "Watch on YouTube".
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url) }
            return nil
        }
    }
}
