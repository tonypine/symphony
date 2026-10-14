import AppKit
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The chip text view, laid out and drawn without a window.
final class ChipTextViewTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 13)

    // MARK: - Size

    func testItsHeightForAWidthIsTextKitsOwnLayoutAtThreeWidths() throws {
        let view = try storyView()
        for width in [120.0, 360.0, 1200.0] {
            let reference = textKitHeight(of: view.attributedText(), width: width)
            XCTAssertEqual(view.height(forWidth: width), reference, "at \(width) pt")
        }
        XCTAssertGreaterThan(view.height(forWidth: 120), view.height(forWidth: 360))
        XCTAssertGreaterThan(view.height(forWidth: 360), view.height(forWidth: 1200))
    }

    func testItTakesTheWidthOfItsLongestLineAsATextDoes() throws {
        let view = try storyView()
        let oneLine = view.fittingSize(width: nil)
        XCTAssertEqual(oneLine.height, view.height(forWidth: 100_000))
        XCTAssertEqual(view.fittingSize(width: 10_000), oneLine)
        let wrapped = view.fittingSize(width: 300)
        XCTAssertLessThanOrEqual(wrapped.width, 300)
        XCTAssertGreaterThan(wrapped.width, 250)
        XCTAssertEqual(wrapped.height, view.height(forWidth: 300))
        XCTAssertEqual(view.height(forWidth: wrapped.width), wrapped.height, "the same lines at the width it takes")
    }

    func testItsBaselineIsTextKitsFirstLine() {
        let body = ChipTextView.baseline(of: font)
        XCTAssertEqual(body.ascent, font.ascender, accuracy: 1.5)
        XCTAssertEqual(body.ascent + body.descent, textKitHeight(of: NSAttributedString(string: "Ag", attributes: [.font: font]), width: 500), accuracy: 0.5)
        let large = ChipTextView.baseline(of: .systemFont(ofSize: 16, weight: .semibold))
        XCTAssertGreaterThan(large.ascent, body.ascent)
        XCTAssertEqual(ChipTextView.baseline(of: font).ascent, body.ascent, "kept for the font")
    }

    func testItReflowsWhenItsWidthChanges() throws {
        let view = try storyView()
        view.setFrameSize(CGSize(width: 1200, height: 40))
        let wide = try XCTUnwrap(view.chipRects(0).first)
        view.setFrameSize(CGSize(width: 140, height: 200))
        let narrow = try XCTUnwrap(view.chipRects(view.content.mentions.count - 1).first)
        XCTAssertEqual(view.textContainer?.size.width, 140)
        XCTAssertEqual(wide.minY, 0)
        XCTAssertGreaterThan(narrow.minY, 0, "the last chip moved down a line")
        // Measuring another width leaves the view's own layout alone.
        _ = view.height(forWidth: 900)
        XCTAssertEqual(view.textContainer?.size.width, 140)
    }

    func testItKeepsALayoutPerWidthSwiftUIAndVoiceOverAskFor() throws {
        let view = try storyView()
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        let container = try XCTUnwrap(view.textContainer)
        for width in [nil, 600, 0, 600] as [CGFloat?] { _ = view.fittingSize(width: width) }
        XCTAssertEqual(view.measuredCount, 3, "one per width")
        _ = view.chipAccessibilityElements[0].accessibilityFrameInParentSpace()
        XCTAssertEqual(view.measuredCount, 3, "VoiceOver reads the view's width from the same layout")
        for width in [100.0, 200, 300, 400, 500] { _ = view.height(forWidth: width) }
        XCTAssertEqual(view.measuredCount, ChipTextView.measuredWidths)
        // The same frame again leaves the view's own layout alone.
        let size = container.size
        view.setFrameSize(view.frame.size)
        XCTAssertTrue(view.textContainer === container)
        XCTAssertEqual(container.size, size)
    }

    // MARK: - Chips

    func testEveryMentionInTheDecisionIsAChipThatNeverSplitsAcrossLines() throws {
        let item = try decision()
        let action = try XCTUnwrap(item.review.action)
        let texts = [action.question ?? ""] + action.whyParagraphs + [action.ifUnanswered ?? ""]
            + action.options.flatMap { [$0.label, $0.effect ?? ""] + $0.tradeoffs.map(\.text) } + [action.recommendationReason ?? ""]
        var chips = 0
        for text in texts {
            let view = ChipTextView(content: ChipTextContent(text, references: item.references), style: ChipTextStyle(font: font))
            XCTAssertFalse(view.content.mentions.contains(where: \.isMissing), text)
            // The review at 1200 pt beside the list, and a narrow pane.
            for width in [1200.0 - 340, 400] {
                view.setFrameSize(CGSize(width: width, height: view.height(forWidth: width)))
                for index in view.content.mentions.indices {
                    XCTAssertEqual(view.chipRects(index).count, 1, "\(view.content.mentions[index].key) splits at \(width) pt in: \(text)")
                }
            }
            chips += view.content.mentions.count
        }
        XCTAssertEqual(chips, 26)
    }

    func testAPointInAChipIsThatChipAndAPointInPlainTextIsNone() throws {
        let view = try storyView()
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        for index in view.content.mentions.indices {
            let rect = try XCTUnwrap(view.chipRects(index).first)
            XCTAssertEqual(view.chipIndex(at: CGPoint(x: rect.midX, y: rect.midY)), index)
            XCTAssertEqual(view.chipIndex(at: CGPoint(x: rect.minX + 1, y: rect.minY + 1)), index)
        }
        XCTAssertNil(view.chipIndex(at: CGPoint(x: 2, y: 4)), "\"Code\" at the start")
        XCTAssertNil(view.chipIndex(at: CGPoint(x: 590, y: 400)))
    }

    func testAChipKeepsItsCharactersAndRoomForItsTint() throws {
        let view = try storyView()
        let text = view.attributedText()
        XCTAssertEqual(text.length, (view.content.source as NSString).length)
        let pullRequest = view.content.mentions[0]
        XCTAssertEqual(text.attributedSubstring(from: pullRequest.range).string, "#448")
        XCTAssertEqual(text.attribute(ChipTextView.chipAttribute, at: pullRequest.range.location, effectiveRange: nil) as? Int, 0)
        // The space before it doesn't break, and holds the tint's padding and the pull request symbol.
        let before = pullRequest.range.location - 1
        XCTAssertEqual((text.string as NSString).character(at: before), 0xA0)
        XCTAssertEqual(text.attribute(.kern, at: before, effectiveRange: nil) as? CGFloat, view.leadingRoom(for: pullRequest))
        XCTAssertGreaterThan(view.leadingRoom(for: pullRequest), DesignTokens.Chip.padding)
        XCTAssertEqual(text.attribute(.kern, at: NSMaxRange(pullRequest.range) - 1, effectiveRange: nil) as? CGFloat, DesignTokens.Chip.padding)
        XCTAssertNil(text.attribute(.underlineStyle, at: pullRequest.range.location, effectiveRange: nil))
    }

    func testATicketsShortNameShowsAsOneChipThatReadsWhole() throws {
        let item = try decision()
        let view = ChipTextView(content: ChipTextContent(try XCTUnwrap(item.review.action?.question), references: item.references), style: ChipTextStyle(font: font))
        let chip = view.content.mentions[1]
        XCTAssertEqual(view.attributedText().attributedSubstring(from: chip.range).string, "TP-891\u{A0}·\u{A0}Remove\u{A0}the\u{A0}retired\u{A0}review\u{A0}states")
        XCTAssertEqual(view.copiedText(for: chip.range), "TP-891 (Remove the retired review states)")
    }

    func testAChipAtTheStartIsIndentedByItsRoom() throws {
        let view = ChipTextView(content: ChipTextContent("#448 is open.", references: try decision().references), style: ChipTextStyle(font: font))
        let paragraph = try XCTUnwrap(view.attributedText().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, view.leadingRoom(for: view.content.mentions[0]))
        view.setFrameSize(CGSize(width: 300, height: 20))
        XCTAssertEqual(try XCTUnwrap(view.chipRects(0).first).minX, 0, accuracy: 0.5)
    }

    func testAMissingMentionHasADottedUnderlineAndNoTintRoom() throws {
        let view = ChipTextView(content: ChipTextContent("Ask TP-999 first.", references: [:]), style: ChipTextStyle(font: font))
        let mention = try XCTUnwrap(view.content.mentions.first)
        XCTAssertTrue(mention.isMissing)
        let text = view.attributedText()
        XCTAssertEqual(text.attribute(.underlineStyle, at: mention.range.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.union(.patternDot).rawValue)
        XCTAssertNil(text.attribute(.kern, at: mention.range.location - 1, effectiveRange: nil))
        XCTAssertEqual((text.string as NSString).character(at: mention.range.location - 1), 0x20)
        XCTAssertEqual(view.leadingRoom(for: mention), 0)

        let popover = PopoverSpy()
        view.popover = popover
        view.setFrameSize(CGSize(width: 300, height: 20))
        view.showDetails(0)
        XCTAssertEqual(popover.shown.map(\.mention.key), ["TP-999"])
        XCTAssertEqual(ReferencePopover(popover.shown[0].mention).content, .missing("Symphony can't see TP-999."))
    }

    func testABoldLeadComesBeforeTheText() throws {
        let item = try decision()
        let content = ChipTextContent(try XCTUnwrap(item.review.action?.ifUnanswered), references: item.references, lead: "If you don't answer:")
        XCTAssertTrue(content.source.hasPrefix("If you don't answer: TP-892 stays in Rework"))
        XCTAssertEqual(content.mentions.first?.range.location, 21)
        let view = ChipTextView(content: content, style: ChipTextStyle(font: font))
        let lead = try XCTUnwrap(view.attributedText().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(lead.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(view.copiedText(for: NSRange(location: 0, length: 27)), "If you don't answer: TP-892")
    }

    // MARK: - Copy and selection

    func testCopyingASelectionAcrossAChipGivesThePlainSentenceWithTheIdentifier() throws {
        let view = try storyView()
        let source = view.content.source as NSString
        let sentence = source.range(of: "Code Review sent #448 back twice.")
        XCTAssertEqual(view.copiedText(for: sentence), "Code Review sent #448 back twice.")
        // A selection that ends inside a chip takes it whole.
        XCTAssertEqual(view.copiedText(for: NSRange(location: 0, length: 19)), "Code Review sent #448")

        view.setSelectedRange(NSRange(location: 12, length: 7))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 12, length: 9))
        XCTAssertEqual(view.copiedSelection, "sent #448")
        XCTAssertEqual(view.writablePasteboardTypes, [.string])
        // An agent's sandbox has no pasteboard server; where there is one, the copy lands on it.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ChipTextViewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        if pasteboard.setString("probe", forType: .string) {
            XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string), "sent #448")
        }

        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(view.copiedSelection)
        XCTAssertFalse(view.writeSelection(to: pasteboard, types: [.string]))
    }

    // MARK: - Popover, click and keyboard

    func testHoverOpensThePopoverAfterTheDelayAndLeavingTellsIt() throws {
        let view = try storyView()
        let popover = PopoverSpy()
        view.popover = popover
        view.hoverDelay = 0.05
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        let rect = try XCTUnwrap(view.chipRects(0).first)

        view.pointerMoved(to: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(view.hoveredChip, 0)
        XCTAssertTrue(popover.shown.isEmpty, "not before the delay")
        let opened = expectation(description: "the popover opens")
        popover.onShow = { opened.fulfill() }
        wait(for: [opened], timeout: 2)
        XCTAssertEqual(popover.shown.first?.mention.key, "#448")
        XCTAssertEqual(popover.shown.first?.hover, true)
        XCTAssertEqual(popover.shown.first?.rect, rect)
        XCTAssertEqual(view.popoverChip, 0)

        view.pointerMoved(to: CGPoint(x: 2, y: 4))
        XCTAssertNil(view.hoveredChip)
        XCTAssertEqual(popover.leftChip, 1)
        view.popoverClosed()
        XCTAssertNil(view.popoverChip)
    }

    func testMovingOffAChipBeforeTheDelayOpensNothing() throws {
        let view = try storyView()
        let popover = PopoverSpy()
        view.popover = popover
        view.hoverDelay = 0.05
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        let rect = try XCTUnwrap(view.chipRects(0).first)
        view.pointerMoved(to: CGPoint(x: rect.midX, y: rect.midY))
        view.pointerMoved(to: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(popover.shown.isEmpty)
    }

    func testMovingFromOneChipToTheNextKeepsTheNextPopoverOpen() throws {
        let view = try storyView()
        view.hoverDelay = 0.05
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        let popover = ChipPopover(content: { _ in
            let controller = NSViewController()
            controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
            return controller
        }, makePopover: { LateClosingPopover() })
        view.popover = popover
        let first = try XCTUnwrap(view.chipRects(0).first)
        let second = try XCTUnwrap(view.chipRects(1).first)

        view.pointerMoved(to: CGPoint(x: first.midX, y: first.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(view.popoverChip, 0)

        view.pointerMoved(to: CGPoint(x: second.midX, y: second.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(popover.isShown, "the first popover's late close leaves the second open")
        XCTAssertEqual(view.popoverChip, 1)

        // A close from a popover that is no longer the open one changes nothing.
        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: NSPopover()))
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(view.popoverChip, 1)

        popover.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(popover.isShown)
        XCTAssertNil(view.popoverChip)
    }

    func testTabMovesBetweenChipsSpaceShowsAndReturnOpens() throws {
        let view = try storyView()
        let popover = PopoverSpy()
        var opened: [String] = []
        view.popover = popover
        view.openMention = { opened.append($0.key) }
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))
        XCTAssertTrue(view.canBecomeKeyView)

        XCTAssertFalse(view.handle(.space), "no chip has the keyboard yet")
        XCTAssertTrue(view.handle(.tab))
        XCTAssertEqual(view.focusedChip, 0)
        XCTAssertTrue(view.handle(.tab))
        XCTAssertEqual(view.focusedChip, 1)
        XCTAssertTrue(view.handle(.space))
        XCTAssertEqual(popover.shown.map(\.mention.key), ["TP-880"])
        XCTAssertEqual(popover.shown.first?.hover, false)
        XCTAssertTrue(view.handle(.escape))
        XCTAssertEqual(popover.closed, 1)
        XCTAssertTrue(view.handle(.enter))
        XCTAssertEqual(opened, ["TP-880"])
        XCTAssertTrue(view.handle(.backtab))
        XCTAssertEqual(view.focusedChip, 0)
        XCTAssertTrue(view.handle(.backtab))
        XCTAssertNil(view.focusedChip, "out of the paragraph")
        XCTAssertFalse(view.handle(.enter))
        XCTAssertTrue(view.handle(.backtab))
        XCTAssertEqual(view.focusedChip, view.content.mentions.count - 1, "Shift-Tab enters at the last chip")
        view.popoverClosed()
        XCTAssertFalse(view.handle(.escape))
    }

    func testTabFromTheParagraphBeforeEntersAtItsFirstChipAndShiftTabAtItsLast() throws {
        let view = try storyView()
        view.enterChips(forward: true)
        XCTAssertEqual(view.focusedChip, 0)
        view.enterChips(forward: false)
        XCTAssertEqual(view.focusedChip, 0, "a chip with the keyboard keeps it")
        view.handle(.backtab)
        view.enterChips(forward: false)
        XCTAssertEqual(view.focusedChip, view.content.mentions.count - 1)
        let plain = ChipTextView(content: ChipTextContent("No mentions.", references: [:]), style: ChipTextStyle(font: font))
        plain.enterChips(forward: true)
        XCTAssertNil(plain.focusedChip)
    }

    func testAChipsMenuCopiesAndOpensItsLink() throws {
        let view = try storyView()
        var opened: [URL] = []
        view.openURL = { opened.append($0) }
        let menu = try XCTUnwrap(view.chipMenu(0))
        XCTAssertEqual(menu.items.map(\.title), ["Copy Link", "Open on GitHub"])
        XCTAssertEqual(try XCTUnwrap(view.chipMenu(1)).items.map(\.title), ["Copy Link", "Open in Linear"])
        let open = menu.items[1]
        _ = (open.target as? NSObject)?.perform(open.action, with: open)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/tonypine/symphony/pull/448"])
        XCTAssertNil(ChipTextView(content: ChipTextContent("TP-999", references: [:]), style: ChipTextStyle(font: font)).chipMenu(0))
    }

    func testAClickOutsideAChipGoesThroughAControlsText() throws {
        let item = try decision()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        let view = ChipTextView(content: ChipTextContent("Leave them to TP-891", references: item.references), style: ChipTextStyle(font: font, selectable: false))
        host.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: view.height(forWidth: 600))
        XCTAssertFalse(view.isSelectable)
        XCTAssertTrue(view.acceptsFirstResponder, "its chip still takes the keyboard")
        let rect = try XCTUnwrap(view.chipRects(0).first)
        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: rect.midY)))
        XCTAssertTrue(view.hitTest(CGPoint(x: rect.midX, y: rect.midY)) === view)

        let plain = ChipTextView(content: ChipTextContent("No mentions.", references: [:]), style: ChipTextStyle(font: font, selectable: false))
        XCTAssertFalse(plain.acceptsFirstResponder)
        XCTAssertFalse(plain.canBecomeKeyView)
        // The control reads for its text, so VoiceOver finds neither the text nor its chips.
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityChildren()?.count, 0)
    }

    func testNewTextReplacesTheChipsAndTheSameTextChangesNothing() throws {
        let view = try storyView()
        let style = view.style
        view.update(content: view.content, style: style)
        XCTAssertEqual(view.chipAccessibilityElements.count, 3)
        view.update(content: ChipTextContent("Just TP-1.", references: [:]), style: style)
        XCTAssertEqual(view.string, "Just TP-1.")
        XCTAssertEqual(view.chipAccessibilityElements.map { $0.accessibilityLabel() }, ["TP-1, Symphony can't see it"])
        view.update(content: view.content, style: ChipTextStyle(font: font, color: .secondaryLabelColor, selectable: false))
        XCTAssertFalse(view.isSelectable)
    }

    // MARK: - Accessibility

    func testEachChipIsALinkVoiceOverCanOpenAndShowDetailsOf() throws {
        let item = try decision()
        let view = ChipTextView(content: ChipTextContent(try XCTUnwrap(item.review.action?.question), references: item.references), style: ChipTextStyle(font: font))
        let popover = PopoverSpy()
        var opened: [String] = []
        view.popover = popover
        view.openMention = { opened.append($0.key) }
        view.setFrameSize(CGSize(width: 600, height: view.height(forWidth: 600)))

        let links = view.chipAccessibilityElements
        XCTAssertEqual(links.map { $0.accessibilityRole() }, Array(repeating: .link, count: 4))
        XCTAssertEqual(links.map { $0.accessibilityLabel() }, [
            "TP-892, Retire two old review steps, Rework",
            "TP-891, Remove the retired review states, Code Review",
            "TP-892, Retire two old review steps, Rework",
            "TP-891, Remove the retired review states and the version switch from the code, Code Review",
        ])
        XCTAssertTrue(links.allSatisfy { $0.accessibilityHelp() == "Shows details" })
        XCTAssertEqual(links[1].accessibilityURL()?.absoluteString, "https://linear.app/tonypine/issue/TP-891")
        // Reading the children lays nothing out; each link's frame is the chip's, worked out when asked for.
        XCTAssertTrue(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.elementsEqual(links, by: ===) ?? false)
        XCTAssertEqual(links[1].accessibilityFrameInParentSpace(), view.chipRects(1).first)
        XCTAssertEqual(links[1].accessibilityFrame(), NSAccessibility.screenRect(fromView: view, rect: try XCTUnwrap(view.chipRects(1).first)))
        view.setFrameSize(CGSize(width: 300, height: view.height(forWidth: 300)))
        XCTAssertEqual(links[1].accessibilityFrameInParentSpace(), view.chipRects(1).first, "it follows a new width")
        XCTAssertTrue(links[1].accessibilityParent() as AnyObject === view)
        XCTAssertTrue(view.accessibilityChildren()?.contains { $0 as AnyObject === links[1] } ?? false)
        XCTAssertTrue(links[1].isAccessibilityElement())

        let showDetails = try XCTUnwrap(links[1].accessibilityCustomActions()?.first)
        XCTAssertEqual(showDetails.name, "Show Details")
        XCTAssertTrue(showDetails.handler?() ?? false)
        XCTAssertEqual(popover.shown.map(\.mention.key), ["TP-891"])
        XCTAssertEqual(popover.shown.first?.hover, false)
        XCTAssertTrue(links[0].accessibilityPerformShowAlternateUI())
        XCTAssertEqual(popover.shown.map(\.mention.key), ["TP-891", "TP-892"])
        XCTAssertTrue(links[1].accessibilityPerformPress())
        XCTAssertEqual(opened, ["TP-891"])
        XCTAssertFalse(links[1].isAccessibilityFocused())
        view.handle(.tab)
        XCTAssertTrue(links[0].isAccessibilityFocused())
    }

    // MARK: - Snapshots

    func testItDrawsItselfIntoAnImageWithoutAWindow() throws {
        let view = try storyView()
        for width in [860.0, 320] {
            view.setFrameSize(CGSize(width: width, height: view.height(forWidth: width)))
            let image = view.image(width: width)
            XCTAssertEqual(image.size, CGSize(width: width, height: view.height(forWidth: width)))
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            XCTAssertEqual(bitmap.pixelsWide, Int(width * 2))
            // The first chip's tint is drawn behind "#448".
            let rect = try XCTUnwrap(view.chipRects(0).first)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(rect.minX * 2) + 2, y: Int(rect.midY * 2)))
            XCTAssertGreaterThan(pixel.alphaComponent, 0.05, "tinted at \(width) pt")
            try write(image, "chip-text-\(Int(width))")
        }
    }

    // MARK: - Helpers

    /// The What happened paragraph about #448, TP-880 and TP-891, at the body size.
    private func storyView() throws -> ChipTextView {
        let item = try decision()
        let action = try XCTUnwrap(item.review.action)
        return ChipTextView(content: ChipTextContent(action.whyParagraphs.joined(separator: " "), references: item.references), style: ChipTextStyle(font: font))
    }

    private func textKitHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.attributedString = text
        manager.ensureLayout(for: manager.documentRange)
        return ceil(manager.usageBoundsForTextContainer.height)
    }

    private func decision() throws -> InboxItem {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/inbox.json")
        return try XCTUnwrap(InboxPayload.decode(Data(contentsOf: url))?.items.first { $0.identifier == "TP-892" })
    }

    /// Keeps a rendering for the record when `CHIP_TEXT_SNAPSHOTS` names a folder.
    private func write(_ image: NSImage, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["CHIP_TEXT_SNAPSHOTS"],
            let bitmap = image.representations.first as? NSBitmapImageRep,
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

/// Records what the view asks of its popover.
/// A popover that opens without a window and, like an animated `NSPopover`, tells its delegate it closed on a
/// later turn of the run loop.
private final class LateClosingPopover: NSPopover {
    private var open = false

    override var isShown: Bool { open }

    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        open = true
    }

    override func close() {
        guard open else { return }
        DispatchQueue.main.async {
            self.open = false
            self.delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
        }
    }
}

private final class PopoverSpy: ChipPopoverPresenting {
    var shown: [(mention: Mention, rect: CGRect, hover: Bool)] = []
    var leftChip = 0
    var closed = 0
    var onShow: () -> Void = {}

    func show(_ mention: Mention, relativeTo rect: CGRect, of view: NSView, hover: Bool) {
        shown.append((mention, rect, hover))
        onShow()
    }

    func pointerLeftChip() { leftChip += 1 }
    func close() { closed += 1 }
}
