import AppKit
import Combine
import RegistaCore
import RegistaEngines
import SwiftUI

/// The teleprompter ("gobbo"): a private floating window near the webcam. It is excluded from every
/// screen capture (`sharingType = .none`: screen recordings, screenshots, screen sharing never show
/// it), always on top, and remembers where it sits on each display. In voice mode it follows the
/// speaker word by word, jumps back when they start a sentence again and logs the takes.
@MainActor
final class TeleprompterController: ObservableObject {
    static let shared = TeleprompterController()

    enum Mode: String, CaseIterable, Identifiable {
        case voice, speed, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .voice: return loc("Voce")
            case .speed: return loc("Velocità")
            case .manual: return loc("Manuale")
            }
        }
        var icon: String {
            switch self {
            case .voice: return "waveform"
            case .speed: return "gauge.with.dots.needle.33percent"
            case .manual: return "hand.point.up.left"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    @Published var text: String = defaults.string(forKey: "prompterText")
        ?? loc("1. Incolla qui il tuo testo, una frase per ripresa.\n2. In modalità Voce il gobbo ti ascolta: / avanza mentre leggi.\n3. Se ricominci una frase, / torna al suo inizio.") {
        didSet {
            if persists { Self.defaults.set(text, forKey: "prompterText") }
            reload()
        }
    }
    @Published var mode = Mode(rawValue: defaults.string(forKey: "prompterMode") ?? "") ?? .voice {
        didSet {
            if persists { Self.defaults.set(mode.rawValue, forKey: "prompterMode") }
            if isPlaying { pause(); play() }
        }
    }
    /// Fixed-speed scrolling, points per second.
    @Published var speed: Double = defaults.object(forKey: "prompterSpeed") as? Double ?? 45 {
        didSet { if persists { Self.defaults.set(speed, forKey: "prompterSpeed") } }
    }
    @Published var fontSize: Double = defaults.object(forKey: "prompterFontSize") as? Double ?? 40 {
        didSet { if persists { Self.defaults.set(fontSize, forKey: "prompterFontSize") } }
    }
    /// Mirrored text, for a beam-splitter teleprompter glass.
    @Published var mirror = defaults.bool(forKey: "prompterMirror") {
        didSet { if persists { Self.defaults.set(mirror, forKey: "prompterMirror") } }
    }
    /// Until the user picks one: the spoken language of Settings › Generale, else the app's language (a French Mac follows
    /// French), else Italian.
    static var defaultLanguage: String {
        let spoken = defaults.string(forKey: StepSettings.languageKey) ?? StepSettings.appLanguage
        return PrompterLanguage.all.contains(spoken) ? spoken : "it"
    }

    /// Recognition language: "it", "fr", "en" or "pt" (PrompterLanguage).
    @Published var language: String = defaults.string(forKey: "prompterLanguage") ?? TeleprompterController.defaultLanguage {
        didSet {
            if persists { Self.defaults.set(language, forKey: "prompterLanguage") }
            if redoWords.isEmpty || VoiceCommandSet.defaults(language: oldValue).redo.joined(separator: ", ") == redoWords {
                redoWords = VoiceCommandSet.defaults(language: language).redo.joined(separator: ", ")
            }
            reload()
        }
    }
    /// Spoken commands, comma-separated phrases.
    @Published var redoWords: String = defaults.string(forKey: "prompterRedoWords") ?? "" {
        didSet { if persists { Self.defaults.set(redoWords, forKey: "prompterRedoWords") }; reload() }
    }
    @Published var stopWords: String = defaults.string(forKey: "prompterStopWords") ?? "stop" {
        didSet { if persists { Self.defaults.set(stopWords, forKey: "prompterStopWords") }; reload() }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var isVisible = false

    /// Lets screenshots see the panel (developer flag `--prompter-demo` only).
    var capturableForTesting = false
    /// false for preview copies (ui.screenshot): they never touch the user's settings.
    private var persists = true
    let follower = ScriptFollower()
    weak var recorder: Recorder? {
        didSet { observeRecorder() }
    }
    fileprivate weak var canvas: PrompterCanvas?
    let lead = CursorLead()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var bag: Set<AnyCancellable> = []
    private var recorderBag: AnyCancellable?

    init() {
        if redoWords.isEmpty { redoWords = VoiceCommandSet.defaults(language: language).redo.joined(separator: ", ") }
        reload()
        // Re-publish follower changes so views observing the controller refresh.
        follower.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        follower.onStop = { [weak self] in self?.recorder?.stop() }
    }

    var commands: VoiceCommandSet {
        let split = { (s: String) in s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return VoiceCommandSet(redo: split(redoWords), stop: split(stopWords))
    }

    private func reload() { follower.load(script: text, commands: commands) }

    var prompt: PromptScript { follower.prompt }
    var wordCount: Int { prompt.tokens.count }

    /// Where the highlight is drawn now: the confirmed cursor, led at the speaker's pace while they read.
    func drawnCursor(at now: CFTimeInterval = CACurrentMediaTime()) -> Int {
        guard mode == .voice, isPlaying else { return follower.cursor }
        return lead.cursor(in: prompt, confirmed: follower.cursor, movedAt: follower.movedAt, now: now,
                           wpm: follower.wpm, onScript: follower.state == .onScript)
    }

    // MARK: Window

    func toggleVisible() { isVisible ? hide() : show() }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        isVisible = true
        installKeys()
    }

    func hide() {
        pause()
        panel?.orderOut(nil)
        isVisible = false
        removeKeys()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        if mode == .voice, let recorder {
            Task {
                await follower.start(recorder: recorder, language: language)
                if !follower.isListening { isPlaying = false }
            }
        }
    }

    func pause() {
        isPlaying = false
        follower.stop(recorder: recorder)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func restart() {
        follower.restart()
        canvas?.scrollToTop()
    }

    func nudge(_ delta: CGFloat) { canvas?.nudge(delta) }

    func jump(toToken index: Int) { follower.jump(to: index) }

    /// Pedal / remote / keyboard forward.
    func next() {
        if mode == .voice { follower.nextSentence() } else { nudge(fontSize * 2.6) }
    }

    /// Pedal / remote / keyboard back: the current sentence again, or the previous one.
    func back() {
        if mode == .voice { follower.previousSentence() } else { nudge(-fontSize * 2.6) }
    }

    /// Writes the live take markers of the recording that just ended next to it (`<name>.takes.json`;
    /// for a screen session folder, `takes.json` inside it). media.import picks them up.
    func saveTakes(for media: URL) async {
        guard let log = await follower.finishedMarkers() else { return }
        var isDir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: media.path, isDirectory: &isDir) && isDir.boolValue
        let url = folder ? media.appendingPathComponent("takes.json") : LiveTakeLog.sidecar(for: media)
        do { try log.write(to: url) } catch { NSLog("Regista: cannot write take markers %@: %@", url.path, "\(error)") }
    }

    private func observeRecorder() {
        recorderBag = recorder?.$isRecording.removeDuplicates().sink { [weak self] recording in
            if recording { self?.follower.recordingDidStart() }
        }
    }

    /// Keyboard, Bluetooth pedals and presentation remotes (they send arrows / Page Up-Down): space
    /// plays or pauses, ↓ → Page Down go to the next sentence, ↑ ← Page Up back to the start of the
    /// sentence (again: the previous one). Active while the teleprompter is in use, never while typing.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isVisible else { return e }
            let inUse = self.isPlaying || self.panel?.isKeyWindow == true || self.recorder?.isRecording == true
            guard inUse, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            if let w = NSApp.keyWindow, w !== self.panel, w.firstResponder is NSText { return e }
            switch e.keyCode {
            case 49: self.togglePlay()                     // space
            case 125, 124, 121: self.next()                // ↓ → Page Down
            case 126, 123, 116: self.back()                // ↑ ← Page Up
            default: return e
            }
            return nil
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: Panel

    static let defaultSize = NSSize(width: 640, height: 360)

    private func makePanel() -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let p = Self.makePanel(frame: Self.savedFrame(on: screen) ?? Self.defaultFrame(on: screen), capturable: capturableForTesting)
        p.contentView = NSHostingView(rootView: TeleprompterView(controller: self))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                self?.isVisible = false
                self?.removeKeys()
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: p, queue: .main) { n in
                guard let w = n.object as? NSWindow else { return }
                Task { @MainActor in Self.saveFrame(w.frame, on: w.screen) }
            }
        }
        return p
    }

    /// The teleprompter window: floating on every Space and over full-screen apps, movable by its
    /// background, and invisible to screen capture unless `capturable` (screenshots in tests only).
    static func makePanel(frame: NSRect, capturable: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = loc("Gobbo")
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 360, height: 200)
        p.backgroundColor = Ed.Prompter.noir
        p.appearance = NSAppearance(named: .darkAqua)
        // Excluded from screen recordings, screenshots and screen sharing: only the speaker sees it.
        p.sharingType = capturable ? .readOnly : .none
        assert(capturable || p.sharingType == .none, "the teleprompter must never be captured")   // l10n-ignore
        return p
    }

    /// Top centre of the screen, right under the menu bar: the eyes stay close to the webcam.
    static func defaultFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.midX - defaultSize.width / 2, y: visible.maxY - defaultSize.height - 6,
                      width: defaultSize.width, height: defaultSize.height)
    }

    private static func frameKey(_ screen: NSScreen?) -> String? {
        guard let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }   // l10n-ignore
        return "prompterFrame-\(id)"
    }

    /// The frame last used on this display, if it still fits on it.
    static func savedFrame(on screen: NSScreen?) -> NSRect? {
        guard let key = frameKey(screen), let s = defaults.string(forKey: key), let screen else { return nil }
        let r = NSRectFromString(s)
        return screen.visibleFrame.intersects(r) && r.width >= 200 ? r : nil
    }

    static func saveFrame(_ frame: NSRect, on screen: NSScreen?) {
        guard let key = frameKey(screen) else { return }
        defaults.set(NSStringFromRect(frame), forKey: key)
    }

    // MARK: Preview (ui.screenshot)

    /// A stand-alone controller showing `text` mid-reading, for offscreen renders of the window.
    static func preview(text: String, mirror: Bool, fontSize: Double) -> TeleprompterController {
        let c = TeleprompterController(preview: true)
        c.text = text
        c.mirror = mirror
        c.fontSize = fontSize
        let p = c.prompt
        // Somewhere in the third sentence (or 40 % through), as if the speaker were reading.
        let target = p.sentences.count > 2 ? p.sentences[2].tokens.lowerBound + 3 : p.tokens.count * 2 / 5
        c.follower.jump(to: min(target, p.tokens.count))
        c.isPlaying = true
        return c
    }

    private init(preview: Bool) {
        persists = false
        reload()
    }
}

