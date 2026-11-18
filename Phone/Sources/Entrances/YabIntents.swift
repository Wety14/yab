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

/// Summarizes the web page in front in Yab, with the model on this iPhone.
/// The words stay on the iPhone, but Siri shows or speaks the answer: so it
/// asks for Face ID first (as the task buttons do) and never reads a private tab.
struct SummarizeCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Current Page"
    static let description = IntentDescription("Summarize the web page currently open in Yab.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try YabIntentsGuard.checkEnabled()

        guard let front = Entrances.pageInFront() else { throw YabIntentError.noActivePage }
        try PageSummary.check(url: front.tab.navigationURL ?? URL(string: front.tab.address), isPrivate: front.isPrivate)
        // A page that is not loaded has only its title to read: not a summary.
        guard front.pages.isLive(front.tab.id) else { throw YabIntentError.pageNotRead }
        let model = OnDeviceModel()
        guard model.isAvailable else { throw YabIntentError.noModel }

        let page = await PageText.read(front.tab, pool: front.pages)
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let ask = AskContext(question: PageSummary.question(languageCode: language), page: page, history: [])
        guard let summary = try? await model.answer(ask), !summary.isEmpty else { throw YabIntentError.noSummary }
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// What may be summarized, and how it is asked for.
enum PageSummary {
    /// A web page that is not private; else why not.
    static func check(url: URL?, isPrivate: Bool) throws {
        guard !isPrivate else { throw YabIntentError.privatePage }
        guard let url, SharedItems.isWeb(url) else { throw YabIntentError.noActivePage }
    }

    /// The question, in the person's language: the model answers in the
    /// language it is told, else in the question's own, which is English.
    static func question(languageCode: String?) -> String {
        let base = "Summarize this page in two or three plain sentences."
        guard let languageCode, let name = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) else { return base }
        return base + " Answer in \(name)."
    }
}

/// Siri, Shortcuts and Spotlight reach Yab only while Settings allows it.
enum YabIntentsGuard {
    @MainActor
    static func checkEnabled(in store: SettingsStore = .shared) throws {
        guard store.siriAppIntents else { throw YabIntentError.disabled }
    }
}

enum YabIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notWeb
    case disabled
    case noActivePage
    case privatePage
    case pageNotRead
    case noModel
    case noSummary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notWeb: "Yab opens web pages: links that start with http or https."
        case .disabled: "Siri App Intents are disabled in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        case .privatePage: "Yab does not summarize private tabs."
        case .pageNotRead: "Open the page in Yab first, then ask again."
        case .noModel: "Summaries need Apple Intelligence on this iPhone."
        case .noSummary: "Yab could not summarize this page."
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
