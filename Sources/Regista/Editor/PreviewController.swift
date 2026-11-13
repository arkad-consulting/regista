import AVFoundation
import AppKit
import CoreImage
import RegistaCore
import RegistaEngines

/// An AVPlayer whose frames are pulled through an AVPlayerItemVideoOutput and drawn by `FrameView`s
/// (drawn in `draw(_:)`, so the app's own window snapshots — ui.screenshot — include the video).
@MainActor
final class FrameSource: ObservableObject {
    let player = AVPlayer()
    private(set) var output: AVPlayerItemVideoOutput?
    private(set) var image: CGImage?
    /// Rotation the frames need (source files from a phone); the composition's frames are upright.
    var orientation: CGImagePropertyOrientation = .up
    private var views: [WeakView] = []
    private var timer: Timer?
    /// Pass-through like frame.render (no colour management), tagged sRGB.
    nonisolated static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct WeakView { weak var view: NSView? }

    init() {
        player.actionAtItemEnd = .pause
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func replace(_ item: AVPlayerItem?) {
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item?.add(out)
        output = item == nil ? nil : out
        player.replaceCurrentItem(with: item)
        if item == nil { image = nil; redraw() }
    }

    func attach(_ view: NSView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakView(view: view))
    }

    private func redraw() { for v in views { v.view?.needsDisplay = true } }

    private func tick() {
        guard let output, player.currentItem != nil else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t), let px = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        image = Self.cgImage(px, orientation)
        redraw()
    }

    nonisolated static func cgImage(_ px: CVPixelBuffer, _ orientation: CGImagePropertyOrientation = .up) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: px)
        if orientation != .up { ci = ci.oriented(orientation) }
        return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Seeks exactly and calls back with the frame at `time` (polls the output until the frame is decoded).
    func frame(at time: CMTime, _ done: @escaping (CGImage?) -> Void) {
        player.pause()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.poll(time, tries: 0, done) ?? done(nil) } }
        }
    }

    private func poll(_ time: CMTime, tries: Int, _ done: @escaping (CGImage?) -> Void) {
        if let output, output.hasNewPixelBuffer(forItemTime: time),
           let px = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            image = Self.cgImage(px, orientation)
            redraw()
            return done(image)
        }
        guard tries < 300 else { return done(image) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            MainActor.assumeIsolated { self?.poll(time, tries: tries + 1, done) ?? done(nil) }
        }
    }
}

/// The monitors' fitting maths: a picture of a given aspect (width / height) letterboxed in an area, centred, never
/// stretched (#52).
enum MonitorFit {
    /// Where a picture of `aspect` lands inside `area`.
    static func rect(aspect: CGFloat, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0, aspect > 0, aspect.isFinite else { return .zero }
        let w = min(area.width, area.height * aspect), h = w / aspect
        return CGRect(x: area.minX + (area.width - w) / 2, y: area.minY + (area.height - h) / 2, width: w, height: h)
    }

    /// The size of a picture of `aspect` fitted in `size`.
    static func size(aspect: CGFloat, in size: CGSize) -> CGSize {
        rect(aspect: aspect, in: CGRect(origin: .zero, size: size)).size
    }

    /// Width / height of the project's frame (9:16 when there is no project).
    static func aspect(_ project: Project?) -> CGFloat {
        guard let s = project?.settings, s.width > 0, s.height > 0 else { return 9.0 / 16 }
        return CGFloat(s.width) / CGFloat(s.height)
    }

    /// The format shown beside "Programma": "9:16", "4:5", "1:1", "16:9", the reduced ratio of another size
    /// ("1280×720" → "16:9", "1000×700" → "10:7"), or the size itself when the ratio does not reduce to small numbers.
    static func label(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height), w = width / g, h = height / g
        return max(w, h) <= 32 ? "\(w):\(h)" : "\(width)×\(height)"
    }

    /// Instagram's Reels guides only make sense on a 9:16 frame.
    static func showsInstagramZones(width: Int, height: Int) -> Bool { label(width: width, height: height) == "9:16" }
}