// MARK: - Canvas (TextKit layout, per-word positions, smooth scroll)

final class PrompterCanvas: NSView {
    var onWordClicked: ((Int) -> Void)?
    /// Where the highlight is now (asked every frame: the controller leads it between recognizer updates).
    var drawnCursor: (() -> Int)?

    // Inputs
    private var prompt = PromptScript("")
    private var fontSize: CGFloat = 40
    private var mirror = false
    private var cursor = 0
    private var mode: TeleprompterController.Mode = .voice
    private var playing = false
    private var speed: CGFloat = 45

    // Layout
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private var laidOutWidth: CGFloat = 0
    /// The font size actually used: the setting, smaller if the longest display line would wrap.
    private var effectiveSize: CGFloat = 40
    private let hPadding: CGFloat = 40

    // Scroll
    private var offset: CGFloat = 0
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    /// Manual scrolling wins over voice following for a few seconds.
    private var manualUntil: CFTimeInterval = 0

    override var isFlipped: Bool { true }
    private var readingLine: CGFloat { bounds.height * 0.36 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func update(prompt: PromptScript, fontSize: CGFloat, mirror: Bool, mode: TeleprompterController.Mode, playing: Bool, speed: CGFloat) {
        let relayout = prompt.display != self.prompt.display || fontSize != self.fontSize
        self.mirror = mirror
        self.mode = mode
        self.playing = playing
        self.speed = speed
        if relayout {
            self.prompt = prompt
            self.fontSize = fontSize
            rebuild()
            recolor(force: true)
        }
        needsDisplay = true
    }

    func scrollToTop() { offset = 0; needsDisplay = true }

    func nudge(_ delta: CGFloat) {
        offset = min(max(0, offset + delta), maxOffset)
        manualUntil = CACurrentMediaTime() + 3
        needsDisplay = true
    }

    /// Jumps straight to the reading position, now and after every relayout (offscreen renders have no display link).
    func settle() {
        snaps = true
        recolor(force: true)
        if mode == .voice { offset = voiceTarget }
        needsDisplay = true
    }

    private var snaps = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - laidOutWidth) > 0.5 {
            rebuild()
            recolor(force: true)
            if snaps { settle() }
        }
    }

    private func rebuild() {
        laidOutWidth = bounds.width
        let width = max(100, bounds.width - hPadding * 2)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        // Prepared lines never wrap: shrink the type until the longest one fits (not below 24 pt).
        let lines = prompt.display.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}"))
        let probe = Ed.Prompter.font(size: fontSize, weight: .bold)
        let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: probe]).width }.max() ?? 0
        effectiveSize = widest > width ? max(24, (fontSize * width / widest).rounded(.down)) : fontSize
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = effectiveSize * 0.22
        para.paragraphSpacing = effectiveSize * 0.75
        storage.setAttributedString(NSAttributedString(string: prompt.display, attributes: [
            .font: Ed.Prompter.font(size: effectiveSize, weight: .semibold),
            .foregroundColor: Ed.Prompter.cream,
            .paragraphStyle: para,
        ]))
        // Keywords: a heavier weight; breath marks: a faint dot.
        for i in prompt.keywordTokens {
            storage.addAttribute(.font, value: Ed.Prompter.font(size: effectiveSize, weight: .bold), range: prompt.tokens[i].range)
        }
        layout.ensureLayout(for: container)
    }

    private static let keywordTint = Ed.Prompter.cream.blended(withFraction: 0.35, of: Ed.Prompter.gold) ?? Ed.Prompter.gold

    /// Read = dimmed, the word just read = gold, still to read = creme (keywords warmer).
    private func recolor(force: Bool = false) {
        let c = drawnCursor?() ?? 0
        guard force || c != cursor else { return }
        cursor = c
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: Ed.Prompter.cream, range: full)
        for i in prompt.keywordTokens { storage.addAttribute(.foregroundColor, value: Self.keywordTint, range: prompt.tokens[i].range) }
        for r in prompt.breathRanges { storage.addAttribute(.foregroundColor, value: Ed.Prompter.cream.withAlphaComponent(0.28), range: r) }
        if mode == .voice, cursor > 0, cursor <= prompt.tokens.count {
            let last = prompt.tokens[cursor - 1].range
            storage.addAttribute(.foregroundColor, value: Ed.Prompter.cream.withAlphaComponent(0.3),
                                 range: NSRange(location: 0, length: last.location))
            storage.addAttribute(.foregroundColor, value: Ed.Prompter.gold, range: last)
        }
        storage.endEditing()
        needsDisplay = true
    }

    /// Scroll offset that puts the next word to read on the reading line.
    private var voiceTarget: CGFloat {
        guard !prompt.tokens.isEmpty else { return 0 }
        let i = min(cursor, prompt.tokens.count - 1)
        let glyph = layout.glyphIndexForCharacter(at: prompt.tokens[i].range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return max(0, line.midY - effectiveSize * 0.1)
    }

    private var maxOffset: CGFloat { layout.usedRect(for: container).height }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastStep == 0 ? 1.0 / 60 : min(0.1, now - lastStep)
        lastStep = now
        recolor()
        let before = offset
        switch mode {
        case .voice:
            // Critically damped approach: quick but never jumpy. A manual scroll wins for a while.
            if CACurrentMediaTime() > manualUntil { offset += (voiceTarget - offset) * CGFloat(1 - exp(-dt * 6)) }
        case .speed:
            if playing, CACurrentMediaTime() > manualUntil { offset = min(maxOffset, offset + speed * CGFloat(dt)) }
        case .manual:
            break
        }
        if abs(offset - before) > 0.05 { needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        nudge(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12))
    }

    override func mouseDown(with event: NSEvent) {
        // Click on a word = "I'm here" (re-anchors voice mode).
        var p = convert(event.locationInWindow, from: nil)
        if mirror { p.x = bounds.width - p.x }
        let textPoint = NSPoint(x: p.x - hPadding, y: p.y - (readingLine - offset))
        let glyph = layout.glyphIndex(for: textPoint, in: container)
        let char = layout.characterIndexForGlyph(at: glyph)
        if let i = prompt.tokens.firstIndex(where: { NSMaxRange($0.range) > char }) {
            onWordClicked?(i)
        }
        if event.clickCount == 2 { window?.performDrag(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Ed.Prompter.noir.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        if mirror {
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        let origin = NSPoint(x: hPadding, y: readingLine - offset)
        let visible = NSRect(x: 0, y: offset - readingLine, width: container.size.width, height: bounds.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.drawBackground(forGlyphRange: glyphs, at: origin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        drawSentenceNumbers(origin: origin, visible: visible)
        ctx.restoreGState()

        // Fade the text out towards the edges: the eye stays on the reading line.
        // Solid under the status bar, then fading to the reading line.
        let top = NSGradient(colorsAndLocations: (Ed.Prompter.noir, 0), (Ed.Prompter.noir, 0.45), (Ed.Prompter.noir.withAlphaComponent(0), 1))!
        top.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: readingLine * 0.8), angle: 90)
        let bottom = NSGradient(colors: [Ed.Prompter.noir.withAlphaComponent(0), Ed.Prompter.noir])!
        bottom.draw(in: NSRect(x: 0, y: bounds.height * 0.64, width: bounds.width, height: bounds.height * 0.36), angle: 90)

        // Reading line: gold markers on both sides.
        let y = readingLine + effectiveSize * 0.1
        Ed.Prompter.gold.setFill()
        for x in [CGFloat(10), bounds.width - 10] {
            let dir: CGFloat = x < bounds.midX ? 1 : -1
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: x, y: y - 7))
            tri.line(to: NSPoint(x: x + 9 * dir, y: y))
            tri.line(to: NSPoint(x: x, y: y + 7))
            tri.close()
            tri.fill()
        }
    }

    /// A small sentence (take) number in the margin of each sentence's first line.
    private func drawSentenceNumbers(origin: NSPoint, visible: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Ed.Prompter.font(family: "Geist Mono", size: 11, weight: .medium),
                                                    .foregroundColor: Ed.Prompter.cream.withAlphaComponent(0.3)]
        for (i, s) in prompt.sentences.enumerated() where !s.tokens.isEmpty {
            let glyph = layout.glyphIndexForCharacter(at: prompt.tokens[s.tokens.lowerBound].range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            guard line.maxY >= visible.minY, line.minY <= visible.maxY else { continue }
            let label = "\(i + 1)" as NSString
            // Clear of the reading-line marker (x 10…19).
            label.draw(at: NSPoint(x: 25, y: origin.y + line.midY - 8), withAttributes: attrs)
        }
    }
}

