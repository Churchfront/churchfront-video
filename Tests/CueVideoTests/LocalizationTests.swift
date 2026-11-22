import XCTest
import CueATEM

/// Every text in the string catalogs has a German translation that takes the same values
/// (names, numbers) as the English, so no German screen shows English or a garbled message.
/// After changing what the app says: Tools/update-strings.sh, then translate (docs/localization.md).
final class LocalizationTests: XCTestCase {
    /// The languages every text must be translated into, besides English.
    static let languages = ["de"]

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogs = ["Sources/CueVideo/Resources/Localizable.xcstrings", "Sources/CueATEM/Resources/Localizable.xcstrings"]

    func catalog(_ path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// The values a text takes, by kind and in any order: "%@ to %@" and "%2$@ zu %1$@" both take two texts.
    static func placeholders(_ s: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:#@[A-Za-z0-9_]+@|l{0,2}[@dDuUxXoOfeEgGcCsSp])"#
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            String(s[Range(m.range, in: s)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    /// Every finished form of a translation: the plain value, or each plural form.
    static func values(_ loc: [String: Any]) -> [String]? {
        if let unit = loc["stringUnit"] as? [String: Any] {
            guard unit["state"] as? String == "translated", let v = unit["value"] as? String else { return nil }
            return [v]
        }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
            let forms = plural.values.compactMap { values($0) }
            return forms.count == plural.count && plural["other"] != nil ? forms.flatMap { $0 } : nil
        }
        return nil
    }

    func testEveryTextIsTranslated() throws {
        for path in Self.catalogs {
            for (key, entry) in try catalog(path) where entry["shouldTranslate"] as? Bool != false {
                let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
                for lang in Self.languages {
                    XCTAssertNotNil(locs[lang].flatMap(Self.values), "\(path): \"\(key)\" has no finished \(lang) translation")
                }
            }
        }
    }

    func testTranslationsTakeTheSameValues() throws {
        for path in Self.catalogs {
            for (key, entry) in try catalog(path) {
                let want = Self.placeholders(key)
                for (lang, loc) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                    if let subs = loc["substitutions"] as? [String: [String: Any]] {
                        // Plural parts with their own numbers: one per number in the English.
                        XCTAssertEqual(subs.count, want.count, "\(path): \"\(key)\" (\(lang)) has \(subs.count) counted parts")
                        continue
                    }
                    for v in Self.values(loc) ?? [] {
                        XCTAssertEqual(Self.placeholders(v), want, "\(path): \"\(key)\" (\(lang)) is \"\(v)\"")
                    }
                }
            }
        }
    }

    /// `.verbatim(name)` relies on "%@" passing the name through untouched.
    func testPassThroughKeysStayUntranslated() throws {
        let app = try catalog(Self.catalogs[0])
        for key in ["%@", ""] where app[key] != nil {
            XCTAssertEqual(app[key]?["shouldTranslate"] as? Bool, false, "\"\(key)\" must not be translated")
        }
    }

    /// The engine finds its own translations, the way the app will at run time.
    func testEngineMessagesLoadInGerman() throws {
        let de = try XCTUnwrap(Bundle.cueATEM.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(de.localizedString(forKey: "The switcher stopped answering", value: nil, table: nil), "Der Mischer antwortet nicht mehr")
    }
}
