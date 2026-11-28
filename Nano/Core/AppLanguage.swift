import AppKit
import Foundation

/// The language Nano shows its interface in. `.system` follows macOS; the
/// others pin Nano alone through its own `AppleLanguages` default, the same
/// setting System Settings › Language & Region › Applications writes.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Language names stay in their own language so either can be found
    /// whatever the interface currently shows.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    /// The choice stored in Nano's own defaults domain. A global
    /// `AppleLanguages` is the macOS language, so it reads as `.system`.
    static func current(
        defaults: UserDefaults = .standard,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> AppLanguage {
        guard let bundleID,
              let languages = defaults.persistentDomain(forName: bundleID)?[defaultsKey] as? [String],
              let first = languages.first
        else { return .system }
        return choice(for: first)
    }

    static func choice(for code: String) -> AppLanguage {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return AppLanguage(rawValue: base).flatMap { $0 == .system ? nil : $0 } ?? .system
    }

    /// The language the running interface was resolved to at launch.
    static var running: AppLanguage {
        choice(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    func store(in defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.defaultsKey)
        case .english, .turkish: defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// Opens a fresh copy of Nano once this one has quit, then quits. Bundle
    /// strings are fixed at launch, so a relaunch is how macOS apps switch.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                             String(ProcessInfo.processInfo.processIdentifier), path]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
