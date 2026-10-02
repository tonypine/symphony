import XCTest
@testable import SymphonyBarCore

private struct LoginItemFailure: Error {}

private final class FakeLoginItem: LoginItemService {
    var status: LoginItemStatus
    var failure: Error?
    var calls: [String] = []

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }
}

final class LoginItemTests: XCTestCase {
    func testIsOnWhileRegistered() {
        XCTAssertTrue(LoginItem.isOn(.enabled))
        XCTAssertTrue(LoginItem.isOn(.requiresApproval))
        XCTAssertFalse(LoginItem.isOn(.notRegistered))
        XCTAssertFalse(LoginItem.isOn(.notFound))
    }

    func testNoteOnlyWhenApprovalIsNeeded() {
        XCTAssertEqual(
            LoginItem.note(.requiresApproval),
            "Allow Symphony in System Settings → General → Login Items to open it at login."
        )
        XCTAssertNil(LoginItem.note(.enabled))
        XCTAssertNil(LoginItem.note(.notRegistered))
        XCTAssertNil(LoginItem.note(.notFound))
    }

    func testTurningOnRegisters() throws {
        for status in [LoginItemStatus.notRegistered, .notFound] {
            let item = FakeLoginItem(status)
            try LoginItem.apply(true, to: item)
            XCTAssertEqual(item.calls, ["register"])
            XCTAssertEqual(item.status, .enabled)
        }
    }

    func testTurningOffUnregisters() throws {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            let item = FakeLoginItem(status)
            try LoginItem.apply(false, to: item)
            XCTAssertEqual(item.calls, ["unregister"])
            XCTAssertEqual(item.status, .notRegistered)
        }
    }

    func testNothingHappensWhenAlreadyMatching() throws {
        for status in [LoginItemStatus.enabled, .requiresApproval, .notRegistered, .notFound] {
            let item = FakeLoginItem(status)
            try LoginItem.apply(LoginItem.isOn(status), to: item)
            XCTAssertEqual(item.calls, [])
        }
    }

    func testFailuresAreThrown() {
        let on = FakeLoginItem(.notRegistered)
        on.failure = LoginItemFailure()
        XCTAssertThrowsError(try LoginItem.apply(true, to: on)) { XCTAssertTrue($0 is LoginItemFailure) }
        XCTAssertEqual(on.status, .notRegistered)

        let off = FakeLoginItem(.enabled)
        off.failure = LoginItemFailure()
        XCTAssertThrowsError(try LoginItem.apply(false, to: off)) { XCTAssertTrue($0 is LoginItemFailure) }
        XCTAssertEqual(off.status, .enabled)
    }
}
