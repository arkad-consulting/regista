import AVFoundation
import AppKit
import RegistaCore

/// Thumbnails and audio of the project's media, decoded once in the background and cached by file path.
@MainActor
final class MediaCache: ObservableObject {
    /// Bumped when new thumbnails or waveforms arrive (views redraw).
    @Published private(set) var revision = 0

    /// Thumbnail step in source time.
    static let thumbStep = 0.5
    private var thumbs: [String: [Int: CGImage]] = [:]
    private var requested: [String: Set<Int>] = [:]
    /// 48 kHz mono float samples per audio file.
    private var samples: [String: [Float]] = [:]
    /// Peak per 10 ms (480 samples) per audio file.
    private var peaks: [String: [Float]] = [:]
    private var decoding: Set<String> = []
    private var bumpScheduled = false
    nonisolated private static let queue = DispatchQueue(label: "regista.media", qos: .utility, attributes: .concurrent)  // l10n-ignore

    /// false while its tab is in the background (S2 #76): nothing is decoded or kept until the tab is shown again.
    private(set) var awake = true

    /// Its tab left the screen: the decoded thumbnails and audio go, and late results are dropped.
    func suspend() {
        awake = false
        thumbs = [:]
        requested = [:]
        samples = [:]
        peaks = [:]
        decoding = []
        revision += 1
    }

    /// Its tab is on screen again: views request what they draw.
    func resume() {
        guard !awake else { return }
        awake = true
        revision += 1
    }

    // MARK: Thumbnails

    /// The cached thumbnail nearest to `time` (requests it when missing).
    func thumbnail(_ path: String, at time: Double) -> CGImage? {
        let k = max(0, Int((time / Self.thumbStep).rounded()))
        if let img = thumbs[path]?[k] { return img }
        guard awake else { return nil }
        request(path, [k])
        return thumbs[path]?.min { abs($0.key - k) < abs($1.key - k) }?.value
    }

    /// A picture of the asset at source `time`: a frame of a video, or the image of a still / a frame of a PNG sequence
    /// (decoded with ImageIO: AVFoundation does not open pictures).
    func picture(_ a: MediaAsset, at time: Double) -> CGImage? {
        guard let im = a.image else { return thumbnail(a.path, at: time) }
        let file = im.kind == .still ? im.path : im.file(at: MediaTime(seconds: time))
        if let img = thumbs[file]?[0] { return img }
        guard awake, !(requested[file]?.contains(0) ?? false) else { return nil }
        requested[file, default: []].insert(0)
        Self.queue.async {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 240,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.awake else { return }
                self.thumbs[file, default: [:]][0] = img
                self.bump()
            }
        }
        return nil
    }

    private func request(_ path: String, _ keys: [Int]) {
        let fresh = keys.filter { !(requested[path]?.contains($0) ?? false) }
        guard !fresh.isEmpty else { return }
        requested[path, default: []].formUnion(fresh)
        Self.queue.async {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 180, height: 180)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
            for k in fresh {
                guard let img = try? gen.copyCGImage(at: CMTime(seconds: Double(k) * Self.thumbStep, preferredTimescale: 600), actualTime: nil) else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.awake else { return }
                    self.thumbs[path, default: [:]][k] = img
                    self.bump()
                }
            }
        }
    }

    private func bump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.bumpScheduled = false
            self?.revision += 1
        }
    }

    // MARK: Audio

    /// 10 ms peaks of an audio file (nil until decoded; decoding starts on first call).
    func peaks(_ path: String) -> [Float]? {
        if let p = peaks[path] { return p }
        decode(path)
        return nil
    }

    func samples(_ path: String) -> [Float]? {
        if let s = samples[path] { return s }
        decode(path)
        return nil
    }

    private func decode(_ path: String) {
        guard awake, !decoding.contains(path) else { return }
        decoding.insert(path)
        Self.queue.async {
            let s = Self.readMono48k(path) ?? []
            var p = [Float](repeating: 0, count: s.count / 480 + 1)
            for (i, x) in s.enumerated() { p[i / 480] = max(p[i / 480], abs(x)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.awake else { return }
                self.samples[path] = s
                self.peaks[path] = p
                self.bump()
            }
        }
    }

    /// The file's sound as 48 kHz float, channels averaged ((L+R)/2: identical channels stay as they are;
    /// AVFoundation's own downmix would add 3 dB).
    nonisolated static func readMono48k(_ path: String) -> [Float]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        nonisolated(unsafe) var channels = 1
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            if let f = try? await track?.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                channels = max(1, Int(asbd.mChannelsPerFrame))
            }
            sem.signal()
        }
        sem.wait()
        guard let track, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: min(channels, 2),
        ])
        let ch = min(channels, 2)
        reader.add(out)
        guard reader.startReading() else { return nil }
        var all: [Float] = []
        while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            if ch == 2 {
                all.reserveCapacity(all.count + n / 2)
                for i in stride(from: 0, to: n - 1, by: 2) { all.append(0.5 * (chunk[i] + chunk[i + 1])) }
            } else {
                all += chunk
            }
        }
        return all
    }
}
