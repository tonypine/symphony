import Foundation
import JavaScriptCore
import XCTest

/// The counterpart check (TP-1511): every component and section of the design catalog (`docs/design/catalog/stories.js`)
/// is in the table of `docs/design/catalog-counterparts.md`, mapped to its shared Swift type in `SymphonyBarUI` or with
/// the reason it has none yet. A mapped type must exist, and every story of a mapped entry must have a variation of the
/// same name in the Component Gallery, as `macos/Gallery/component-variations.txt` lists them (`SymphonyGallery --check`
/// holds that list to the gallery's stories).
final class CatalogCounterpartsTests: XCTestCase {
    // MARK: - The repository's own

    func testEveryCatalogEntryHasItsCounterpart() throws {
        let entries = try CatalogCounterparts.entries(catalog: try Self.read("docs/design/catalog/stories.js"))
        XCTAssertTrue(entries.contains { $0.address == "components/key-value-list" }, "the catalog reads as no entries")
        let lines = CatalogCounterparts.table(try Self.read("docs/design/catalog-counterparts.md"))
        let problems = CatalogCounterparts.problems(
            entries: entries, table: lines, types: try Self.sharedTypes(),
            variations: CatalogCounterparts.variations(try Self.read("macos/Gallery/component-variations.txt"))
        )
        for problem in problems { XCTFail(problem) }
    }

    /// Both components of TP-1511 are mapped, and every not-yet-built entry the ticket named says so and nothing else.
    func testTheTableMapsTheSharedComponentsAndListsWhatIsNotBuilt() throws {
        let lines = Dictionary(uniqueKeysWithValues: CatalogCounterparts.table(try Self.read("docs/design/catalog-counterparts.md")).map { ($0.address, $0) })
        XCTAssertEqual(lines["components/key-value-list"]?.type, "KeyValueList")
        XCTAssertEqual(lines["components/collapsible-card"]?.type, "CollapsibleCard")
        for address in ["tooltip", "toggle", "toast", "sheet-header", "empty-state", "attachment-thumbnail", "step-strip"] {
            XCTAssertEqual(lines["components/\(address)"]?.words, CatalogCounterparts.notBuilt, address)
        }
    }

    // MARK: - What makes it fail

