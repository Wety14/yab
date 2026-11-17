import AppIntents
import Foundation

/// Errors thrown by Yab App Intents for Siri and Shortcuts.
enum SystemIntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case disabled
    case noActivePage

    var errorDescription: String? {
        switch self {
        case .disabled: "Siri App Intents are disabled in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled: "Siri App Intents are disabled in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        }
    }
}

/// Helper gate verifying whether Siri & App Intents are enabled in Settings.
enum SystemIntentsGuard {
    static func checkEnabled() throws {
        guard Store.settings.bool(forKey: "ai.siri.enabled") else {
            throw SystemIntentError.disabled
        }
    }
}

/// Actions for the macOS Shortcuts app and Siri. The app's URL and window handoff
/// already handles calls made before its first browser window exists.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Yab"
    static let description = IntentDescription("Open a web address in Yab.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Web Address") var address: URL

    func perform() async throws -> some IntentResult {
        try SystemIntentsGuard.checkEnabled()
        guard Bookmark.keepable(address) else { throw OpenPageError.invalidAddress }
        await MainActor.run { Links.take(address) }
        return .result()
    }
}

private enum OpenPageError: Error, LocalizedError {
    case invalidAddress
    var errorDescription: String? { "Enter an HTTP or HTTPS web address." }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab in Yab"
    static let description = IntentDescription("Open a new tab in Yab.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        try SystemIntentsGuard.checkEnabled()
        await MainActor.run { Links.requestNewTab() }
        return .result()
    }
}

/// Summarizes the web page currently in front in Yab.
struct SummarizePageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Page in Yab"
    static let description = IntentDescription("Summarize the web page currently open in Yab.")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SystemIntentsGuard.checkEnabled()

        guard let activeTab = (BrowserWindows.shared.activeBrowser ?? Links.browser)?.active,
              let page = activeTab.builtPage,
              let url = page.url else {
            throw SystemIntentError.noActivePage
        }

        let title = activeTab.title.isEmpty ? Address.pretty(url) : activeTab.title
        var bodyText = ""
        if let text = try? await page.evaluate(.expression("document.body ? document.body.innerText : ''"), in: .page, frame: nil, gesture: false) as? String {
            bodyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pageSummary: String
        if let gist = await LinkSummary.gist(LinkSummary.Page(title: title, text: bodyText)) {
            pageSummary = gist
        } else if !bodyText.isEmpty {
            let snippet = bodyText.prefix(280).trimmingCharacters(in: .whitespacesAndNewlines)
            pageSummary = "\(title): \(snippet)"
        } else {
            pageSummary = "\(title): \(Address.pretty(url))"
        }

        return .result(dialog: IntentDialog(stringLiteral: pageSummary))
    }
}

/// The voice shortcuts Siri offers without a shortcut being manually created.
struct YabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizePageIntent(),
            phrases: [
                "Summarize this page in \(.applicationName)",
                "Summarize page in \(.applicationName)"
            ],
            shortTitle: "Summarize Page",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: NewTabIntent(),
            phrases: [
                "New tab in \(.applicationName)",
                "Open a new tab in \(.applicationName)"
            ],
            shortTitle: "New Tab",
            systemImageName: "plus"
        )
        AppShortcut(
            intent: OpenPageIntent(),
            phrases: [
                "Open page in \(.applicationName)",
                "Open a link in \(.applicationName)"
            ],
            shortTitle: "Open Page",
            systemImageName: "link"
        )
    }
}
