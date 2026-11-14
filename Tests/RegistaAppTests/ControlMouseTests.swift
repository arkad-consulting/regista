import AppKit
import SwiftUI
import Testing
@testable import Regista

// The control set (Sources/Regista/UI/Controls.swift and the shared controls beside it), one control at a time, driven
// with real mouse and key events (#29). Each control is hosted alone and inside the containers it lives in in the app:
// a scroll view, a panel column, a floating card over something that also takes clicks. A click or a drag changes what
// it must, exactly once; a disabled control does nothing; the control is still on screen afterwards; nothing under it
// reacts.

/// What a control changes, observed by the test.
@MainActor
final class Probe<T>: ObservableObject {
    @Published var value: T
    var commits: [T] = []
    var actions = 0
    /// Clicks that reached the background under the control (they must not).
    var under = 0
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

/// Where a control is hosted.
enum Container: String, CaseIterable, CustomTestStringConvertible {
    case alone, scroll, column, card
    var testDescription: String { rawValue }
}

/// Hosts `content` in a container, over a background that counts the clicks reaching it.
private struct Hosted<Content: View, T>: View {
    let container: Container
    @ObservedObject var probe: Probe<T>
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // What lies under the control: a surface that takes clicks (the canvas, a row, a card's parent).
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { probe.under += 1 }
            switch container {
            case .alone:
                content().frame(width: 280)
            case .scroll:
                // In a vertical scroll view under other content, as in a side panel.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "Section").frame(height: 40)
                        content()
                        Color.clear.frame(height: 400)
                    }
                    .padding(Ed.Space.l)
                }
                .frame(width: 300, height: 260)
            case .column:
                VStack(alignment: .leading, spacing: 10) {
                    RSection("Section") { content() }
                    Spacer()
                }
                .padding(Ed.Space.l)
                .frame(width: 300, height: 260)
                .background(Ed.side)
            case .card:
                // A floating card with a shadow, the way the canvas bar and the popovers float.
                content()
                    .padding(Ed.Space.m)
                    .frame(width: 280)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.panel))
                    .shadow(radius: 8)
            }
        }
        .frame(width: 400, height: 320)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
