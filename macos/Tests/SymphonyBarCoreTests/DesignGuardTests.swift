import XCTest

/// The design guard (TP-1493, `docs/design/design-system.md` §3.11): a view takes every style value from
/// `DesignTokens` or a shared component. What the views held when the guard landed is the baseline in
/// `macos/Tests/DesignGuard/baseline.txt`, which always equals the count and can only go down.
final class DesignGuardTests: XCTestCase {
    // MARK: - The app's views

    func testEveryViewMatchesTheBaseline() throws {
        let bypasses = try DesignGuard.scan(sources: Self.sources)
        XCTAssertFalse(bypasses.isEmpty, "the guard read no source")
        let baseline = try DesignGuard.parseBaseline(String(contentsOf: Self.baselineFile, encoding: .utf8))
        for message in DesignGuard.failures(bypasses: bypasses, baseline: baseline) { XCTFail(message) }
    }

    func testTheBaselineFileIsWrittenAsTheGuardWritesIt() throws {
        let text = try String(contentsOf: Self.baselineFile, encoding: .utf8)
        XCTAssertEqual(DesignGuard.formatBaseline(try DesignGuard.parseBaseline(text)), text, "keep the baseline sorted, one line per file and kind")
    }

    /// `.frame(` literals are counted and reported, and fail nothing in this ticket.
    func testFrameLiteralsAreReported() throws {
        let frames = try DesignGuard.scan(sources: Self.sources).filter { $0.kind == .frame }
        print("Design guard: \(frames.count) literal sizes in .frame( across \(Set(frames.map(\.file)).count) files (reported, not guarded)")
        XCTAssertFalse(frames.isEmpty)
    }

    func testTheDesignSystemFilesAreTheOnlyExemptions() throws {
        let files = try DesignGuard.sourceFiles(in: Self.sources)
        XCTAssertFalse(files.contains("SymphonyBarUI/DesignSystem.swift"))
        XCTAssertFalse(files.contains("SymphonyBarUI/InteractionStyles.swift"))
        XCTAssertTrue(files.contains("SymphonyBar/TicketPageView.swift"))
        XCTAssertTrue(files.contains("SymphonyBarUI/QuestionBlock.swift"))
        XCTAssertFalse(files.contains { $0.hasPrefix("SymphonyBarCore/") }, "the guard reads the views' folders only")
        XCTAssertTrue(DesignGuard.isExempt("SymphonyBarCore/DesignTokens.swift"))
        XCTAssertTrue(DesignGuard.isExempt("SymphonyBarUI/DesignSystem/Panel.swift"))
        XCTAssertTrue(DesignGuard.isExempt("SymphonyBar/DesignSystem/Chips/Chip.swift"))
        XCTAssertFalse(DesignGuard.isExempt("SymphonyBarUI/DesignSystemPreview.swift"))
        XCTAssertFalse(DesignGuard.isExempt("SymphonyBar/HomeView.swift"))
    }

    // MARK: - Walkthrough

    /// Step 1: a page that adds `.font(.title3)` fails the guard, which names the file, the line and the type style.
    func testANewRawFontFailsWithTheFileTheLineAndTheTypeStyle() {
        let page = """
        struct HomeView: View {
            var body: some View {
                Text("Home")
                    .font(.title3)
            }
        }
        """
        let failures = DesignGuard.failures(bypasses: DesignGuard.scan(page, file: "SymphonyBar/HomeView.swift"), baseline: [:])
        XCTAssertEqual(failures.count, 1)
        let message = failures.first ?? ""
        XCTAssertTrue(message.contains("SymphonyBar/HomeView.swift:4: font bypass .title3"), message)
        XCTAssertTrue(message.contains("use `.textStyle(.heading)` (`DesignTokens.TypeStyle.heading`)"), message)
    }

