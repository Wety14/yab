import AppKit
import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
struct SiriIntentsTests {
    @MainActor
    @Test func siriAppIntentsSettingClassification() {
        let item = SettingsItem.all.first { $0.id == "ai-siri" }
        #expect(item != nil)
        #expect(item?.page == .ai)
        #expect(NativeActions.classification(item!) == "read_write")
        #expect(NativeSetting.all.contains { $0.id == "ai-siri" })
    }

    @MainActor
    @Test func siriAppIntentsToggle() throws {
        let original = Store.settings.object(forKey: "ai.siri.enabled")
        defer {
            if let original {
                Store.settings.set(original, forKey: "ai.siri.enabled")
            } else {
                Store.settings.removeObject(forKey: "ai.siri.enabled")
            }
        }

        let prefs = Preferences()
        // Off by default
        Store.settings.removeObject(forKey: "ai.siri.enabled")
        #expect(!prefs.siriAppIntents)

        // Toggled on
        prefs.siriAppIntents = true
        #expect(Store.settings.bool(forKey: "ai.siri.enabled"))

        // Toggled off
        prefs.siriAppIntents = false
        #expect(!Store.settings.bool(forKey: "ai.siri.enabled"))
    }

    @MainActor
    @Test func intentsRefuseWhenDisabled() async throws {
        let original = Store.settings.object(forKey: "ai.siri.enabled")
        defer {
            if let original {
                Store.settings.set(original, forKey: "ai.siri.enabled")
            } else {
                Store.settings.removeObject(forKey: "ai.siri.enabled")
            }
        }

        // Ensure disabled
        Store.settings.set(false, forKey: "ai.siri.enabled")

        var openPage = OpenPageIntent()
        openPage.address = URL(string: "https://example.com")!
        await #expect(throws: SystemIntentError.self) {
            try await openPage.perform()
        }

        let newTab = NewTabIntent()
        await #expect(throws: SystemIntentError.self) {
            try await newTab.perform()
        }

        let summarize = SummarizePageIntent()
        await #expect(throws: SystemIntentError.self) {
            try await summarize.perform()
        }

        // Check error description
        #expect(SystemIntentError.disabled.localizedDescription == "Siri App Intents are disabled in Yab Settings.")
        #expect(SystemIntentError.disabled.errorDescription == "Siri App Intents are disabled in Yab Settings.")
    }

    @MainActor
    @Test func summarizeFailsCleanlyWhenNoActivePage() async throws {
        let original = Store.settings.object(forKey: "ai.siri.enabled")
        defer {
            if let original {
                Store.settings.set(original, forKey: "ai.siri.enabled")
            } else {
                Store.settings.removeObject(forKey: "ai.siri.enabled")
            }
        }

        Store.settings.set(true, forKey: "ai.siri.enabled")

        let summarize = SummarizePageIntent()
        // No browser / tab open in this headless test
        await #expect(throws: SystemIntentError.self) {
            try await summarize.perform()
        }
        #expect(SystemIntentError.noActivePage.errorDescription == "There is no open web page to summarize.")
    }
}
