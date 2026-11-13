import AVFoundation
import CoreImage
import Foundation
import RegistaCore

/// Draws one output frame of a RenderJob with Core Image: every visual layer (crop → Lanczos scale →
/// transform → ffmpeg-eq grade) over black, then the caption band. Colour is not managed: values go
/// from the source's Y'CbCr to R'G'B' and back to Y'CbCr unchanged, like an ffmpeg filter graph.
final class FrameDrawer: @unchecked Sendable {
    let job: RenderJob
    /// Project track id → composition track id.
    let trackIDs: [String: CMPersistentTrackID]
    /// Asset id → display orientation of its frames.
    let orientations: [String: CGImagePropertyOrientation]
    let context: CIContext
    let captions: CaptionBands?
    let states: [Captions.State]
    private var cache: [Int: CIImage] = [:]
    private let lock = NSLock()
    let graphics = GraphicsStore()
    let shapes = LayerShapes()
    let fx = FXStore()
    let motion = MotionStore()
    let backdrops = BackdropStore()

    init(job: RenderJob, trackIDs: [String: CMPersistentTrackID], orientations: [String: CGImagePropertyOrientation]) throws {
        self.job = job
        self.trackIDs = trackIDs
        self.orientations = orientations
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        if let c = job.captions {
            captions = try CaptionBands(job: job)
            states = c.states
        } else {
            captions = nil
            states = []
        }
    }

    var canvas: CGRect { CGRect(x: 0, y: 0, width: job.width, height: job.height) }

    /// The project's frame background (black by default; the dark backdrop of split layouts; the kit's surface when
    /// there is no picture, see `RenderJob.background`).
    var backgroundColor: CIColor {
        guard let hex = job.background else { return .black }
        let c = GraphicsStore.rgb(hex)
        return CIColor(red: c.0, green: c.1, blue: c.2)
    }

