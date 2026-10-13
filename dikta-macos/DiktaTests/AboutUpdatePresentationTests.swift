import XCTest
@testable import Dikta

final class AboutUpdatePresentationTests: XCTestCase {
    func testUnknownUpdateAlwaysOffersManualCheckIncludingWhenAutomaticChecksAreOff() {
        // Automatic-check consent is deliberately not an input to manual discovery.
        let state = AboutUpdatePresentation(updateAvailable: false, pendingVersion: nil, canCheckForUpdates: true)
        XCTAssertEqual(state.title, "Check for Updates…")
        XCTAssertTrue(state.isEnabled)
        var checks = 0
        state.checkForUpdates { checks += 1 }
        XCTAssertEqual(checks, 1)
    }

    func testKnownVersionReplacesManualLabelAndUsesSameCheckAction() {
        let state = AboutUpdatePresentation(updateAvailable: true, pendingVersion: "1.6", canCheckForUpdates: true)
        XCTAssertEqual(state.title, "v1.6 available…")
        var checks = 0
        state.checkForUpdates { checks += 1 }
        XCTAssertEqual(checks, 1)
    }

    func testIncompleteOrClearedBadgeFallsBackToManualCheckWithoutUpToDateClaim() {
        for state in [
            AboutUpdatePresentation(updateAvailable: true, pendingVersion: nil, canCheckForUpdates: true),
            AboutUpdatePresentation(updateAvailable: false, pendingVersion: "1.6", canCheckForUpdates: true)
        ] {
            XCTAssertEqual(state.title, "Check for Updates…")
        }
    }

    func testActiveUpdaterKeepsBothLabelsVisibleButDisablesAndRejectsAction() {
        for known in [false, true] {
            let state = AboutUpdatePresentation(updateAvailable: known, pendingVersion: known ? "1.6" : nil, canCheckForUpdates: false)
            XCTAssertEqual(state.title, known ? "v1.6 available…" : "Check for Updates…")
            XCTAssertFalse(state.isEnabled)
            var checks = 0
            state.checkForUpdates { checks += 1 }
            XCTAssertEqual(checks, 0)
        }
    }

    func testAvailabilityRecoveryReenablesManualAction() {
        let state = AboutUpdatePresentation(updateAvailable: false, pendingVersion: nil, canCheckForUpdates: true)
        XCTAssertTrue(state.isEnabled)
        var checks = 0
        state.checkForUpdates { checks += 1 }
        XCTAssertEqual(checks, 1)
    }
}
