import AppIntents
import Foundation
import XCTest
@testable import YabPhone

@MainActor
final class SiriIntentsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "settings-siri-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - the setting

    func testSiriToggleDefaultsToOnAndTheChoiceSticks() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.siriAppIntents, "the Shortcuts people made keep working until they turn it off")

        store.siriAppIntents = false
        XCTAssertFalse(store.siriAppIntents)
        XCTAssertFalse(SettingsStore(defaults: defaults).siriAppIntents, "kept across launches")

        store.siriAppIntents = true
        XCTAssertTrue(SettingsStore(defaults: defaults).siriAppIntents)
    }

    func testTheGuardFollowsTheSetting() throws {
        let store = SettingsStore(defaults: defaults)
        try YabIntentsGuard.checkEnabled(in: store)

        store.siriAppIntents = false
        XCTAssertThrowsError(try YabIntentsGuard.checkEnabled(in: store)) {
            XCTAssertEqual($0 as? YabIntentError, .disabled)
        }

        store.siriAppIntents = true
        XCTAssertNoThrow(try YabIntentsGuard.checkEnabled(in: store))
    }

    func testEveryIntentRefusesWhenTurnedOff() async {
        let shared = SettingsStore.shared
        let before = shared.siriAppIntents
        defer { shared.siriAppIntents = before }
        shared.siriAppIntents = false

        await assertDisabled { try await OpenURLInYabIntent(url: URL(string: "https://example.com")!).perform() }
        await assertDisabled { try await SearchInYabIntent(text: "search query").perform() }
        await assertDisabled { try await NewPrivateTabIntent().perform() }
        await assertDisabled { try await SummarizeCurrentPageIntent().perform() }
    }

    private func assertDisabled<Result>(_ run: () async throws -> Result, line: UInt = #line) async {
        do {
            _ = try await run()
            XCTFail("Should have thrown YabIntentError.disabled", line: line)
        } catch {
            XCTAssertEqual(error as? YabIntentError, .disabled, line: line)
        }
    }

    // MARK: - summarizing the page in front

    func testSummarizingAsksForFaceIDFirst() {
        XCTAssertEqual(SummarizeCurrentPageIntent.authenticationPolicy, .requiresAuthentication)
    }

    func testAPrivateTabIsNeverSummarized() {
        XCTAssertThrowsError(try PageSummary.check(url: URL(string: "https://example.com"), isPrivate: true)) {
            XCTAssertEqual($0 as? YabIntentError, .privatePage)
        }
    }

    func testOnlyAWebPageIsSummarized() throws {
        try PageSummary.check(url: URL(string: "https://example.com/a"), isPrivate: false)
        try PageSummary.check(url: URL(string: "http://example.com/a"), isPrivate: false)
        for address in [nil, "yab://settings", "about:blank", "file:///tmp/a.html"] {
            XCTAssertThrowsError(try PageSummary.check(url: address.flatMap(URL.init(string:)), isPrivate: false), address ?? "no address") {
                XCTAssertEqual($0 as? YabIntentError, .noActivePage)
            }
        }
    }

    func testTheSummaryIsAskedForInThePersonsLanguage() {
        XCTAssertTrue(PageSummary.question(languageCode: "fr").hasSuffix("Answer in French."))
        XCTAssertTrue(PageSummary.question(languageCode: "en").hasSuffix("Answer in English."))
        XCTAssertEqual(PageSummary.question(languageCode: nil), "Summarize this page in two or three plain sentences.")
    }
}
