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

    func testPageSummaryIsItsOwnChoiceAndStartsOff() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.siriPageSummary, "reading pages is new: off until the person turns it on")
        XCTAssertTrue(store.siriAppIntents, "the existing shortcuts are not affected by it")

        store.siriPageSummary = true
        XCTAssertTrue(store.siriPageSummary)
        XCTAssertTrue(SettingsStore(defaults: defaults).siriPageSummary, "kept across launches")
        XCTAssertTrue(store.siriAppIntents)

        store.siriPageSummary = false
        store.siriAppIntents = false
        XCTAssertFalse(SettingsStore(defaults: defaults).siriPageSummary)
        XCTAssertFalse(SettingsStore(defaults: defaults).siriAppIntents)
    }

    func testThePageSummaryGuardFollowsItsOwnSetting() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertThrowsError(try YabIntentsGuard.checkPageSummaryEnabled(in: store)) {
            XCTAssertEqual($0 as? YabIntentError, .summaryDisabled)
        }
        // The Open, Search and Private Tab guard is untouched by it.
        XCTAssertNoThrow(try YabIntentsGuard.checkEnabled(in: store))

        store.siriPageSummary = true
        XCTAssertNoThrow(try YabIntentsGuard.checkPageSummaryEnabled(in: store))
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

    func testSummarizingNeedsAnUnlockedIPhone() {
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

    // MARK: - the summary run (the Siri device flow is mobile acceptance)

    private let page = PageSummary.Front(tab: "tab-1", url: URL(string: "https://example.com/a"), isPrivate: false, isLoaded: true)
    private var context: PageContext { PageContext(title: "A", address: "https://example.com/a", text: "words") }

    private func optedIn() -> SettingsStore {
        let store = SettingsStore(defaults: defaults)
        store.siriAppIntents = true
        store.siriPageSummary = true
        return store
    }

    private func source(
        front: @escaping () -> PageSummary.Front? = { nil },
        readiness: @escaping () -> OnDeviceModel.Readiness = { .ready },
        read: @escaping (PageSummary.Front) async -> PageContext? = { _ in nil },
        answer: @escaping (AskContext) async throws -> String = { _ in "A summary." }
    ) -> PageSummary.Source {
        PageSummary.Source(front: front, readiness: readiness, read: read, answer: answer)
    }

    private func assertRun(_ expected: YabIntentError, _ source: PageSummary.Source, _ store: SettingsStore, line: UInt = #line) async {
        do {
            let text = try await PageSummary.run(source, settings: store, languageCode: nil)
            XCTFail("Should have thrown \(expected), got \(text)", line: line)
        } catch {
            XCTAssertEqual(error as? YabIntentError, expected, line: line)
        }
    }

    func testASummaryNeedsItsOwnOptIn() async {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.siriAppIntents)
        var read = false
        let src = source(front: { self.page }, read: { _ in read = true; return self.context })
        await assertRun(.summaryDisabled, src, store)
        XCTAssertFalse(read, "the page is not read without the opt-in")
    }

    func testASummaryIsRefusedWhenAllIntentsAreOff() async {
        let store = optedIn()
        store.siriAppIntents = false
        await assertRun(.disabled, source(front: { self.page }, read: { _ in self.context }), store)
    }

    func testASummaryIsRefusedWhenAppleIntelligenceIsOffOnThisIPhone() async {
        var read = false
        let src = source(front: { self.page }, readiness: { .appleIntelligenceOff }, read: { _ in read = true; return self.context })
        await assertRun(.appleIntelligenceOff, src, optedIn())
        XCTAssertFalse(read, "nothing is read while Apple Intelligence is off")

        await assertRun(.noModel, source(front: { self.page }, readiness: { .unavailable }, read: { _ in self.context }), optedIn())
    }

    func testReadinessTellsAppleIntelligenceOffFromAMissingModel() {
        XCTAssertEqual(OnDeviceModel.readiness(of: .available), .ready)
        XCTAssertEqual(OnDeviceModel.readiness(of: .unavailable(.appleIntelligenceNotEnabled)), .appleIntelligenceOff)
        XCTAssertEqual(OnDeviceModel.readiness(of: .unavailable(.deviceNotEligible)), .unavailable)
        XCTAssertEqual(OnDeviceModel.readiness(of: .unavailable(.modelNotReady)), .unavailable)
    }

    func testASummaryRefusesPrivateUnloadedAndMissingPages() async {
        let store = optedIn()
        var privatePage = page; privatePage.isPrivate = true
        var unloaded = page; unloaded.isLoaded = false
        var notWeb = page; notWeb.url = URL(string: "yab://settings")
        await assertRun(.privatePage, source(front: { privatePage }, read: { _ in self.context }), store)
        await assertRun(.pageNotRead, source(front: { unloaded }, read: { _ in self.context }), store)
        await assertRun(.noActivePage, source(front: { notWeb }, read: { _ in self.context }), store)
        await assertRun(.noActivePage, source(front: { nil }, read: { _ in self.context }), store)
    }

    func testASummaryIsReturnedWhenEveryGateIsOpen() async throws {
        var asked: AskContext?
        let src = source(front: { self.page }, read: { _ in self.context }, answer: { asked = $0; return "  A summary.\n" })
        let text = try await PageSummary.run(src, settings: optedIn(), languageCode: "fr")
        XCTAssertEqual(text, "A summary.")
        XCTAssertEqual(asked?.page, context)
        XCTAssertTrue(asked?.question.hasSuffix("Answer in French.") == true)
    }

    func testAnEmptyOrFailedAnswerIsNotASummary() async {
        let store = optedIn()
        await assertRun(.noSummary, source(front: { self.page }, read: { _ in self.context }, answer: { _ in " \n" }), store)
        struct Boom: Error {}
        await assertRun(.noSummary, source(front: { self.page }, read: { _ in self.context }, answer: { _ in throw Boom() }), store)
    }

    func testCancellationWhileTheModelAnswersGivesSiriNoDialog() async {
        let store = optedIn()
        let src = source(front: { self.page }, read: { _ in self.context }, answer: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "A summary that must not be spoken."
        })
        let result = await Task { try await PageSummary.run(src, settings: store, languageCode: nil) }.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationWhileThePageIsReadStopsBeforeTheModel() async {
        let store = optedIn()
        var modelAsked = false
        let src = source(front: { self.page },
                         read: { _ in withUnsafeCurrentTask { $0?.cancel() }; return self.context },
                         answer: { _ in modelAsked = true; return "A summary." })
        let result = await Task { try await PageSummary.run(src, settings: store, languageCode: nil) }.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(modelAsked)
    }

    func testTurningTheChoiceOffDuringAnAwaitStopsTheSummary() async {
        let store = optedIn()
        let afterRead = source(front: { self.page }, read: { _ in store.siriPageSummary = false; return self.context })
        await assertRun(.summaryDisabled, afterRead, store)

        store.siriPageSummary = true
        let afterAnswer = source(front: { self.page }, read: { _ in self.context }, answer: { _ in
            store.siriAppIntents = false
            return "A summary."
        })
        await assertRun(.disabled, afterAnswer, store)
    }

    func testAppleIntelligenceTurnedOffDuringAnAwaitStopsTheSummary() async {
        var state = OnDeviceModel.Readiness.ready
        let src = source(front: { self.page }, readiness: { state }, read: { _ in self.context }, answer: { _ in
            state = .appleIntelligenceOff
            return "A summary."
        })
        await assertRun(.appleIntelligenceOff, src, optedIn())
    }

    func testANewTabOrPrivateTabDuringAnAwaitStopsTheSummary() async {
        var current: PageSummary.Front? = page
        let navigates = source(front: { current }, read: { _ in
            current?.url = URL(string: "https://example.com/other")
            return self.context
        })
        await assertRun(.pageChanged, navigates, optedIn())

        current = page
        let goesPrivate = source(front: { current }, read: { _ in self.context }, answer: { _ in
            current?.isPrivate = true
            return "A summary."
        })
        await assertRun(.privatePage, goesPrivate, optedIn())

        current = page
        let switches = source(front: { current }, read: { _ in
            current = PageSummary.Front(tab: "tab-2", url: self.page.url, isPrivate: false, isLoaded: true)
            return self.context
        })
        await assertRun(.pageChanged, switches, optedIn())
    }
}
