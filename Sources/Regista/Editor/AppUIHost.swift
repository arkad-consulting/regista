import AVFoundation
import AppKit
import ImageIO
import RegistaCore
import RegistaEngines
import ScreenCaptureKit
import SwiftUI

/// `UIHost` for the engine: ui.screenshot draws the app's own window (no Screen Recording permission:
/// AppKit renders the view hierarchy into a bitmap, the video monitors included because they draw their
/// frames in `draw(_:)`); preview.frame pulls a frame from the live preview player. Called on the engine
/// queue, never on the main thread.
final class AppUIHost: UIHost, @unchecked Sendable {
    weak var store: EditorStore?
    /// The main window (set by `WindowAccessor`).
    weak var window: NSWindow?
    /// The recorder (Registra renders draw its devices and permissions).
    weak var recorder: Recorder?

    /// Builds a root view showing a navigation state (activity, level, tabs), with the app's environment (set
    /// by AppState).
    var makeRoot: (@MainActor (Navigation) -> AnyView)?
    /// Wraps any view in the app's environment (the Marca picker, Settings, the voice sheet).
    var makeView: (@MainActor (AnyView) -> AnyView)?
    /// Builds a root view for another store (a scratch tab a render opened a project in, ui.screenshot `inspector.project`).
    var makeRootFor: (@MainActor (EditorStore, Navigation) -> AnyView)?
    @MainActor private var offscreen: NSWindow?
    /// The teleprompter copy an offscreen render shows (kept alive until it is drawn).
    @MainActor private var previewController: TeleprompterController?

