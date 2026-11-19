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
/// The words stay on the iPhone, but Siri shows or speaks the answer, so a
/// private tab is never read. It needs an unlocked iPhone, and it is a choice
/// of its own in Settings (off until turned on), apart from the Open, Search
/// and Private Tab intents that keep working as before.
struct SummarizeCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Current Page"
    static let description = IntentDescription("Summarize the web page currently open in Yab.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let summary = try await PageSummary.run(.live, languageCode: language)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// What may be summarized, and how it is asked for.
@MainActor
enum PageSummary {
    /// The tab in front, as the summary sees it.
    struct Front: Equatable, Sendable {
        var tab: Tab.ID
        var url: URL?
        var isPrivate: Bool
        /// Its web view is loaded: a page that is not has only its title.
        var isLoaded: Bool
    }

    /// Where the summary gets the page, the model and its readiness, so each
    /// can be stood in for in a test.
    struct Source {
        var front: () -> Front?
        var readiness: () -> OnDeviceModel.Readiness
        /// The page's words, or nil when there is no page any more.
        var read: (Front) async -> PageContext?
        var answer: (AskContext) async throws -> String

        static var live: Source {
            Source(
                front: {
                    Entrances.pageInFront().map {
                        Front(tab: $0.tab.id,
                              url: $0.tab.navigationURL ?? URL(string: $0.tab.address),
                              isPrivate: $0.isPrivate,
                              isLoaded: $0.pages.isLive($0.tab.id))
                    }
                },
                readiness: { OnDeviceModel().readiness },
                read: { front in
                    guard let now = Entrances.pageInFront(), now.tab.id == front.tab else { return nil }
                    return await PageText.read(now.tab, pool: now.pages)
                },
                answer: { try await OnDeviceModel().answer($0) })
        }
    }

    /// The summary, or why not. Every gate is checked before the page is
    /// read and again after each wait (the page, the model), and a cancelled
    /// run stops there, so Siri is never handed a dialog the person has
    /// since cancelled, turned off, or navigated away from.
    static func run(_ source: Source, settings: SettingsStore = .shared, languageCode: String?) async throws -> String {
        let front = try admit(source, settings)
        try Task.checkCancellation()

        guard let page = await source.read(front) else { throw YabIntentError.noActivePage }
        try Task.checkCancellation()
        try stillAdmitted(front, source, settings)

        let ask = AskContext(question: question(languageCode: languageCode), page: page, history: [])
        let summary: String
        do {
            summary = try await source.answer(ask)
        } catch {
            // A cancelled model call is a cancellation, not "could not summarize".
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw YabIntentError.noSummary
        }
        try Task.checkCancellation()
        try stillAdmitted(front, source, settings)

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YabIntentError.noSummary }
        return trimmed
    }

    /// The tab in front when every gate is open; else why not.
    private static func admit(_ source: Source, _ settings: SettingsStore) throws -> Front {
        try YabIntentsGuard.checkEnabled(in: settings)
        try YabIntentsGuard.checkPageSummaryEnabled(in: settings)
        guard let front = source.front() else { throw YabIntentError.noActivePage }
        try check(url: front.url, isPrivate: front.isPrivate)
        // A page that is not loaded has only its title to read: not a summary.
        guard front.isLoaded else { throw YabIntentError.pageNotRead }
        switch source.readiness() {
        case .ready: break
        case .appleIntelligenceOff: throw YabIntentError.appleIntelligenceOff
        case .unavailable: throw YabIntentError.noModel
        }
        return front
    }

    /// The same gates after a wait, and the same page in front.
    private static func stillAdmitted(_ front: Front, _ source: Source, _ settings: SettingsStore) throws {
        let now = try admit(source, settings)
        guard now.tab == front.tab, now.url == front.url else { throw YabIntentError.pageChanged }
    }

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
    /// Open, Search, Private Tab and the rest: on unless turned off.
    @MainActor
    static func checkEnabled(in store: SettingsStore = .shared) throws {
        guard store.siriAppIntents else { throw YabIntentError.disabled }
    }

    /// Reading a page: only once the person has turned it on.
    @MainActor
    static func checkPageSummaryEnabled(in store: SettingsStore = .shared) throws {
        guard store.siriPageSummary else { throw YabIntentError.summaryDisabled }
    }
}

enum YabIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notWeb
    case disabled
    case summaryDisabled
    case noActivePage
    case privatePage
    case pageNotRead
    case pageChanged
    case appleIntelligenceOff
    case noModel
    case noSummary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notWeb: "Yab opens web pages: links that start with http or https."
        case .disabled: "Siri App Intents are disabled in Yab Settings."
        case .summaryDisabled: "Summarizing pages with Siri is off. Turn it on in Yab Settings, under AI."
        case .noActivePage: "There is no open web page to summarize."
        case .privatePage: "Yab does not summarize private tabs."
        case .pageNotRead: "Open the page in Yab first, then ask again."
        case .pageChanged: "The page changed while it was being read. Ask again."
        case .appleIntelligenceOff: "Apple Intelligence is turned off on this iPhone. Turn it on in Settings, then ask again."
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