    /// Step 2: replacing a raw `.foregroundStyle(.secondary)` with its token fails until the baseline is lowered by one.
    func testARemovedBypassFailsUntilTheBaselineIsLowered() {
        let before = """
        Text("a").foregroundStyle(.secondary)
        Text("b").foregroundStyle(.secondary)
        """
        let after = """
        Text("a").foregroundStyle(DesignTokens.TextColor.secondary.color)
        Text("b").foregroundStyle(.secondary)
        """
        let file = "SymphonyBar/InboxView.swift"
        let baseline: DesignGuard.Counts = [file: [.color: 2]]
        XCTAssertEqual(DesignGuard.failures(bypasses: DesignGuard.scan(before, file: file), baseline: baseline), [])
        let bypasses = DesignGuard.scan(after, file: file)
        XCTAssertEqual(
            DesignGuard.failures(bypasses: bypasses, baseline: baseline),
            ["SymphonyBar/InboxView.swift has 1 color bypass(es), below its baseline of 2: lower the baseline line to `SymphonyBar/InboxView.swift color 1`"]
        )
        XCTAssertEqual(DesignGuard.failures(bypasses: bypasses, baseline: [file: [.color: 1]]), [])
    }

    // MARK: - What counts

    func testFontsCount() {
        let found = scan("""
        .font(.caption)
        .font(.system(size: 11, weight: .medium))
        .font(.body.monospaced())
        .font(Font.headline)
        .font(compact ? .caption2 : .callout)
        private var nameFont: Font { .system(size: 12) }
        static let tag = NSFont.systemFont(ofSize: 16)
        """)
        XCTAssertEqual(found.map(\.kind), Array(repeating: .font, count: 8))
        XCTAssertEqual(found.map(\.value), [".caption", ".system", ".body", "Font.headline", ".caption2", ".callout", ".system(size:", ".systemFont(ofSize:"])
        XCTAssertEqual(found.map(\.line), [1, 2, 3, 4, 5, 5, 6, 7])
        XCTAssertEqual(found[2].use, "`.textStyle(.mono)` (`DesignTokens.TypeStyle.mono`)")
        XCTAssertEqual(found[1].use, "`.textStyle(_:)` with the `DesignTokens.TypeStyle` of that size and weight")
    }

    func testColoursCount() {
        let found = scan("""
        .foregroundStyle(.secondary)
        .foregroundColor(.red)
        .background(Color.accentColor.opacity(0.1))
        .fill(.quaternary)
        .stroke(.separator, lineWidth: 1)
        .strokeBorder(Color.white)
        .tint(.green)
        .foregroundStyle(selected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.primary))
        private var mark: Color { Color.orange }
        """)
        XCTAssertEqual(found.filter { $0.kind == .color }.map(\.value), [
            ".secondary", ".red", "Color.accentColor", ".quaternary", ".separator", "Color.white", ".green", ".tertiary",
            "Color.primary", "Color.orange",
        ])
        XCTAssertEqual(found.first?.use, "`DesignTokens.TextColor.secondary.color`")
        XCTAssertEqual(found.first { $0.value == ".red" }?.use, "`DesignTokens.Status.problem.tint` (`.text` for text)")
    }

    func testRawColoursCount() {
        let found = scan("""
        let a = NSColor.labelColor
        let b = Color(nsColor: .systemRed)
        let c = Color(red: 0.2, green: 0.3, blue: 0.4)
        let d = Color(hex: 0xFF0000)
        let e = Color(.sRGB, red: 1, green: 0, blue: 0)
        """)
        XCTAssertEqual(found.map(\.kind), Array(repeating: .rawColor, count: 5))
        XCTAssertEqual(found.map(\.line), [1, 2, 3, 4, 5])
    }

    func testNumbersCount() {
        let found = scan("""
        .padding(.horizontal, 12)
        HStack(spacing: 6) {
        .cornerRadius(9)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
        .shadow(color: shadow, radius: 4, y: 2)
        .stroke(tint, lineWidth: 1.5)
        .padding(.top, DesignTokens.Space.s2 + 2)
        """)
        XCTAssertEqual(found.map(\.kind), Array(repeating: .number, count: 8))
        XCTAssertEqual(found.map(\.value), ["12", "6", "9", "16", "4", "2", "1.5", "2"])
        XCTAssertEqual(found[0].use, "`DesignTokens.Space.s3`")
        XCTAssertEqual(found[1].use, "a `DesignTokens.Space` step (4, 8, 12, 16, 20, 24, 32, 40), or a component that owns the gap")
        XCTAssertEqual(found[3].use, "`DesignTokens.Radius.card`")
        XCTAssertEqual(found[2].use, "`DesignTokens.Control.medium.radius`")
        XCTAssertEqual(found[4].use, "`.elevation(_:in:)` with a `DesignTokens.Elevation` level")
    }

