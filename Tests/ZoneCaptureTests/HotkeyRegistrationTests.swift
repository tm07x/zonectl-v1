import XCTest
@testable import ZoneCaptureCore

final class HotkeyRegistrationTests: XCTestCase {
    func testHandlerFailureDoesNotReserveOrRegisterAction() {
        let registry = HotkeyRegistry()
        var reserved = false
        var invoked = false
        var failure: Int32?
        let id = registry.register({ invoked = true }, installHandler: { -9876 }, reserve: { _ in
            reserved = true
            return 0
        }, onFailure: { failure = $0 })

        XCTAssertNil(id)
        XCTAssertFalse(reserved)
        XCTAssertFalse(registry.dispatch(id: 1))
        XCTAssertFalse(invoked)
        XCTAssertEqual(failure, -9876)
    }

    func testReservationFailureRemovesActionAndReportsStatus() {
        let registry = HotkeyRegistry()
        var reservedID: UInt32?
        var failure: Int32?
        let id = registry.register({}, installHandler: { 0 }, reserve: { id in
            reservedID = id
            return -123
        }, onFailure: { failure = $0 })

        XCTAssertNil(id)
        XCTAssertEqual(failure, -123)
        XCTAssertFalse(registry.dispatch(id: reservedID!))
    }

    func testRetryAfterHandlerFailureDispatchesCorrectAction() throws {
        let registry = HotkeyRegistry()
        registry.register({}, installHandler: { -1 }, reserve: { _ in
            XCTFail("must not reserve without a handler")
            return 0
        })
        var invoked = 0
        let id = try XCTUnwrap(registry.register({ invoked += 1 }, installHandler: { 0 }, reserve: { _ in 0 }))
        XCTAssertEqual(id, 1)
        XCTAssertTrue(registry.dispatch(id: id))
        XCTAssertEqual(invoked, 1)
    }
}