private func host<T, V: View>(_ probe: Probe<T>, _ container: Container, @ViewBuilder _ content: @escaping () -> V) -> MouseRig {
    MouseRig(Hosted(container: container, probe: probe, content: content), size: CGSize(width: 400, height: 320))
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct ControlMouseTests {
    // MARK: Buttons

    @Test(arguments: Container.allCases)
    func edButtonRunsOnceAndDisabledDoesNothing(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) {
            VStack {
                EdButton(title: "Esporta") { p.actions += 1 }
                EdButton(title: "Annulla", disabled: true) { p.actions += 100 }
                EdButton(title: "Principale", prominent: true) { p.commits.append(true) }
            }
        }
        defer { rig.close() }
        #expect(rig.click("Esporta"))
        #expect(p.actions == 1, "EdButton in \(c): \(p.actions) actions")
        #expect(rig.click("Annulla"))
        #expect(p.actions == 1, "a disabled EdButton ran its action")
        #expect(rig.click("Principale"))
        #expect(p.commits == [true])
        #expect(p.under == 0, "a click on an EdButton reached what lies under it")
        #expect(rig.element("Esporta") != nil)
    }

    @Test(arguments: Container.allCases)
    func iconButtonRunsOnce(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) {
            HStack {
                IconButton(symbol: "scissors", help: "Taglia") { p.actions += 1 }
                IconButton(symbol: "trash", help: "Elimina") { p.actions += 100 }.disabled(true)
                IconButton(symbol: "sidebar.left", help: "Pannello", chrome: true) { p.commits.append(true) }
            }
        }
        defer { rig.close() }
        #expect(rig.click("Taglia"))
        #expect(p.actions == 1)
        #expect(rig.click("Elimina"))
        #expect(p.actions == 1, "a disabled IconButton ran its action")
        #expect(rig.click("Pannello"))
        #expect(p.commits.count == 1)
        #expect(p.under == 0)
    }

    @Test(arguments: Container.allCases)
    func accentLinkRunsOnce(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) { AccentLinkButton(title: "Importa…", tip: "Importa un file") { p.actions += 1 } }
        defer { rig.close() }
        #expect(rig.click("Importa un file"))
        #expect(p.actions == 1)
        #expect(p.under == 0)
    }

    // MARK: Switches

    @Test(arguments: Container.allCases)
    func toggleFlipsOnceFromTheSwitchAndFromItsLabel(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) { RToggle(title: "Specchiato", isOn: p.binding, subtitle: "Per il vetro") }
        defer { rig.close() }
        let e = try #require(rig.elements(containing: "Specchiato").first { $0.isControl })
        // The switch at the right end, then the title at the left: the whole row is the toggle.
        rig.click(CGPoint(x: e.frame.maxX - 12, y: e.frame.midY))
        #expect(p.value == true, "RToggle's switch in \(c)")
        rig.click(CGPoint(x: e.frame.minX + 10, y: e.frame.minY + 6))
        #expect(p.value == false, "RToggle's label in \(c)")
        #expect(p.under == 0)
        #expect(rig.elements(containing: "Specchiato").contains { $0.isControl })
    }

    @Test(arguments: Container.allCases)
    func switchFlipsAndDisabledStays(_ c: Container) throws {
        let p = Probe(false), q = Probe(false)
        let rig = host(p, c) {
            HStack {
                RSwitch(isOn: p.binding, label: "Camera")
                RSwitch(isOn: q.binding, label: "Microfono").disabled(true)
            }
        }
        defer { rig.close() }
        #expect(rig.click("Camera"))
        #expect(p.value == true)
        #expect(rig.click("Camera"))
        #expect(p.value == false)
        #expect(rig.click("Microfono"))
        #expect(q.value == false, "a disabled RSwitch flipped")
        #expect(p.under == 0)
    }

    /// The row opens its choices; its own switch flips without opening them.
    @Test(arguments: Container.allCases)
    func switchRowOpensAndItsSwitchToggles(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) {
            RSwitchRow(symbol: "camera", title: "Camera", detail: "FaceTime HD", isOn: p.binding, expanded: false) { p.actions += 1 }
        }
        defer { rig.close() }
        let row = try #require(rig.elements(containing: "FaceTime").first)
        rig.click(row.centre)
        #expect(p.actions == 1, "a click on the row did not open its choices")
        #expect(p.value == false, "a click on the row flipped the switch")
        // The switch is the toggle of the row (a check box to accessibility), named after the row.
        let toggle = try #require(rig.elements().first { $0.role == "AXCheckBox" && $0.visible })
        rig.click(toggle.centre)
        #expect(p.value == true, "the row's switch did not flip")
        #expect(p.actions == 1, "the switch opened the row")
        #expect(p.under == 0)
    }

    // MARK: Chips and segments

    @Test(arguments: Container.allCases)
    func chipsSelectOnceAndTheAddChipOpens(_ c: Container) throws {
        let p = Probe<String?>("a")
        let rig = host(p, c) {
            VStack {
                RChips(items: [.init(id: "a", title: "Uno"), .init(id: "b", title: "Due"), .init(id: "c", title: "Tre")], selection: p.value,
                       add: .init(title: "Lingua", tip: "Aggiungi una lingua") { p.actions += 1 }) { id in p.value = id; p.commits.append(id) }
                RChips(items: [.init(id: "x", title: "Rosso"), .init(id: "y", title: "Verde")], selection: nil, flow: true,
                       add: .init(title: "Tono") { p.actions += 10 }) { id in p.commits.append(id) }
            }
        }
        defer { rig.close() }
        #expect(rig.click("Due"))
        #expect(p.value == "b" && p.commits == ["b"])
        #expect(rig.click("Aggiungi una lingua"))
        #expect(p.actions == 1)
        #expect(rig.click("Verde"))
        #expect(p.commits == ["b", "y"])
        #expect(rig.click("Tono"))
        #expect(p.actions == 11)
        #expect(p.under == 0)
    }

    @Test(arguments: Container.allCases)
    func segmentedSelectsDisabledStaysAndArrowsMove(_ c: Container) throws {
        let p = Probe("pro")
        let rig = host(p, c) {
            RSegmented(items: [("simple", "Semplice"), ("pro", "Pro"), ("off", "Spento")], selection: p.binding, disabled: ["off"])
        }
        defer { rig.close() }
        #expect(rig.click("Semplice"))
        #expect(p.value == "simple")
        #expect(rig.click("Spento"))
        #expect(p.value == "simple", "a disabled segment was selected")
        // Focused (the click gave it the focus), → moves to the next segment.
        rig.key(.right)
        #expect(p.value == "pro", "→ on a focused RSegmented in \(c)")
        #expect(p.under == 0)
    }

    // MARK: Slider

    /// A click on the track sets the value there and commits once; a drag follows the pointer and commits once at
    /// release; ← → step and commit. In a scroll view the drag moves the slider, not the scroll view.
    @Test(arguments: Container.allCases)
    func sliderClickDragAndKeys(_ c: Container) throws {
        let p = Probe(0.0)
        let rig = host(p, c) { RSlider(value: p.binding, range: 0...100, label: "Livello") { p.commits.append($0) } }
        defer { rig.close() }
        let e = try #require(rig.element("Livello"))
        // The track is the bottom 18 pt of the control (the label row above).
        let y = e.frame.maxY - 9
        rig.click(CGPoint(x: e.frame.minX + e.frame.width * 0.75, y: y))
        #expect(abs(p.value - 75) < 3, "a click on RSlider's track in \(c) gave \(p.value)")
        #expect(p.commits.count == 1, "a click committed \(p.commits.count) times")
        let before = p.value
        rig.drag(from: CGPoint(x: e.frame.minX + e.frame.width * 0.75, y: y), by: CGSize(width: -e.frame.width * 0.5, height: 0))
        #expect(p.value < before - 30, "a drag on RSlider in \(c) did not follow")
        #expect(p.commits.count == 2, "a drag committed \(p.commits.count - 1) times")
        rig.key(.right)
        #expect(p.commits.count == 3, "→ on a focused RSlider did not commit")
        #expect(p.under == 0)
        #expect(rig.element("Livello") != nil)
    }

    @Test(arguments: Container.allCases)
    func intensityBarSetsAndCommitsOnce(_ c: Container) throws {
        let p = Probe(0.0)
        let rig = host(p, c) { IntensityBar(value: p.binding, label: "Quanto") { p.commits.append($0) } }
        defer { rig.close() }
        let e = try #require(rig.element("Quanto"))
        rig.click(CGPoint(x: e.frame.midX, y: e.frame.maxY - 11))
        #expect(p.value > 0.2 && p.value < 0.8, "IntensityBar in \(c) gave \(p.value)")
        #expect(p.commits.count == 1)
        #expect(p.under == 0)
    }

    // MARK: Text

    @Test(arguments: Container.allCases)
    func textFieldTakesTheFocusTypesAndClears(_ c: Container) throws {
        let p = Probe("")
        let rig = host(p, c) { RTextField(placeholder: "Cerca", text: p.binding, symbol: "magnifyingglass", clearable: true) }
        defer { rig.close() }
        let e = try #require(rig.element("Cerca", role: "AXTextField"))
        rig.click(e.centre)
        #expect(rig.isTyping, "a click on RTextField in \(c) did not give it the focus")
        rig.type("ciao")
        #expect(p.value == "ciao")
        rig.window.makeFirstResponder(nil)
        rig.pump(0.1)
        #expect(rig.click("Cancella la ricerca"))
        #expect(p.value == "", "the clear button did not empty the field")
        #expect(p.under == 0)
    }

    @Test(arguments: Container.allCases)
    func textEditorTypesSubmitsAndExits(_ c: Container) throws {
        let p = Probe("")
        let rig = host(p, c) {
            RTextEditor(placeholder: "Scrivi", text: p.binding, kind: .grows(1...4), onSubmit: { p.actions += 1 }, onExit: { p.commits.append("exit") })
        }
        defer { rig.close() }
        let e = try #require(rig.elements(containing: "Scrivi").first { $0.isControl })
        rig.click(e.centre)
        #expect(rig.isTyping, "a click on RTextEditor in \(c) did not give it the focus")
        rig.type("riga")
        #expect(p.value == "riga")
        rig.key(.returnKey)
        #expect(p.actions == 1, "Return in RTextEditor did not submit once (\(p.actions))")
        rig.key(.escape)
        #expect(p.commits == ["exit"], "Esc in RTextEditor did not exit")
    }

    @Test func scrollingTextEditorTypes() throws {
        let p = Probe("")
        let rig = host(p, .column) { RTextEditor(placeholder: "Copione", text: p.binding, kind: .scrolls(min: 80, max: 120)) }
        defer { rig.close() }
        let e = try #require(rig.elements(containing: "Copione").first { $0.isControl })
        rig.click(e.centre)
        #expect(rig.isTyping)
        rig.type("testo")
        #expect(p.value == "testo")
    }

    /// The Ispettore's values: a click makes a field, Return commits once, Esc gives up.
    @Test func inspectorValueFieldCommitsOnReturnAndNotOnEscape() throws {
        let p = Probe("")
        let rig = host(p, .column) { InspectorValueField(text: "1.00") { p.commits.append($0) } }
        defer { rig.close() }
        let e = try #require(rig.elements(containing: "Clicca per scrivere il valore").first ?? rig.element("1.00"))
        rig.click(e.centre)
        rig.pump(0.1)
        #expect(rig.isTyping, "a click on a value did not make a field")
        rig.key("a", keyCode: 0, modifiers: .command)   // select all
        rig.type("2.5")
        rig.key(.returnKey)
        #expect(p.commits.last == "2.5" && p.commits.count == 1, "Return committed \(p.commits)")
        rig.click(e.centre)
        rig.pump(0.1)
        rig.type("9")
        rig.key(.escape)
        #expect(p.commits.count == 1, "Esc committed a value")
    }

    // MARK: Rows

    @Test(arguments: Container.allCases)
    func pickRowRunsItsLinkSeparatelyAndGreyedRowsDoNothing(_ c: Container) throws {
        let p = Probe(false)
        let rig = host(p, c) {
            VStack(spacing: 2) {
                PickRow(title: "ComfyUI", detail: "Gratis, sul Mac", link: RowLink(title: "Installa…", tip: "Installa il motore") { p.commits.append(true) }) { p.actions += 1 }
                PickRow(title: "Higgsfield", reason: "Manca la chiave") { p.actions += 100 }
            }
        }
        defer { rig.close() }
        let row = try #require(rig.elements(containing: "ComfyUI").first { $0.isControl })
        rig.click(row.centre)
        #expect(p.actions == 1, "PickRow in \(c)")
        #expect(rig.click("Installa il motore"))
        #expect(p.commits.count == 1 && p.actions == 1, "the row's link ran the row (or not itself)")
        let grey = try #require(rig.elements(containing: "Higgsfield").first { $0.isControl })
        rig.click(grey.centre)
        #expect(p.actions == 1, "a greyed PickRow ran its action")
        #expect(p.under == 0)
    }

    @Test(arguments: Container.allCases)
    func sideRowAndChoiceListRunOnce(_ c: Container) throws {
        let p = Probe<String?>(nil)
        let rig = host(p, c) {
            VStack(spacing: 2) {
                SideRow(symbol: "music.note", title: "Musica", detail: "0:30") { p.actions += 1 }
                RChoiceList(items: [.init(id: "cam", title: "FaceTime"), .init(id: "usb", title: "USB")], selection: "cam") { p.value = $0 }
            }
        }
        defer { rig.close() }
        let side = try #require(rig.elements(containing: "Musica").first { $0.isControl })
        rig.click(side.centre)
        #expect(p.actions == 1)
        let usb = try #require(rig.elements(containing: "USB").first { $0.isControl })
        rig.click(usb.centre)
        #expect(p.value == "usb")
        #expect(p.under == 0)
    }

    @Test func tabStripSelects() throws {
        let p = Probe("a")
        let rig = host(p, .column) { TabStrip(items: [("a", "Passi"), ("b", "Sottotitoli"), ("c", "Trascrizione")], selection: p.binding) }
        defer { rig.close() }
        #expect(rig.click("Trascrizione"))
        #expect(p.value == "c")
        #expect(p.under == 0)
    }

    /// A swatch opens the system colour panel on its colour, and a colour picked there comes back to it.
    @Test func colorSwatchOpensThePanelAndTakesItsColour() throws {
        let p = Probe("#112233")
        let rig = host(p, .column) { ColorSwatch(role: "primary", hex: p.binding, caption: "Primario") }
        defer { rig.close(); NSColorPanel.shared.orderOut(nil) }
        let events = RigGuard.events.count
        let e = try #require(rig.elements(containing: "Primario").first { $0.isControl })
        rig.click(e.centre)
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .window && $0.detail.contains("NSColorPanel") }, "the colour panel did not open")
        NSColorPanel.shared.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        // What the panel sends its target when a colour is picked in it.
        _ = ColorPanelBridge.shared.perform(NSSelectorFromString("changed:"), with: NSColorPanel.shared)
        rig.pump(0.1)
        #expect(p.value == "#FF0000", "the colour picked did not reach the swatch (\(p.value))")
    }

    /// A splitter follows a drag and stores the new size.
    @Test func splitterDragsAndStores() throws {
        let p = Probe(0.0)
        let rig = host(p, .alone) {
            HStack(spacing: 0) {
                Color.gray.frame(width: 150)
                Splitter(orientation: .vertical, stored: p.binding, current: 150, range: 100...300, thickness: 1)
                Color.blue
            }
            .frame(height: 200)
        }
        defer { rig.close() }
        let e = try #require(rig.element("Divisore"))
        rig.drag(from: e.centre, by: CGSize(width: 40, height: 0))
        #expect(p.value > 170 && p.value < 210, "the splitter stored \(p.value)")
    }
}
}
