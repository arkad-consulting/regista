import Foundation
import Testing

// #135: a file imports the system framework whose symbols it names. A framework that arrives only through another
// import (CoreText through CoreGraphics or CoreImage) builds with one SDK and not with the next: the macOS 27 SDK stopped
// handing CoreText on, and one motion template no longer compiled. This scan of Sources and Tests catches the next one
// with whatever SDK builds it. Comments and string contents are ignored (a name in a doc comment is not a use).

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The frameworks checked: the symbols that are theirs, and the imports that hand them on by contract (the framework
/// itself; AVFoundation is built on CoreMedia and CoreVideo and always exports them).
private let frameworks: [(name: String, symbols: String, imports: Set<String>)] = [
    ("CoreText", #"CT(Font|Line|Frame|Run|Framesetter|ParagraphStyle|Typesetter)\w*|kCT[A-Z]\w*"#, ["CoreText"]),
    ("ImageIO", #"CGImage(Source|Destination|Metadata)\w*|kCGImage(Property|Destination|Source)\w*"#, ["ImageIO"]),
    ("CoreImage", #"CI(Image|Filter|Context|Color|Vector|Kernel|ColorKernel|Sampler)\b"#, ["CoreImage", "CoreImage.CIFilterBuiltins"]),
    ("Vision", #"VN[A-Z]\w*"#, ["Vision"]),
    ("Accelerate", #"vDSP\w*|vImage\w*"#, ["Accelerate"]),
    ("UniformTypeIdentifiers", #"UTType\b"#, ["UniformTypeIdentifiers"]),
    ("ScreenCaptureKit", #"SC(Stream|ShareableContent|ContentFilter|Display|Window|RunningApplication|ScreenshotManager)\w*"#, ["ScreenCaptureKit"]),
    ("Speech", #"SF(SpeechRecognizer|SpeechAudioBufferRecognitionRequest|SpeechURLRecognitionRequest|SpeechRecognitionTask|SpeechRecognitionResult|Transcription)\w*"#, ["Speech"]),
    ("CoreMedia", #"CM(Time|TimeRange|SampleBuffer|FormatDescription|BlockBuffer|VideoFormatDescription|AudioFormatDescription)\w*|kCM[A-Z]\w*"#, ["CoreMedia", "AVFoundation", "AVKit"]),
    ("CoreVideo", #"CV(PixelBuffer|ImageBuffer|PixelBufferPool)\w*|kCVPixel\w*"#, ["CoreVideo", "AVFoundation", "AVKit"]),
    ("AVFoundation", #"AV(Asset|URLAsset|Player|Capture|Mutable|VideoComposition|AudioEngine|AudioPCMBuffer|AudioFile|AudioFormat|AudioPlayer|AudioMix)\w*"#,
     ["AVFoundation", "AVKit", "AVFAudio"]),
]

/// The source without comments and without the contents of its string literals.
private func code(_ source: String) -> String {
    let c = Array(source)
    var out: [Character] = [], i = 0
    func at(_ s: String) -> Bool { let a = Array(s); return i + a.count <= c.count && Array(c[i..<(i + a.count)]) == a }
    /// Moves past the next `close` (or to the end of the line when `sameLine` and none closes there).
    func skip(to close: String, sameLine: Bool) {
        while i < c.count, !at(close) {
            if sameLine, c[i] == "\n" { return }
            if sameLine, close == "\"", c[i] == "\\" { i += 1 }
            i += 1
        }
        i = min(i + close.count, c.count)
    }
    while i < c.count {
        if at("//") { while i < c.count, c[i] != "\n" { i += 1 } }
        else if at("/*") { i += 2; skip(to: "*/", sameLine: false); out.append(" ") }
        else if at("\"\"\"") { i += 3; skip(to: "\"\"\"", sameLine: false); out.append(" ") }
        else if at("#\"") { i += 2; skip(to: "\"#", sameLine: true); out.append(" ") }
        else if c[i] == "\"" { i += 1; skip(to: "\"", sameLine: true); out.append(" ") }
        else { out.append(c[i]); i += 1 }
    }
    return String(out)
}

private func imports(_ code: String) -> Set<String> {
    var out: Set<String> = []
    for line in code.split(separator: "\n") {
        let words = line.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(of: "import"), i + 1 < words.count, words[..<i].allSatisfy({ $0.hasPrefix("@") }) else { continue }
        // `import struct Foundation.URL`: the module is the first part of the last word.
        let module = words[words.count - 1]
        out.insert(module)
        if words.count - i > 2, let first = module.split(separator: ".").first { out.insert(String(first)) }
    }
    return out
}

@Test func everyFileImportsTheSystemFrameworksItNames() throws {
    var files = 0, missing: [String] = []
    for folder in ["Sources", "Tests"] {
        let dir = repo.appendingPathComponent(folder)
        let urls = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            files += 1
            let text = code(try String(contentsOf: url, encoding: .utf8))
            let has = imports(text)
            for f in frameworks where has.isDisjoint(with: f.imports) {
                guard let r = text.range(of: #"(?<![A-Za-z0-9_.])("# + f.symbols + ")", options: .regularExpression) else { continue }
                missing.append("\(url.path.dropFirst(repo.path.count + 1)): uses \(text[r]) without `import \(f.name)`")
            }
        }
    }
    #expect(files > 300, "the scan found only \(files) files")
    #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
}

/// The scan sees a use, and does not take a comment or a string for one.
@Test func theImportScanReadsCodeNotCommentsOrStrings() {
    let source = """
    import CoreGraphics
    @preconcurrency import AVFoundation
    // CTFontGetSize in a comment
    let a = "CIImage in a string"
    let b = CTFontGetSize(font)
    """
    let text = code(source)
    #expect(imports(text) == ["CoreGraphics", "AVFoundation"])
    #expect(text.contains("CTFontGetSize(font)") && !text.contains("comment") && !text.contains("CIImage"))
}