struct PrompterCanvasView: NSViewRepresentable {
    @ObservedObject var controller: TeleprompterController
    /// Offscreen renders: jump to the reading position at once.
    var settled = false

    func makeNSView(context: Context) -> PrompterCanvas {
        let v = PrompterCanvas(frame: .zero)
        controller.canvas = v
        v.onWordClicked = { [weak controller] i in controller?.jump(toToken: i) }
        v.drawnCursor = { [weak controller] in controller?.drawnCursor() ?? 0 }
        return v
    }

    func updateNSView(_ v: PrompterCanvas, context: Context) {
        v.update(prompt: controller.prompt, fontSize: controller.fontSize, mirror: controller.mirror,
                 mode: controller.mode, playing: controller.isPlaying, speed: controller.speed)
        if settled { v.settle() }
    }
}

// MARK: - Panel content

struct TeleprompterView: View {
    @ObservedObject var controller: TeleprompterController
    var settled = false

    var body: some View {
        ZStack {
            PrompterCanvasView(controller: controller, settled: settled)
            VStack {
                HStack(alignment: .top) {
                    PrompterStatusPill(controller: controller)
                    Spacer()
                    if controller.mode == .voice, controller.isPlaying { PaceBadge(wpm: controller.follower.wpm) }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if controller.mode == .voice, controller.isPlaying, !controller.follower.lastHeard.isEmpty {
                        Text(verbatim: loc("sento: %@", controller.follower.lastHeard))
                            .font(Ed.mono(Ed.TypeSize.caption))
                            .foregroundStyle(Ed.Prompter.creamColor.opacity(0.38))
                            .lineLimit(1)
                    }
                    Spacer()
                    PrompterControls(controller: controller)
                }
            }
            .padding(.horizontal, Ed.Space.m)
            .padding(.top, 30)
            .padding(.bottom, 10)
        }
        .background(Ed.Prompter.noirColor)
        .preferredColorScheme(.dark)
    }
}