/// Draws the current frame of a `FrameSource`, letterboxed on black in the area of `aspect` (the project's format).
final class FrameView: NSView {
    weak var source: FrameSource?
    var aspect: CGFloat = 9.0 / 16

    override var isFlipped: Bool { true }

    /// Where the picture lands inside the view.
    var pictureRect: CGRect { MonitorFit.rect(aspect: aspect, in: bounds).integral }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.draw(MainActor.assumeIsolated { source?.image }, in: ctx, picture: pictureRect)
    }

    /// Black in `picture`, then the image fitted inside it at its own aspect: a frame whose size does not match (the
    /// project changed format and the player has not caught up) is letterboxed, never stretched. `ctx` has a
    /// top-left origin (the flipped view).
    static func draw(_ image: CGImage?, in ctx: CGContext, picture r: CGRect) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(r)
        guard let image, image.width > 0, image.height > 0 else { return }
        let fit = MonitorFit.rect(aspect: CGFloat(image.width) / CGFloat(image.height), in: r)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // Flipped view: draw the image upright.
        ctx.translateBy(x: fit.minX, y: fit.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: fit.size))
        ctx.restoreGState()
    }
}

/// The Program monitor's player: the timeline through the export compositor, rebuilt when the project changes.
@MainActor
final class PreviewController: ObservableObject {
    weak var store: EditorStore?
    let program = FrameSource()
    let source = FrameSource()
    /// Playhead, seconds (published at ~30 Hz while playing).
    let playhead = Playhead()
    @Published private(set) var isPlaying = false
    @Published private(set) var buildError: String?
    /// Audio tracks soloed in the preview (a monitoring state, not part of the project).
    @Published var solo: Set<String> = [] { didSet { scheduleRebuild() } }

    private var builtFrom: Project?
    private var pendingBuild: DispatchWorkItem?
    private var waiters: [() -> Void] = []
    private var timeObserver: Any?
    private var generation = 0
    private var shuttle: Float = 0
    nonisolated private static let buildQueue = DispatchQueue(label: "regista.preview.build", qos: .userInitiated)  // l10n-ignore

