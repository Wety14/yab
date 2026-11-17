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

    func testSiriToggleDefaultsToOff() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.siriAppIntents)

        store.siriAppIntents = true
        XCTAssertTrue(store.siriAppIntents)
        XCTAssertTrue(defaults.bool(forKey: "ai.siri.enabled"))

        store.siriAppIntents = false
        XCTAssertFalse(store.siriAppIntents)
        XCTAssertFalse(defaults.bool(forKey: "ai.siri.enabled"))
    }

    func testIntentsRefuseWhenDisabled() async throws {
        let original = UserDefaults.standard.object(forKey: "ai.siri.enabled")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "ai.siri.enabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "ai.siri.enabled")
            }
        }

        UserDefaults.standard.set(false, forKey: "ai.siri.enabled")

        let openIntent = OpenURLInYabIntent(url: URL(string: "https://example.com")!)
        do {
            _ = try await openIntent.perform()
            XCTFail("Should have thrown YabIntentError.disabled")
        } catch let error as YabIntentError {
            XCTAssertEqual(error, .disabled)
            XCTAssertEqual(error.localizedStringResource.key, "Siri App Intents are disabled in Yab Settings.")
        }

        let searchIntent = SearchInYabIntent(text: "search query")
        do {
            _ = try await searchIntent.perform()
            XCTFail("Should have thrown YabIntentError.disabled")
        } catch let error as YabIntentError {
            XCTAssertEqual(error, .disabled)
        }

        let privateIntent = NewPrivateTabIntent()
        do {
            _ = try await privateIntent.perform()
            XCTFail("Should have thrown YabIntentError.disabled")
        } catch let error as YabIntentError {
            XCTAssertEqual(error, .disabled)
        }

        let summarizeIntent = SummarizeCurrentPageIntent()
        do {
            _ = try await summarizeIntent.perform()
            XCTFail("Should have thrown YabIntentError.disabled")
        } catch let error as YabIntentError {
            XCTAssertEqual(error, .disabled)
        }
    }
}
