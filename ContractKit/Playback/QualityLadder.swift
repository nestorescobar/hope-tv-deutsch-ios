import AVFoundation

/// The Quality picker of one HLS stream (awe#6868, ADR-0260). Pure, so it tests without AVKit.
///
/// The options come from the variants the player parsed from the master playlist (awe#6879): one per
/// height, plus Auto. A choice is a cap ("up to"), never a lock: AVPlayer can still play lower on a
/// slow network.
struct QualityLadder: Equatable {
    struct Variant: Equatable {
        let width: Int
        let height: Int
        /// The highest `BANDWIDTH` at this height, in bits per second. 0 sets no bit-rate cap.
        let bandwidth: Int
    }

    /// One row of the menu. `cap` is the height the choice stores (`QualityPreference.auto` for Auto).
    struct Option: Equatable {
        let title: String
        let cap: Int
        let isOn: Bool
    }

    /// One per height, highest first.
    let variants: [Variant]

    /// A real ladder has fewer than 10 heights. The limit bounds the menu a hostile playlist builds.
    static let maxHeights = 16

    /// "4K" and "8K" by their names; every other height reads as `<height>p`. Not translated.
    static func label(height: Int) -> String {
        switch height {
        case 4320: return "8K"
        case 2160: return "4K"
        default: return "\(height)p"
        }
    }

    /// The variant the menu checks for a stored cap, nil for Auto. Rule: the nearest variant at or
    /// below the cap, else the lowest (the viewer asked for less than this stream's lowest).
    func selection(cap: Int) -> Variant? {
        guard cap > QualityPreference.auto else { return nil }
        return variants.first { $0.height <= cap } ?? variants.last
    }

    /// The cap to set on the item, nil for none. The best variant is the same as no cap.
    func constraint(cap: Int) -> Variant? {
        guard let selected = selection(cap: cap), selected != variants.first else { return nil }
        return selected
    }

    /// Auto, then every height highest first, each worded as a cap.
    func options(cap: Int) -> [Option] {
        let selected = selection(cap: cap)
        let auto = Option(title: ChromeText.string(.qualityAuto), cap: QualityPreference.auto, isOn: selected == nil)
        return [auto] + variants.map { variant in
            Option(title: ChromeText.string(.qualityUpTo, ["label": Self.label(height: variant.height)]),
                   cap: variant.height, isOn: variant == selected)
        }
    }
}

extension QualityLadder {
    /// nil when the variants offer fewer than two heights.
    init?(raw: [Variant]) {
        let variants = Self.merged(raw)
        guard variants.count >= 2 else { return nil }
        self.init(variants: variants)
    }

    /// One variant per height, highest first, at most `maxHeights`. AVFoundation does not merge or
    /// sort. Per height: the widest width and the highest bandwidth, each on its own, so an
    /// anamorphic variant never narrows the cap.
    static func merged(_ raw: [Variant]) -> [Variant] {
        var byHeight: [Int: Variant] = [:]
        for variant in raw {
            let known = byHeight[variant.height]
            byHeight[variant.height] = Variant(width: max(variant.width, known?.width ?? 0), height: variant.height,
                                               bandwidth: max(variant.bandwidth, known?.bandwidth ?? 0))
        }
        return Array(byHeight.values.sorted { $0.height > $1.height }.prefix(maxHeights))
    }

    /// One parsed variant, or nil when it offers no height: no video attributes (audio only), or a
    /// width or height below 1 (0x0 when there is no `RESOLUTION`) or not finite. A missing,
    /// negative or non-finite peak reads as 0 (no bit-rate cap).
    static func variant(presentationSize size: CGSize?, peakBitRate: Double?) -> Variant? {
        // `Int(_:)` traps above `Int.max`. No real stream comes near 2^31 pixels or bit/s.
        let bound = Double(Int32.max)
        guard let size, size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return nil }
        let peak = peakBitRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return Variant(width: Int(min(size.width, bound)), height: Int(min(size.height, bound)), bandwidth: Int(min(peak, bound)))
    }

    /// The ladder of the player's own asset, or nil when it offers no choice or does not load. It reads
    /// the master the player already fetched: a second fetch can spend a single-use stream token.
    static func load(from asset: AVAsset) async -> QualityLadder? {
        guard let asset = asset as? AVURLAsset, let variants = try? await asset.load(.variants) else { return nil }
        return QualityLadder(raw: variants.compactMap {
            variant(presentationSize: $0.videoAttributes?.presentationSize, peakBitRate: $0.peakBitRate)
        })
    }
}

extension QualityLadder {
    /// The two item limits for a cap. nil clears both (`.zero`, 0).
    static func limits(_ cap: Variant?) -> (maximumResolution: CGSize, peakBitRate: Double) {
        guard let cap else { return (.zero, 0) }
        return (CGSize(width: cap.width, height: cap.height), Double(cap.bandwidth))
    }

    /// A cap, never a lock (ADR-0260).
    static func apply(_ cap: Variant?, to item: AVPlayerItem) {
        let limits = limits(cap)
        item.preferredMaximumResolution = limits.maximumResolution
        item.preferredPeakBitRate = limits.peakBitRate
    }
}

/// The viewer's choice: a height in `UserDefaults`, kept on the device (the cap depends on the TV's
/// network, not the account). Every next item reads it.
struct QualityPreference {
    static let key = "player-quality-cap-height"
    /// No cap.
    static let auto = 0

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cap: Int {
        get { max(Self.auto, defaults.integer(forKey: Self.key)) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
