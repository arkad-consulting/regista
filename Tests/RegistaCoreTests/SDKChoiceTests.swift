import Foundation
import Testing
@testable import RegistaCore

// #136: without Xcode, the build picks a macOS SDK of the Command Line Tools it can build SwiftUI with (scripts/lib.sh
// swift_sdk). The macOS 27 SDK declares @State as a macro whose plugin ships only with Xcode, while the same tools carry
// the 26.5 SDK, which builds. Stand-in xcode-select and xcrun: a tools folder with three SDKs and the links Apple ships.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A tools folder with MacOSX27.0, 26.5 and 15.4 SDKs (MacOSX.sdk → 27.0, MacOSX27.sdk → 27.0, MacOSX26.sdk → 26.5) and
/// stand-in tools on a bin folder: xcrun's swiftc fails for the SDKs named in FAKE_FAILS and logs each probe.
private func tools() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("regista-sdk-\(UUID().uuidString)", isDirectory: true)
    let sdks = root.appendingPathComponent("dev/SDKs"), bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for v in ["27.0", "26.5", "15.4"] {
        let sdk = sdks.appendingPathComponent("MacOSX\(v).sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Version": v], format: .xml, options: 0)
        try plist.write(to: sdk.appendingPathComponent("SDKSettings.plist"))
    }
    for (link, target) in [("MacOSX.sdk", "MacOSX27.0.sdk"), ("MacOSX27.sdk", "MacOSX27.0.sdk"), ("MacOSX26.sdk", "MacOSX26.5.sdk")] {
        try FileManager.default.createSymbolicLink(atPath: sdks.appendingPathComponent(link).path, withDestinationPath: target)
    }
    let scripts = [
        "xcode-select": "#!/bin/bash\necho \"$FAKE_DEV\"\n",
        "xcrun": """
        #!/bin/bash
        case "$1" in
          --show-sdk-path) echo "$FAKE_DEV/SDKs/MacOSX.sdk" ;;
          swiftc)
            [ "$2" = --version ] && { echo "Apple Swift version 6.4"; exit 0; }
            echo "${4##*/}" >>"$FAKE_CALLS"
            real="$(cd "$4" && pwd -P)"
            case " $FAKE_FAILS " in *" ${real##*/} "*) echo "error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found" >&2; exit 1 ;; esac ;;
        esac

        """,
    ]
    for (name, text) in scripts {
        let file = bin.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    return root
}

private struct Choice: Equatable { var status: Int32; var sdk: String; var note: String; var probes: [String] }

/// swift_sdk run with the stand-in tools; `cache` names the verdict folder (the same name: a later build).
private func choose(_ root: URL, fails: [String], cache: String, sdkroot: String = "", developer: String? = nil) throws -> Choice {
    let calls = root.appendingPathComponent("calls-\(cache)")
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"),
                               ["-c", ". \"$0/scripts/lib.sh\"; swift_sdk; s=$?; printf '%s|%s|%s' \"$s\" \"${SDKROOT:-}\" \"$SWIFT_SDK_NOTE\"", repo.path],
                               environment: ["FAKE_DEV": developer ?? root.appendingPathComponent("dev").path, "FAKE_FAILS": fails.joined(separator: " "),
                                             "FAKE_CALLS": calls.path, "SDKROOT": sdkroot,
                                             "REGISTA_SDK_PROBE_DIR": root.appendingPathComponent("cache-\(cache)").path,
                                             "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"])
    let parts = r.stdoutText.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let probes = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let sdk = parts.count > 1 ? parts[1] : "?"
    return Choice(status: Int32(parts.first ?? "") ?? -1, sdk: sdk.isEmpty ? "" : String(sdk.split(separator: "/").last ?? ""),
                  note: parts.count > 2 ? parts[2] : "?", probes: probes)
}

@Test func theNewestSDKThatBuildsSwiftUIIsChosen() throws {
    let root = try tools()
    defer { try? FileManager.default.removeItem(at: root) }
    // The default (27.0) cannot expand @State: 26.5 is chosen, by its real folder, and 15.4 is never tried.
    let first = try choose(root, fails: ["MacOSX27.0.sdk"], cache: "a")
    #expect(first == Choice(status: 0, sdk: "MacOSX26.5.sdk", note: "macOS 26.5 SDK", probes: ["MacOSX.sdk", "MacOSX26.5.sdk"]), "\(first)")
    // A later build reads the verdicts: no probe runs again.
    let again = try choose(root, fails: ["MacOSX27.0.sdk"], cache: "a")
    #expect(again.sdk == "MacOSX26.5.sdk" && again.probes == first.probes, "\(again)")
    // The default builds: nothing is exported, one probe.
    let fine = try choose(root, fails: [], cache: "b")
    #expect(fine == Choice(status: 0, sdk: "", note: "", probes: ["MacOSX.sdk"]), "\(fine)")
}

@Test func noSDKThatBuildsSwiftUIStopsTheBuild() throws {
    let root = try tools()
    defer { try? FileManager.default.removeItem(at: root) }
    let none = try choose(root, fails: ["MacOSX27.0.sdk", "MacOSX26.5.sdk", "MacOSX15.4.sdk"], cache: "c")
    #expect(none.status == 1 && none.sdk == "" && none.probes == ["MacOSX.sdk", "MacOSX26.5.sdk", "MacOSX15.4.sdk"], "\(none)")
    // The installer then says to install Xcode, in the person's language.
    for (lang, word) in [("en", "Xcode"), ("it", "Xcode"), ("fr", "Xcode"), ("pt", "Xcode")] {
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$0/scripts/lib.sh\"; t sdk_needs_xcode", repo.path],
                                   environment: ["REGISTA_LANG": lang])
        #expect(r.stdoutText.contains(word) && r.stdoutText.contains("App Store"), "\(lang): \(r.stdoutText)")
    }
}

@Test func anSDKThePersonChoseOrXcodeIsKept() throws {
    let root = try tools()
    defer { try? FileManager.default.removeItem(at: root) }
    let chosen = try choose(root, fails: ["MacOSX27.0.sdk"], cache: "d", sdkroot: "/somewhere/MacOSX99.sdk")
    #expect(chosen == Choice(status: 0, sdk: "MacOSX99.sdk", note: "", probes: []), "\(chosen)")
    let xcode = try choose(root, fails: ["MacOSX27.0.sdk"], cache: "e", developer: "/Applications/Xcode.app/Contents/Developer")
    #expect(xcode == Choice(status: 0, sdk: "", note: "", probes: []), "\(xcode)")
}

/// Every build path asks for the SDK before it builds: the installer's preflight, the app and server builds, the tests
/// and the commit hook.
@Test func everyBuildPathChoosesTheSDK() throws {
    for file in ["scripts/install.sh", "scripts/build-app.sh", "scripts/build-mcp.sh", "scripts/test.sh", ".githooks/pre-commit"] {
        let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
        #expect(text.contains("swift_sdk"), "\(file) builds without choosing the SDK")
    }
}
