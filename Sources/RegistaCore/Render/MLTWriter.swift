import Foundation

/// Writes the timeline as a Shotcut-compatible MLT XML project (the subset Shotcut itself saves, as in
/// the Python prototype's mltlib.py): profile, main_bin, black background, one <chain> per clip with its
/// filters inside (Shotcut "Crop: Source", avfilter.eq, 1-frame audio fades), playlists tagged
/// shotcut:video / shotcut:audio, mix + qtblend transitions (upper video tracks blend onto V1).
/// Captions become one full-frame transparent PNG per caption state on their own video track.
/// Graphics: stills and PNG sequences become `qimage` producers placed with Shotcut's "Size, Position & Rotate"
/// (`affine`, rest state), titles one full-frame transparent PNG each (drawn by the compositor), music and SFX audio
/// chains with "Gain" (`volume` level) and the ducking as keyframes of a second `volume` filter.
/// Limits: keyframed crops keep their first crop (Shotcut's crop filter is not animatable); transform scale/offset/
/// rotation of full-frame clips (overlays placed by hand keep position, size and rotation), overlay/title animations, effects, blend modes and transitions are not exported
/// (warnings say which); the export's final limiter and loudness correction are not in the project.
public struct MLTWriter {
    public var project: Project
    /// PNG per caption state, in `Captions.states` order (empty: no caption track).
    public var captionImages: [URL] = []
    public var captions: Captions?
    /// Full-frame PNG per title clip (clip id → file), drawn at rest by the compositor.
    public var layerImages: [String: URL] = [:]
    public private(set) var warnings: [String] = []

    public init(project: Project, captions: Captions?, captionImages: [URL], layerImages: [String: URL] = [:]) {
        self.project = project
        self.captions = captions
        self.captionImages = captionImages
        self.layerImages = layerImages
    }

    private var producers: [String] = []
    /// Clip id → volume keyframes ("frame=dB;…", relative to the clip) of ducked audio clips.
    private var ducking: [String: String] = [:]
    private var playlists: [(id: String, xml: String, video: Bool)] = []
    private var counters: [String: Int] = [:]

