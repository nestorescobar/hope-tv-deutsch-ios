import Foundation
import XCTest
@testable import HopeTViOS

/// The shared conformance fixtures.
///
/// They live once at the repository root and are read from disk by three suites — Vitest,
/// XCTest and JUnit (ADR-0164 point 3). The path is resolved from `#filePath`, so the same
/// test runs from Xcode and from `xcodebuild`.
enum Fixtures {
    /// `fixtures/app-contract`: the shared root. `preset-resolution.json` sits here, beside
    /// the per-App capture folders.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent("fixtures/app-contract", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        fatalError("fixtures/app-contract is not above \(#filePath)")
    }()

    /// The repository root, two levels above `fixtures/app-contract`.
    static let repository: URL = root.deletingLastPathComponent().deletingLastPathComponent()

    /// The `hope-tv` capture this renderer conforms to.
    static let directory: URL = root.appendingPathComponent("hope-tv", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(name))
    }

    /// A file at the shared root, named relative to it (`preset-resolution.json`,
    /// `hope-tv/manifest.json`).
    static func shared(_ path: String) throws -> JSONValue {
        let url = root.appendingPathComponent(path)
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }
}
