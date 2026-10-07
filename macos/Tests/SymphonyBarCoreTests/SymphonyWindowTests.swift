import XCTest
@testable import SymphonyBarCore

final class SymphonyWindowTests: XCTestCase {
    private let snapshot = StateSnapshot()

    // MARK: - D0 window states

    func testASymphonyThatAnswersShowsTheViews() {
        for status in [SymphonyStatus.running(snapshot, external: false), .paused(snapshot, external: true)] {
            for hasConfig in [true, false] {
                let state = WindowState(status: status, hasConfig: hasConfig)
                XCTAssertEqual(state, .connected)
                XCTAssertNil(state.placeholder)
                XCTAssertTrue(state.countsKnown)
                XCTAssertNil(state.connectionLabel)
            }
        }
    }

    func testStoppedOffersStartSymphony() {
        let state = WindowState(status: .stopped, hasConfig: true)
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(state.placeholder?.actions, [.startSymphony])
        XCTAssertEqual(state.placeholder?.showsSpinner, false)
        XCTAssertEqual(WindowState.Action.startSymphony.title, "Start Symphony")
        XCTAssertEqual(state.connectionLabel, "Stopped")
    }

    func testStartingShowsASpinnerAndNoAction() {
        let state = WindowState(status: .starting, hasConfig: true)
        XCTAssertEqual(state.placeholder?.title, "Symphony is starting…")
        XCTAssertEqual(state.placeholder?.showsSpinner, true)
        XCTAssertEqual(state.placeholder?.actions, [])
        XCTAssertEqual(state.connectionLabel, "Starting…")
    }

    func testNotAnsweringOffersOpenLogsAndRestart() {
        let state = WindowState(status: .error("Symphony isn't answering"), hasConfig: true)
        XCTAssertEqual(state, .notAnswering)
        XCTAssertEqual(state.placeholder?.title, "Symphony isn't answering.")
        XCTAssertEqual(state.placeholder?.actions, [.openLogs, .restartSymphony])
        XCTAssertEqual(state.placeholder?.actions.map(\.title), ["Open Logs", "Restart Symphony"])
        XCTAssertEqual(state.connectionLabel, "Not answering")
        XCTAssertEqual(state.connectionStatus, .problem)
    }

    func testWithoutConfigItAsksForSettings() {
        for status in [SymphonyStatus.stopped, .error("Symphony exited with code 1")] {
            let state = WindowState(status: status, hasConfig: false)
            XCTAssertEqual(state, .firstLaunch)
            XCTAssertEqual(state.placeholder?.title, "Symphony doesn't know where its config is.")
            XCTAssertEqual(state.placeholder?.actions.map(\.title), ["Open Settings…"])
        }
        XCTAssertEqual(WindowState(status: .starting, hasConfig: false), .starting)
    }

    func testCountsAreUnknownUnlessConnected() {
        for state in [WindowState.stopped, .starting, .notAnswering, .firstLaunch] {
            XCTAssertFalse(state.countsKnown, "\(state)")
            XCTAssertNotNil(state.placeholder, "\(state)")
            XCTAssertFalse(state.placeholder!.title.localizedCaseInsensitiveContains("unavailable"))
        }
    }

    func testFooterStateWords() {
        XCTAssertEqual(WindowState.connected.stateWord(paused: false), "Running")
        XCTAssertEqual(WindowState.connected.stateWord(paused: true), "Paused")
        XCTAssertEqual(WindowState.stopped.stateWord(paused: false), "Stopped")
        XCTAssertEqual(WindowState.firstLaunch.stateWord(paused: false), "Not set up")
    }

    func testHasConfigNeedsAnExistingFile() throws {
        XCTAssertFalse(WindowState.hasConfig(path: ""))
        XCTAssertFalse(WindowState.hasConfig(path: "  "))
        XCTAssertFalse(WindowState.hasConfig(path: "/nonexistent/symphony.yml"))
        let file = uniqueTemporaryDirectory("config").appendingPathExtension("yml")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(WindowState.hasConfig(path: " \(file.path)\n"))
    }

    // MARK: - Sidebar