    func image(at time: MediaTime, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        var out = job.project.settings.backdrop.flatMap { backdrops.image($0, width: job.width, height: job.height, graphics: graphics) }
            ?? CIImage(color: backgroundColor).cropped(to: canvas)
        let layers = job.layers(at: time)
        let subjects = RenderJob.subjects(layers)
        var mattes: [Int: CIImage] = [:]
        for (i, layer) in layers.enumerated() {
            // A template that re-draws the picture under it (device frame) replaces what is drawn so far.
            if case .motion(let m, _, _, _) = layer.source, m.consumesBelow == true {
                if layer.opacity > 0.001, let drawn = motion.render(layer, job: job, below: out) { out = drawn.cropped(to: canvas) }
                continue
            }
            guard layer.opacity > 0.001, var drawn = picture(layer, source: source) else { continue }
            if layer.dim > 0 {
                // Picture fade to black (#79): premultiplied colour scaled down, coverage kept.
                let k = 1 - min(layer.dim, 1)
                drawn = drawn.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                                                                          "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                                                                          "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)])
            }
            let over = Self.blend(drawn, over: out, layer.blend)
            // Behind the subject: where the person of the full-frame layer below is, keep what was there before.
            if case .some(.some(let s)) = subjects[i], let matte = mattes[s] ?? matteImage(layers[s]) {
                mattes[s] = matte
                out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: over, kCIInputMaskImageKey: matte])
                    .cropped(to: canvas)
            } else {
                out = over
            }
        }
        let fx = job.frameFX(at: time)
        if !fx.isIdentity { out = apply(fx, to: out) }
        if let band = captionBand(at: time) { out = band.composited(over: out) }
        return out
    }

    /// One layer drawn on the canvas (nil when its picture is missing at this time).
    func picture(_ layer: VideoLayer, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        switch layer.source {
        case .video:
            guard let id = trackIDs[layer.trackID], let buffer = source(id) else { return nil }
            return draw(layer, withCursor(layer, CIImage(cvPixelBuffer: buffer)))
        case .image(let path):
            guard let img = graphics.image(path) else { return nil }
            return draw(layer, img, oriented: false)
        case .title(let title):
            guard let t = try? graphics.title(title, outputWidth: job.width) else { return nil }
            return placeNative(layer, content: CIImage(cgImage: t.image), anchor: t.anchor)
        case .sticker(let sticker):
            guard let img = fx.sticker(sticker, outputWidth: job.width) else { return nil }
            return placeNative(layer, content: CIImage(cgImage: img), anchor: CGPoint(x: Double(img.width) / 2, y: Double(img.height) / 2))
        case .shape(let shape, let progress):
            // Callouts are drawn in frame coordinates: only the layer's offset and opacity apply.
            guard var img = fx.shape(shape, progress: progress, w: job.width, h: job.height) else { return nil }
            if layer.x != 0 || layer.y != 0 {
                img = img.transformed(by: CGAffineTransform(translationX: layer.x * Double(job.width), y: -layer.y * Double(job.height)))
            }
            if layer.opacity < 1 {
                img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
            }
            return img.cropped(to: canvas)
        case .motion:
            return motion.render(layer, job: job, below: nil)?.cropped(to: canvas)
        }
    }

    /// The person matte of a full-frame layer, placed exactly like its picture (crop, scale, keyframes), on the canvas.
    func matteImage(_ layer: VideoLayer) -> CIImage? {
        guard let path = layer.matte, let m = graphics.image(path), layer.sourceWidth > 0, layer.sourceHeight > 0 else { return nil }
        let sx = Double(layer.sourceWidth) / m.extent.width, sy = Double(layer.sourceHeight) / m.extent.height
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(m.clampedToExtent().cropped(to: m.extent.insetBy(dx: -4, dy: -4)), forKey: kCIInputImageKey)
        lanczos.setValue(sy, forKey: kCIInputScaleKey)
        lanczos.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        let full = lanczos.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: layer.sourceWidth, height: layer.sourceHeight))
        var geometry = layer
        geometry.color = nil
        geometry.effects = []
        geometry.opacity = 1
        // Vision's matte is soft over ~10 px: steepen it around 0.5 (0.3 → 0, 0.7 → 1) so the type does not fade into
        // a halo around the head, keeping a few pixels of anti-aliasing.
        return draw(geometry, full, oriented: false)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0), "inputBiasVector": CIVector(x: -0.75, y: -0.75, z: -0.75, w: 0)])
            .applyingFilter("CIColorClamp")
            .cropped(to: canvas)
    }

    static func blend(_ top: CIImage, over bottom: CIImage, _ mode: BlendMode) -> CIImage {
        switch mode {
        case .normal: return top.composited(over: bottom)
        case .screen: return top.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: bottom])
        case .multiply: return top.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: bottom])
        }
    }

    /// Transitions and flashes on the whole picture (captions excluded).
    func apply(_ fx: FrameFX, to image: CIImage) -> CIImage {
        var out = image
        let W = Double(job.width), H = Double(job.height)
        if fx.shiftX != 0 || fx.shiftY != 0 || fx.blur > 0 {
            // Edges repeat (smear) instead of revealing black: it reads as a whip pan.
            out = out.clampedToExtent().transformed(by: CGAffineTransform(translationX: fx.shiftX * W, y: -fx.shiftY * H))
            if fx.blur > 0.5 {
                out = out.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: fx.blur,
                                                                     kCIInputAngleKey: fx.shiftY != 0 ? Double.pi / 2 : 0])
            }
            out = out.cropped(to: canvas)
        }
        if fx.defocus > 0.5 {
            out = out.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: fx.defocus]).cropped(to: canvas)
        }
        if fx.dip > 0 { out = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: fx.dip)).cropped(to: canvas).composited(over: out) }
        if fx.flash > 0 {
            let c = GraphicsStore.rgb(fx.flashColor)
            out = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2, alpha: fx.flash)).cropped(to: canvas).composited(over: out)
        }
        return out
    }

    func render(at time: MediaTime, source: (CMPersistentTrackID) -> CVPixelBuffer?, into buffer: CVPixelBuffer) {
        context.render(image(at: time, source: source), to: buffer, bounds: canvas, colorSpace: nil)
    }

    func draw(_ layer: VideoLayer, _ frame: CIImage, oriented: Bool = true) -> CIImage {
        var img = oriented ? frame.oriented(orientations[layer.clipID] ?? orientations[layer.assetID] ?? .up) : frame
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let (w, h, x, y) = (layer.crop[0], layer.crop[1], layer.crop[2], layer.crop[3])
        let rect = CGRect(x: x, y: Double(layer.sourceHeight) - y - h, width: w, height: h)
        if let p = layer.placement, p.fit == .box {
            return drawBox(layer, img, rect: rect)
        }
        if let p = layer.placement, p.fit != .fill {
            // Own size: the crop scaled with the output width (contain: fitted inside the frame), drawn around its centre.
            img = img.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let (bw, bh) = layer.baseSize(width: job.width, height: job.height)
            if abs(bw - w) > 0.5 || abs(bh - h) > 0.5 {
                let lanczos = CIFilter(name: "CILanczosScaleTransform")!
                lanczos.setValue(img, forKey: kCIInputImageKey)
                lanczos.setValue(bh / h, forKey: kCIInputScaleKey)
                lanczos.setValue((bw / w) / (bh / h), forKey: kCIInputAspectRatioKey)
                img = lanczos.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: bw, height: bh))
            }
            return placeNative(layer, content: img, anchor: CGPoint(x: bw / 2, y: bh / 2))
        }
        // Edge pixels are repeated outside the frame so the Lanczos kernel never sees transparency.
        img = img.clampedToExtent().cropped(to: rect.insetBy(dx: -8, dy: -8))
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let W = Double(job.width), H = Double(job.height)
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(img, forKey: kCIInputImageKey)
        lanczos.setValue(H / h, forKey: kCIInputScaleKey)
        lanczos.setValue((W / w) / (H / h), forKey: kCIInputAspectRatioKey)
        img = lanczos.outputImage!.cropped(to: canvas)
        if let b = layer.cameraBlur { img = Self.smear(img, b, size: canvas.size) }
        if layer.isSpatial {
            img = Self.project(img, corners: layer.corners(width: job.width, height: job.height), height: H)
        } else if layer.scale != 1 || layer.x != 0 || layer.y != 0 || layer.rotation != 0 {
            let c = CGPoint(x: W / 2, y: H / 2)
            let t = CGAffineTransform(translationX: c.x + layer.x * W, y: c.y - layer.y * H)
                .rotated(by: -layer.rotation * .pi / 180).scaledBy(x: layer.scale, y: layer.scale)
                .translatedBy(x: -c.x, y: -c.y)
            img = img.transformed(by: t)
        }
        if let color = layer.color, !color.isIdentity { img = Self.grade(img, color) }
        if let g = layer.grade { img = fx.applyGrade(g, to: img.cropped(to: canvas), canvas: canvas, outputWidth: job.width, fill: true) }
        img = effects(layer, img.cropped(to: canvas), fill: true)
        if layer.opacity < 1 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
        }
        return img.cropped(to: canvas)
    }

    /// A boxed layer (screen-recording layouts): the crop (already at the box's aspect) scaled to fill the box, cut
    /// to the mask's shape (and to the person for a cut-out), bordered, shadowed, then placed like a native picture.
    func drawBox(_ layer: VideoLayer, _ frame: CIImage, rect: CGRect) -> CIImage {
        let (bw, bh) = layer.baseSize(width: job.width, height: job.height)
        let w = max(Int(bw.rounded()), 1), h = max(Int(bh.rounded()), 1)
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        /// Crop → box, Lanczos, edges repeated so the kernel never sees transparency.
        func fitted(_ img: CIImage) -> CIImage {
            let src = img.clampedToExtent().cropped(to: rect.insetBy(dx: -8, dy: -8))
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let lanczos = CIFilter(name: "CILanczosScaleTransform")!
            lanczos.setValue(src, forKey: kCIInputImageKey)
            lanczos.setValue(Double(h) / rect.height, forKey: kCIInputScaleKey)
            lanczos.setValue((Double(w) / rect.width) / (Double(h) / rect.height), forKey: kCIInputAspectRatioKey)
            return lanczos.outputImage!.cropped(to: box)
        }
        var img = fitted(frame)
        if let b = layer.cameraBlur { img = Self.smear(img, b, size: box.size) }
        let clear = CIImage(color: .clear).cropped(to: box)
        let mask = layer.mask ?? LayerMask()
        if mask.cutout == true, let path = layer.matte, let m = graphics.image(path), layer.sourceWidth > 0, layer.sourceHeight > 0 {
            // The matte at the source frame's size, then cut and scaled exactly like the picture.
            let sx = Double(layer.sourceWidth) / m.extent.width, sy = Double(layer.sourceHeight) / m.extent.height
            let up = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6 * max(sx, sy)])
            var matte = LayerShapes.steepen(fitted(up.cropped(to: CGRect(x: 0, y: 0, width: layer.sourceWidth, height: layer.sourceHeight))))
            // Soft sides: shoulders cut by the camera frame fade out instead of ending on a hard vertical line.
            matte = LayerShapes.featherSides(matte, width: Double(w), box: box)
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: matte]).cropped(to: box)
        }
        if let shape = shapes.mask(mask, w: w, h: h) {
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: shape]).cropped(to: box)
        }
        let short = Double(min(job.width, job.height))
        if mask.cutout != true, let ring = shapes.border(mask, w: w, h: h, width: (mask.borderWidth ?? 0) * short / 1080) {
            img = ring.composited(over: img)
        }
        // Card frame decorations fade out while the card is zoomed up towards full frame (inset-frame's entrance and exit).
        var decor = shapes.decoration(mask, w: w, h: h, short: short)
        let fade = min(max((1.35 - layer.scale) / 0.35, 0), 1)
        if fade < 1 {
            let alpha = ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)]
            decor = (decor.under?.applyingFilter("CIColorMatrix", parameters: alpha), decor.over?.applyingFilter("CIColorMatrix", parameters: alpha))
        }
        if let over = decor.over { img = over.composited(over: img) }
        if let s = mask.shadow, s > 0, mask.frame != "float" {   // a floating screen draws its own shadow (decoration)
            img = img.composited(over: LayerShapes.shadow(of: img, opacity: s, radius: 0.022 * short, drop: 0.008 * short))
        }
        if let under = decor.under { img = img.composited(over: under) }
        return placeNative(layer, content: img, anchor: CGPoint(x: Double(w) / 2, y: Double(h) / 2))
    }

    /// A picture that keeps its own size: `anchor` (content pixels, bottom-left origin) goes to the layer centre,
    /// then scale and rotation around it; grade, effects and opacity follow.
    func placeNative(_ layer: VideoLayer, content: CIImage, anchor: CGPoint) -> CIImage {
        let H = Double(job.height)
        let (cx, cy) = layer.centre(width: job.width, height: job.height)
        var img: CIImage
        if layer.isSpatial {
            // 2.5D: the picture's rest centre (the anchor point sits on the layer centre), projected corner by corner.
            let w = content.extent.width, h = content.extent.height
            let rest = (cx + w / 2 - anchor.x, cy - (h / 2 - anchor.y))
            let corners = Projection.corners(w: w, h: h, centre: rest, scale: layer.scale, rotation: layer.rotation, anchorX: layer.anchorX,
                                             anchorY: layer.anchorY, rotationX: layer.rotationX, rotationY: layer.rotationY,
                                             distance: layer.perspective * Double(job.width) / SafeZones.referenceWidth)
            img = Self.project(content, corners: corners, height: H)
        } else {
            let t = CGAffineTransform(translationX: cx, y: H - cy).rotated(by: -layer.rotation * .pi / 180)
                .scaledBy(x: layer.scale, y: layer.scale).translatedBy(x: -anchor.x, y: -anchor.y)
            img = content.transformed(by: t)
        }
        if let color = layer.color, !color.isIdentity { img = Self.grade(img, color) }
        if let g = layer.grade { img = fx.applyGrade(g, to: img, canvas: canvas, outputWidth: job.width, fill: false) }
        img = effects(layer, img, fill: false)
        if layer.opacity < 1 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
        }
        return img.cropped(to: canvas)
    }

    /// Camera-move blur of a drawn crop (extent at the origin, `size`): the mean of copies scaled and shifted along the
    /// shutter's maps, as many as the smear needs (one every ~2.5 px, 3…24), so a pan, a zoom or both smear by exactly
    /// the camera's travel (CIMotionBlur only does straight lines, with a kernel longer than its radius). Edges repeat,
    /// so nothing transparent is pulled in.
    static func smear(_ image: CIImage, _ b: CameraBlur, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let W = Double(size.width), H = Double(size.height)
        let base = image.clampedToExtent()
        let taps = min(max(Int((b.length / 2.5).rounded(.up)), 3), 24)
        // A map u → u·k + d in top-left fractions, as a transform of bottom-left pixels.
        func transform(_ m: CameraBlur.Map) -> CGAffineTransform {
            CGAffineTransform(a: m.scale, b: 0, c: 0, d: m.scale, tx: m.dx * W, ty: H * (1 - m.scale - m.dy))
        }
        let weight = 1 / Double(taps)
        var sum: CIImage?
        for i in 0..<taps {
            let s = -1 + 2 * (Double(i) + 0.5) / Double(taps)
            let m = s < 0 ? b.back.scaled(-s) : b.forward.scaled(s)
            // CIColorMatrix works on unpremultiplied colour: scaling the alpha alone scales the premultiplied tap.
            let tap = base.transformed(by: transform(m)).cropped(to: rect)
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)])
            sum = sum.map { tap.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? tap
        }
        return (sum ?? image).cropped(to: rect)
    }

    /// A picture (extent at the origin) mapped onto four frame corners TL, TR, BR, BL (top-left origin pixels).
    static func project(_ image: CIImage, corners c: [(Double, Double)], height H: Double) -> CIImage {
        let e = image.extent
        let src = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        func v(_ p: (Double, Double)) -> CIVector { CIVector(x: p.0, y: H - p.1) }
        return src.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": v(c[0]), "inputTopRight": v(c[1]),
                                                                         "inputBottomRight": v(c[2]), "inputBottomLeft": v(c[3])])
    }

    /// The layer's Core Image effects. Full-frame layers are clamped first so blurs never pull in black edges.
    func effects(_ layer: VideoLayer, _ image: CIImage, fill: Bool) -> CIImage {
        var img = image
        for e in layer.effects {
            let s = e.strength
            let base = fill ? img.clampedToExtent() : img
            switch e.kind {
            case .blur:
                img = base.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: e.radius * s])
            case .glow:
                img = base.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: e.radius, kCIInputIntensityKey: s])
            case .vignette:
                img = base.applyingFilter("CIVignette", parameters: [kCIInputRadiusKey: 1 + e.radius, kCIInputIntensityKey: s * 1.2])
            case .sharpen:
                img = base.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6 * s, kCIInputRadiusKey: e.radius])
            case .lut:
                guard let path = e.path, let cube = graphics.cube(path) else { continue }
                let graded = base.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cube.size, "inputCubeData": cube.data])
                img = s >= 1 ? graded : graded.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: base, kCIInputTimeKey: 1 - s])
            case .glitch:
                img = FXStore.glitch(img, e, canvas: fill ? canvas : img.extent, outputWidth: job.width)
            case .chromaKey:
                img = fx.chromaKey(img, e)
            default: continue
            }
            img = img.cropped(to: fill ? canvas : image.extent.insetBy(dx: -3 * e.radius, dy: -3 * e.radius))
        }
        return img
    }

    /// ffmpeg `eq` (vf_eq.c process_c on 8-bit limited-range Y'CbCr: Y' = Y'·c + b, chroma scaled by s)
    /// as one colour matrix on R'G'B' (BT.709): M = A⁻¹·diag(c, s, s)·A plus the luma offset.
    static func grade(_ img: CIImage, _ e: ColorAdjust) -> CIImage {
        let ci = Int(e.contrast * 4096), si = Int(e.saturation * 4096)
        let c = Double(ci) / 4096, s = Double(si) / 4096
        let bi = Int(100 * e.brightness + 100) * 511 / 200 - 128 - ci / 32
        let offset = (16 * c + Double(bi) - 0.5 - 16) / 219   // limited-range luma → full range, mean floor error
        let kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb
        // A: R'G'B' → Y'CbCr; A⁻¹ back.
        let a = [[kr, kg, kb], [-kr / (2 * (1 - kb)), -kg / (2 * (1 - kb)), 0.5], [0.5, -kg / (2 * (1 - kr)), -kb / (2 * (1 - kr))]]
        let ai = [[1, 0, 2 * (1 - kr)], [1, -2 * (1 - kb) * kb / kg, -2 * (1 - kr) * kr / kg], [1, 2 * (1 - kb), 0]]
        let d = [c, s, s]
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { m[i][j] += ai[i][k] * d[k] * a[k][j] } } }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
            "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
            "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: offset, y: offset, z: offset, w: 0),
        ])
    }

    /// The caption band of the state showing at `time` (frame-exact from absolute word times), cached per state.
    func captionBand(at time: MediaTime) -> CIImage? {
        guard let captions, let k = states.firstIndex(where: { $0.start <= time && time < $0.end }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[k] { return cached }
        let s = states[k]
        let image = captions.state(s.chunk, count: s.count)
        let band = CIImage(cgImage: image)
        let o = captions.origin(chunk: s.chunk)
        let placed = band.transformed(by: CGAffineTransform(translationX: o.x, y: Double(job.height) - o.y - Double(image.height)))
        cache[k] = placed
        return placed
    }
}