    func testFramesAreCountedApart() {
        let found = scan(".frame(width: 120, height: 24)\n.frame(maxWidth: .infinity)")
        XCTAssertEqual(found.map(\.kind), [.frame, .frame])
        XCTAssertEqual(DesignGuard.counts(found), [:], "frame literals fail nothing yet")
        XCTAssertEqual(DesignGuard.counts(found, kinds: [.frame]), ["View.swift": [.frame: 2]])
    }

    // MARK: - Buttons and disabled controls (TP-1505)

    func testAButtonWithoutTheSharedStyleCounts() {
        let found = scan("""
        Button("Open") { open() }
            .buttonStyle(.borderedProminent)
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
        }
        .help("Close")
        """)
        XCTAssertEqual(found.map(\.kind), [.button, .button])
        XCTAssertEqual(found.map(\.line), [1, 3])
        XCTAssertEqual(found.first?.message, "View.swift:1: button bypass Button: use \(DesignGuard.buttonReplacement)")
    }

    func testTheSharedButtonStyleAndTheIconButtonDoNotCount() {
        XCTAssertEqual(scan("""
        Button("Approve Plan") { approve() }
            .keyboardShortcut(.defaultAction)
            .directorButton(.primary, disabledReason: reason)
        Button {
            close()
        } label: {
            Text("Close")
        }
        .onHover { hovering = $0 }
        .buttonStyle(DirectorButtonStyle(kind: .quiet))
        IconButton("xmark", help: "Close") { close() }
        let label = makeButton(title)
        """), [])
    }

    func testADisabledControlCounts() {
        let found = scan("Toggle(\"On\", isOn: $on)\n    .disabled(working)\nText(\"x\").disabledReason(reason)")
        XCTAssertEqual(found.map(\.kind), [.disabled])
        XCTAssertEqual(found.first?.line, 2)
        XCTAssertEqual(found.first?.use, DesignGuard.disabledReplacement)
    }

    /// A new unstyled button and a new `.disabled(` each fail a file whose baseline has fewer.
    func testANewUnstyledButtonOrDisabledControlFails() {
        let bypasses = scan("Button(\"A\") {}\nButton(\"B\") {}.disabled(true)")
        let failures = DesignGuard.failures(bypasses: bypasses, baseline: ["View.swift": [.button: 1]])
        XCTAssertEqual(failures.count, 2, failures.joined(separator: "\n"))
        XCTAssertTrue(failures[0].hasPrefix("View.swift has 2 button bypass(es), above its baseline of 1"), failures[0])
        XCTAssertTrue(failures[1].hasPrefix("View.swift draws with 1 raw disabled value(s) and is not in the baseline"), failures[1])
    }

    func testTheNewKindsAreBaselineKinds() throws {
        let counts: DesignGuard.Counts = ["SymphonyBar/A.swift": [.button: 2, .disabled: 1]]
        XCTAssertEqual(try DesignGuard.parseBaseline(DesignGuard.formatBaseline(counts)), counts)
        XCTAssertTrue(DesignGuard.formatBaseline(counts).hasSuffix("SymphonyBar/A.swift button 2\nSymphonyBar/A.swift disabled 1\n"))
    }

    // MARK: - Status dots (TP-1506)

    func testACircleInAStatusColourCounts() {
        let found = scan("""
        Circle()
            .fill(control.status.tint)
            .frame(width: 8, height: 8)
        Circle().fill(DesignTokens.Status.idle.tint).frame(width: 8, height: 8)
        .background(Circle().fill(color(.red)))
        Circle().foregroundStyle(.green)
        """)
        XCTAssertEqual(found.filter { $0.kind == .dot }.map(\.line), [1, 4, 5, 6])
        XCTAssertEqual(found.first { $0.kind == .dot }?.message, "View.swift:1: dot bypass Circle(): use \(DesignGuard.dotReplacement)")
    }

