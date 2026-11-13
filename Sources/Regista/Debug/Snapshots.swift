import AppKit

/// Developer flag `--snapshot-dir <dir>`: every second the app writes a PNG of each of its
/// windows (main window, teleprompter). Lets us check the UI without screen-recording rights.
@MainActor
enum DebugSnapshots {
    private static var timer: Timer?

    static func startIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot-dir"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in capture(into: dir) }
        }
    }

    private static func capture(into dir: URL) {
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(n)" : window.title
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
