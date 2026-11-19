import Foundation

/// Whether this process belongs to a release build (#113): the `RegistaRelease` key scripts/build-app.sh writes in the app's
/// Info.plist under REGISTA_RELEASE (scripts/release.sh). The app, and regista-mcp / regista-engine in its Contents/MacOS,
/// read the app's Info.plist through Bundle.main. A downloaded app has no source folder: what it tells a person (an error a
/// job line shows, a hint Claude relays) never names one of its scripts.
public enum ReleaseBuild {
    public static func isRelease(_ bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: "RegistaRelease") as? Bool) == true
    }

    /// `source` (a hint that names a script of the source folder) in a build of that folder, `release` in a release build.
    public static func sourceHint(_ source: String, release: String = "", isRelease: Bool = isRelease()) -> String {
        isRelease ? release : source
    }
}