/// The video composition instruction: one for the whole timeline, carrying the drawer.
final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let drawer: FrameDrawer

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], drawer: FrameDrawer) {
        self.timeRange = timeRange
        requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.drawer = drawer
    }
}

/// The custom AVVideoCompositing used by export.render and frame.render (and later the app's preview).
final class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    private let queue = DispatchQueue(label: "regista.compositor")
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    /// Tests only: called before each frame of a project is drawn, with the frame time; a hook that blocks reproduces
    /// a frame that never arrives (the export stall of #71). One hook per project name, so tests running in parallel
    /// keep their own.
    static let testHook = TestHook()

    final class TestHook: @unchecked Sendable {
        private let lock = NSLock()
        private var hooks: [String: @Sendable (MediaTime) -> Void] = [:]
        func set(_ project: String, _ h: (@Sendable (MediaTime) -> Void)?) { lock.lock(); hooks[project] = h; lock.unlock() }
        func callAsFunction(_ project: String, _ t: MediaTime) {
            lock.lock(); let h = hooks[project]; lock.unlock()
            h?(t)
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
                  let out = renderContext?.newPixelBuffer() else {
                request.finish(with: CommandError(.io, "compositor: no instruction or pixel buffer"))
                return
            }
            let t = request.compositionTime
            let time = MediaTime(value: t.value, timescale: Int64(t.timescale)).snapped(to: instruction.drawer.job.frameRate)
            Self.testHook(instruction.drawer.job.project.name, time)
            instruction.drawer.render(at: time, source: { request.sourceFrame(byTrackID: $0) }, into: out)
            AVRenderer.tag709(out)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