    /// Renders the editor into an offscreen window at the requested size: works while the screen is locked
    /// or the window is hidden, and never changes what the user is looking at.
    func screenshot(workspace: String?, width: Int?, height: Int?, canvas: JSONValue?, record: JSONValue?, voice: JSONValue?, tabs: Int?,
                    inspector: JSONValue?, texts: JSONValue?, jobs: JSONValue?, audio: JSONValue?, to output: URL) throws -> (width: Int, height: Int, shown: JSONValue) {
        precondition(!Thread.isMainThread)
        // `inspector.project`: a project opened in a scratch store for this render only (never a tab, never saved).
        var scratch: EditorStore?
        if let path = inspector?["project"]?.stringValue {
            let s = DispatchQueue.main.sync { MainActor.assumeIsolated { store.map { EditorStore(bench: $0.bench, tabID: "render") } } }
            guard let s else { throw CommandError(.io, "ui.screenshot: the editor is not ready") }  // l10n-ignore
            do { try s.engine.execute("project.open", params: ["path": .string(path)]) }
            catch { throw CommandError(.io, "ui.screenshot: inspector.project: \(error)") }  // l10n-ignore
            DispatchQueue.main.sync { MainActor.assumeIsolated { s.refreshFromEngine() } }
            scratch = s
        }
        // Impostazioni › Motori draws engines.status taken now (this runs on the tab's engine queue), as on a forced tier.
        let enginesTier = workspace.flatMap { w in w.hasPrefix("settings-engines-") ? MachineTier(rawValue: String(w.dropFirst(17))) : nil }
        let enginesStatus = workspace?.hasPrefix("settings-engines") == true ? try? store?.engine.execute("engines.status") : nil
        let audioDemo = AudioDemo.from(audio)
        var problem: String?
        var host: NSView?
        var shown: JSONValue = .null
        var canvasShown = false
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let store, let makeRoot else { problem = "the editor is not ready"; return }  // l10n-ignore
                let live = window?.contentView?.bounds.size
                let view: NSView
                if let w = workspace, w.hasPrefix("teleprompter") {
                    // The teleprompter window (never captured on screen), showing the project's script mid-reading.
                    let size = CGSize(width: width ?? Int(TeleprompterController.defaultSize.width), height: height ?? Int(TeleprompterController.defaultSize.height))
                    let c = TeleprompterController.preview(text: store.project?.script?.prompt ?? TeleprompterController.shared.text,
                                                           mirror: w == "teleprompter-mirror", fontSize: TeleprompterController.shared.fontSize)
                    view = NSHostingView(rootView: TeleprompterView(controller: c, settled: true))
                    view.frame = CGRect(origin: .zero, size: size)
                    previewController = c
                    shown = ["workspace": .string(w), "sentences": .number(Double(c.prompt.sentences.count)),
                             "cursor": .number(Double(c.follower.cursor)), "keywords": .array(c.prompt.keywords.map { .string($0) }),
                             "excludedFromScreenCapture": .bool(TeleprompterController.makePanel(frame: .zero, capturable: false).sharingType == .none)]
                } else if workspace == "brand-picker", let makeView {
                    // The Marca picker (the toolbar's popover in the app): the one place the project's kit is picked (E4 #3).
                    BrandKitLibrary.shared.reload()
                    let size = CGSize(width: width ?? Int(BrandPicker.width), height: height ?? Int(BrandPicker.height(kits: BrandKitLibrary.shared.kits.count)))
                    view = NSHostingView(rootView: makeView(AnyView(BrandPicker().frame(width: size.width, height: size.height).background(Ed.side)
                        .environment(\.colorScheme, .dark))))
                    view.frame = CGRect(origin: .zero, size: size)
                    shown = ["workspace": "brand-picker", "kits": .array(BrandKitLibrary.shared.kits.map { .string($0.id) }),
                             "active": store.project?.brand.map { .string($0.id) } ?? .null]
                } else if let w = workspace, w == "voice" || w == "voice-setup" || w == "settings-voice", let makeView {
                    // The voice screens (V1 #61, V2 #62), from sample data when `voice` names a state.
                    let state = voice?["state"]?.stringValue
                    let demo = state.map { VoiceDemo.model($0, tier: voice?["tier"]?.stringValue) }
                    let size: CGSize
                    switch w {
                    case "voice-setup":
                        size = CGSize(width: width ?? Int(VoiceSetupView.size.width), height: height ?? Int(VoiceSetupView.size.height))
                        view = NSHostingView(rootView: makeView(AnyView(VoiceSetupSheet().environment(\.voiceDemo, demo))))
                    case "settings-voice":
                        size = CGSize(width: width ?? Int(SettingsView.size.width), height: height ?? Int(SettingsView.size.height))
                        view = NSHostingView(rootView: makeView(AnyView(SettingsView(pinned: .voice, voiceProfiles: demo == nil ? nil : VoiceDemo.profiles)
                            .environment(\.voiceDemo, demo).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))))
                    default:
                        size = CGSize(width: width ?? Int(live?.width ?? 1440), height: height ?? Int(live?.height ?? 900))
                        view = NSHostingView(rootView: AnyView(makeRoot(Self.navigation(for: "voice", current: store.nav)).environment(\.voiceDemo, demo)))
                    }
                    view.frame = CGRect(origin: .zero, size: size)
                    let m = demo ?? store.voice
                    var o: [String: JSONValue] = ["workspace": .string(w), "state": state.map { .string($0) } ?? "live",
                                                  "panel": .string("\(m.state)"), "step": .string(m.setupStep.rawValue),
                                                  "tier": .string(m.snapshot.tier), "profile": m.snapshot.profile.map { .string($0) } ?? .null,
                                                  "languages": .array(m.snapshot.languages.map { .string($0.code) })]
                    if let l = m.snapshot.language(m.setup.language ?? m.activeLanguage?.code) {
                        o["trainBlocked"] = VoiceTraining.blockReason(m.snapshot, language: l, lookup: loc).map { .string($0) } ?? .null
                    }
                    shown = .object(o)
                } else if let w = workspace, w == "settings" || w.hasPrefix("settings-"), let makeView {
                    // The Settings window (its own size) on one tab (M2 #59): settings = the General tab; settings-engines-<tier>
                    // draws Motori as on that tier, from engines.status taken for the render (engines.json is not touched).
                    let tab = SettingsTab.allCases.first { w.hasPrefix($0.screenshotName) } ?? .general
                    // Motori and Brand kit are drawn whole (every engine, the whole kit editor), the other tabs at the window's size.
                    let size = CGSize(width: width ?? Int(SettingsView.size.width),
                                      height: height ?? (tab == .engines ? SettingsView.enginesRenderHeight
                                                                       : tab == .brand ? SettingsView.brandRenderHeight : Int(SettingsView.size.height)))
                    let demo = enginesStatus.map { EnginesDemo(status: $0, tier: enginesTier) }
                    view = NSHostingView(rootView: makeView(AnyView(SettingsView(pinned: tab, engines: demo, height: size.height)
                        .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))))
                    view.frame = CGRect(origin: .zero, size: size)
                    var o: [String: JSONValue] = ["workspace": .string(w), "tab": .string(tab.rawValue)]
                    if let status = enginesStatus {
                        let c = EngineCatalog(status: status, tier: enginesTier)
                        o["tier"] = .string(c.tier.rawValue)
                        o["rows"] = .number(Double(c.rows.count))
                        o["needsTier"] = .array(c.rows.filter { if case .needsTier = $0.state { true } else { false } }.map { .string($0.id) })
                        o["installable"] = .array(c.rows.filter { $0.action == .install }.map { .string($0.id) })
                    }
                    shown = .object(o)
                } else if let inspector {
                    // The Ispettore tab for a selection (E1 #53), on the active tab or a scratch copy of a project.
                    let target = scratch ?? store
                    let size = CGSize(width: width ?? Int(live?.width ?? 1440), height: height ?? Int(live?.height ?? 900))
                    var nav = Self.navigation(for: workspace ?? "edit-pro", current: store.nav)
                    nav.rightTab = .inspector
                    let sel = Self.inspectorSelection(inspector["select"]?.stringValue ?? "none", in: target)
                    if let tab = audioDemo?.tab { nav.soundTab = tab }
                    let root = scratch != nil ? makeRootFor?(target, nav) : makeRoot(nav)
                    guard let root else { problem = "the editor is not ready"; return }  // l10n-ignore
                    view = NSHostingView(rootView: root.environment(\.inspectorDemo, sel).environment(\.audioDemo, audioDemo))
                    view.frame = CGRect(origin: .zero, size: size)
                    shown = Self.describe(target, nav: nav, width: size.width)
                    if case .object(var o) = shown {
                        let t = InspectorTarget.resolve(sel, in: target.project)
                        o["inspector"] = ["kind": .string(t.kind.rawValue), "clips": .array(t.clipIDs.map { .string($0) }),
                                          "sections": .array(t.sections(in: target.project).map { .string($0.rawValue) }),
                                          "caption": sel.caption.map { ["trackId": .string($0.trackID), "chunk": .number(Double($0.chunk))] } ?? .null,
                                          "scratch": .bool(scratch != nil)]
                        shown = .object(o)
                    }
                } else {
                    let size = CGSize(width: width ?? Int(live?.width ?? 1440), height: height ?? Int(live?.height ?? 900))
                    var nav = Self.navigation(for: workspace, current: store.nav)
                    // `texts`: the steps from sample data (E2 #54); `jobs`: sample jobs in the status bar.
                    let stepsDemo = texts?["state"]?.stringValue.map { StepsDemo.snapshot($0, tier: texts?["tier"]?.stringValue ?? "medium") }
                    if stepsDemo != nil { nav.textsTab = .steps }
                    let jobsDemo = jobs.map { JobsDemo.samples(open: $0["open"]?.boolValue ?? true) }
                    if let tab = audioDemo?.tab { nav.soundTab = tab }
                    let ws = nav.workspace
                    let demo = canvas.flatMap(Self.canvasDemo)
                    // Registra is always drawn from a value (the current choices, or `record`'s state): the live capture
                    // layers never draw offscreen, and a demo state must not reach the recorder or the saved choices.
                    if ws == .record { recorder?.refreshDevices() }   // device names even before Registra was opened
                    let recordDemo = ws == .record ? recorder.map { Self.recordDemo(record, from: $0.sources) } : nil
                    // `tabs`: the active tab and sample ones, drawn instead of the open tabs (no project is opened).
                    let tabsDemo = tabs.map { TabInfo.samples($0, active: TabInfo(store)) }
                    view = NSHostingView(rootView: makeRoot(nav).environment(\.canvasDemo, demo).environment(\.recordDemo, recordDemo)
                        .environment(\.tabsDemo, tabsDemo).environment(\.stepsDemo, stepsDemo).environment(\.jobsDemo, jobsDemo)
                        .environment(\.audioDemo, audioDemo))
                    view.frame = CGRect(origin: .zero, size: size)
                    shown = Self.describe(store, nav: nav, width: size.width)
                    if case .object(var o) = shown {
                        let shownTabs = tabsDemo ?? store.bench.tabs.map { TabInfo($0) }
                        o["tabs"] = .array(shownTabs.map(\.json))
                        o["tabsDemo"] = .bool(tabsDemo != nil)
                        shown = .object(o)
                    }
                    if case .object(var o) = shown, stepsDemo != nil || jobsDemo != nil || nav.activity == .texts {
                        let steps = stepsDemo?.steps ?? store.textSteps
                        o["textsTab"] = .string(nav.textsTab.rawValue)
                        o["steps"] = .object(Dictionary(uniqueKeysWithValues: TextStep.allCases.map { ($0.rawValue, JSONValue.string(steps[$0].status.rawValue)) }))
                        if let jobsDemo { o["jobs"] = .number(Double(jobsDemo.groups.flatMap(\.jobs).count)) }
                        shown = .object(o)
                    }
                    if let recordDemo, let recorder, case .object(var o) = shown {
                        o["record"] = RecordView.describe(recordDemo, recorder: recorder)
                        shown = .object(o)
                    }
                    canvasShown = demo != nil
                }
                let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.appearance = NSAppearance(named: .darkAqua)
                w.contentView = view
                offscreen = w
                host = view
            }
        }
        if let problem { throw CommandError(.io, "ui.screenshot: \(problem)") }  // l10n-ignore
        // Let SwiftUI lay out, the monitors draw their frame and thumbnails arrive.
        // Brand kit previews, look thumbnails and the Graphics panel's tile previews are rendered by the compositor.
        settle(workspace?.hasPrefix("brand") == true || workspace == "settings-brand" ? 4 : workspace?.hasPrefix("graphics") == true ? 8 : 1.5)
        var result: Result<(Int, Int), Error> = .failure(CommandError(.io, "ui.screenshot: nothing drawn"))  // l10n-ignore
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                if let host { result = Result { try Self.write(host, to: output) } }
                // What the canvas selected and hit-tests, once the view has appeared.
                if canvasShown, let store, case .object(var o) = shown {
                    o["canvas"] = Self.describeCanvas(store)
                    shown = .object(o)
                }
                offscreen?.contentView = nil
                offscreen?.close()
                offscreen = nil
                previewController = nil
                scratch?.suspend()
            }
        }
        let (pw, ph) = try result.get()
        return (pw, ph, shown)
    }

    /// ui.screenshot real: the main window as it is on screen, its native title bar included (ScreenCaptureKit on the
    /// app's own window). Only when the Screen Recording permission is already in effect: CGPreflightScreenCaptureAccess
    /// never prompts, and without it nothing that could prompt is called.
    func captureWindow(to output: URL) throws -> (width: Int, height: Int, shown: JSONValue) {
        precondition(!Thread.isMainThread)
        guard CGPreflightScreenCaptureAccess() else {
            throw CommandError(.io, "ui.screenshot real: Regista has no Screen Recording permission in effect (System Settings › Privacy & Security › Screen & System Audio Recording), so it captured nothing and asked nothing. ui.screenshot without real renders the window offscreen")  // l10n-ignore
        }
        var windowID: CGWindowID = 0
        var shown: JSONValue = .null
        var problem: String?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let w = window ?? store?.ui.window, w.isVisible, !w.isMiniaturized else { problem = "the main window is not on screen"; return }  // l10n-ignore
                windowID = CGWindowID(w.windowNumber)
                shown = Self.describeWindow(w)
            }
        }
        if let problem { throw CommandError(.io, "ui.screenshot real: \(problem)") }  // l10n-ignore
        final class Box: @unchecked Sendable { var result: Result<CGImage, Error> = .failure(CommandError(.io, "ui.screenshot real: the capture did not answer in 20 s")) }  // l10n-ignore
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CommandError(.io, "ui.screenshot real: ScreenCaptureKit does not list the main window (\(windowID))")  // l10n-ignore
                }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                box.result = .success(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
        let image = try box.result.get()
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw CommandError(.io, "ui.screenshot real: cannot write \(output.path)")  // l10n-ignore
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CommandError(.io, "ui.screenshot real: cannot write \(output.path)") }  // l10n-ignore
        if case .object(var o) = shown {
            o["scale"] = .number(Double(image.width) / max(1, o["windowWidth"]?.doubleValue ?? Double(image.width)))
            shown = .object(o)
        }
        return (image.width, image.height, shown)
    }

    /// The live window's top band, in points from the window's top-left corner: its size, the native toolbar band
    /// (titleRowHeight), the three traffic lights, the toolbar item with the title row's controls (and whether a click
    /// at its centre reaches it), and where the content's first row begins.
    @MainActor
    static func describeWindow(_ w: NSWindow) -> JSONValue {
        let h = w.frame.height
        func rect(_ r: CGRect) -> JSONValue {
            ["x": .number(Double(r.minX)), "y": .number(Double(h - r.maxY)), "width": .number(Double(r.width)), "height": .number(Double(r.height))]
        }
        let lights = WindowChrome.buttons(w).filter { $0.window != nil }.map { b -> JSONValue in
            guard case .object(var o) = rect(b.convert(b.bounds, to: nil)) else { return .null }
            o["hidden"] = .bool(b.isHidden)
            return .object(o)
        }
        // The SwiftUI content's first row, from the window's top (the content view is full size: its top is 0).
        let hostTop = h - (w.contentView?.frame.maxY ?? h)
        var o: [String: JSONValue] = ["windowWidth": .number(Double(w.frame.width)), "windowHeight": .number(Double(h)),
                                      "titleRowHeight": .number(Double(WindowChrome.titleBarHeight(w))),
                                      "trafficLightButtons": .array(lights), "fullScreen": .bool(w.styleMask.contains(.fullScreen)),
                                      "contentTop": WindowChrome.shared.contentTop.map { .number(Double(hostTop + $0)) } ?? .null,
                                      "toolbar": .bool(w.toolbar != nil)]
        if let items = WindowChrome.titleItems(w) {
            let r = items.convert(items.bounds, to: nil)
            o["titleItems"] = rect(r)
            let hit = w.contentView?.superview?.hitTest(CGPoint(x: r.midX, y: r.midY))
            o["titleItemsHitTest"] = .bool(hit.map { $0 === items || $0.isDescendant(of: items) } ?? false)
        }
        return .object(o)
    }

    /// The navigation a ui.screenshot workspace name shows. Activities: home, record, media, texts, audio, voice,
    /// graphics, generate, export (the library activities with the editor at the Pro level); the editor: edit-pro (also
    /// pro, pro-fullscreen), edit-semplice (also quick, semplice); graphics-<section> = Grafica on one section
    /// (filters, adjust, effects, styles, motion, logo); panel-prompter / panel-claude / panel-inspector = the Pro editor
    /// with that right-panel tab. nil or unknown: what the window shows now.
    @MainActor
    static func navigation(for name: String?, current: Navigation) -> Navigation {
        var nav = current
        guard let name else { return nav }
        if name.hasPrefix("graphics-"), let section = Navigation.GraphicsSection(rawValue: String(name.dropFirst(9))) {
            nav.show(.pro)
            nav.showGraphics(section)
            return nav
        }
        if name.hasPrefix("panel-"), let tab = Navigation.RightTab(rawValue: String(name.dropFirst(6))) {
            nav.show(.pro)
            nav.rightTab = tab
            return nav
        }
        switch name {
        case "edit-pro", "pro", "pro-fullscreen": nav.show(.pro)
        case "edit-semplice", "quick", "semplice": nav.show(.quick)
        default:
            guard let a = Navigation.Activity(rawValue: name) else { return nav }
            if a.isLibrary { nav.show(.pro) }
            nav.select(a)
        }
        return nav
    }

    /// What the rendered window shows, from the same view model the views draw.
    @MainActor
    static func describe(_ store: EditorStore, nav: Navigation, width: CGFloat) -> JSONValue {
        let lanes = LaneRow.rows(store.project).map { r -> JSONValue in
            var o: [String: JSONValue] = ["label": .string(r.label), "title": .string(r.title), "exists": .bool(r.track != nil)]
            if let t = r.track {
                o["trackId"] = .string(t.id)
                o["clips"] = .number(Double(t.kind == .caption ? (t.captions?.chunks.count ?? 0) : t.clips.count))
            }
            return .object(o)
        }
        return ["workspace": .string(nav.workspace.rawValue), "activity": .string(nav.activity.rawValue), "level": .string(nav.level.rawValue),
                "rightTab": .string(nav.rightTab.rawValue), "project": store.project.map { .string($0.name) } ?? .null,
                "duration": .number(store.project?.duration.displaySeconds ?? 0), "lanes": .array(lanes),
                "transcriptWords": .number(Double(store.words.count)), "agentConnected": .bool(store.agentConnected),
                "agentCommands": .number(Double(store.activity.filter(\.isAgent).count)),
                "trafficLights": .number(Double(WindowChrome.shared.trafficLights)), "fullScreen": .bool(WindowChrome.shared.fullScreen),
                "titleRowHeight": .number(Double(WindowChrome.shared.titleBar)),
                // The right panel: fixed width at the window's right edge on every activity (a render always shows it).
                "rightPanel": ["x": .number(Double(width - Chrome.rightWidth)), "width": .number(Double(Chrome.rightWidth))],
                // The live window's three traffic lights as macOS placed them: left edge and centre from the window's top edge.
                "trafficLightButtons": .array((store.ui.window.map(WindowChrome.trafficLightFrames) ?? []).map {
                    ["minX": .number(Double($0.minX)), "midY": .number(Double($0.midY))]
                }),
                "titleBarHeight": store.ui.window.map { .number(Double(WindowChrome.titleBarHeight($0))) } ?? .null,
                "recentProjects": .number(Double(store.recents.paths.count)),
                // The Graphics panel's section and how many catalog items it lists (E4 #3).
                "graphicsSection": nav.activity == .graphics ? .string(nav.graphicsSection.rawValue) : .null,
                "graphicsItems": nav.activity == .graphics ? .number(Double(GraphicsCatalog.items(in: nav.graphicsSection).count)) : .null]
    }

    /// ui.screenshot's `inspector.select`: a clip id, the first video / audio / overlay clip, the captions (first block),
    /// "multi" (the first two video clips, else any two clips) or "none".
    @MainActor
    static func inspectorSelection(_ select: String, in store: EditorStore) -> InspectorSelection {
        guard let p = store.project else { return InspectorSelection() }
        let all = p.tracks.flatMap { t in t.clips.map { (t, $0) } }
        func first(_ ok: (Track, Clip) -> Bool) -> InspectorSelection { all.first(where: ok).map { InspectorSelection(clips: [$0.1.id]) } ?? InspectorSelection() }
        switch select {
        case "none": return InspectorSelection()
        case "first-video": return first { t, c in t.kind == .video && p.asset(c.assetID)?.image == nil && !c.isGenerated }
        case "first-audio": return first { t, _ in t.kind == .audio }
        case "first-music": return first { t, _ in t.kind == .audio && t.role == "music" }
        case "first-overlay": return first { t, c in t.kind == .overlay || c.isGenerated || p.asset(c.assetID)?.image != nil }
        case "captions":
            guard let t = p.tracks.first(where: { $0.captions?.chunks.isEmpty == false }) else { return InspectorSelection() }
            return InspectorSelection(caption: CaptionPick(trackID: t.id, chunk: 0))
        case "multi":
            let videos = all.filter { $0.0.kind == .video }.prefix(2).map(\.1.id)
            return InspectorSelection(clips: Set(videos.count == 2 ? videos : all.prefix(2).map(\.1.id)))
        default: return InspectorSelection(clips: p.locate(clip: select) != nil ? [select] : [])
        }
    }

    /// ui.screenshot's `record` object applied to the current choices (nil: the current choices as they are).
    @MainActor
    static func recordDemo(_ v: JSONValue?, from current: RecordingSources) -> RecordDemo {
        var s = current
        if let p = v?["preset"]?.stringValue.flatMap(RecordingSources.Preset.init(rawValue:)) { s.apply(p) }
        for source in RecordingSources.Source.allCases {
            if let on = v?[source.rawValue]?.boolValue { s.set(source, on) }
        }
        if let k = v?["layout"]?.stringValue.flatMap(LayoutSpec.Kind.init(rawValue:)) { s.layout.kind = k }
        if let c = v?["corner"]?.stringValue { s.layout.corner = c }
        if let z = v?["size"]?.stringValue { s.layout.size = z }
        if let sh = v?["shape"]?.stringValue { s.layout.shape = sh }
        // Sample displays (the picker): the second one is selected, so the main and the recorded display both show.
        var displays: [DisplayInfo]?
        if let n = v?["displays"]?.doubleValue {
            displays = Array(DisplayInfo.samples.prefix(max(1, min(DisplayInfo.samples.count, Int(n)))))
            s.target = .display(displays!.count > 1 ? displays![1].id : displays![0].id)
        }
        return RecordDemo(sources: s, open: v?["open"]?.stringValue.flatMap(RecordingSources.Source.init(rawValue:)),
                          grantPermissions: v?["permissions"]?.stringValue == "granted", displays: displays)
    }

    /// ui.screenshot's `canvas` object.
    static func canvasDemo(_ v: JSONValue) -> CanvasDemo? {
        guard let select = v["select"]?.stringValue else { return nil }
        return CanvasDemo(select: select, drag: v["drag"]?.arrayValue?.compactMap(\.doubleValue), scale: v["scale"]?.doubleValue,
                          scope: v["scope"]?.stringValue.flatMap(CaptionScope.init(rawValue:)))
    }

    /// The elements on the preview at the playhead, as the canvas hit-tests them.
    @MainActor
    static func describeCanvas(_ store: EditorStore) -> JSONValue {
        guard let p = store.project else { return .null }
        let t = MediaTime(seconds: store.preview.time).snapped(to: p.settings.frameRate)
        return ["time": .number(t.displaySeconds), "selected": store.canvasSelection.map { .string($0) } ?? .null,
                "scope": .string(store.captionScope.rawValue),
                "elements": .array(CanvasLayout.elements(p, at: t, renderer: AVRenderer()).map(\.json))]
    }

    /// Lets the main run loop run for `seconds` (the engine queue just waits).
    private func settle(_ seconds: Double) {
        let s = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { s.signal() }
        s.wait()
    }

    /// The view at 1 pixel per point, as PNG.
    @MainActor
    static func write(_ view: NSView, to output: URL) throws -> (Int, Int) {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CommandError(.io, "ui.screenshot: cannot allocate the bitmap")  // l10n-ignore
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CommandError(.io, "ui.screenshot: PNG encoding failed") }  // l10n-ignore
        do { try png.write(to: output) } catch { throw CommandError(.io, "ui.screenshot: cannot write \(output.path)") }  // l10n-ignore
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func previewFrame(at time: MediaTime, to output: URL) throws -> (width: Int, height: Int) {
        precondition(!Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
            guard let preview = self?.store?.preview else { done.signal(); return }
            preview.whenCurrent {
                preview.playhead.set(time.seconds)
                preview.program.frame(at: CMTime(value: time.ticks / (MediaTime.ticksPerSecond / 30000), timescale: 30000)) { img in
                    image = img
                    done.signal()
                }
            }
        } }
        guard done.wait(timeout: .now() + 30) == .success else { throw CommandError(.io, "preview.frame: the player did not answer in 30 s") }  // l10n-ignore
        guard let image else { throw CommandError(.io, "preview.frame: no frame from the preview player (empty timeline?)") }  // l10n-ignore
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw CommandError(.io, "preview.frame: cannot write \(output.path)")  // l10n-ignore
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CommandError(.io, "preview.frame: cannot write \(output.path)") }  // l10n-ignore
        return (image.width, image.height)
    }
}

/// Grabs the hosting NSWindow of the SwiftUI root.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: Probe, context: Context) { v.onWindow = onWindow }
}

/// Empty parts of the custom top bar behave like a native title bar: drag moves the window,
/// double-click follows the user's "double-click a window's title bar" setting (zoom by default).
struct TitleBarArea: NSViewRepresentable {
    final class Area: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            if event.clickCount == 2 { TitleBarArea.doubleClick(w) } else { w.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ v: Area, context: Context) {}

    static func doubleClick(_ w: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": w.performMiniaturize(nil)
        case "None": break
        default: w.performZoom(nil)   // "Maximize", "Fill" or unset
        }
    }

    /// With a hidden title bar the system's transparent title-bar strip (top ~28 px) still takes the
    /// clicks there but no longer zooms on double-click: catch those and do what Area does.
    private static var monitor: Any?
    static func installEdgeMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let w = event.window, let frame = w.contentView?.superview,
                  let hit = frame.hitTest(event.locationInWindow),
                  String(describing: type(of: hit)).contains("Titlebar") else { return event }  // l10n-ignore
            doubleClick(w)
            return nil
        }
    }
}
