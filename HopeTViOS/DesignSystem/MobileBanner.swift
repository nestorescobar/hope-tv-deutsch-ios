import Foundation

/// The hero art made for phones. A show's `images.bannerMobile` centers the person, where the TV
/// `banner` keeps them at the right edge, under the hero text. It is usually 1:1, but the CMS also
/// serves 16:9, so nothing here reads the shape: the hero fills its frame with either.
enum MobileBanner {
    /// Wide enough for the hero height on a large phone at 3x.
    static let artWidth = 1600
    /// Resources nest a few levels: a block, its list, a record.
    private static let maxDepth = 8

    /// The `images.bannerMobile` of the record with this id, anywhere in a block's resources.
    /// nil when the record is not there or serves none.
    static func file(recordId: String, in resources: JSONValue, depth: Int = 0) -> ImageFile? {
        guard depth < maxDepth else { return nil }
        switch resources {
        case let .object(fields):
            if fields["_id"]?.text == recordId, let file = ImageFile(resources["images"]["bannerMobile"]) { return file }
            for value in fields.values {
                if let file = file(recordId: recordId, in: value, depth: depth + 1) { return file }
            }
            return nil
        case let .array(items):
            for value in items {
                if let file = file(recordId: recordId, in: value, depth: depth + 1) { return file }
            }
            return nil
        default:
            return nil
        }
    }
}