struct PrompterStatusPill: View {
    @ObservedObject var controller: TeleprompterController
    @State private var pulse = false

    var body: some View {
        let (label, color) = status
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(controller.isPlaying && controller.mode == .voice ? (pulse ? 0.35 : 1) : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text(verbatim: label)
                .font(Ed.ui(Ed.TypeSize.small, .medium))
                .foregroundStyle(Ed.Prompter.creamColor.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .background(Ed.Prompter.noirColor.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        .onAppear { pulse = true }
        .tip(controller.follower.errorMessage ?? "")
    }

    private var status: (String, Color) {
        let f = controller.follower
        if let e = f.errorMessage { return (e, Ed.danger) }
        guard controller.isPlaying else { return (loc("In pausa · spazio per partire"), Ed.Prompter.creamColor.opacity(0.38)) }
        switch controller.mode {
        case .speed: return (loc("Scorrimento automatico"), Ed.Prompter.goldDeep)
        case .manual: return (loc("Manuale · rotella, frecce o pedale"), Ed.Prompter.goldDeep)
        case .voice:
            if let s = f.restarted { return (loc("↺ Frase %@ da capo", String(s + 1)), Ed.Prompter.goldColor) }
            if f.tracker.cursor >= f.prompt.tokens.count, !f.prompt.tokens.isEmpty { return (loc("Fine del testo"), Ed.Prompter.goldColor) }
            let where_ = take
            switch f.state {
            case .offScript: return (loc("Fuori copione · ti aspetto"), Ed.Prompter.amber)
            case .onScript: return (loc("Ti seguo") + where_, Ed.Prompter.goldColor)
            case .waiting: return (loc("In ascolto · inizia a leggere") + where_, Ed.Prompter.goldColor)
            }
        }
    }

    /// " · frase 3 · ripresa 2": which take of which sentence is being read.
    private var take: String {
        let f = controller.follower
        guard let s = f.tracker.currentSentence, f.prompt.sentences.count > 1 else { return "" }
        let n = f.tracker.markers.filter { $0.sentence == s + 1 }.count + 1
        return " · " + loc("frase %@", String(s + 1)) + (n > 1 ? " · " + loc("ripresa %@", String(n)) : "")
    }
}

/// Words per minute against the 150–170 target: a calm colour when on pace.
struct PaceBadge: View {
    let wpm: Double?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: loc("%@ parole/min", wpm.map { String(Int($0.rounded())) } ?? "—"))
                .font(Ed.mono(Ed.TypeSize.small, .medium))
                .foregroundStyle(Ed.Prompter.creamColor.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Ed.Prompter.surface.opacity(0.8), in: Capsule())
        .tip(loc("Ritmo ideale: %@–%@ parole al minuto", String(Int(PaceMeter.target.lowerBound)), String(Int(PaceMeter.target.upperBound))))
    }

    private var color: Color {
        guard let wpm else { return Ed.Prompter.creamColor.opacity(0.38) }
        switch PaceMeter.band(wpm) {
        case .slow: return Ed.Prompter.slow
        case .good: return Ed.Prompter.goldColor
        case .fast: return Ed.Prompter.amber
        }
    }
}

struct PrompterControls: View {
    @ObservedObject var controller: TeleprompterController

