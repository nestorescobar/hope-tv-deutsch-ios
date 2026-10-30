import Foundation

/// The display name of a served public person (awe#7035): a port of the DEFAULT format of
/// `getPersonName` in `packages/utils/src/persons.ts` (`format: 'fullName'`, `withTitle: true`).
/// Change both together.
///
/// It reads the served name parts only. The server enforces `initialsOnly` (ADR-0008,
/// `apis/frontend/modules/persons/helpers/toPublicPerson.js`): it puts the initials into
/// `firstName`, `lastName` and `fullName`, and never sends the flag, so this port does not read it.
enum PersonName {
    /// A non-empty `fullName`, else `prefix` + `firstName`, the middle initial, `lastName` +
    /// `, suffix`. `""` when no part is served.
    static func display(_ person: JSONValue) -> String {
        if let fullName = part(person["fullName"]) { return fullName }
        let core = [part(person["firstName"]), part(person["middleName"]).map(initial), part(person["lastName"])]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !core.isEmpty else { return core }
        let prefix = part(person["prefix"]).map { "\($0) " } ?? ""
        let suffix = part(person["suffix"]).map { ", \($0)" } ?? ""
        return prefix + core + suffix
    }

    /// A JS-truthy string: not empty. A blank string is truthy in JS, so it is kept.
    private static func part(_ value: JSONValue) -> String? {
        guard let text = value.string, !text.isEmpty else { return nil }
        return text
    }

    /// `initial`: the first character, upper-cased, and a dot. `""` for a blank value.
    private static func initial(_ value: String) -> String {
        guard let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "" }
        return first.uppercased() + "."
    }
}
