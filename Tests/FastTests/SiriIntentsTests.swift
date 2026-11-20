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
    @Test func newTabRefusesWhenSiriIsOff() async {
        await withSettings(siri: nil, ai: .on) {
            #expect(throws: SystemIntentError.disabled) { try SystemIntentsGuard.checkSiriAllowed() }
            await #expect(throws: SystemIntentError.disabled) { try await NewTabIntent().perform() }
        }
    }

    @MainActor
    @Test func siriAloneAllowsNewTabWithAIOff() async {
        await withSettings(siri: true, ai: .off) {
            #expect(throws: Never.self) { try SystemIntentsGuard.checkSiriAllowed() }
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

    /// Counts what a stand-in was asked, for the tests below.
    @MainActor
    private final class Calls {
        var model = 0
    }

    /// Runs `body` with a page that needs no browser and the given model in
    /// place of the one on this Mac, and puts the real ones back.
    @MainActor
    private func withStandIns(page: @escaping @MainActor () async throws -> LinkSummary.Page = { LinkSummary.Page(title: "Fixture", text: "Owned fixture") },
                              model: @escaping @MainActor (LinkSummary.Page) async -> String?,
                              _ body: () async throws -> Void) async rethrows {
        let originalPage = SystemIntentsBridge.readPage
        let originalModel = SystemIntentsBridge.writeGist
        defer {
            SystemIntentsBridge.readPage = originalPage
            SystemIntentsBridge.writeGist = originalModel
        }
        SystemIntentsBridge.readPage = page
        SystemIntentsBridge.writeGist = model
        try await body()
    }

    @MainActor
    @Test func summaryIsSpokenWhenNothingChangesWhileTheModelWrites() async {
        // The slow model alone changes nothing: the words come back.
        await withSettings(siri: true, ai: .on) {
            await withStandIns(model: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                return "A fixture summary."
            }) {
                await #expect(throws: Never.self) { try await SummarizePageIntent().perform() }
            }
        }
    }

    @MainActor
    @Test func summaryIsNotSpokenWhenSiriGoesOffWhileTheModelWrites() async {
        await withSettings(siri: true, ai: .on) {
            await withStandIns(model: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                Store.settings.set(false, forKey: SystemIntentsBridge.enabledKey)
                return "A summary nobody may hear."
            }) {
                await #expect(throws: SystemIntentError.disabled) { try await SummarizePageIntent().perform() }
            }
        }
    }

    @MainActor
    @Test func summaryIsNotSpokenWhenAIGoesOffWhileTheModelWrites() async {
        await withSettings(siri: true, ai: .on) {
            await withStandIns(model: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                Store.settings.set(AIUse.Level.off.rawValue, forKey: AIUse.key)
                return "A summary nobody may hear."
            }) {
                await #expect(throws: SystemIntentError.aiOff) { try await SummarizePageIntent().perform() }
            }
        }
    }

    @MainActor
    @Test func pageIsNotSentToTheModelWhenSiriGoesOffWhileItIsRead() async {
        let calls = Calls()
        await withSettings(siri: true, ai: .on) {
            await withStandIns(page: {
                try? await Task.sleep(for: .milliseconds(50))
                Store.settings.set(false, forKey: SystemIntentsBridge.enabledKey)
                return LinkSummary.Page(title: "Fixture", text: "Owned fixture")
            }, model: { _ in
                calls.model += 1
                return "A summary nobody may hear."
            }) {
                await #expect(throws: SystemIntentError.disabled) { try await SummarizePageIntent().perform() }
                #expect(calls.model == 0)
            }
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
