import XCTest
@testable import SymphonyBarCore

final class WindowFrameStoreTests: XCTestCase {
    func testItHasNoFrameUntilOneIsSaved() {
        XCTAssertNil(WindowFrameStore(name: "SymphonyMainWindow", defaults: MemoryKeyValueStore()).load())
    }

    func testItKeepsTheFrameUnderAppKitsAutosaveKey() {
        let defaults = MemoryKeyValueStore()
        WindowFrameStore(name: "SymphonyMainWindow", defaults: defaults).save("100 200 1200 760 0 0 1512 944 ")

        XCTAssertEqual(defaults.values["NSWindow Frame SymphonyMainWindow"] as? String, "100 200 1200 760 0 0 1512 944 ")
        XCTAssertEqual(
            WindowFrameStore(name: "SymphonyMainWindow", defaults: defaults).load(),
            "100 200 1200 760 0 0 1512 944 "
        )
    }

    func testAnEmptyOrForeignValueIsNoFrame() {
        let defaults = MemoryKeyValueStore()
        defaults.values["NSWindow Frame SymphonyMainWindow"] = ""
        XCTAssertNil(WindowFrameStore(name: "SymphonyMainWindow", defaults: defaults).load())
        defaults.values["NSWindow Frame SymphonyMainWindow"] = 42
        XCTAssertNil(WindowFrameStore(name: "SymphonyMainWindow", defaults: defaults).load())
    }

    func testQAModeKeepsTheFrameInTheQARoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = AppStores(environment: [QAMode.environmentKey: root.path])

        WindowFrameStore(name: "SymphonyMainWindow", defaults: stores.defaults).save("0 30 1400 900 0 0 1512 944 ")

        let saved = try XCTUnwrap(stores.qaMode).settingsFile
        let values = try XCTUnwrap(NSDictionary(contentsOf: saved))
        XCTAssertEqual(values["NSWindow Frame SymphonyMainWindow"] as? String, "0 30 1400 900 0 0 1512 944 ")
        XCTAssertNil(WindowFrameStore(name: "SymphonyMainWindow", defaults: AppStores(environment: [
            QAMode.environmentKey: root.appendingPathComponent("other").path,
        ]).defaults).load())
    }
}