    init() {
        let p = program.player
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.playhead.set(t.seconds) }
        }
        // The play icon follows the player's real rate (the time observer stops firing once the player stops, #32).
        rateObservation = p.observe(\.rate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rateChanged() } }
        }
    }

    private var rateObservation: NSKeyValueObservation?

    private func rateChanged() {
        let p = program.player
        isPlaying = p.rate != 0
        // Played to the end: park on the last frame, the end time itself has no picture (#32).
        if p.rate == 0, p.currentItem != nil, p.currentTime().seconds > lastFrame + 1e-3 { seek(lastFrame) }
    }

    var time: Double { playhead.time }
    var duration: Double { store?.project?.duration.seconds ?? 0 }
    /// Start of the last frame with a picture.
    var lastFrame: Double {
        guard let p = store?.project else { return 0 }
        return RenderJob.lastFrame(duration: p.duration, rate: p.settings.frameRate).seconds
    }

    /// Where the player goes after a rebuild and whether it plays on: the same time, clamped to the last frame, and
    /// playing only if it was playing before the end (resuming at the end would play the frameless end time, #32).
    nonisolated static func resume(at time: Double, lastFrame: Double, wasPlaying: Bool) -> (time: Double, play: Bool) {
        let t = max(0, min(time, lastFrame))
        return (t, wasPlaying && time < lastFrame - 1e-3)
    }

    /// The project the preview should play: muted and non-soloed audio tracks left out.
    private func previewProject() -> Project? {
        guard var p = store?.project else { return nil }
        if !solo.isEmpty {
            for i in p.tracks.indices where p.tracks[i].kind == .audio && !solo.contains(p.tracks[i].id) { p.tracks[i].muted = true }
        }
        return p
    }

    func projectChanged() { scheduleRebuild() }

    /// Its tab left the screen (S2 #76): the players let go of their items and the built composition; `projectChanged`
    /// rebuilds them when the tab is shown again. Not while a frame is being waited for (preview.frame).
    func suspend() {
        guard waiters.isEmpty else { return }
        pendingBuild?.cancel()
        pendingBuild = nil
        generation += 1
        program.player.pause()
        program.replace(nil)
        source.replace(nil)
        sourcePath = nil
        keepAlive = nil
        builtFrom = nil
    }

    private func scheduleRebuild(delay: Double = 0.12) {
        pendingBuild?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuild() } }
        pendingBuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuild() {
        pendingBuild = nil
        // A tab in the background builds no player (S2 #76), unless a frame is waited for (preview.frame).
        guard store?.isActive != false || !waiters.isEmpty else { return }
        let target = previewProject()
        guard target != builtFrom else { return flushWaiters() }
        generation += 1
        let gen = generation
        // A voice-only project plays too: its background and captions (#72).
        guard let target, target.duration > .zero else {
            builtFrom = target
            program.replace(nil)
            buildError = nil
            return flushWaiters()
        }
        Self.buildQueue.async {
            let result = Result { try PreviewPlayer.makeItem(target) }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                let last = RenderJob.lastFrame(duration: target.duration, rate: target.settings.frameRate).seconds
                let next = Self.resume(at: self.time, lastFrame: last, wasPlaying: self.program.player.rate != 0)
                switch result {
                case .success(let built):
                    self.program.replace(built.item)
                    self.keepAlive = built
                    self.buildError = nil
                    self.seek(next.time)
                    if next.play { self.program.player.play() }
                case .failure(let e):
                    self.program.replace(nil)
                    self.buildError = "\(e)"
                }
                self.builtFrom = target
                self.flushWaiters()
            }
        }
    }

    private var keepAlive: PreviewItem?

    private func flushWaiters() {
        let w = waiters
        waiters = []
        w.forEach { $0() }
    }

    /// Calls back once the player plays the current project.
    func whenCurrent(_ done: @escaping () -> Void) {
        if pendingBuild == nil, previewProject() == builtFrom { return done() }
        waiters.append(done)
        if pendingBuild != nil { pendingBuild?.cancel(); rebuild() } else if previewProject() != builtFrom { rebuild() }
    }

    // MARK: Transport

    func seek(_ seconds: Double) {
        let t = max(0, min(seconds, lastFrame))
        playhead.set(t)
        program.player.seek(to: CMTime(seconds: t, preferredTimescale: 30000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if program.player.rate != 0 { program.player.pause(); shuttle = 0 }
        else {
            if time >= lastFrame - 1e-3 { seek(0) }
            program.player.play()
        }
    }

    /// J / K / L: reverse, stop, forward; repeated J or L doubles the speed (up to 8×).
    func shuttle(_ direction: Int) {
        let p = program.player
        if direction == 0 { p.pause(); shuttle = 0; return }
        let d = Float(direction)
        shuttle = (shuttle * d > 0) ? min(abs(shuttle) * 2, 8) * d : d
        if shuttle < 0, !(p.currentItem?.canPlayReverse ?? false) {
            step(frames: -15)   // the custom compositor cannot always play backwards: jump back half a second
            shuttle = 0
            return
        }
        p.rate = shuttle
    }

    func step(frames: Int) {
        program.player.pause()
        seek((time * 30).rounded() / 30 + Double(frames) / 30)
    }

    // MARK: Source monitor

    private var sourcePath: String?
    func showSource(_ asset: MediaAsset?) {
        guard asset?.path != sourcePath, store?.isActive != false else { return }
        sourcePath = asset?.path
        guard let asset else { return source.replace(nil) }
        let path = asset.path, start = min(1, asset.duration.seconds / 2)
        Self.buildQueue.async {
            let (item, orientation) = PreviewPlayer.sourceItem(path: path)
            nonisolated(unsafe) let it = item
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.sourcePath == path else { return }
                    self.source.orientation = orientation
                    self.source.replace(it)
                    self.source.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }
}

/// The playhead, separate from the controller so only the views that follow it redraw at 30 Hz.
@MainActor
final class Playhead: ObservableObject {
    @Published private(set) var time: Double = 0
    func set(_ t: Double) { if abs(t - time) > 1e-4 { time = t } }
}