    func testSidebarListsOnlyBuiltViewsInTheDesignsOrder() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.views, [.inbox, .overview, .repos, .diagnostics])
        XCTAssertEqual(sidebar.sections.map(\.section), [.main, .factory])
        XCTAssertEqual(sidebar.sections.first?.views, [.inbox, .overview])
        XCTAssertEqual(sidebar.sections.last?.views, [.repos, .diagnostics])
        XCTAssertEqual(SidebarSection.factory.title, "Factory")
    }

    func testViewsJoinInPlace() {
        let sidebar = Sidebar(built: [.diagnostics, .overview, .repos, .usage, .inbox])
        XCTAssertEqual(sidebar.views, [.inbox, .overview, .usage, .repos, .diagnostics])
        XCTAssertEqual(sidebar.sections.map(\.section), [.main, .insights, .factory])
        XCTAssertEqual(sidebar.sections.map { $0.section.title }, [nil, "Insights", "Factory"])
    }

    func testShortcutsFollowSidebarOrderUpToEight() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.shortcut(for: .inbox), 1)
        XCTAssertEqual(sidebar.shortcut(for: .overview), 2)
        XCTAssertEqual(sidebar.shortcut(for: .repos), 3)
        XCTAssertEqual(sidebar.shortcut(for: .diagnostics), 4)
        XCTAssertNil(sidebar.shortcut(for: .tickets))
        XCTAssertEqual(sidebar.view(forShortcut: 4), .diagnostics)
        XCTAssertNil(sidebar.view(forShortcut: 5))
        XCTAssertNil(sidebar.view(forShortcut: 0))

        let all = Sidebar(built: SymphonyView.allCases)
        XCTAssertEqual(all.views.count, 8)
        XCTAssertEqual(all.views.compactMap(all.shortcut(for:)), Array(1...8))
        XCTAssertEqual(all.view(forShortcut: 8), .diagnostics)
    }

    func testRestoresTheSavedViewWhenItShowsInTheWindow() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.restoredView(saved: "diagnostics"), .diagnostics)
        XCTAssertEqual(sidebar.restoredView(saved: "overview"), .overview)
        // The first time, the window opens on the Inbox: decisions first.
        XCTAssertEqual(sidebar.restoredView(saved: nil), .inbox)
        XCTAssertEqual(sidebar.restoredView(saved: "tickets"), .inbox)
        XCTAssertEqual(sidebar.restoredView(saved: "repos"), .inbox)
        XCTAssertEqual(Sidebar(built: [.overview, .diagnostics]).restoredView(saved: "nonsense"), .overview)
    }

    func testEveryViewHasATitleSymbolAndSubtitle() {
        for view in SymphonyView.allCases {
            XCTAssertFalse(view.title.isEmpty)
            XCTAssertFalse(view.subtitle.isEmpty)
            XCTAssertFalse(view.symbol.isEmpty)
        }
        XCTAssertTrue(SymphonyView.repos.opensOwnWindow)
        XCTAssertFalse(SymphonyView.diagnostics.opensOwnWindow)
    }

    // MARK: - Design tokens

    func testEveryStatusTokenHasItsColorSymbolAndWord() {
        let expected: [DesignTokens.Status: (DesignTokens.SystemColor, String, String)] = [
            .you: (.orange, "person.crop.circle.badge.exclamationmark", "Waiting on you"),
            .working: (.blue, "circle.dotted.circle", "Working"),
            .problem: (.red, "exclamationmark.triangle.fill", "Needs attention"),
            .done: (.green, "checkmark.circle.fill", "Healthy"),
            .idle: (.gray, "pause.circle", "Paused"),
            .forced: (.purple, "bolt.fill", "Forced"),
        ]
        XCTAssertEqual(Set(DesignTokens.Status.allCases), Set(expected.keys))
        for status in DesignTokens.Status.allCases {
            let (color, symbol, word) = expected[status]!
            XCTAssertEqual(status.color, color, "\(status)")
            XCTAssertEqual(status.symbol, symbol, "\(status)")
            XCTAssertEqual(status.word, word, "\(status)")
        }
        // Status colors are reserved: no two statuses share one.
        XCTAssertEqual(Set(DesignTokens.Status.allCases.map(\.color)).count, DesignTokens.Status.allCases.count)
        XCTAssertEqual(DesignTokens.Status.badgeTint(dark: false), 0.14)
        XCTAssertEqual(DesignTokens.Status.badgeTint(dark: true), 0.22)
    }

    func testLayoutTokensMatchTheWindowSize() {
        XCTAssertEqual(DesignTokens.Layout.windowWidth, 1200)
        XCTAssertEqual(DesignTokens.Layout.windowHeight, 760)
        XCTAssertEqual(DesignTokens.Layout.minWindowWidth, 960)
        XCTAssertEqual(DesignTokens.Layout.minWindowHeight, 600)
        XCTAssertEqual(
            [DesignTokens.Space.s1, DesignTokens.Space.s2, DesignTokens.Space.s3, DesignTokens.Space.s4,
             DesignTokens.Space.s5, DesignTokens.Space.s6, DesignTokens.Space.s8],
            [4, 8, 12, 16, 20, 24, 32]
        )
        XCTAssertEqual(DesignTokens.Radius.card - DesignTokens.Space.s1, DesignTokens.Radius.row)
    }

    /// The design system maps tokens to system colors only: no hex or RGB literal anywhere in the app's sources.
    func testNoHardcodedColorsInTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let patterns = [#"Color\(\s*red:"#, #"Color\(\s*\.sRGB"#, #"NSColor\(\s*(calibrated|srgb|device)?[Rr]ed:"#, #"#[0-9A-Fa-f]{6}\b"#]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns {
                XCTAssertNil(text.range(of: pattern, options: .regularExpression), "\(file.lastPathComponent) matches \(pattern)")
            }
        }
    }
}
