import AppKit
import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
struct SiriIntentsTests {
    /// Runs `body` with the two switches the summary intent reads set as
    /// asked, and puts them back.
    @MainActor
    private func withSettings(siri: Bool?, ai: AIUse.Level?, _ body: () async throws -> Void) async rethrows {
        let keys = [SystemIntentsBridge.enabledKey, AIUse.key]
        let originals = keys.map { Store.settings.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { Store.settings.set(original, forKey: key) } else { Store.settings.removeObject(forKey: key) }
            }
        }
        if let siri { Store.settings.set(siri, forKey: SystemIntentsBridge.enabledKey) } else { Store.settings.removeObject(forKey: SystemIntentsBridge.enabledKey) }
        if let ai { Store.settings.set(ai.rawValue, forKey: AIUse.key) } else { Store.settings.removeObject(forKey: AIUse.key) }
        try await body()
    }

    @MainActor
    @Test func siriSettingIsThePersonsAlone() {
        let item = SettingsItem.all.first { $0.id == "ai-siri" }
        #expect(item != nil)
        #expect(item?.page == .ai)
        #expect(NativeActions.classification(item!) == "user_only")
        #expect(!NativeSetting.all.contains { $0.id == "ai-siri" })
        #expect(!(item?.words ?? "").contains("arc-divergent"))
    }

    @MainActor
    @Test func siriAppIntentsToggle() async {
        await withSettings(siri: nil, ai: nil) {
            let prefs = Preferences()
            // Off by default
            #expect(!prefs.siriAppIntents)

            prefs.siriAppIntents = true
            #expect(Store.settings.bool(forKey: SystemIntentsBridge.enabledKey))

            prefs.siriAppIntents = false
            #expect(!Store.settings.bool(forKey: SystemIntentsBridge.enabledKey))
        }
    }

    @MainActor
    @Test func summaryRefusesWhenSiriIsOff() async {
        await withSettings(siri: false, ai: .on) {
            #expect(throws: SystemIntentError.disabled) { try SystemIntentsGuard.checkSummaryAllowed() }
            await #expect(throws: SystemIntentError.disabled) { try await SummarizePageIntent().perform() }
        }
    }

    @MainActor
    @Test func summaryRefusesWhenAIIsOff() async {
        await withSettings(siri: true, ai: .off) {
            #expect(throws: SystemIntentError.aiOff) { try SystemIntentsGuard.checkSummaryAllowed() }
        }
    }

    @MainActor
    @Test func summaryIsAllowedWhenAsked() async {
        // "When Asked" still answers what the person calls up themselves.
        await withSettings(siri: true, ai: .asked) {
            #expect(throws: Never.self) { try SystemIntentsGuard.checkSummaryAllowed() }
        }
    }

    @Test func errorsSayWhatHappened() {
        #expect(SystemIntentError.disabled.errorDescription == "Siri & App Intents is off in Yab Settings.")
        #expect(SystemIntentError.aiOff.errorDescription == "AI is turned off in Yab Settings.")
        #expect(SystemIntentError.noActivePage.errorDescription == "There is no open web page to summarize.")
        #expect(SystemIntentError.privatePage.errorDescription == "Yab does not read private tabs.")
        #expect(SystemIntentError.asleepPage.errorDescription == "That tab is asleep. Switch to it in Yab, then try again.")
        #expect(SystemIntentError.noSummary.errorDescription == "Yab could not summarize this page on this Mac.")
    }
}
