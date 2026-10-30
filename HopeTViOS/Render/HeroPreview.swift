import AVFoundation
import SwiftUI

/// The show preview video of the hero (ruled 2026-10-26, a narrow exception to "nothing plays
/// inline"): muted, looping and decorative, on a hero shelf only. No controls, no focus, no
/// progress, no history. It matches the web `Hero`: the art first, then the video fades in
/// `delay` after the item shows. Pure parts here; the view is `HeroPreviewVideo`.
enum HeroPreview {
    /// The web `Hero` `videoDelay` (3000 ms). Each page change waits the full time again.
    static let delay: Duration = .seconds(3)
    /// The art-to-video fade, as the web `useMediaStyle` (800 ms).
    static let fadeDuration = 0.8

    /// Where each show's preview stopped, by hero card id, in memory for this app run (ruled
    /// 2026-10-27). The next showing goes on from there, so a viewer sees more of the clip, as on
    /// the web, where the loop never restarts.
    @MainActor static var positions: [String: Double] = [:]

    /// The time a new showing starts at: the saved position, else the start. nil: from 0.
    static func resumeTime(_ saved: Double?) -> CMTime? {
        guard let saved, saved.isFinite, saved > 0 else { return nil }
        return CMTime(seconds: saved, preferredTimescale: 600)
    }

    /// An allowlist, not an escape: each id lands in the host or the path, so an id that could
    /// add a label, a segment or a query is refused.
    private static let id = #/[A-Za-z0-9]{1,64}/#

    /// A show's `previewVideo` (`{ provider, videoId, accountId }`) as an https HLS url, or nil.
    /// Only `cloudflare` resolves, with the url the web builds (`getPlayerUrl.js`). Never log it.
    static func source(_ preview: JSONValue) -> URL? {
        guard preview["provider"].text == "cloudflare",
              let account = preview["accountId"].text, account.wholeMatch(of: id) != nil,
              let video = preview["videoId"].text, video.wholeMatch(of: id) != nil else { return nil }
        return ContractValidator.playableURL("https://customer-\(account).cloudflarestream.com/\(video)/manifest/video.m3u8")
    }

    /// When the preview may play. Pure, so the rule is testable.
    struct Gate: Equatable {
        /// The item serves a preview that resolves (`source`).
        var hasSource: Bool
        /// Reduce Motion is on: the art stays, as the web keeps the image.
        var reduceMotion: Bool
        /// The full-screen player is open.
        var playbackOpen: Bool
        /// The hero shows: it appeared, its screen is the one on show, and it is scrolled into view.
        var onScreen: Bool
        /// The scene is `.active`.
        var sceneActive: Bool

        /// Why it must not play, for the debug log. nil: it may play.
        var hold: String? {
            if !hasSource { return "no source" }
            if reduceMotion { return "reduce motion" }
            if playbackOpen { return "playback open" }
            if !onScreen { return "off screen" }
            if !sceneActive { return "scene inactive" }
            return nil
        }

        var mayPlay: Bool { hold == nil }
    }

    /// One muted looping player for one show (`key`). `stop` releases the stream; drop the object
    /// after it.
    @MainActor @Observable
    final class Playback {
        let key: String
        @ObservationIgnored let player = AVQueuePlayer()
        /// True once it plays from its start time. The fade waits for it, so a frame from 0
        /// never shows before the seek.
        private(set) var playing = false
        @ObservationIgnored private let looper: AVPlayerLooper
        @ObservationIgnored private var itemObservation: NSKeyValueObservation?
        @ObservationIgnored private var statusObservation: NSKeyValueObservation?
        @ObservationIgnored private var stopped = false

