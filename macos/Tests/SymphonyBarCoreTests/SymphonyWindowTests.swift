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
        XCTAssertEqual(WindowState.Action.cancelUpdate.title, "Cancel Update")
        XCTAssertEqual(WindowState.Action.updateNow.title, "Update Now Anyway")
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

    func testSidebarListsTheFiveDestinationsWithFactorysPagesUnderIt() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.destinations, [.home, .journal, .work, .insights, .factory])
        XCTAssertEqual(sidebar.destinations.map(\.title), ["Home", "Journal", "Work", "Insights", "Factory"])
        XCTAssertEqual(sidebar.items, [
            .destination(.home), .destination(.journal), .destination(.work), .destination(.insights), .destination(.factory),
            .page(.setup), .page(.repos), .page(.diagnostics), .page(.settings),
        ])
        XCTAssertEqual(Destination.work.pages, [.initiatives, .tickets])
        XCTAssertEqual(Destination.insights.pages, [.quality, .usage, .shipped, .audit])
        XCTAssertEqual(Destination.factory.pages, [.setup, .repos, .diagnostics, .settings])
        XCTAssertEqual(Destination.allCases.map(\.presentation), [.single, .single, .tabs, .tabs, .list])
        // Every page belongs to the destination that lists it; the Inbox is Home's drawer.
        for destination in Destination.allCases {
            for page in destination.pages { XCTAssertEqual(page.destination, destination) }
        }
        XCTAssertEqual(SymphonyView.inbox.destination, .home)
    }

    func testTheSelectedRowIsTheDestinationOrFactorysPage() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.item(for: .overview), .destination(.home))
        XCTAssertEqual(sidebar.item(for: .inbox), .destination(.home))
        XCTAssertEqual(sidebar.item(for: .journal), .destination(.journal))
        XCTAssertEqual(sidebar.item(for: .tickets), .destination(.work))
        XCTAssertEqual(sidebar.item(for: .audit), .destination(.insights))
        XCTAssertEqual(sidebar.item(for: .diagnostics), .page(.diagnostics))
    }

    func testCommandOneToFivePickTheDestinations() {
        // The View menu's items, which carry ⌘1–⌘5.
        let items = Sidebar().menuItems
        XCTAssertEqual(items.map(\.title), ["Home", "Journal", "Work", "Insights", "Factory"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(items.map(\.destination), [.home, .journal, .work, .insights, .factory])
        XCTAssertEqual(Destination.work.shortcutHelp, "Work (⌘3)")

        // ⌘3 opens Work on Initiatives, with Tickets as its other tab.
        let work = items.first { $0.keyEquivalent == "3" }!.destination
        XCTAssertEqual(DestinationMemory().page(for: work), .initiatives)
        XCTAssertEqual(work.presentation, .tabs)
        XCTAssertEqual(work.pages, [.initiatives, .tickets])
    }

    func testDestinationsOpenOnTheirFirstPageThenTheLastOneThisSession() {
        var memory = DestinationMemory()
        XCTAssertEqual(memory.page(for: .work), .initiatives)
        XCTAssertEqual(memory.page(for: .insights), .quality)
        XCTAssertEqual(memory.page(for: .factory), .setup)
        XCTAssertEqual(memory.page(for: .home), .overview)
        XCTAssertEqual(memory.page(for: .journal), .journal)
        memory.remember(.tickets)
        memory.remember(.audit)
        // Repos and Settings open their own windows: Factory stays on the page it showed.
        memory.remember(.diagnostics)
        memory.remember(.repos)
        memory.remember(.settings)
        XCTAssertEqual(memory.page(for: .work), .tickets)
        XCTAssertEqual(memory.page(for: .insights), .audit)
        XCTAssertEqual(memory.page(for: .factory), .diagnostics)
        XCTAssertEqual(DestinationMemory().page(for: .work), .initiatives)
    }

    func testOnlyHomeAndFactoryCarryABadge() {
        let setup = SetupSummary(errors: 1, warnings: 2)
        XCTAssertEqual(
            Destination.home.badge(waitingOnYou: 4, setup: setup),
            DestinationBadge(count: 4, status: .you, accessibilityValue: "4 waiting")
        )
        XCTAssertEqual(
            Destination.factory.badge(waitingOnYou: 4, setup: setup),
            DestinationBadge(count: 3, status: .problem, accessibilityValue: "Setup: 1 error, 2 warnings")
        )
        XCTAssertEqual(Destination.factory.badge(waitingOnYou: 0, setup: SetupSummary(warnings: 1))?.status, .problem)
        for destination in [Destination.journal, .work, .insights] {
            XCTAssertNil(destination.badge(waitingOnYou: 4, setup: setup))
        }
        XCTAssertNil(Destination.home.badge(waitingOnYou: 0, setup: setup))
        XCTAssertNil(Destination.factory.badge(waitingOnYou: 4, setup: SetupSummary()))
    }

    func testWorkCountsTheEpicsWaitingOnAPerson() {
        XCTAssertEqual(
            Destination.work.badge(waitingOnYou: 4, setup: SetupSummary(), epicsWaiting: 2),
            DestinationBadge(count: 2, status: .you, accessibilityValue: "2 epics waiting on you")
        )
        XCTAssertEqual(Destination.work.badge(waitingOnYou: 0, setup: SetupSummary(), epicsWaiting: 1)?.accessibilityValue, "1 epic waiting on you")
        XCTAssertNil(Destination.work.badge(waitingOnYou: 4, setup: SetupSummary(), epicsWaiting: 0))
        XCTAssertNil(Destination.journal.badge(waitingOnYou: 4, setup: SetupSummary(), epicsWaiting: 2))
    }

    func testRestoresTheSavedViewWhenItShowsInTheWindow() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.restoredView(saved: "diagnostics"), .diagnostics)
        XCTAssertEqual(sidebar.restoredView(saved: "overview"), .overview)
        // The first time, the window opens on Home: what needs you first. A window that remembers the Inbox opens on
        // Home too, where its items are (TP-1454).
        XCTAssertEqual(sidebar.restoredView(saved: nil), .overview)
        XCTAssertEqual(sidebar.restoredView(saved: "inbox"), .overview)
        XCTAssertEqual(sidebar.restoredView(saved: "tickets"), .tickets)
        XCTAssertEqual(sidebar.restoredView(saved: "journal"), .journal)
        XCTAssertEqual(sidebar.restoredView(saved: "audit"), .audit)
        XCTAssertEqual(sidebar.restoredView(saved: "repos"), .overview)
        XCTAssertEqual(sidebar.restoredView(saved: "settings"), .overview)
        XCTAssertEqual(sidebar.restoredView(saved: "nonsense"), .overview)
    }

    func testEveryViewHasATitleSymbolAndSubtitle() {
        for view in SymphonyView.allCases {
            XCTAssertFalse(view.title.isEmpty)
            XCTAssertFalse(view.subtitle.isEmpty)
            XCTAssertFalse(view.symbol.isEmpty)
            XCTAssertEqual(view.id, view.rawValue)
        }
        for destination in Destination.allCases {
            XCTAssertFalse(destination.symbol.isEmpty)
            XCTAssertEqual(destination.id, destination.rawValue)
            XCTAssertFalse(destination.firstPage.opensOwnWindow)
        }
        XCTAssertTrue(SymphonyView.repos.opensOwnWindow)
        XCTAssertTrue(SymphonyView.settings.opensOwnWindow)
        XCTAssertFalse(SymphonyView.diagnostics.opensOwnWindow)
        // A tabbed destination's name heads the toolbar, as its tabs name the page.
        XCTAssertEqual(SymphonyView.tickets.toolbarTitle, "Work")
        XCTAssertEqual(SymphonyView.usage.toolbarTitle, "Insights")
        XCTAssertEqual(SymphonyView.overview.toolbarTitle, "Home")
        XCTAssertEqual(SymphonyView.setup.toolbarTitle, "Setup")
        XCTAssertEqual(SymphonyView.journal.subtitle, Journal.explanation)
    }

    // MARK: - Finding a ticket (⌘F)

    private func trackedTickets() -> TicketList {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let forced: [StateSnapshot.ForcedTicket] = [
            ("TP-14", "Retry the release"), ("TP-1455", "The five destinations"), ("TP-145", "Sidebar badges"),
            ("API-9", "Release notes for the café"), ("API-10", nil),
        ].map { .init(identifier: $0.0, issueID: nil, title: $0.1, repoKey: "web", summary: "", state: "Todo") }
        return TicketList(state: OverviewState(snapshot: StateSnapshot(forced: forced), generatedAt: now), now: now)
    }

    func testFindsATicketByItsIdentifierExactFirstThenByPrefix() {
        let list = trackedTickets()
        XCTAssertEqual(TicketFinder.matches("tp-145", in: list).map(\.identifier), ["TP-145", "TP-1455"])
        XCTAssertEqual(TicketFinder.matches(" TP-1455 ", in: list).map(\.identifier), ["TP-1455"])
        XCTAssertEqual(TicketFinder.target("tp-145", in: list), "TP-145")
    }

    func testFindsATicketByEveryWordOfItsTitle() {
        let list = trackedTickets()
        XCTAssertEqual(TicketFinder.matches("release", in: list).map(\.identifier).sorted(), ["API-9", "TP-14"])
        XCTAssertEqual(TicketFinder.matches("Cafe NOTES", in: list).map(\.identifier), ["API-9"])
        XCTAssertEqual(TicketFinder.matches("five badges", in: list), [])
        XCTAssertEqual(TicketFinder.line(list.row("TP-1455")!), "TP-1455 · The five destinations")
        XCTAssertEqual(TicketFinder.line(list.row("API-10")!), "API-10")
    }

    func testAnUntrackedIdentifierStillOpensItsPageAndNothingElseDoes() {
        let list = trackedTickets()
        XCTAssertEqual(TicketFinder.target("shop-7", in: list), "SHOP-7")
        XCTAssertEqual(TicketFinder.target("shop-7", in: nil), "SHOP-7")
        XCTAssertNil(TicketFinder.target("no such words", in: list))
        XCTAssertNil(TicketFinder.target("   ", in: list))
        XCTAssertEqual(TicketFinder.matches("", in: list), [])
        XCTAssertEqual(TicketFinder.matches("TP", in: nil), [])
        let many = TicketList(
            state: OverviewState(snapshot: StateSnapshot(forced: (1...12).map {
                .init(identifier: "TP-\($0)", issueID: nil, title: nil, repoKey: nil, summary: "", state: nil)
            })),
            now: Date()
        )
        XCTAssertEqual(TicketFinder.matches("TP", in: many).count, TicketFinder.limit)
    }

    // MARK: - Design tokens

    func testEveryStatusTokenHasItsColorSymbolAndWord() {
        let expected: [DesignTokens.Status: (DesignTokens.ColorToken, String, String)] = [
            .you: (.statusYou, "person.crop.circle.badge.exclamationmark", "Waiting on you"),
            .working: (.statusWorking, "circle.dotted.circle", "Working"),
            .problem: (.statusProblem, "exclamationmark.triangle.fill", "Needs attention"),
            .done: (.statusDone, "checkmark.circle.fill", "Healthy"),
            .idle: (.statusIdle, "pause.circle", "Paused"),
            .forced: (.statusForced, "bolt.fill", "Forced"),
        ]
        XCTAssertEqual(Set(DesignTokens.Status.allCases), Set(expected.keys))
        for status in DesignTokens.Status.allCases {
            let (color, symbol, word) = expected[status]!
            XCTAssertEqual(status.color, color, "\(status)")
            XCTAssertEqual(status.textColor.cssName, color.cssName + "-text", "\(status)")
            XCTAssertEqual(status.tintColor.cssName, "--tint-" + status.rawValue, "\(status)")
            XCTAssertEqual(status.symbol, symbol, "\(status)")
            XCTAssertEqual(status.word, word, "\(status)")
        }
        // Status colors are reserved: no two statuses share one.
        XCTAssertEqual(Set(DesignTokens.Status.allCases.map(\.color)).count, DesignTokens.Status.allCases.count)
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

    /// The design system maps tokens to system colors only: no hex or RGB literal anywhere in the app's sources, but
    /// the chart palette's validated pair in `DesignSystem.swift` (design system §3.3).
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
            for pattern in patterns where !(file.lastPathComponent == "DesignSystem.swift" && pattern.hasPrefix("NSColor")) {
                XCTAssertNil(text.range(of: pattern, options: .regularExpression), "\(file.lastPathComponent) matches \(pattern)")
            }
        }
    }
}
