import AppKit
import RegistaCore
import SwiftUI

// Ispettore › Schermo (R2 #51, #42 #43 #44): the look of a screen recording after it was recorded — where the face
// goes, the styled frame, the drawn cursor, the key badges, the automatic zoom and the output format. Each control is
// one command through the tab's store (ScreenLook); sliders commit once, on release. Whatever cannot apply to this take
// stays visible, disabled, with the reason.

struct ScreenLookSection: View {
    @EnvironmentObject private var store: EditorStore
    let target: ScreenLookTarget
    let project: Project
    @State private var drafts: [String: Double] = [:]

    var body: some View {
        let info = ScreenLook.sessionInfo(target.link)
        VStack(alignment: .leading, spacing: 0) {
            faceGroup
            frameGroup
            cursorGroup
            keysGroup(info)
            zoomGroup(info)
            formatGroup
        }
        .onChange(of: store.projectVersion) { drafts = [:] }
    }

    private func run(_ cmd: InspectorCommand) { store.run(cmd.id, cmd.params) }

    /// A slider row whose drag writes a draft and whose release runs `commit` (one undo step per gesture).
    private func slider(_ label: String, key: String, value: Double, range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String, parse: ((String) -> Double?)? = nil,
                        commit: @escaping (Double) -> InspectorCommand) -> some View {
        InspectorSlider(label: label, value: drafts[key] ?? value, range: range, step: step, format: format,
                        parse: parse ?? { Double($0.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }) },
                        onDrag: { drafts[key] = $0 },
                        onCommit: { v in
                            drafts[key] = v
                            guard abs(v - value) > 1e-6 else { return }
                            run(commit(v))
                        })
    }

    // MARK: Volto

    private var faceGroup: some View {
        InspectorGroup(title: loc("Volto")) {
            if let f = target.from, let e = target.to {
                note(String(format: loc("Vale per il tratto selezionato (%@ – %@)."), shortTime(f.seconds), shortTime(e.seconds)), symbol: "scissors")
            }
            FaceLayoutControls(layout: Binding(get: { target.layout }, set: { run(ScreenLook.layout($0, target)) }),
                               aspect: Double(project.settings.width) / Double(max(project.settings.height, 1)), hint: nil)
                .disabled(!target.hasCamera)
                .opacity(target.hasCamera ? 1 : 0.4)
            if !target.hasCamera {
                reason(loc("Questa registrazione non ha la camera: c'è solo lo schermo."))
            } else if target.layoutCount > 1 {
                note(String(format: loc("La registrazione cambia inquadratura %d volte: una scelta qui le sostituisce tutte. Seleziona una clip per cambiare solo quel tratto."),
                            target.layoutCount - 1), symbol: "info.circle")
            }
        }
    }

    // MARK: Cornice

    private var frameGroup: some View {
        let framable = LayoutSpec.framed.contains(target.layout.kind)
        let frame = target.layout.frame
        return InspectorGroup(title: loc("Cornice")) {
            RToggle(title: loc("Schermo su uno sfondo"), isOn: Binding(get: { frame != nil }, set: { run(ScreenLook.framed($0, target)) }),
                    subtitle: loc("Lo schermo intero, con margine, angoli arrotondati e ombra."))
                .disabled(!framable)
                .opacity(framable ? 1 : 0.4)
            if !framable {
                reason(loc("La cornice va con «Bolla» e «Solo schermo»."))
            } else if frame != nil {
                backgrounds(ScreenLook.background(frame))
                slider(loc("Margine"), key: "padding", value: ScreenLook.frameValue(.padding, target), range: 0...0.2, step: 0.005,
                       format: Fmt.percent, parse: Fmt.parsePercent) { ScreenLook.frame(.padding, $0, target) }
                slider(loc("Angoli"), key: "radius", value: ScreenLook.frameValue(.radius, target), range: 0...0.08, step: 0.002,
                       format: Fmt.percent, parse: Fmt.parsePercent) { ScreenLook.frame(.radius, $0, target) }
                slider(loc("Ombra"), key: "shadow", value: ScreenLook.frameValue(.shadow, target), range: 0...1, step: 0.05,
                       format: Fmt.percent, parse: Fmt.parsePercent) { ScreenLook.frame(.shadow, $0, target) }
            }
        }
    }

    /// The backgrounds as small previews of themselves: the kit's, the built-in gradients, the kit's colours, an image.
    @ViewBuilder private func backgrounds(_ current: ScreenBackground) -> some View {
        let brand = project.brand.map(Backdrop.brand) ?? Backdrop.preset("graphite")!
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: loc("Sfondo")).font(Ed.ui(12)).foregroundStyle(Ed.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                BackdropChip(backdrop: brand, title: project.brand == nil ? loc("Grafite") : loc("Marca"), on: current == .brand) {
                    run(ScreenLook.background(.brand, target))
                }
                ForEach(Backdrop.presets.filter { project.brand != nil || $0.name != "graphite" }, id: \.name) { p in
                    BackdropChip(backdrop: p.backdrop, title: Self.presetTitle(p.name), on: current == .preset(p.name)) {
                        run(ScreenLook.background(.preset(p.name), target))
                    }
                }
                BackdropChip(backdrop: nil, title: loc("Immagine"), on: { if case .image = current { true } else { false } }()) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { run(ScreenLook.background(.image(url.path), target)) }
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.colors(project.brand), id: \.self) { hex in
                    let on = current == .color(hex)
                    Button { run(ScreenLook.background(.color(hex), target)) } label: {
                        Circle().fill(Color(hexString: hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Ed.gold, lineWidth: on ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .tip("Sfondo in tinta unita")
                }
                Spacer()
            }
            .padding(.leading, 3).padding(.top, 2)
        }
    }

    static func presetTitle(_ name: String) -> String {
        switch name {
        case "graphite": loc("Grafite")
        case "aurum": loc("Oro")
        case "dusk": loc("Crepuscolo")
        case "lagoon": loc("Laguna")
        case "mist": loc("Nebbia")
        case "sand": loc("Sabbia")
        default: name
        }
    }

    /// Plain colours: the kit's by role, else neutral ones.
    static func colors(_ kit: BrandKit?) -> [String] {
        let roles = ["ink", "surface", "primary", "accent", "paper"]
        var out = roles.compactMap { kit?.colors[$0]?.uppercased() }.filter { Backdrop.rgb($0) != nil }
        for c in ["#000000", "#16171A", "#F4F4F2"] where out.count < 6 && !out.contains(c) { out.append(c) }
        return Array(NSOrderedSet(array: out).array.compactMap { $0 as? String }.prefix(7))
    }

    // MARK: Cursore

    private var cursorGroup: some View {
        let c = target.cursor
        let on = target.cursorDrawn
        return InspectorGroup(title: loc("Cursore")) {
            VStack(alignment: .leading, spacing: 10) {
                RToggle(title: loc("Cursore disegnato"), isOn: Binding(get: { c.visible }, set: { run(ScreenLook.cursor("visible", .bool($0), target)) }))
                slider(loc("Dimensione"), key: "cursorScale", value: c.scale, range: 0.5...4, step: 0.1,
                       format: { String(format: "%.1f×", $0) }) { ScreenLook.cursor("scale", .number(($0 * 10).rounded() / 10), target) }
                slider(loc("Fluidità"), key: "cursorSmoothing", value: c.smoothing, range: 0...1, step: 0.05,
                       format: Fmt.percent, parse: Fmt.parsePercent) { ScreenLook.cursor("smoothing", .number(($0 * 100).rounded() / 100), target) }
                RToggle(title: loc("Nascondi quando è fermo"), isOn: Binding(get: { c.hideWhenIdle }, set: { run(ScreenLook.cursor("hideWhenIdle", .bool($0), target)) }))
                RToggle(title: loc("Onda a ogni clic"), isOn: Binding(get: { c.clickRipple }, set: { run(ScreenLook.cursor("clickRipple", .bool($0), target)) }))
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.4)
            if !on {
                reason(loc("Il cursore è già nel video: per ridisegnarlo, registra con «Nascondi il cursore»."))
            }
        }
    }

    // MARK: Tasti premuti

    private func keysGroup(_ info: ScreenSessionInfo) -> some View {
        let s = ScreenLook.keysState(target, in: project)
        let available = info.keys > 0
        return InspectorGroup(title: loc("Tasti premuti")) {
            VStack(alignment: .leading, spacing: 10) {
                RToggle(title: loc("Mostra le scorciatoie"), isOn: Binding(get: { s.on }, set: { on in
                    var n = s; n.on = on; run(ScreenLook.keys(n, target))
                }), subtitle: available ? String(format: loc("Tasti registrati in questa ripresa: %d."), info.keys) : nil)
                row(loc("Posizione")) {
                    RSegmented(items: [("bottom", loc("Sotto")), ("top", loc("Sopra"))], selection: Binding(get: { s.position }, set: { v in
                        var n = s; n.position = v; run(ScreenLook.keys(n, target))
                    }))
                }
                .disabled(!s.on).opacity(s.on ? 1 : 0.5)
                row(loc("Quali")) {
                    RSegmented(items: [(false, loc("Scorciatoie")), (true, loc("Tutti i tasti"))], selection: Binding(get: { s.allKeys }, set: { v in
                        var n = s; n.allKeys = v; run(ScreenLook.keys(n, target))
                    }))
                }
                .disabled(!s.on).opacity(s.on ? 1 : 0.5)
            }
            .disabled(!available && !s.on)
            .opacity(available || s.on ? 1 : 0.4)
            if !available {
                reason(info.readable
                       ? loc("Nessun tasto registrato in questa ripresa: Regista registra i tasti solo con il permesso Accessibilità (Impostazioni di Sistema › Privacy e sicurezza › Accessibilità).")
                       : loc("Il file della sessione non si trova più: i tasti premuti non si possono leggere."))
            }
        }
    }

    // MARK: Zoom automatico

    private func zoomGroup(_ info: ScreenSessionInfo) -> some View {
        let z = ScreenLook.zoomState(target, in: project)
        let available = info.clicks > 0
        return InspectorGroup(title: loc("Zoom automatico")) {
            VStack(alignment: .leading, spacing: 10) {
                RToggle(title: loc("Zoom sui clic"), isOn: Binding(get: { z.on }, set: { on in
                    var n = z; n.on = on; run(ScreenLook.zoom(n, target))
                }), subtitle: available ? String(format: loc("Clic in questa ripresa: %d."), info.clicks) : nil)
                Group {
                    slider(loc("Intensità"), key: "zoom", value: z.zoom, range: 1.2...2.6, step: 0.05,
                           format: { String(format: "%.2f×", $0) }) { v in var n = z; n.zoom = v; return ScreenLook.zoom(n, target) }
                    RToggle(title: loc("Segui il cursore"), isOn: Binding(get: { z.follow }, set: { v in
                        var n = z; n.follow = v; run(ScreenLook.zoom(n, target))
                    }), subtitle: loc("L'inquadratura accompagna il puntatore anche tra un clic e l'altro."))
                    HStack {
                        EdButton(title: loc("Ricalcola"), symbol: "arrow.clockwise") { run(ScreenLook.zoom(z, target)) }
                        Spacer()
                    }
                }
                .disabled(!z.on).opacity(z.on ? 1 : 0.5)
            }
            .disabled(!available && !z.on)
            .opacity(available || z.on ? 1 : 0.4)
            if !available {
                reason(loc("Nessun clic registrato in questa ripresa: lo zoom automatico parte dai clic."))
            }
        }
    }

    // MARK: Formato di uscita

    private var formatGroup: some View {
        InspectorGroup(title: loc("Formato di uscita")) {
            RSegmented(items: ScreenLook.formats.map { ($0, $0) },
                       selection: Binding(get: { ScreenLook.formatID(project) ?? "" }, set: { run(ScreenLook.format($0)) }),
                       symbols: ["16:9": "rectangle", "9:16": "rectangle.portrait", "4:5": "rectangle.portrait", "1:1": "square"])
            note(loc("Il volto, la cornice, lo zoom e i tasti si ridispongono nel nuovo formato."), symbol: "aspectratio")
        }
    }

    // MARK: Pieces

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: loc(title)).font(Ed.ui(12)).foregroundStyle(Ed.text2).lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .leading)
            content()
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(Ed.icon(10.5)).foregroundStyle(Ed.text3).frame(width: 14)
            Text(verbatim: loc(text)).font(Ed.ui(11.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why a control is disabled.
    private func reason(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(Ed.icon(10.5)).foregroundStyle(Ed.warn).frame(width: 14)
            Text(verbatim: loc(text)).font(Ed.ui(11.5)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A frame background as a small preview of itself (the gradient drawn, an image icon), its name underneath.
struct BackdropChip: View {
    let backdrop: Backdrop?
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let b = backdrop { BackdropFill(backdrop: b) } else {
                        Ed.well
                        Image(systemName: "photo").font(Ed.icon(12)).foregroundStyle(Ed.text3)
                    }
                    // The screen floating on it, as the frame draws it.
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(backdrop == nil ? 0 : 0.18))
                        .padding(.horizontal, 9).padding(.vertical, 7)
                }
                .frame(height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Ed.gold : (hover ? Color.white.opacity(0.25) : Color.white.opacity(0.1)),
                                                                        lineWidth: on ? 1.5 : 1))
                Text(verbatim: loc(title)).font(Ed.ui(10.5, on ? .semibold : .regular)).foregroundStyle(on ? Ed.text : Ed.text3).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(loc(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A Backdrop drawn with SwiftUI gradients (the swatch; the export draws it with Core Image).
struct BackdropFill: View {
    let backdrop: Backdrop

    var body: some View {
        let colors = (backdrop.colors ?? ["#000000"]).map { Color(hexString: $0) }
        switch backdrop.kind {
        case .solid: colors[0]
        case .linear:
            // CSS angle: 0 = towards the top, 90 = towards the right.
            let a = (backdrop.angle ?? 180) * .pi / 180
            let dx = sin(a) / 2, dy = -cos(a) / 2
            LinearGradient(colors: colors, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
        case .radial:
            let c = backdrop.center ?? [0.5, 0.5]
            GeometryReader { geo in
                RadialGradient(colors: colors, center: UnitPoint(x: c[0], y: c[1]), startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 1.1)
            }
        case .image:
            if let path = backdrop.path, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Ed.well
            }
        }
    }
}
