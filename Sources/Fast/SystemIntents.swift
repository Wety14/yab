import AppIntents
import Foundation

// build.sh compiles this file alone to extract the App Intents metadata, with
// a stub of what it names beside it. Anything the intents need from the app
// goes through SystemIntentsBridge (SystemIntentsBridge.swift), so the stub
// stays short.

/// Why an intent could not answer, in the words Siri and Shortcuts say.
enum SystemIntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case disabled
    case aiOff
    case noActivePage
    case privatePage
    case asleepPage
    case noSummary

    var errorDescription: String? {
        switch self {
        case .disabled: "Siri & App Intents is off in Yab Settings."
        case .aiOff: "AI is turned off in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        case .privatePage: "Yab does not read private tabs."
        case .asleepPage: "That tab is asleep. Switch to it in Yab, then try again."
        case .noSummary: "Yab could not summarize this page on this Mac."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled: "Siri & App Intents is off in Yab Settings."
        case .aiOff: "AI is turned off in Yab Settings."
        case .noActivePage: "There is no open web page to summarize."
        case .privatePage: "Yab does not read private tabs."
        case .asleepPage: "That tab is asleep. Switch to it in Yab, then try again."
        case .noSummary: "Yab could not summarize this page on this Mac."
        }
    }
}

/// What reading a page by voice needs: the switch in Settings › AI, and AI
/// itself being on.
enum SystemIntentsGuard {
    static func checkSummaryAllowed() throws {
        guard SystemIntentsBridge.siriEnabled else { throw SystemIntentError.disabled }
        guard SystemIntentsBridge.aiAllowed else { throw SystemIntentError.aiOff }
    }
}

/// Actions for the macOS Shortcuts app. The app's URL and window handoff
/// already handles calls made before its first browser window exists.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Yab"
    static let description = IntentDescription("Open a web address in Yab.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Web Address") var address: URL

    func perform() async throws -> some IntentResult {
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
        await MainActor.run { Links.requestNewTab() }
        return .result()
    }
}

/// Says what the web page in front in Yab is about, from the model on this
/// Mac. Never a private tab, and only with Siri & App Intents and AI on.
struct SummarizePageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Page in Yab"
    static let description = IntentDescription("Summarize the web page currently open in Yab.")
    static var openAppWhenRun: Bool { false }
    // The page in front is read aloud: not on a Mac that is locked.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SystemIntentsGuard.checkSummaryAllowed()
        let summary = try await SystemIntentsBridge.summarizeFrontPage()
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// The voice shortcuts Siri offers without a shortcut being made by hand.
/// Open Page stays in the Shortcuts app: it needs an address, and nobody
/// says one aloud.
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
    }
}