    var body: some View {
        HStack(spacing: Ed.Space.m) {
            ForEach(TeleprompterController.Mode.allCases) { m in
                Button { controller.mode = m } label: {
                    Image(systemName: m.icon)
                        .foregroundStyle(controller.mode == m ? Ed.Prompter.goldColor : Ed.Prompter.creamColor.opacity(0.62))
                }
                .tip(m.label)
            }
            divider
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(Ed.Prompter.creamColor)
            }
            .tip(controller.mode == .voice ? "Ascolta / smetti di ascoltare" : "Avvia / pausa", shortcut: "Spazio")
            Button { controller.back() } label: { Image(systemName: "backward.end.fill") }
                .tip("Frase da capo, poi la precedente", shortcut: "↑ ←")
            Button { controller.next() } label: { Image(systemName: "forward.end.fill") }
                .tip("Frase successiva", shortcut: "↓ →")
            Button { controller.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .tip("Dall'inizio")
            if controller.mode == .speed {
                divider
                Button { controller.speed = max(10, controller.speed - 5) } label: { Image(systemName: "tortoise.fill") }
                    .tip("Più lento")
                Text(verbatim: "\(Int(controller.speed))").font(Ed.mono(Ed.TypeSize.small)).frame(width: 26)
                Button { controller.speed = min(200, controller.speed + 5) } label: { Image(systemName: "hare.fill") }
                    .tip("Più veloce")
            }
            divider
            Button { controller.fontSize = max(20, controller.fontSize - 4) } label: { Image(systemName: "textformat.size.smaller") }
                .tip("Testo più piccolo")
            Button { controller.fontSize = min(96, controller.fontSize + 4) } label: { Image(systemName: "textformat.size.larger") }
                .tip("Testo più grande")
            Button { controller.mirror.toggle() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .foregroundStyle(controller.mirror ? Ed.Prompter.goldColor : Ed.Prompter.creamColor.opacity(0.62))
            }
            .tip("Specchiato (vetro teleprompter)")
        }
        .buttonStyle(.plain)
        .font(Ed.icon(Ed.TypeSize.body, .medium))
        .foregroundStyle(Ed.Prompter.creamColor.opacity(0.62))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Ed.Prompter.surface.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Ed.Prompter.creamColor.opacity(0.14), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Ed.Prompter.creamColor.opacity(0.14)).frame(width: 1, height: 14)
    }
}

