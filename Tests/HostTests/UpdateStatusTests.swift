import XCTest

final class UpdateStatusTests: XCTestCase {
    func testMenuTextForEveryStatus() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let statuses: [(UpdateStatus, String)] = [
            (.sourceBuild, "Built from source, update with scripts/update-mac.sh"),
            (.notConfigured, "Update signing is not configured"),
            (.checking, "Checking…"),
            (.upToDate(checkedAt: now.addingTimeInterval(-5 * 60)), "Up to date · checked 5 min ago"),
            (.available(version: "0.0.6"), "Downloading 0.0.6…"),
            (.readyToInstall(version: "0.0.6"), "0.0.6 ready, installs when you quit"),
            (.failed(message: "network error", checkedAt: nil), "Update check failed")
        ]

        for (status, expected) in statuses {
            XCTAssertEqual(UpdateStatusPresentation.menuText(for: status, now: now), expected)
        }
    }

    func testVersionLabelIncludesMarketingAndBuildVersions() {
        XCTAssertEqual(
            UpdateStatusPresentation.versionLabel(shortVersion: "0.0.1", buildVersion: "20261017.111102"),
            "0.0.1 (20261017.111102)"
        )
    }

    func testMatchingBuildShowsWhatsNewOnceAndClearsSavedValues() throws {
        let suiteName = "UpdateStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        UpdateNoticeStore.save(version: "0.0.6", build: "42", notes: "New features", to: defaults)

        XCTAssertTrue(UpdateNoticeStore.shouldPresent(savedBuild: "42", runningBuild: "42"))
        XCTAssertEqual(
            UpdateNoticeStore.consume(forRunningBuild: "42", from: defaults),
            PendingUpdateNotice(version: "0.0.6", build: "42", notes: "New features")
        )
        XCTAssertNil(defaults.object(forKey: UpdateNoticeStore.versionKey))
        XCTAssertNil(defaults.object(forKey: UpdateNoticeStore.buildKey))
        XCTAssertNil(defaults.object(forKey: UpdateNoticeStore.notesKey))
        XCTAssertNil(UpdateNoticeStore.consume(forRunningBuild: "42", from: defaults))
    }

    func testMismatchedBuildDoesNotShowWhatsNew() throws {
        let suiteName = "UpdateStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        UpdateNoticeStore.save(version: "0.0.6", build: "42", notes: "New features", to: defaults)

        XCTAssertFalse(UpdateNoticeStore.shouldPresent(savedBuild: "42", runningBuild: "43"))
        XCTAssertNil(UpdateNoticeStore.consume(forRunningBuild: "43", from: defaults))
    }

    func testHTMLReleaseNotesAreStoredAsPlainText() {
        XCTAssertEqual(
            UpdateNoticeStore.plainTextNotes("<ul><li>Fix sound &amp; timing</li><li>New games</li></ul>", format: "html"),
            "Fix sound & timing\nNew games"
        )
    }
}
