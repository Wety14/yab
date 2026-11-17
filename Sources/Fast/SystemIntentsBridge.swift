import Foundation

/// What the App Intents in SystemIntents.swift ask of the app. build.sh
/// compiles that file alone, to extract the intents' metadata, with a stub of
/// this enum; the real one lives here, where the browser is.
enum SystemIntentsBridge {
    static let enabledKey = "ai.siri.enabled"

    /// Settings › AI › Siri & App Intents. Off until the person turns it on.
    static var siriEnabled: Bool { Store.settings.bool(forKey: enabledKey) }

    /// A voice request is something the person asked for: allowed unless AI
    /// is off.
    static var aiAllowed: Bool { AIUse.allows(.asked) }

    /// In a sentence or two, what the page in front is about. The model on
    /// this Mac writes it: the page goes nowhere else.
    @MainActor
    static func summarizeFrontPage() async throws -> String {
        guard let browser = BrowserWindows.shared.activeBrowser ?? Links.browser, let tab = browser.active else {
            throw SystemIntentError.noActivePage
        }
        guard !browser.privateBrowsing, !tab.shy else { throw SystemIntentError.privatePage }
        guard let page = tab.builtPage else { throw SystemIntentError.asleepPage }
        guard let url = page.url, Bookmark.keepable(url) else { throw SystemIntentError.noActivePage }

        // Bounded in the page, so a long one is not carried across whole.
        let script = "(document.body ? document.body.innerText : '').slice(0, 3000)"
        let text = (try? await page.evaluate(.expression(script), in: .page, frame: nil, gesture: false) as? String) ?? ""
        let title = tab.title.isEmpty ? Address.pretty(url) : tab.title
        let content = LinkSummary.Page(title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let gist = await LinkSummary.gist(content) else { throw SystemIntentError.noSummary }
        return gist
    }
}