// MARK: - Languages

/// The languages the teleprompter follows by voice (on-device recognition), named in their own language.
enum PrompterLanguage {
    static let all = ["it", "fr", "en", "pt"]

    static func locale(_ code: String) -> Locale {
        switch code {
        case "fr": Locale(identifier: "fr-FR")
        case "en": Locale(identifier: "en-US")
        case "pt": Locale(identifier: "pt-BR")
        default: Locale(identifier: "it-IT")
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "fr": "Français"
        case "en": "English"
        case "pt": "Português"
        default: "Italiano"
        }
    }
}

// MARK: - "Gobbo" tab of the right panel: write the script, choose how it scrolls.

struct PrompterEditorView: View {
    @ObservedObject private var p = TeleprompterController.shared
    /// Whether this Mac recognizes the chosen language on device (nil while checking).
    @State private var support: LiveSpeechSession.OnDeviceSupport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Ed.Space.l) {
                Text(verbatim: String(format: loc("%d frasi · %d parole · circa %d min"), p.prompt.sentences.count,
                                      p.wordCount, max(1, Int((Double(p.wordCount) / 160).rounded()))))
                    .font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text2)
                Text("In modalità **Voce** il gobbo ti ascolta: avanza mentre leggi, si ferma se parli d'altro e, se ricominci una frase, torna al suo inizio e segna una nuova ripresa. Una riga numerata = una ripresa; \" / \" = pausa, *parola* = parola chiave. La finestra non compare mai nelle registrazioni dello schermo.")
                    .font(Ed.ui(Ed.TypeSize.small))
                    .foregroundStyle(Ed.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $p.text)
                    .font(Ed.ui(Ed.TypeSize.title))
                    .foregroundStyle(Ed.text)
                    .scrollContentBackground(.hidden)
                    .padding(Ed.Space.m)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.well))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line2))

                RSection(loc("Scorrimento")) {
                    RSegmented(items: TeleprompterController.Mode.allCases.map { ($0, $0.label) }, selection: $p.mode,
                               symbols: Dictionary(uniqueKeysWithValues: TeleprompterController.Mode.allCases.map { ($0, $0.icon) }))
                    if p.mode == .speed {
                        RSlider(value: $p.speed, range: 10...200, step: 5, label: loc("Velocità"), format: { String(format: loc("%d pt/s"), Int($0)) })
                    }
                    RSlider(value: $p.fontSize, range: 20...96, step: 2, label: loc("Dimensione del testo"), format: { "\(Int($0)) pt" })
                    RToggle(title: loc("Specchiato"), isOn: $p.mirror, subtitle: loc("Per il vetro di un teleprompter"))
                }

                if p.mode == .voice {
                    RSection(loc("Segue la voce")) {
                        RChips(items: PrompterLanguage.all.map { .init(id: $0, title: PrompterLanguage.name($0)) }, selection: p.language, height: 26) {
                            p.language = $0
                        }
                        if let note = supportNote {
                            Text(verbatim: note.text).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(note.warning ? Ed.warn : Ed.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: Ed.Space.m) {
                            field(loc("Rifaccio"), text: $p.redoWords)
                            field(loc("Stop"), text: $p.stopWords).frame(maxWidth: 120)
                        }
                        .tip("Comandi vocali: «rifaccio» scarta la ripresa e torna all'inizio della frase, «stop» ferma la registrazione. Più frasi separate da virgole; ogni lingua ha i suoi (FR «je recommence», EN «let me redo», PT «vou refazer»).")
                    }
                }

                FlowLayout(spacing: Ed.Space.s, lineSpacing: Ed.Space.s) {
                    EdButton(title: p.isVisible ? loc("Nascondi il gobbo") : loc("Mostra il gobbo"), symbol: p.isVisible ? "eye.slash" : "eye") {
                        p.toggleVisible()
                    }
                    EdButton(title: p.isPlaying ? (p.mode == .voice ? loc("Smetti di ascoltare") : loc("Pausa"))
                                                : (p.mode == .voice ? loc("Ascolta e segui") : loc("Avvia")),
                             symbol: p.isPlaying ? "pause.fill" : "play.fill") {
                        p.show()
                        p.togglePlay()
                    }
                    .keyboardShortcut(.space, modifiers: [.option])
                    .tip("Prova il gobbo prima di registrare", shortcut: "⌥Spazio")
                    EdButton(title: loc("Ricomincia"), symbol: "arrow.counterclockwise") { p.restart() }
                }
                Text(verbatim: loc("Spazio, frecce e pedale o telecomando guidano il gobbo quando è in uso."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
            .padding(Ed.Space.l)
        }
        .task(id: p.language) { support = await LiveSpeechSession.onDeviceSupport(for: PrompterLanguage.locale(p.language)) }
    }

    private var supportNote: (text: String, warning: Bool)? {
        switch support {
        case .installed: (loc("Riconoscimento sul Mac: nessun audio esce dal computer."), false)
        case .downloadable: (loc("Riconoscimento sul Mac: macOS scarica la lingua la prima volta che il gobbo ascolta."), false)
        case .unavailable: (String(format: loc("Il riconoscimento di %@ non è disponibile su questo Mac: usa Velocità o Manuale"), PrompterLanguage.name(p.language)), true)
        case nil: nil
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.xs) {
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2)
            RTextField(text: text)
        }
    }
}