        init(url: URL, key: String, startAt start: CMTime?) {
            self.key = key
            player.isMuted = true
            player.allowsExternalPlayback = false
            // The screensaver must still run over a decorative loop.
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            guard let start else {
                begin()
                return
            }
            // The looper puts its first item in the player after this init: `currentItem` is
            // still nil here (measured, tvOS 27 simulator). Wait for it, then for the item.
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.seekFirstItem(to: start) }
            }
        }

        /// The position to keep for the next showing. nil before it plays.
        var position: Double? {
            guard playing else { return nil }
            let seconds = player.currentTime().seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }

        /// Seeks the first looper item to `start` once it can, then plays. Only this first pass
        /// starts late: the looper plays every next pass from 0. An item that fails plays from 0.
        private func seekFirstItem(to start: CMTime) {
            guard itemObservation != nil, let item = player.currentItem else { return }
            itemObservation = nil
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status != .unknown else { return }
                DispatchQueue.main.async {
                    guard let self, self.statusObservation != nil else { return }
                    self.statusObservation = nil
                    guard item.status == .readyToPlay else { return self.begin() }
                    item.seek(to: start, completionHandler: { _ in
                        DispatchQueue.main.async { self.begin() }
                    })
                }
            }
        }

        private func begin() {
            guard !stopped else { return }
            player.play()
            playing = true
        }

        func stop() {
            stopped = true
            itemObservation = nil
            statusObservation = nil
            looper.disableLooping()
            player.pause()
            player.removeAllItems()
        }
    }
}

/// The preview layer of `HeroShelfView`, between the art and the gradients. `url` is nil while
/// the gate holds (`HeroPreview.Gate`). A change of `index` or `url` tears the player down and
/// keeps its position for `key`; a new url loads after `HeroPreview.delay` from that position,
/// and the video fades in only once it plays and its layer has a frame, so it never fades to
/// black.
struct HeroPreviewVideo: View {
    let index: Int
    /// The hero card id: whose position to resume and keep.
    let key: String
    let url: URL?
    /// The gate's reason, for the debug log when `url` goes nil.
    let hold: String?

    @State private var playback: HeroPreview.Playback?
    /// The page `playback` belongs to, so the log can tell a page change from the gate.
    @State private var playbackIndex: Int?
    @State private var ready = false

    private struct Key: Equatable {
        let index: Int
        let url: URL?
    }

    var body: some View {
        ZStack {
            if let playback {
                HeroPreviewLayer(player: playback.player) {
                    guard self.playback === playback, !ready else { return }
                    ready = true
                    log("ready")
                }
                .id(ObjectIdentifier(playback))
                .opacity(ready && playback.playing ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: HeroPreview.fadeDuration), value: ready && playback?.playing == true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: Key(index: index, url: url)) {
            stop(playbackIndex != index ? "page change" : hold ?? "no source")
            guard let url, (try? await Task.sleep(for: HeroPreview.delay)) != nil else { return }
            let saved = HeroPreview.positions[key]
            playback = HeroPreview.Playback(url: url, key: key, startAt: HeroPreview.resumeTime(saved))
            playbackIndex = index
            log("start at \(Int(saved ?? 0)) s")
        }
        .onDisappear { stop("off screen") }
    }

    private func stop(_ reason: String) {
        guard let current = playback else { return }
        let position = current.position
        if let position {
            HeroPreview.positions[current.key] = position
        }
        current.stop()
        playback = nil
        playbackIndex = nil
        ready = false
        // The player's own time, not the saved one: it shows whether the seek landed.
        log("stop \(reason) at \(Int(position ?? 0)) s")
    }

    private func log(_ event: String) {
        #if DEBUG
        NSLog("[tv] hero preview: %@", event)
        #endif
    }
}

/// A bare video layer: no controls, no focus, no Now Playing info.
private struct HeroPreviewLayer: UIViewRepresentable {
    let player: AVPlayer
    let onReady: () -> Void

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        view.onReady = onReady
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.onReady = onReady
    }

    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override var canBecomeFocused: Bool { false }
        var onReady: (() -> Void)?
        private var observation: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.onReady?() }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