    func testAStoryWithoutItsVariationFailsAndNamesTheStory() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }, { name: "Header glow" }]"#))
        let problems = CatalogCounterparts.problems(
            entries: entries, table: CatalogCounterparts.table(Self.table), types: ["CollapsibleCard"],
            variations: ["collapsible-card-open"]
        )
        XCTAssertEqual(problems, [
            "components/collapsible-card's story \"Header glow\" has no variation collapsible-card-header-glow in the Component Gallery: "
                + "add it to the entry's stories in macos/Gallery and to macos/Gallery/component-variations.txt.",
        ])
    }

    func testAnEntryMissingFromTheTableFails() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }]"#, extra: #"{ title: "Glow ring", stories: [] }"#))
        let problems = CatalogCounterparts.problems(
            entries: entries, table: CatalogCounterparts.table(Self.table), types: ["CollapsibleCard"], variations: ["collapsible-card-open"]
        )
        XCTAssertEqual(problems, [
            "components/glow-ring (Glow ring) is in the catalog and not in docs/design/catalog-counterparts.md: map it to its Swift type, "
                + "or write why it has none (\"not built\").",
        ])
    }

    func testAMappedTypeThatDoesNotExistFails() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }]"#))
        let problems = CatalogCounterparts.problems(
            entries: entries, table: CatalogCounterparts.table(Self.table), types: ["KeyValueList"], variations: ["collapsible-card-open"]
        )
        XCTAssertEqual(problems, [
            "components/collapsible-card is mapped to CollapsibleCard, which SymphonyBarUI does not declare as a public type.",
        ])
    }

    func testAnEntryListedTwiceOrNoLongerInTheCatalogFails() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }]"#))
        let table = Self.table + "| `components/collapsible-card` | not built |\n| `components/old-thing` | not built |\n"
        let problems = CatalogCounterparts.problems(
            entries: entries, table: CatalogCounterparts.table(table), types: ["CollapsibleCard"], variations: ["collapsible-card-open"]
        )
        XCTAssertEqual(problems, [
            "components/collapsible-card is in docs/design/catalog-counterparts.md twice.",
            "components/old-thing is in docs/design/catalog-counterparts.md and no longer in the catalog: remove its line.",
        ])
    }

    /// An entry not built, or with a reason, needs no type and no variation.
    func testAReasonNeedsNothingElse() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }]"#))
        for words in ["not built", "`CollapsibleCard` draws it; its stories are not in the gallery one by one yet"] {
            let table = "| `components/collapsible-card` | \(words) |\n| `sections/window` | \(CatalogCounterparts.notBuilt) |\n"
            XCTAssertEqual(CatalogCounterparts.problems(entries: entries, table: CatalogCounterparts.table(table), types: [], variations: []), [])
        }
    }

    // MARK: - Reading

    func testTheCatalogIsReadAsTheCatalogShellReadsIt() throws {
        let entries = try CatalogCounterparts.entries(catalog: Self.catalog(stories: #"[{ name: "Open" }, { name: "Header focused" }, { id: "own-id", name: "Named" }]"#))
        XCTAssertEqual(entries, [
            CatalogCounterparts.Entry(
                address: "components/collapsible-card", title: "Collapsible card",
                stories: [.init(id: "open", name: "Open"), .init(id: "header-focused", name: "Header focused"), .init(id: "own-id", name: "Named")]
            ),
            CatalogCounterparts.Entry(address: "sections/window", title: "Window", stories: [.init(id: "ticket-page-laptop", name: "Ticket page, laptop")]),
        ])
        XCTAssertEqual(CatalogCounterparts.slug("Tickets, filtered, with the details"), "tickets-filtered-with-the-details")
        XCTAssertEqual(CatalogCounterparts.slug("Tokens against the ticket’s cap"), "tokens-against-the-ticket-s-cap")
    }

    func testACatalogThatDoesNotRunFails() {
        XCTAssertThrowsError(try CatalogCounterparts.entries(catalog: "window.CATALOG = (function () { throw new Error('broken'); })();"))
        XCTAssertThrowsError(try CatalogCounterparts.entries(catalog: "var nothing = 1;"))
    }

    func testTheTableReadsTypesAndReasons() {
        let lines = CatalogCounterparts.table("""
            | Catalog entry | In SymphonyBarUI |
            | --- | --- |
            | `components/button` | `DirectorButtonStyle` |
            | `components/chip` | `Chip` draws its kinds |
            | `components/toggle` | not built |
            Some words about it.
            """)
        XCTAssertEqual(lines, [
            CatalogCounterparts.Line(address: "components/button", words: "`DirectorButtonStyle`", type: "DirectorButtonStyle"),
            CatalogCounterparts.Line(address: "components/chip", words: "`Chip` draws its kinds", type: nil),
            CatalogCounterparts.Line(address: "components/toggle", words: "not built", type: nil),
        ])
    }

    func testPublicTypesAreFoundInTheSources() {
        let types = CatalogCounterparts.publicTypes(in: [
            "public struct KeyValueList<Content: View>: View {}\nstruct Hidden {}\n@MainActor public final class Presenter {}",
            "public enum FoldMotion {}\npublic protocol Drawn {}\npublic typealias Shown = Int\nprivate struct Mine {}",
        ])
        XCTAssertEqual(types, ["KeyValueList", "Presenter", "FoldMotion", "Drawn", "Shown"])
    }

    func testTheVariationsFileSkipsItsHeader() {
        XCTAssertEqual(CatalogCounterparts.variations("# a header\n# more\nbutton-primary\n\n  row-default  \n"), ["button-primary", "row-default"])
    }

    // MARK: - Fixtures

    static let table = """
        | Catalog entry | In SymphonyBarUI |
        | --- | --- |
        | `components/collapsible-card` | `CollapsibleCard` |
        | `sections/window` | Drawn by the app's own window |

        """

    /// A catalog in the shape of `stories.js`: one component with `stories`, and one section.
    static func catalog(stories: String, extra: String? = nil) -> String {
        """
        window.CATALOG = (function () {
          const components = [{ title: "Collapsible card", stories: \(stories) }\(extra.map { ", " + $0 } ?? "")];
          return {
            groups: [
              { id: "tokens", title: "Tokens", items: [{ title: "Colour", stories: [{ name: "Accent" }] }] },
              { id: "components", title: "Components", items: components },
              { id: "sections", title: "Sections", items: [{ title: "Window", stories: [{ name: "Ticket page, laptop" }] }] },
            ],
          };
        })();
        """
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The public types every Swift file under `macos/Sources/SymphonyBarUI` declares.
    static func sharedTypes() throws -> Set<String> {
        let folder = root.appendingPathComponent("macos/Sources/SymphonyBarUI")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var sources: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append(try String(contentsOf: url, encoding: .utf8))
        }
        XCTAssertFalse(sources.isEmpty)
        return Set(CatalogCounterparts.publicTypes(in: sources))
    }
}

/// Reads the catalog, the table and the gallery's list, and says what disagrees.
enum CatalogCounterparts {
    static let tablePath = "docs/design/catalog-counterparts.md"
    static let variationsPath = "macos/Gallery/component-variations.txt"
    static let notBuilt = "not built"
    /// The catalog's groups the table covers: its tokens are `DesignTokensCatalogTests`'.
    static let groups = ["components", "sections"]

    struct Story: Equatable {
        let id: String
        let name: String
    }

    struct Entry: Equatable {
        /// `components/key-value-list`, as in the catalog's `#components/key-value-list/…`.
        let address: String
        let title: String
        let stories: [Story]

        /// The entry's id within its group: `key-value-list`.
        var id: String { String(address.split(separator: "/").last ?? "") }
    }

    struct Line: Equatable {
        let address: String
        /// The second cell as written.
        let words: String
        /// The Swift type, when the cell is one in backticks and nothing else.
        let type: String?
    }

    struct CatalogError: Error, CustomStringConvertible {
        let description: String
    }

    /// The catalog shell's `slug` (`catalog.js`): lower case, every run of other characters one dash, none at the ends.
    static func slug(_ text: String) -> String {
        var out = ""
        var dash = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.unicodeScalars.append(scalar)
            } else {
                dash = true
            }
        }
        return out
    }

    /// Every component and section of `catalog` (the text of `stories.js`), run as the browser runs it, with each
    /// item's and story's id as the catalog shell gives them.
    static func entries(catalog: String) throws -> [Entry] {
        let context: JSContext = JSContext()
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        context.evaluateScript("var window = {};")
        context.evaluateScript(catalog)
        if let thrown { throw CatalogError(description: "stories.js did not run: \(thrown)") }
        let read = context.evaluateScript("""
            JSON.stringify((window.CATALOG && window.CATALOG.groups || []).map(function (g) {
              return { id: g.id, items: (g.items || []).map(function (i) {
                return { id: i.id || null, title: i.title, stories: (i.stories || []).map(function (s) { return { id: s.id || null, name: s.name }; }) };
              }) };
            }))
            """)
        if let thrown { throw CatalogError(description: "stories.js did not read: \(thrown)") }
        struct Group: Decodable {
            struct Item: Decodable {
                struct Story: Decodable {
                    let id: String?
                    let name: String
                }

                let id: String?
                let title: String
                let stories: [Story]
            }

            let id: String
            let items: [Item]
        }
        let data = Data((read?.toString() ?? "[]").utf8)
        let groups = try JSONDecoder().decode([Group].self, from: data)
        let entries = groups.filter { Self.groups.contains($0.id) }.flatMap { group in
            group.items.map { item in
                Entry(
                    address: "\(group.id)/\(item.id ?? slug(item.title))", title: item.title,
                    stories: item.stories.map { Story(id: $0.id ?? slug($0.name), name: $0.name) }
                )
            }
        }
        if entries.isEmpty { throw CatalogError(description: "stories.js has no components and no sections") }
        return entries
    }

    /// The table's lines: every row whose first cell is a catalog address in backticks.
    static func table(_ markdown: String) -> [Line] {
        markdown.split(separator: "\n").compactMap { raw in
            let cells = raw.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // "| a | b |" splits into "", a, b, "".
            guard cells.count == 4, cells[0].isEmpty, cells[3].isEmpty else { return nil }
            let address = cells[1]
            guard address.hasPrefix("`"), address.hasSuffix("`"), address.count > 2 else { return nil }
            let name = String(address.dropFirst().dropLast())
            guard groups.contains(where: { name.hasPrefix($0 + "/") }) else { return nil }
            return Line(address: name, words: cells[2], type: type(in: cells[2]))
        }
    }

    /// `` `KeyValueList` `` alone is a type; anything else is words.
    static func type(in cell: String) -> String? {
        guard cell.hasPrefix("`"), cell.hasSuffix("`"), cell.count > 2 else { return nil }
        let inner = cell.dropFirst().dropLast()
        guard let first = inner.first, first.isLetter || first == "_", inner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return String(inner)
    }

    /// The types `sources` declare public: structs, classes, enums, protocols, actors and type aliases.
    static func publicTypes(in sources: [String]) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\bpublic\s+(?:final\s+)?(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        return sources.flatMap { source in
            pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
        }
    }

    /// The names in the gallery's list: every line that is not blank or a comment.
    static func variations(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// What disagrees, in plain words; empty when the catalog, the table, the types and the gallery agree.
    static func problems(entries: [Entry], table: [Line], types: Set<String>, variations: Set<String>) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []
        for line in table where !seen.insert(line.address).inserted {
            problems.append("\(line.address) is in \(tablePath) twice.")
        }
        let lines = Dictionary(table.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            guard let line = lines[entry.address] else {
                problems.append(
                    "\(entry.address) (\(entry.title)) is in the catalog and not in \(tablePath): map it to its Swift type, or write why it has none (\"\(notBuilt)\")."
                )
                continue
            }
            guard let type = line.type else { continue }
            if !types.contains(type) {
                problems.append("\(entry.address) is mapped to \(type), which SymphonyBarUI does not declare as a public type.")
            }
            for story in entry.stories {
                let variation = "\(entry.id)-\(story.id)"
                if !variations.contains(variation) {
                    problems.append(
                        "\(entry.address)'s story \"\(story.name)\" has no variation \(variation) in the Component Gallery: add it to the entry's stories in macos/Gallery and to \(variationsPath)."
                    )
                }
            }
        }
        let addresses = Set(entries.map(\.address))
        for line in table where !addresses.contains(line.address) && seen.remove(line.address) != nil {
            problems.append("\(line.address) is in \(tablePath) and no longer in the catalog: remove its line.")
        }
        return problems
    }
}