    func testACircleInAnotherColourOrTheSharedDotDoesNotCount() {
        XCTAssertEqual(scan("""
        Circle().fill(DesignTokens.ColorToken.accent.color).frame(width: 6, height: 6)
        Circle().fill(.white).frame(width: 13, height: 13)
        StatusDot(control.status, size: .large)
        Circle()
        Circle().stroke(DesignTokens.Surface.separator.color)
        """).filter { $0.kind == .dot }, [])
    }

    func testTheDotKindIsABaselineKind() throws {
        let counts: DesignGuard.Counts = ["SymphonyBar/A.swift": [.dot: 2]]
        XCTAssertEqual(try DesignGuard.parseBaseline(DesignGuard.formatBaseline(counts)), counts)
        XCTAssertTrue(DesignGuard.Kind.guarded.contains(.dot))
        let failures = DesignGuard.failures(bypasses: scan("Circle().fill(row.status.tint)"), baseline: [:])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("View.swift draws with 1 raw dot value(s) and is not in the baseline"), failures[0])
    }

    // MARK: - Stock pickers and menus (TP-1508)

    func testAStockPickerOrMenuCounts() {
        let found = scan("""
        Picker("Repo", selection: $repo) { Text("All") }
        Menu {
            Button("Open") {}
        } label: { Text("More") }
        Menu("Move to") { Button("Todo") {} }
        """)
        XCTAssertEqual(found.filter { $0.kind == .picker }.map(\.line), [1])
        XCTAssertEqual(found.filter { $0.kind == .menu }.map(\.line), [2, 5])
        XCTAssertEqual(found.first { $0.kind == .picker }?.message, "View.swift:1: picker bypass Picker: use \(DesignGuard.pickerReplacement)")
        XCTAssertEqual(found.first { $0.kind == .menu }?.use, DesignGuard.menuReplacement)
    }

    func testTheSharedControlsAndLongerNamesDoNotCount() {
        XCTAssertEqual(scan("""
        DatePicker("From", selection: $from)
        ScopePicker(model: model)
        PopUp("Repo", selection: $repo, choices: choices)
        SegmentedControl("Period", selection: $period, segments: segments)
        MenuButton("More") { [] }
        MenuItem("Open") {}
        .contextMenu { Text("Open") }
        """).filter { $0.kind == .picker || $0.kind == .menu }, [])
    }

    func testThePickerAndMenuKindsAreBaselineKinds() throws {
        let counts: DesignGuard.Counts = ["SymphonyBar/A.swift": [.picker: 2, .menu: 1]]
        XCTAssertEqual(try DesignGuard.parseBaseline(DesignGuard.formatBaseline(counts)), counts)
        XCTAssertTrue(DesignGuard.Kind.guarded.contains(.picker))
        XCTAssertTrue(DesignGuard.Kind.guarded.contains(.menu))
        let failures = DesignGuard.failures(bypasses: scan("Menu(\"More\") {}"), baseline: [:])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("View.swift draws with 1 raw menu value(s) and is not in the baseline"), failures[0])
    }

    // MARK: - What does not count

    func testTokensAndComponentsDoNotCount() {
        XCTAssertEqual(scan("""
        Text("a").textStyle(.body)
        .font(DesignTokens.TypeStyle.body.font)
        .font(DecisionType.tag)
        .foregroundStyle(DesignTokens.TextColor.secondary.color)
        .foregroundStyle(DesignTokens.Status.problem.tint)
        .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .padding(DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Control.small.padding)
        HStack(spacing: DesignTokens.Space.s2) {
        .elevation(.level1, in: shape)
        .background(Color.clear)
        .fontWeight(.semibold)
        .lineSpacing(4)
        """), [])
    }

    func testZeroIsNotAStyleValue() {
        XCTAssertEqual(scan("VStack(spacing: 0) {\n.padding(0)\n.padding(.horizontal, 0.0)"), [])
    }

    func testCommentsAndStringsAreNotRead() {
        XCTAssertEqual(scan("""
        // Use .foregroundStyle(.secondary) and .padding(8) here.
        /* .font(.title3) /* nested .font(.body) */ still a comment .padding(4) */
        let hint = "call .font(.caption) with .padding(12)"
        let raw = #"Color(red: 1) and .font(.title)"#
        let block = \"""
            .foregroundStyle(.red)
            \"""
        """), [])
    }

    func testACommentDoesNotWaiveALine() {
        let found = scan(".font(.title3) // design-guard: allow\n// swiftlint:disable all\n.padding(12)")
        XCTAssertEqual(found.map(\.value), [".title3", "12"])
    }

    func testAValueInsideTwoGuardedCallsCountsOnce() {
        let found = scan(".background(Text(\"x\").foregroundStyle(.secondary).padding(.horizontal, 4))")
        XCTAssertEqual(found.map(\.kind), [.color, .number])
    }

    func testALabelledValueStopsAtTheLineEnd() {
        XCTAssertEqual(scan("var spacing: CGFloat\nlet radius = min(8, 4)").map(\.value), [])
    }

    func testCountsAndLinesForAWholeFile() {
        let found = scan("struct A {\n    var body: some View {\n        Text(\"x\")\n            .foregroundStyle(.secondary)\n            .padding(8)\n    }\n}")
        XCTAssertEqual(found.map(\.line), [4, 5])
        XCTAssertEqual(found.first?.message, "View.swift:4: color bypass .secondary: use `DesignTokens.TextColor.secondary.color`")
    }

    // MARK: - The baseline

    func testABaselineRoundTrips() throws {
        let counts: DesignGuard.Counts = ["SymphonyBar/B.swift": [.number: 3, .font: 1], "SymphonyBar/A.swift": [.color: 2]]
        let text = DesignGuard.formatBaseline(counts)
        XCTAssertTrue(text.hasSuffix("SymphonyBar/A.swift color 2\nSymphonyBar/B.swift font 1\nSymphonyBar/B.swift number 3\n"), text)
        XCTAssertEqual(try DesignGuard.parseBaseline(text), counts)
    }

    func testABadBaselineLineIsRefused() {
        for line in ["SymphonyBar/A.swift color", "SymphonyBar/A.swift hue 2", "SymphonyBar/A.swift frame 2", "SymphonyBar/A.swift color 0", "SymphonyBar/A.swift color x"] {
            XCTAssertThrowsError(try DesignGuard.parseBaseline("# header\n\(line)\n"), line) { error in
                XCTAssertEqual(error as? DesignGuard.BaselineError, .badLine(2, line))
            }
        }
        XCTAssertThrowsError(try DesignGuard.parseBaseline("SymphonyBar/A.swift color 2\nSymphonyBar/A.swift color 3"))
    }

    func testAFileAboveItsBaselineListsEveryBypassOfThatKind() {
        let bypasses = scan(".padding(4)\n.padding(8)")
        let failures = DesignGuard.failures(bypasses: bypasses, baseline: ["View.swift": [.number: 1]])
        XCTAssertEqual(failures, ["""
        View.swift has 2 number bypass(es), above its baseline of 1: take the new one(s) from DesignTokens or a shared component
          View.swift:1: number bypass 4: use `DesignTokens.Space.s1`
          View.swift:2: number bypass 8: use `DesignTokens.Space.s2`
        """])
    }

    func testAFileNotInTheBaselineMayHaveNone() {
        let failures = DesignGuard.failures(bypasses: scan(".tint(.blue)"), baseline: [:])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("View.swift draws with 1 raw color value(s) and is not in the baseline"), failures[0])
    }

    func testABaselineLineWithNothingLeftMustBeDeleted() {
        XCTAssertEqual(
            DesignGuard.failures(bypasses: [], baseline: ["SymphonyBar/Gone.swift": [.rawColor: 1]]),
            ["SymphonyBar/Gone.swift has no rawColor bypass left: delete its `rawColor` line from the baseline"]
        )
    }

    // MARK: - Helpers

    private func scan(_ source: String) -> [DesignGuard.Bypass] { DesignGuard.scan(source, file: "View.swift") }

    /// `macos/Sources`.
    static var sources: URL { macos.appendingPathComponent("Sources") }

    static var baselineFile: URL { macos.appendingPathComponent("Tests/DesignGuard/baseline.txt") }

    static var macos: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
