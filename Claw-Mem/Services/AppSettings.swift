import Foundation

enum SummaryLanguage: String, CaseIterable, Identifiable {
    case zhTW = "繁體中文"
    case zhCN = "簡體中文"
    case en = "English"
    case ja = "日本語"

    var id: String { rawValue }
}

@Observable @MainActor
final class AppSettings {
    var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "geminiModel") }
    }
    var summaryLanguage: SummaryLanguage {
        didSet { UserDefaults.standard.set(summaryLanguage.rawValue, forKey: "summaryLanguage") }
    }
    var watchPath: String {
        didSet { UserDefaults.standard.set(watchPath, forKey: "watchPath") }
    }
    var syncFolderPath: String {
        didSet { UserDefaults.standard.set(syncFolderPath, forKey: "syncFolderPath") }
    }

    /// Stable per-install identifier used to scope per-device sync log files
    /// (e.g., `log.{deviceID}.jsonl`) so two machines never overwrite each
    /// other's append-only records.
    let deviceID: String

    var geminiAPIKey: String {
        get { KeychainManager.load(key: "geminiAPIKey") ?? "" }
        set { _ = KeychainManager.save(key: "geminiAPIKey", value: newValue) }
    }

    var hasAPIKey: Bool { !geminiAPIKey.isEmpty }

    init() {
        let saved = UserDefaults.standard.string(forKey: "geminiModel")
        let supported = [
            "gemini-3.1-flash-lite-preview",
            "gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.0-flash-lite",
            "gemini-1.5-flash", "gemini-1.5-pro", "gemma-4-31b-it",
        ]
        if let saved, supported.contains(saved) {
            self.geminiModel = saved
        } else {
            self.geminiModel = "gemini-3.1-flash-lite-preview"
            UserDefaults.standard.set("gemini-3.1-flash-lite-preview", forKey: "geminiModel")
        }
        let langStr = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "繁體中文"
        self.summaryLanguage = SummaryLanguage(rawValue: langStr) ?? .zhTW
        self.watchPath = UserDefaults.standard.string(forKey: "watchPath")
            ?? (NSHomeDirectory() + "/.claude/projects")
        self.syncFolderPath = UserDefaults.standard.string(forKey: "syncFolderPath") ?? ""

        if let existing = UserDefaults.standard.string(forKey: "deviceID") {
            self.deviceID = existing
        } else {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: "deviceID")
            self.deviceID = new
        }
    }
}
