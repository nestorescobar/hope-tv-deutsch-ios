import SwiftUI

// Minimal BlurHash decoder — returns just the average color from the hash.
// Sufficient as a placeholder swatch on TV while the full image loads.
// Reference: https://github.com/woltapp/blurhash (MIT)
enum BlurHash {
    static func averageColor(from hash: String) -> Color? {
        guard hash.count >= 6 else { return nil }
        guard hash.allSatisfy({ base83Characters.contains($0) }) else { return nil }
        let avgColorString = String(hash.dropFirst(2).prefix(4))
        guard let value = base83Decode(avgColorString) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    private static let base83Characters: [Character] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    static func base83Decode(_ string: String) -> Int? {
        var value = 0
        for char in string {
            guard let index = base83Characters.firstIndex(of: char) else { return nil }
            value = value * 83 + index
        }
        return value
    }

}
