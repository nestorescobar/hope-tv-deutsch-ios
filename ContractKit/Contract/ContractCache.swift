import Foundation

/// The identity of one cached document.
///
/// Everything that changes the bytes is in the key: a language switch, an entity switch or
/// a contract-version bump reads a different entry instead of a stale one.
struct ContractCacheKey: Hashable {
    let appSlug: String
    let entityId: String
    let language: String
    let contractVersion: Int
    /// nil for the manifest.
    let screenId: String?
    let param: String?

    static func manifest(_ config: ContractConfig, contractVersion: Int) -> ContractCacheKey {
        ContractCacheKey(
            appSlug: config.appSlug,
            entityId: config.entityId,
            language: config.language,
            contractVersion: contractVersion,
            screenId: nil,
            param: nil
        )
    }

    static func screen(_ config: ContractConfig, contractVersion: Int, screenId: String, param: String?) -> ContractCacheKey {
        ContractCacheKey(
            appSlug: config.appSlug,
            entityId: config.entityId,
            language: config.language,
            contractVersion: contractVersion,
            screenId: screenId,
            param: param
        )
    }

    /// A filename with no separator a value could smuggle in.
    var filename: String {
        let parts = [appSlug, entityId, language, String(contractVersion), screenId ?? "manifest", param ?? "-"]
        let safe = parts.map { part in
            String(part.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        }
        return safe.joined(separator: ".") + ".json"
    }
}

/// Last-known-good storage, one file per key.
///
/// Written only after a document has decoded, validated AND rendered — decoding is not the
/// same as working.
struct ContractCache {
    private let directory: URL

    init(directoryName: String = "app-contract") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load(_ key: ContractCacheKey) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key.filename))
    }

    /// Atomic, so a crash mid-write cannot leave a truncated last-known-good behind.
    func store(_ data: Data, for key: ContractCacheKey) {
        try? data.write(to: directory.appendingPathComponent(key.filename), options: .atomic)
    }

    func remove(_ key: ContractCacheKey) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key.filename))
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
