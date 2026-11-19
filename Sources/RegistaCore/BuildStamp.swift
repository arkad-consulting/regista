import Foundation

/// Which build of Regista this binary is: the git short sha it was built from, with "-dirty.<hash of the
/// uncommitted changes>" when the tree was not clean, and the commit's time (to tell which of two builds is older).
/// The app, regista-mcp and regista-engine carry the same stamp when built by the scripts, so a mismatch between
/// the running app and the MCP server can be named (issue #45).
///
/// The values come from `BuildStamp.generated.swift` (gitignored), written by `scripts/build-stamp.sh` before
/// `scripts/build-app.sh` and `scripts/build-mcp.sh` compile. Without it (a plain `swift build`, `swift test`)
/// the id is "dev". A plain build after new commits keeps the last generated values: build with the scripts.
public struct BuildStamp: Equatable, Sendable {
    public var id: String
    /// Unix seconds of the commit the build comes from; nil when unknown.
    public var commitTime: Int?

    public init(id: String, commitTime: Int? = nil) {
        self.id = id
        self.commitTime = commitTime
    }

    public static let unstamped = "dev"
    public static let current = BuildStamp(id: BuildStampValues.id, commitTime: BuildStampValues.commitTime)

    /// What to rebuild when the app and regista-mcp come from different builds.
    public enum Mismatch: Equatable, Sendable {
        case rebuildApp, rebuildMCP, rebuildBoth
    }

    /// nil when both are the same build. A missing (nil) stamp means a build from before build ids, so that side is
    /// the older one; an unstamped ("dev") side is the one to rebuild; otherwise the older commit loses, and two
    /// builds of the same commit with different uncommitted changes both need rebuilding.
    public static func mismatch(app: BuildStamp?, mcp: BuildStamp?) -> Mismatch? {
        guard let app else { return mcp == nil ? nil : .rebuildApp }
        guard let mcp else { return .rebuildMCP }
        if app.id == mcp.id { return nil }
        if app.id == unstamped { return .rebuildApp }
        if mcp.id == unstamped { return .rebuildMCP }
        if let a = app.commitTime, let m = mcp.commitTime, a != m { return a < m ? .rebuildApp : .rebuildMCP }
        return .rebuildBoth
    }

    /// The plain-English warning engines.status carries, nil when the builds match.
    public static func warning(app: BuildStamp?, mcp: BuildStamp?) -> String? {
        guard let m = mismatch(app: app, mcp: mcp) else { return nil }
        let a = "the Regista app (build \(app?.id ?? "from before build ids"))", s = "regista-mcp (build \(mcp?.id ?? "from before build ids"))"
        // A downloaded app (#113): the two come from different copies of Regista, and no source folder can rebuild them.
        let copies = "\(a) and \(s) come from different copies of Regista: in Regista › Settings › Claude, reconnect Claude to this app (or install the newest Regista from its disk image), then restart the Claude session."
        switch m {
        case .rebuildApp:
            return ReleaseBuild.sourceHint("\(a) is older than \(s): quit Regista, run scripts/build-app.sh --install, then reopen it.", release: copies)
        case .rebuildMCP:
            return ReleaseBuild.sourceHint("\(s) is older than \(a): run scripts/build-mcp.sh, then restart the Claude session so it relaunches the MCP server.", release: copies)
        case .rebuildBoth:
            return ReleaseBuild.sourceHint("\(a) and \(s) differ (same commit with different uncommitted changes, or a commit time is unknown): run scripts/build-app.sh --install (it rebuilds regista-mcp too), reopen Regista and restart the Claude session.", release: copies)
        }
    }

    /// The error for a command the running app does not know: it is older than the MCP server that sent it.
    public static func unknownInApp(_ command: String, app: BuildStamp?, mcp: BuildStamp?) -> String {
        "The Regista app (build \(app?.id ?? "from before build ids")) does not know '\(command)': it is older than the MCP server "
            + "(build \(mcp?.id ?? "?")). " + ReleaseBuild.sourceHint("Quit Regista, run scripts/build-app.sh --install (or scripts/install.sh), then reopen it.", release: "Install the newest Regista from its disk image, then reconnect Claude to it in Regista › Settings › Claude.")
    }

    /// As sent in the socket hello and in engines.status.
    public var json: [String: JSONValue] {
        var o: [String: JSONValue] = ["build": .string(id)]
        if let commitTime { o["buildCommitTime"] = .number(Double(commitTime)) }
        return o
    }

    /// From a hello or an engines.status reply; nil when it has no "build" (a binary from before build ids).
    public init?(json: JSONValue?) {
        guard let id = json?["build"]?.stringValue else { return nil }
        self.init(id: id, commitTime: json?["buildCommitTime"]?.doubleValue.map { Int($0) })
    }
}

/// The generated file adds `id` / `commitTime` to `BuildStampValues` itself; a member of the type wins over these
/// protocol defaults, so the fallback applies only when the file is absent.
protocol BuildStampDefaults {}
extension BuildStampDefaults {
    static var id: String { BuildStamp.unstamped }
    static var commitTime: Int? { nil }
}
enum BuildStampValues: BuildStampDefaults {}
