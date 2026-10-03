import XCTest
@testable import SymphonyBarCore

final class SecretsReaderTests: XCTestCase {
    private let secrets = SecretSettings(linearAPIKey: "lin_api_test", extraEnvironment: [])

    func testReadsOffTheCallingQueueAndReportsOnTheCallbackQueue() {
        let callbackQueue = DispatchQueue(label: "callback")
        let callbackKey = DispatchSpecificKey<Bool>()
        callbackQueue.setSpecific(key: callbackKey, value: true)
        let loadedOffCallbackQueue = expectation(description: "loaded")
        let done = expectation(description: "done")
        let reader = SecretsReader(callbackQueue: callbackQueue) { [secrets] in
            if DispatchQueue.getSpecific(key: callbackKey) == nil { loadedOffCallbackQueue.fulfill() }
            return secrets
        }

        callbackQueue.sync {
            reader.read { result in
                XCTAssertEqual(DispatchQueue.getSpecific(key: callbackKey), true)
                XCTAssertEqual(try? result.get(), self.secrets)
                done.fulfill()
            }
        }
        wait(for: [loadedOffCallbackQueue, done], timeout: 5)
    }

    func testCountsReadsUntilTheyFinish() {
        let callbackQueue = DispatchQueue(label: "callback")
        let blocked = DispatchSemaphore(value: 0)
        var changes: [Int] = []
        let reader = SecretsReader(callbackQueue: callbackQueue) { [secrets] in
            blocked.wait()
            return secrets
        }
        let done = expectation(description: "both reads")
        done.expectedFulfillmentCount = 2

        callbackQueue.sync {
            reader.onChange = { changes.append(reader.pendingReads) }
            reader.read { _ in done.fulfill() }
            reader.read { _ in done.fulfill() }
            XCTAssertTrue(reader.isWaiting)
            XCTAssertEqual(reader.pendingReads, 2)
        }
        blocked.signal()
        blocked.signal()
        wait(for: [done], timeout: 5)

        callbackQueue.sync {
            XCTAssertFalse(reader.isWaiting)
            XCTAssertEqual(changes, [1, 2, 1, 0])
        }
    }

    func testPassesTheKeychainErrorOn() {
        let callbackQueue = DispatchQueue(label: "callback")
        let done = expectation(description: "done")
        let reader = SecretsReader(callbackQueue: callbackQueue) {
            throw KeychainError(status: errSecAuthFailed)
        }

        callbackQueue.sync {
            reader.read { result in
                guard case let .failure(error) = result else { return XCTFail("expected a failure") }
                XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }
}
