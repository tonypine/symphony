import XCTest
@testable import SymphonyBarCore

/// The Key block's state (TP-1540): a key typed, Test connection, a pass that keeps the key, Enable only after a pass,
/// Disable and Remove Key.
final class ProviderKeyEditorTests: XCTestCase {
    private let id = "opencode-go"

    func testEnableIsAvailableOnlyOnceATestPassed() throws {
        var editor = ProviderKeyEditor()
        var keys = ProviderKeys()
        XCTAssertEqual(editor.text(id, keys: keys), "")
        XCTAssertFalse(editor.canTest(id, keys: keys), "no key to test")
        XCTAssertNil(editor.beginTest(id, keys: keys))
        XCTAssertFalse(editor.canEnable(id, keys: keys))

        editor.edit(id, to: " sk-go ", keys: keys)
        XCTAssertTrue(editor.canTest(id, keys: keys))
        XCTAssertEqual(editor.beginTest(id, keys: keys), "sk-go")
        XCTAssertEqual(editor.testing, id)
        XCTAssertFalse(editor.canTest(id, keys: keys), "one test at a time")
        XCTAssertNil(editor.beginTest(id, keys: keys))

        keys = try XCTUnwrap(editor.finishTest(id, key: "sk-go", result: .works("ok"), keys: keys), "a pass keeps the key")
        XCTAssertNil(editor.testing)
        XCTAssertEqual(keys.keys, [id: "sk-go"])
        XCTAssertFalse(keys.isEnabled(id), "a pass doesn't enable it")
        XCTAssertEqual(editor.result(id, keys: keys), .works("ok"))
        XCTAssertEqual(editor.text(id, keys: keys), "sk-go")
        XCTAssertTrue(editor.canEnable(id, keys: keys))

        keys = keys.enabling(id, true)
        XCTAssertFalse(editor.canEnable(id, keys: keys), "already on")
        keys = keys.enabling(id, false)
        XCTAssertTrue(editor.canEnable(id, keys: keys), "after Disable the passed test still holds")
        XCTAssertEqual(keys.keys, [id: "sk-go"], "Disable keeps the key")
    }

    func testAFailedTestKeepsNothingAndOffersNoEnable() {
        var editor = ProviderKeyEditor()
        let keys = ProviderKeys()
        editor.edit(id, to: "bad", keys: keys)
        _ = editor.beginTest(id, keys: keys)
        XCTAssertNil(editor.finishTest(id, key: "bad", result: .fails("rejected"), keys: keys))
        XCTAssertEqual(editor.result(id, keys: keys), .fails("rejected"))
        XCTAssertFalse(editor.canEnable(id, keys: keys))
        XCTAssertEqual(editor.text(id, keys: keys), "bad", "the key typed stays to fix")
    }

    func testEditingTheKeyClearsItsResultAndAStaleResultIsDropped() throws {
        var editor = ProviderKeyEditor()
        var keys = ProviderKeys()
        editor.edit(id, to: "sk-1", keys: keys)
        _ = editor.beginTest(id, keys: keys)
        // Edited during the test: its result is stale.
        editor.edit(id, to: "sk-2", keys: keys)
        XCTAssertNil(editor.finishTest(id, key: "sk-1", result: .works("ok"), keys: keys))
        XCTAssertNil(editor.result(id, keys: keys))
        XCTAssertNil(editor.testing)

        _ = editor.beginTest(id, keys: keys)
        keys = try XCTUnwrap(editor.finishTest(id, key: "sk-2", result: .works("ok"), keys: keys))
        editor.edit(id, to: "sk-2", keys: keys)
        XCTAssertNotNil(editor.result(id, keys: keys), "the same text is no edit")
        editor.edit(id, to: "sk-3", keys: keys)
        XCTAssertNil(editor.result(id, keys: keys))
        XCTAssertFalse(editor.canEnable(id, keys: keys), "a new key needs its own test")
    }

    func testRemoveKeyEmptiesTheFieldAndKeepsEnable() {
        var editor = ProviderKeyEditor()
        let keys = ProviderKeys(keys: [id: "sk-go"], enabled: [id])
        editor.edit(id, to: "typed", keys: keys)
        let removed = editor.removeKey(id, keys: keys)
        XCTAssertEqual(removed.keys, [:])
        XCTAssertEqual(removed.enabled, [id])
        XCTAssertFalse(removed.isEnabled(id))
        XCTAssertEqual(editor.text(id, keys: removed), "")
        XCTAssertNil(editor.result(id, keys: removed))
    }
}
