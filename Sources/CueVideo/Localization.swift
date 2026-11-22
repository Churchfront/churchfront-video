import SwiftUI

// Every text the app shows is in Resources/Localizable.xcstrings, keyed by its English words,
// with its translations. See docs/localization.md for how to write and translate texts.
//
// - A literal passed to Text, Button, .help, or to the app's own views (LabelText, PillButton,
//   Card, Tag …, which take a LocalizedStringKey) is looked up and translated.
// - Words in code that aren't views use String(localized: "…").
// - Names people typed or the hardware reports (sources, cameras, shots, screens, NDI names,
//   addresses) are never translated: pass them as .verbatim(name).

extension LocalizedStringKey {
    /// Shown exactly as it is, never translated: a name from the setup or the switcher, a number, an address.
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}

/// The language the app is shown in. System follows the Mac's own language order; the others
/// override it for this app only (in its own preferences, AppleLanguages), from the next start.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, de
    var id: String { rawValue }

    /// Each language in its own words, so someone who can't read the current one still finds theirs.
    var name: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .en: return .verbatim("English")
        case .de: return .verbatim("Deutsch")
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Saves the choice. It takes effect the next time the app opens.
    func choose() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }

    /// The language the app is showing right now (it only changes when the app starts).
    static var showing: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Only an app bundle can open itself again; `swift run` can't.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens the app again, so a new language takes effect. The new copy starts
    /// once this one has quit (and stopped its cameras), so the two never run together.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
