import Foundation

/// Reads a `RichText` block's Tiptap doc into the blocks the TV draws.
///
/// The nodes the mobile renderer draws that make sense read-only on a TV: `paragraph`,
/// `heading`, `bulletList`, `orderedList`, `blockquote`, `horizontalRule`, and inline `text`
/// and `hardBreak`. Marks: `bold`, `italic`, `underline`, `strike`. A `link` mark draws its
/// text plain, because tvOS opens no URLs. Any other block node is skipped, as on mobile, and
/// any other inline node or mark adds nothing.
enum RichTextReader {
    /// How deep lists and quotes may nest. The rest is not drawn.
    static let maxDepth = 16

    /// The highest number an ordered list starts at, so `start + index` cannot overflow.
    static let maxListStart = 1_000_000

    /// nil when the doc draws nothing: absent, no content, or only blank text (the mobile
    /// `isRichTextDocEmpty` rule).
    static func model(_ doc: JSONValue) -> RichTextModel? {
        let blocks = blocks(doc["content"], depth: 0)
        let model = RichTextModel(blocks: blocks)
        return model.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model
    }

    private static func blocks(_ content: JSONValue, depth: Int) -> [RichTextModel.Block] {
        guard depth < maxDepth else { return [] }
        return content.array.compactMap { block($0, depth: depth) }
    }

    private static func block(_ node: JSONValue, depth: Int) -> RichTextModel.Block? {
        switch node["type"].string {
        case "paragraph":
            let runs = runs(node["content"])
            return isBlank(runs) ? nil : .paragraph(runs)
        case "heading":
            let runs = runs(node["content"])
            let level = min(max(node["attrs"]["level"].int ?? 1, 1), 6)
            return isBlank(runs) ? nil : .heading(level: level, runs)
        case "bulletList", "orderedList":
            let items = node["content"].array
                .map { blocks($0["content"], depth: depth + 1) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            let ordered = node["type"].string == "orderedList"
            let start = min(max(node["attrs"]["start"].int ?? 1, 0), maxListStart)
            return .list(ordered: ordered, start: ordered ? start : 1, items: items)
        case "blockquote":
            let inner = blocks(node["content"], depth: depth + 1)
            return inner.isEmpty ? nil : .quote(inner)
        case "horizontalRule":
            return .rule
        default:
            return nil
        }
    }

    private static func runs(_ content: JSONValue) -> [RichTextModel.Run] {
        content.array.compactMap { inline in
            switch inline["type"].string {
            case "text":
                guard let text = inline["text"].string, !text.isEmpty else { return nil }
                return RichTextModel.Run(text: text, marks: Set(inline["marks"].array.compactMap { mark($0["type"].string) }))
            case "hardBreak":
                return RichTextModel.Run(text: "\n")
            default:
                return nil
            }
        }
    }

    private static func mark(_ type: String?) -> RichTextModel.Run.Mark? {
        switch type {
        case "bold": return .bold
        case "italic": return .italic
        case "underline": return .underline
        case "strike": return .strike
        default: return nil
        }
    }

    private static func isBlank(_ runs: [RichTextModel.Run]) -> Bool {
        runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
