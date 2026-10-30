import Foundation

/// The floor of the source ladder.
///
/// Compiled into the binary, so it needs no network, no cache and no bundled file. It is
/// the reason a hostile or absent API can never produce a blank root screen.
enum BuiltInContract {
    static let layoutId = "builtin-layout"
    static let screenId = "builtin-home"

    /// The floor's own text. No manifest is active here, so `ChromeText` has no served strings:
    /// the text is compiled in, one entry per shell `CONTENT_LANGUAGE`.
    struct Strings: Equatable {
        let language: String
        let home: String
        let unreachable: String
    }

    static let english = Strings(
        language: "en",
        home: "Home",
        unreachable: "The content cannot load right now. Check the internet connection of this device, then open the app again."
    )

    static let translations: [String: Strings] = [
        "en": english,
        // cspell:disable
        "de": Strings(
            language: "de",
            home: "Startseite",
            unreachable: "Die Inhalte können gerade nicht geladen werden. Bitte die Internetverbindung des Geräts prüfen und die App erneut öffnen."
        ),
        // cspell:enable
    ]

    /// Matches the primary subtag (`de-AT` → `de`). An unknown language draws English.
    static func strings(for language: String) -> Strings {
        let primary = language.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return translations[primary] ?? english
    }

    /// `name` is the shell's display name (`SHELL_DISPLAY_NAME`), so the floor names this App.
    static func manifestJSON(name: String, strings: Strings = english) -> String {
        """
    {
      "contractVersion": 1,
      "app": {
        "id": "builtin",
        "slug": "builtin",
        "name": \(jsonString(name)),
        "design": "tv",
        "languages": ["\(strings.language)"],
        "defaultLanguage": "\(strings.language)"
      },
      "entryScreenId": null,
      "defaultLayoutId": "\(layoutId)",
      "layouts": [
        {
          "id": "\(layoutId)",
          "content": {
            "ROOT": {
              "type": { "resolvedName": "Root" },
              "isCanvas": true, "props": {}, "custom": {}, "hidden": false,
              "nodes": ["contentPlaceholder"], "linkedNodes": {}
            },
            "contentPlaceholder": {
              "type": { "resolvedName": "ContentPlaceholder" },
              "isCanvas": false, "props": {}, "custom": { "type": "layout" }, "hidden": false,
              "parent": "ROOT", "nodes": [], "linkedNodes": {}
            }
          },
          "navigation": { "tabs": [{ "screenId": "\(screenId)", "label": \(jsonString(strings.home)), "icon": "circle-play" }] }
        }
      ],
      "screens": [{ "id": "\(screenId)", "kind": "static", "resourceType": null, "layoutId": null, "presentation": "push" }],
      "preset": {}
    }
    """
    }

    static func screenJSON(name: String, strings: Strings = english) -> String {
        """
    {
      "id": "\(screenId)",
      "kind": "static",
      "layoutId": "\(layoutId)",
      "language": "\(strings.language)",
      "blockResources": {},
      "content": {
        "ROOT": {
          "type": { "resolvedName": "Root" },
          "isCanvas": true, "props": {}, "custom": {}, "hidden": false,
          "nodes": ["section"], "linkedNodes": {}
        },
        "section": {
          "type": { "resolvedName": "Section" },
          "isCanvas": true, "props": {}, "custom": { "type": "layout" }, "hidden": false,
          "parent": "ROOT", "nodes": ["container"], "linkedNodes": {}
        },
        "container": {
          "type": { "resolvedName": "Container" },
          "isCanvas": true, "props": { "direction": { "xs": "y" } }, "custom": { "type": "layout" },
          "hidden": false, "parent": "section", "nodes": ["title", "note"], "linkedNodes": {}
        },
        "title": {
          "type": { "resolvedName": "SimpleText" },
          "isCanvas": false, "props": { "as": "h1", "text": \(jsonString(name)) }, "custom": { "type": "content" },
          "hidden": false, "parent": "container", "nodes": [], "linkedNodes": {}
        },
        "note": {
          "type": { "resolvedName": "SimpleText" },
          "isCanvas": false,
          "props": { "as": "p", "text": \(jsonString(strings.unreachable)) },
          "custom": { "type": "content" }, "hidden": false, "parent": "container", "nodes": [], "linkedNodes": {}
        }
      }
    }
    """
    }

    /// A JSON string literal, quotes and escapes included: a display name is free text.
    private static func jsonString(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}

extension BuiltInContract {
    /// The floor of the ladder: a manifest that needs no network and no cache, so a
    /// hostile or absent API can never produce a blank root screen. A failure here is a
    /// build error in the literal above, not a runtime condition.
    static func manifest(name: String = AppConfig.displayName, language: String = AppConfig.contract.language) -> AppManifest {
        try! ContractDecoder.manifest(Data(manifestJSON(name: name, strings: strings(for: language)).utf8))
    }

    static func screen(name: String = AppConfig.displayName, language: String = AppConfig.contract.language) -> AppScreen {
        try! ContractDecoder.screen(Data(screenJSON(name: name, strings: strings(for: language)).utf8))
    }
}
