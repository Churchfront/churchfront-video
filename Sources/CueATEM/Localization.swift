import Foundation

// Messages people see from the engine (a camera turned down the login, the switcher stopped
// answering) are translated with the rest of the app: Resources/Localizable.xcstrings, read
// with String(localized: "…", bundle: .cueATEM). The command log stays in English.

extension Bundle {
    /// The engine's translations. Inside an app the bundle is copied into Contents/Resources
    /// (build.sh does it); `swift run` and `swift test` find it where SwiftPM built it.
    public static let cueATEM: Bundle = {
        let name = "CueVideo_CueATEM.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return .module
    }()
}
