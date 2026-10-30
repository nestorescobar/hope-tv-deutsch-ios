import CoreGraphics
import Foundation

/// An uploaded file as the contract serves it.
struct ImageFile: Equatable {
    let name: String
    let containerId: String
    let blurhash: String?
    /// Pixel size when the record carries one. Optional: older uploads have none.
    let width: Int?
    let height: Int?

    init?(_ value: JSONValue) {
        guard let name = value["name"].text, let containerId = value["containerId"].text else { return nil }
        self.name = name
        self.containerId = containerId
        self.blurhash = value["blurhash"].text
        self.width = value["width"].int
        self.height = value["height"].int
    }

    /// Whether the image fills a frame of `aspect` (height ÷ width) without a visible crop.
    /// Art up to `tolerance` taller or wider than the frame still fills (a 15% overshoot crops
    /// about 13%); anything further off is judged not to fit. `nil` when the file has no
    /// dimensions.
    func fits(aspect: CGFloat, tolerance: CGFloat = 1.15) -> Bool? {
        guard let width, let height, width > 0 else { return nil }
        let ratio = CGFloat(height) / CGFloat(width)
        return ratio <= aspect * tolerance && ratio >= aspect / tolerance
    }
}

/// Image bases are shell config, never contract data (ADR-0138).
struct ImageConfig: Equatable {
    let cdn: String
    let bucket: String

    /// The shared resize URL, in Swift.
    ///
    /// The "signature" in the path is base64 of the path with no secret, and gates nothing —
    /// the Worker's bucket allowlist is the real gate. It is reproduced here only because
    /// the Worker expects the path shape.
    func url(_ file: ImageFile?, width: Int) -> URL? {
        guard let file, !cdn.isEmpty else { return nil }
        let path = "/w:\(width)/\(bucket)/\(file.containerId)/\(file.name)"
        // The signature is base64 of the RAW path, because the Worker signs the raw path.
        let signature = Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        // A file name carries spaces and other characters a URL cannot hold as-is; without
        // this, `URL(string:)` answers nil and the card loses its image.
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(cdn)/resize/\(signature)\(encoded)")
    }
}

enum ImageCatalog {
    /// Ordered slots an image falls back through. `default` is the only one always authored,
    /// and it is the item's main image. `banner` is hero art (focus on the right, no title), so
    /// a landscape card never takes it before `default`.
    private static let slots = ["default", "banner", "poster", "podcast"]

    /// The first present image of an `images` map, or nil. A portrait card, a hero and a banner
    /// card ask for their own slot in `BlockRegistry.art`, before they reach this ladder.
    static func pick(_ images: JSONValue) -> ImageFile? {
        for slot in slots {
            if let file = ImageFile(images[slot]) { return file }
        }
        return nil
    }
}