    private mutating func next(_ kind: String) -> String {
        let n = counters[kind, default: 0]
        counters[kind] = n + 1
        return "\(kind)\(n)"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func props(_ p: [(String, Any)], indent: String = "    ") -> String {
        p.map { "\(indent)<property name=\"\($0.0)\">\(esc("\($0.1)"))</property>\n" }.joined()
    }

    var fps: Double { project.settings.frameRate.doubleValue }
    func frames(_ t: MediaTime) -> Int { Int((t.seconds * fps).rounded()) }

    private mutating func filter(_ service: String, _ p: [(String, Any)], shotcut: String?, in i: Int, out o: Int) -> String {
        var all = [("mlt_service", service as Any)] + p
        if let shotcut { all.append(("shotcut:filter", shotcut)) }
        return "    <filter id=\"\(next("filter"))\" in=\"\(i)\" out=\"\(o)\">\n" + Self.props(all, indent: "      ") + "    </filter>\n"
    }

    private mutating func chain(_ clip: Clip, _ asset: MediaAsset, video: Bool) -> (id: String, in: Int, out: Int) {
        let id = next("chain")
        let length = Int((asset.duration.seconds * fps).rounded(.up))
        // A retimed clip (clip.speed) plays at normal speed in Shotcut for its timeline length (warned in xml()).
        let i = frames(clip.sourceIn), o = clip.speed == nil ? frames(clip.sourceOut) - 1 : min(i + max(frames(clip.duration), 1), length) - 1
        var xml = "  <chain id=\"\(id)\" out=\"\(length - 1)\">\n"
        xml += Self.props([("length", length), ("eof", "pause"), ("resource", asset.path), ("mlt_service", "avformat-novalidate"),
                           ("seekable", 1), ("audio_index", video ? -1 : 0), ("video_index", video ? 0 : -1),
                           ("mute_on_pause", 0), ("shotcut:caption", "\(asset.name) \(clip.id)")])
        if video, let v = asset.video {
            if let k = clip.keyframes, k.count > 1 { warnings.append("clip \(clip.id): keyframed crop exported as its first crop") }
            // Boxed layout layers keep their resting transform (their keyframes are entrances and zooms).
            let tr = (clip.placement?.fit == .box ? nil : clip.keyframes?.first?.transform) ?? clip.transform ?? Transform()
            if tr.scale != 1 || tr.x != 0 || tr.y != 0 || tr.rotation != 0 { warnings.append("clip \(clip.id): scale/offset/rotation not exported") }
            var c = tr.cropRect(sourceWidth: v.width, sourceHeight: v.height).map { Int($0.rounded()) }
            // A boxed layer (screen-recording layouts): the crop at the box's aspect, then "Size, Position & Rotate" into the box.
            var boxRect: [Double]?
            if clip.placement?.fit == .box {
                var rest = clip
                rest.keyframes = nil
                var p = project
                if let loc = p.locate(clip: clip.id) { p.tracks[loc.track].clips[loc.clip] = rest }
                let job = RenderJob(project: p, preset: ExportPreset.named(nil, project: p), captions: false)
                if let layer = job.layers(at: clip.start).first(where: { $0.clipID == clip.id }) {
                    c = layer.crop.map { Int($0.rounded()) }
                    boxRect = layer.box(width: project.settings.width, height: project.settings.height) + [layer.opacity]
                }
                if let m = clip.mask, m.shape != .rect || m.cutout == true {
                    warnings.append("clip \(clip.id): \(m.cutout == true ? "person cut-out" : m.shape.rawValue + " mask") not exported (drawn as a rectangle)")
                }
            }
            if c != [v.width, v.height, 0, 0] {
                xml += filter("crop", [("top", c[3]), ("bottom", v.height - c[3] - c[1]), ("left", c[2]), ("right", v.width - c[2] - c[0]),
                                       ("center", 0), ("center_bias", 0), ("use_profile", 1)], shotcut: "crop", in: i, out: o)
            }
            if let r = boxRect {
                let v = r.map { String(format: "%.1f", $0) }
                xml += filter("affine", [("background", "color:#00000000"), ("transition.fill", 1), ("transition.distort", 0),
                                         ("transition.rect", "\(v[0]) \(v[1]) \(v[2]) \(v[3]) \(String(format: "%.3f", r[4]))"),
                                         ("transition.valign", "middle"), ("transition.halign", "center"), ("transition.threads", 0)],
                              shotcut: "affineSizePosition", in: i, out: o)
            }
            if let e = clip.color, !e.isIdentity {
                xml += filter("avfilter.eq", [("av.brightness", e.brightness), ("av.contrast", e.contrast), ("av.saturation", e.saturation)],
                              shotcut: nil, in: i, out: o)
            }
            // Picture fades (#79) as Shotcut's brightness fades (to black).
            let d = o - i + 1
            if let f = clip.pictureFadeIn {
                let n = min(max(Int((f.seconds * fps).rounded()), 1), max(d - 1, 1))
                xml += filter("brightness", [("level", "0=0;\(n)=1"), ("alpha", 1), ("shotcut:animIn", n)], shotcut: "fadeInBrightness", in: i, out: o)
            }
            if let f = clip.pictureFadeOut {
                let n = min(max(Int((f.seconds * fps).rounded()), 1), max(d - 1, 1))
                xml += filter("brightness", [("level", "\(d - 1 - n)=1;\(d - 1)=0"), ("alpha", 1), ("shotcut:animOut", n)], shotcut: "fadeOutBrightness", in: i, out: o)
            }
        } else {
            let d = o - i + 1
            if let f = clip.fadeIn {
                let n = min(max(Int((f.seconds * fps).rounded()), 1), max(d - 1, 1))
                xml += filter("volume", [("window", 75), ("max_gain", "20dB"), ("level", "0=-60;\(n)=0"), ("shotcut:animIn", n)], shotcut: "fadeInVolume", in: i, out: o)
            }
            if let f = clip.fadeOut {
                let n = min(max(Int((f.seconds * fps).rounded()), 1), max(d - 1, 1))
                xml += filter("volume", [("window", 75), ("max_gain", "20dB"), ("level", "\(d - 1 - n)=0;\(d - 1)=-60"), ("shotcut:animOut", n)],
                              shotcut: "fadeOutVolume", in: i, out: o)
            }
            if let g = clip.gain, g != 0 {
                xml += filter("volume", [("level", String(format: "%.2f", g))], shotcut: "audioGain", in: i, out: o)
            }
            if let keys = ducking[clip.id], !keys.isEmpty {
                xml += filter("volume", [("level", keys)], shotcut: "audioGain", in: i, out: o)
            }
        }
        producers.append(xml + "  </chain>\n")
        return (id, i, o)
    }

    /// A title (its full-frame PNG) or an image asset (still / sequence) as a qimage producer, placed with
    /// "Size, Position & Rotate" at its rest state.
    private mutating func imageEntry(_ clip: Clip) -> (Int, String, Int)? {
        let n = max(frames(clip.start + clip.duration) - frames(clip.start), 1)
        let id = next("producer")
        var props: [(String, Any)]
        var rect: [Double]?
        var rotation = 0.0
        if clip.keyframes?.isEmpty == false { warnings.append("clip \(clip.id): animation not exported (rest state)") }
        if clip.isGenerated {
            guard let png = layerImages[clip.id] else { warnings.append("title \(clip.id): no image (no compositor in this host)"); return nil }
            props = [("length", n), ("eof", "pause"), ("resource", png.path), ("ttl", 1), ("aspect_ratio", 1), ("progressive", 1),
                     ("seekable", 1), ("mlt_service", "qimage"), ("shotcut:caption", "title \(clip.title?.text ?? "")")]
        } else {
            guard let a = project.asset(clip.assetID), let im = a.image, let v = a.video else { return nil }
            if im.kind == .still {
                props = [("length", n), ("eof", "pause"), ("resource", im.path), ("ttl", 1), ("aspect_ratio", 1), ("progressive", 1),
                         ("seekable", 1), ("mlt_service", "qimage"), ("shotcut:caption", a.name)]
            } else {
                props = [("length", im.count), ("eof", "pause"), ("resource", im.path), ("begin", im.first + frames(clip.sourceIn)), ("ttl", 1),
                         ("aspect_ratio", 1), ("progressive", 1), ("seekable", 1), ("mlt_service", "qimage"), ("shotcut:caption", a.name)]
            }
            let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
            var rest = clip
            rest.keyframes = nil
            rest.effects = nil
            var p = project
            if let loc = p.locate(clip: clip.id) { p.tracks[loc.track].clips[loc.clip] = rest }
            var j = job
            j.project = p
            let mid = (clip.start + MediaTime(seconds: clip.duration.seconds / 2)).snapped(to: project.settings.frameRate)
            if var layer = j.layers(at: mid).first(where: { $0.clipID == clip.id }) {
                layer.ink = nil   // the whole picture is placed, transparent margins included
                // Shotcut's rectangle is the unrotated picture; the filter turns it around its centre.
                var flat = layer
                flat.rotation = 0
                let b = flat.box(width: project.settings.width, height: project.settings.height)
                if layer.placement != nil || b != [0, 0, Double(project.settings.width), Double(project.settings.height)] {
                    rect = b + [layer.opacity]
                }
                rotation = layer.rotation
            }
            _ = v
        }
        var xml = "  <producer id=\"\(id)\" in=\"0\" out=\"\(n - 1)\">\n" + Self.props(props)
        if let r = rect {
            let v = r.map { String(format: "%.1f", $0) }
            xml += filter("affine", [("background", "color:#00000000"), ("transition.fill", 1), ("transition.distort", 0),
                                     ("transition.rect", "\(v[0]) \(v[1]) \(v[2]) \(v[3]) \(String(format: "%.3f", r[4]))"),
                                     ("transition.valign", "middle"), ("transition.halign", "center"), ("transition.threads", 0)]
                                     + (rotation != 0 ? [("transition.fix_rotate_x", String(format: "%.2f", rotation))] : []),
                          shotcut: "affineSizePosition", in: 0, out: n - 1)
        }
        producers.append(xml + "  </producer>\n")
        return (frames(clip.start), "    <entry producer=\"\(id)\" in=\"0\" out=\"\(n - 1)\"/>\n", n)
    }

    /// Ducking envelopes as volume keyframes per clip of each ducked track (linear in dB between the ramp points).
    private mutating func computeDucking() {
        for track in project.tracks where track.kind == .audio {
            guard let d = track.ducking, let source = project.tracks.first(where: { $0.id == d.sourceTrack }) else { continue }
            let regions = DuckingEnvelope.regions(of: source, in: project, mergeGap: d.mergeGap)
            for clip in track.clips {
                let c0 = clip.start.seconds, c1 = clip.end.seconds
                var points: [(Int, Double)] = [(0, 0)]
                for (a, b) in regions where b + d.release > c0 && a - d.attack < c1 {
                    for (t, g) in [(a - d.attack, 0.0), (a, d.depth), (b, d.depth), (b + d.release, 0.0)] where t > c0 && t < c1 {
                        let f = Int(((t - c0) * fps).rounded())
                        if let last = points.last, f <= last.0 { points[points.count - 1] = (last.0, min(last.1, g)) } else { points.append((f, g)) }
                    }
                }
                if points.count > 1 { ducking[clip.id] = points.map { "\($0.0)=\(String(format: "%.1f", $0.1))" }.joined(separator: ";") }
            }
        }
    }

    private mutating func playlist(_ name: String, audio: Bool, entries: [(start: Int, xml: String, length: Int)]) {
        let id = next("playlist")
        var xml = "  <playlist id=\"\(id)\">\n" + Self.props([(audio ? "shotcut:audio" : "shotcut:video", 1), ("shotcut:name", name)])
        var cursor = 0
        for e in entries.sorted(by: { $0.start < $1.start }) where e.length > 0 && e.start >= cursor {
            if e.start > cursor { xml += "    <blank length=\"\(e.start - cursor)\"/>\n" }
            xml += e.xml
            cursor = e.start + e.length
        }
        playlists.append((id, xml + "  </playlist>\n", !audio))
    }

    public mutating func xml() -> String {
        let s = project.settings
        let total = max(frames(project.duration), 1)
        computeDucking()
        if project.transitions?.isEmpty == false { warnings.append("transitions (flash/whip/dip) are not exported") }
        if let bg = project.settings.background { warnings.append("frame background \(bg) not exported (black)") }
        if let b = project.settings.backdrop { warnings.append("frame backdrop \(b.label) not exported (black)") }
        if project.grade != nil { warnings.append("look/adjustments of the whole picture not exported") }
        for r in project.recordings ?? [] where r.cursorInVideo == false && (r.cursor ?? CursorStyle()).visible {
            warnings.append("recording \(r.id): drawn cursor not exported (the take has no cursor in the video)")
        }
        for track in project.tracks {
            for clip in track.clips {
                if let sp = clip.speed {
                    let what = sp.freeze == true ? "freeze frame" : sp.reverse == true ? "reverse" : sp.isRamp ? "speed ramp" : "speed \(sp.rate)×"
                    warnings.append("clip \(clip.id): \(what) not exported (plays at normal speed for its length)")
                }
                if clip.grade != nil { warnings.append("clip \(clip.id): look/adjustments not exported") }
                if let m = clip.motion { warnings.append("clip \(clip.id): motion template \(m.template) exported as one still picture (not animated)") }
                if let sh = clip.shape { warnings.append("clip \(clip.id): \(sh.kind == .progressBar ? "progress bar exported half filled, not moving" : "callout exported fully drawn (no draw-on)")") }
            }
        }
        for track in project.tracks where track.kind == .video || track.kind == .overlay {
            var entries: [(Int, String, Int)] = []
            for clip in track.clips {
                if clip.effects?.isEmpty == false { warnings.append("clip \(clip.id): effects not exported") }
                if let b = clip.blend, b != .normal { warnings.append("clip \(clip.id): blend mode \(b.rawValue) not exported") }
                if clip.behindSubject == true { warnings.append("clip \(clip.id): behind the subject not exported (drawn over the person)") }
                if clip.isGenerated || project.asset(clip.assetID)?.image != nil {
                    if let e = imageEntry(clip) { entries.append(e) }
                    continue
                }
                guard let a = project.asset(clip.assetID), a.video != nil else { continue }
                let c = chain(clip, a, video: true)
                entries.append((frames(clip.start), "    <entry producer=\"\(c.id)\" in=\"\(c.in)\" out=\"\(c.out)\"/>\n", c.out - c.in + 1))
            }
            playlist(track.name, audio: false, entries: entries)
        }
        if let captions, !captionImages.isEmpty {
            var entries: [(Int, String, Int)] = []
            for (k, st) in captions.states.enumerated() where k < captionImages.count {
                // Frames whose time is in [start, end), never past the end of the timeline.
                let a = Int((st.start.seconds * fps - 1e-6).rounded(.up)), b = min(Int((st.end.seconds * fps - 1e-6).rounded(.up)), total)
                guard b > a else { continue }
                let id = next("producer")
                producers.append("  <producer id=\"\(id)\" in=\"0\" out=\"\(b - a - 1)\">\n" + Self.props([
                    ("length", b - a), ("eof", "pause"), ("resource", captionImages[k].path), ("ttl", 1), ("aspect_ratio", 1),
                    ("progressive", 1), ("seekable", 1), ("mlt_service", "qimage"), ("shotcut:caption", captions.chunks[st.chunk].text),
                ]) + "  </producer>\n")
                entries.append((a, "    <entry producer=\"\(id)\" in=\"0\" out=\"\(b - a - 1)\"/>\n", b - a))
            }
            playlist("Captions", audio: false, entries: entries)
        }
        for track in project.tracks where track.kind == .audio {
            var entries: [(Int, String, Int)] = []
            for clip in track.clips {
                guard let a = project.asset(clip.assetID), a.audio != nil else { continue }
                let c = chain(clip, a, video: false)
                entries.append((frames(clip.start), "    <entry producer=\"\(c.id)\" in=\"\(c.in)\" out=\"\(c.out)\"/>\n", c.out - c.in + 1))
            }
            playlist(track.name, audio: true, entries: entries)
        }

        let g = Int(Rational.gcd(Int64(s.width), Int64(s.height)))
        var out = "<?xml version=\"1.0\" standalone=\"no\"?>\n"
        out += "<mlt LC_NUMERIC=\"C\" version=\"7.41.0\" title=\"Shotcut version 26.9.28 (\(Self.esc(project.name)))\" producer=\"main_bin\">\n"
        out += "  <profile description=\"Regista \(s.width)x\(s.height) \(s.frameRate)\" width=\"\(s.width)\" height=\"\(s.height)\" progressive=\"1\" sample_aspect_num=\"1\" sample_aspect_den=\"1\" display_aspect_num=\"\(s.width / g)\" display_aspect_den=\"\(s.height / g)\" frame_rate_num=\"\(s.frameRate.num)\" frame_rate_den=\"\(s.frameRate.den)\" colorspace=\"709\"/>\n"
        out += "  <playlist id=\"main_bin\">\n" + Self.props([("xml_retain", 1)]) + "  </playlist>\n"
        out += producers.joined()
        out += "  <producer id=\"black\" in=\"0\" out=\"\(total - 1)\">\n" + Self.props([
            ("length", total), ("eof", "pause"), ("resource", 0), ("aspect_ratio", 1), ("mlt_service", "color"),
            ("mlt_image_format", "rgba"), ("set.test_audio", 0)]) + "  </producer>\n"
        out += "  <playlist id=\"background\">\n    <entry producer=\"black\" in=\"0\" out=\"\(total - 1)\"/>\n  </playlist>\n"
        out += playlists.map(\.xml).joined()
        out += "  <tractor id=\"tractor0\" title=\"Shotcut project\" in=\"0\" out=\"\(total - 1)\">\n"
        out += Self.props([("shotcut", 1), ("shotcut:projectAudioChannels", 2), ("shotcut:projectFolder", 0)])
        out += "    <track producer=\"background\"/>\n"
        for p in playlists { out += "    <track producer=\"\(p.id)\"\(p.video ? "" : " hide=\"video\"")/>\n" }
        var bottomVideo: Int?
        for (i, p) in playlists.enumerated() {
            let b = i + 1
            out += "    <transition id=\"\(next("transition"))\">\n" + Self.props([("a_track", 0), ("b_track", b), ("mlt_service", "mix"),
                                                                                ("always_active", 1), ("sum", 1)], indent: "      ") + "    </transition>\n"
            if p.video {
                out += "    <transition id=\"\(next("transition"))\">\n" + Self.props([
                    ("a_track", bottomVideo ?? 0), ("b_track", b), ("version", "0.1"), ("mlt_service", "qtblend"), ("threads", 0),
                    ("disable", bottomVideo == nil ? 1 : 0)], indent: "      ") + "    </transition>\n"
                bottomVideo = bottomVideo ?? b
            }
        }
        return out + "  </tractor>\n</mlt>\n"
    }
}
