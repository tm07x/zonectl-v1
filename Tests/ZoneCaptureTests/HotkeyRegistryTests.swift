import XCTest
@testable import ZoneCaptureCore

/// Regression tests for the hotkey hijack bug: two hotkey registrations must
/// get distinct IDs, and a delivered hotkey event must fire the action that
/// belongs to *its* ID — never the most recently registered one.
final class HotkeyRegistryTests: XCTestCase {

    func testRegistrationsGetDistinctIDs() {
        let registry = HotkeyRegistry()
        let first = registry.register {}
        let second = registry.register {}
        XCTAssertNotEqual(first, second)
    }

    func testDispatchFiresTheActionForThatIDOnly() {
        let registry = HotkeyRegistry()
        var panelFired = false
        var pageFired = false
        let panelID = registry.register { panelFired = true }
        let pageID = registry.register { pageFired = true }

        XCTAssertTrue(registry.dispatch(id: panelID))
        XCTAssertTrue(panelFired)
        XCTAssertFalse(pageFired, "panel hotkey must not trigger the page-capture action")

        panelFired = false
        XCTAssertTrue(registry.dispatch(id: pageID))
        XCTAssertTrue(pageFired)
        XCTAssertFalse(panelFired, "page hotkey must not trigger the panel action")
    }

    func testDispatchUnknownIDReturnsFalse() {
        let registry = HotkeyRegistry()
        _ = registry.register {}
        XCTAssertFalse(registry.dispatch(id: 9999))
    }

    func testUnregisterRemovesTheActionAndReusesNothing() {
        let registry = HotkeyRegistry()
        var fired = false
        let id = registry.register { fired = true }
        registry.unregister(id: id)
        XCTAssertFalse(registry.dispatch(id: id))
        XCTAssertFalse(fired)

        // A later registration must never collide with the removed ID.
        let next = registry.register {}
        XCTAssertNotEqual(next, id)
    }
}
