import AppIntents
import Foundation

/// Yab in Shortcuts, Siri and Spotlight: open a web page, search, a private
/// tab. Each opens Yab and does what its own control does there (Entrances):
/// a page opens as a tab, as a link from another app, words are searched as New
/// Tab's field searches them, a private tab is New Tab with the eyes shut.
struct OpenURLInYabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL in Yab"
    static let description = IntentDescription("Opens a web page in Yab over whatever is on screen, as a link from another app does. Keep makes it a tab.")
    static let openAppWhenRun = true

    @Parameter(title: "URL") var url: URL

    init() {}

    init(url: URL) {
        self.url = url
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in Yab")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try YabIntentsGuard.checkEnabled()
        guard SharedItems.isWeb(url) else { throw YabIntentError.notWeb }
        Entrances.perform(.open(url))
        return .result()
    }
}

struct SearchInYabIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Yab"
    static let description = IntentDescription("Searches the web in a new Yab tab with the search engine chosen in Yab\u{2019}s Settings. An address opens that page.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", requestValueDialog: IntentDialog("What do you want to search for?")) var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$text) in Yab")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try YabIntentsGuard.checkEnabled()
        Entrances.perform(.search(text))
        return .result()
    }
}

struct NewPrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Tab"
    static let description = IntentDescription("Opens Yab\u{2019}s New Tab with the eyes shut: nothing typed or opened is kept. Asks for Face ID first when Private is locked.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try YabIntentsGuard.checkEnabled()
        Entrances.perform(.route(.privateTab))
        return .result()
    }
}

/// Summarizes the web page currently in front in Yab.
struct SummarizeCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Current Page"
    static let description = IntentDescription("Summarize the web page currently open in Yab.")
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try YabIntentsGuard.checkEnabled()

        guard let app = Entrances.attachedApp,
              let activeTab = app.browser.tab,
              let url = activeTab.navigationURL ?? URL(string: activeTab.address) else {
            throw YabIntentError.noActivePage
        }

        let context = await PageText.read(activeTab, pool: app.pages)
        let title = activeTab.title.isEmpty ? url.absoluteString : activeTab.title
        let pageSummary: String

        let model = OnDeviceModel()
        let ask = AskContext(
            question: "Summarize this page in two or three plain sentences.",
            page: context,
            history: []
        )
        if model.isAvailable, let answered = try? await model.answer(ask), !answered.isEmpty {
            pageSummary = answered
        } else if !context.text.isEmpty {
            let snippet = context.text.prefix(280).trimmingCharacters(in: .whitespacesAndNewlines)
            pageSummary = "\(title): \(snippet)"
        } else {
            pageSummary = "\(title): \(url.absoluteString)"
        }

        return .result(dialog: IntentDialog(stringLiteral: pageSummary))
    }
}

/// Helper gate verifying whether Siri & App Intents are enabled in Settings.
enum YabIntentsGuard {
    static func checkEnabled() throws {
        guard UserDefaults.standard.bool(forKey: "ai.siri.enabled") else {
            throw YabIntentError.disabled
        }
    }
}

enum YabIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notWeb
    case disabled
    case noActivePage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notWeb: "Yab opens web pages: links that start with http or https."
        case .disabled: "Siri App Intents are disabled in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        }
    }
}

/// The intents Siri and Spotlight offer without a shortcut being made.
/// Their pictures are the system's symbols: App Shortcuts take no others.
struct YabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SummarizeCurrentPageIntent(), phrases: [
            "Summarize this page in \(.applicationName)",
            "Summarize page in \(.applicationName)",
        ], shortTitle: "Summarize Page", systemImageName: "doc.text")
        AppShortcut(intent: SearchInYabIntent(), phrases: [
            "Search in \(.applicationName)",
            "Search the web in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: NewPrivateTabIntent(), phrases: [
            "New private tab in \(.applicationName)",
            "Open a private tab in \(.applicationName)",
        ], shortTitle: "New Private Tab", systemImageName: "eyeglasses")
        AppShortcut(intent: OpenURLInYabIntent(), phrases: [
            "Open a link in \(.applicationName)",
        ], shortTitle: "Open URL", systemImageName: "link")
    }
}
