import AppKit
import RegistaCore
import SwiftUI

/// The small form of a motion template (issue #22): the 3–5 fields its spec picks, prefilled with the defaults, and
/// Applica at the playhead. Everything runs through motion.add (undo, agent log, MCP parity).
struct MotionForm: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    let spec: MotionSpec
    @State private var values: [String: JSONValue] = [:]

    /// Italian labels of the common field names (dynamic keys: their English is in Localizable.strings).
    static let labels: [String: String] = [
        "title": "Titolo", "rows": "Righe", "images": "Immagini", "value": "Valore", "from": "Da", "icon": "Icona", "dim": "Scurisci il video",
        "kicker": "Etichetta", "x": "Posizione orizzontale", "color": "Colore", "items": "Voci (riga 1)", "items2": "Voci (riga 2)",
        "y1": "Altezza riga 1", "y2": "Altezza riga 2", "background": "Sfondo", "size": "Dimensione", "zoomBack": "Torna a tutto schermo",
        "panels": "Pannelli", "tilt": "Inclinazione", "topLeft": "Testo in alto", "bottomLeft": "Testo in basso", "kind": "Tipo",
        "values": "Valori", "labels": "Etichette", "theme": "Tema", "centerY": "Altezza dell'orbita", "radius": "Raggio", "period": "Secondi per giro",
        "text": "Testo", "headline": "Titolo", "accent": "Parola in evidenza", "label": "Etichetta", "caption": "Didascalia", "steps": "Passi",
        "lines": "Righe", "prompt": "Testo", "name": "Nome", "status": "Stato", "filename": "Nome del file", "layout": "Disposizione",
        "before": "Prima", "after": "Dopo", "note": "Nota", "number": "Numero", "rings": "Anelli", "style": "Stile", "path": "Percorso",
        "message": "Messaggio", "total": "Totale",
    ]

    /// The words for a choice value of a template field (a lookup key); values with no words (ids, "S", "16:9") show as they are.
    static func choiceLabel(_ id: String) -> String {
        [
            "top": "In alto", "middle": "Al centro", "lower": "In basso", "bottom": "In basso", "center": "Al centro",
            "left": "Sinistra", "right": "Destra", "topLeft": "In alto a sinistra", "topRight": "In alto a destra",
            "bottomLeft": "In basso a sinistra", "bottomRight": "In basso a destra", "dark": "Scuro", "light": "Chiaro",
            "accent": "Accento", "white": "Bianco", "paper": "Carta", "gradient": "Sfumatura", "dark-grid": "Griglia scura",
            "neon": "Neon", "glass": "Vetro", "plain": "Senza effetti", "bar": "Barre", "bars": "Barre", "line": "Linea",
            "donut": "Ciambella", "number": "Numero", "curve": "Curva", "none": "Nessuno", "gold": "Oro", "flat": "Piatto",
            "metal": "Metallo", "cw": "Orario", "ccw": "Antiorario", "timeline": "Timeline", "wheels": "Ruote colore",
            "waveform": "Forma d'onda", "fx": "Effetti", "sliders": "Cursori",
            "talking-head-v1": "Talking head", "elegant-serif": "Serif elegante", "bold-keyword": "Bold + parola chiave",
            "ghost-karaoke": "Karaoke fantasma",
        ][id] ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: loc(spec.label)).font(Ed.display(17, .medium)).foregroundStyle(Ed.text)
                Spacer()
                EdButton(title: "Applica", symbol: "wand.and.stars", prominent: true) { apply() }
            }
            ForEach(spec.form, id: \.self) { name in
                if let f = spec.field(name) { row(f) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ed.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ed.line))
        .onAppear { values = [:] }
        .onChange(of: spec.id) { values = [:] }
    }

    private func value(_ f: EffectsCatalog.Field) -> JSONValue { values[f.name] ?? f.example }

    @ViewBuilder private func row(_ f: EffectsCatalog.Field) -> some View {
        let label = Self.labels[f.name] ?? f.name
        VStack(alignment: .leading, spacing: 4) {
            if f.type != "boolean" { SectionLabel(label) }
            switch f.type {
            case "boolean":
                RToggle(title: label, isOn: Binding(get: { value(f).boolValue ?? false }, set: { values[f.name] = .bool($0) }))
            case "choice":
                RSegmented(items: (f.choices ?? []).map { ($0, Self.choiceLabel($0)) },
                           selection: Binding(get: { value(f).stringValue ?? "" }, set: { values[f.name] = .string($0) }))
            case "number":
                textField(Binding(get: { value(f).doubleValue.map { $0.formatted() } ?? "" },
                                  set: { if let d = Double($0.replacingOccurrences(of: ",", with: ".")) { values[f.name] = .number(d) } }))
            case "numbers":
                textField(Binding(get: { (value(f).arrayValue ?? []).compactMap(\.doubleValue).map { $0.formatted() }.joined(separator: "  ") },
                                  set: { values[f.name] = .array($0.split(whereSeparator: { $0 == " " || $0 == ";" }).compactMap { Double($0) }.map { .number($0) }) }))
            case "list":
                textField(Binding(get: { (value(f).arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ") },
                                  set: { values[f.name] = .array($0.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") }) }))
            case "images":
                imagePicker(f)
            default:
                textField(Binding(get: { value(f).stringValue ?? "" }, set: { values[f.name] = .string($0) }))
            }
        }
    }

    private func textField(_ text: Binding<String>) -> some View {
        RTextField(text: text)
    }

    private func imagePicker(_ f: EffectsCatalog.Field) -> some View {
        let paths = (value(f).arrayValue ?? []).compactMap(\.stringValue)
        return HStack(spacing: 8) {
            EdButton(title: "Scegli immagini…", symbol: "photo.on.rectangle") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK { values[f.name] = .array(panel.urls.map { .string($0.path) }) }
            }
            Text(verbatim: paths.isEmpty ? loc("Nessuna: pannelli di esempio") : paths.count == 1 ? loc("1 immagine") : loc("%@ immagini", String(paths.count)))
                .font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
        }
    }

    /// The motion.add params of Applica: the template at the playhead with the fields changed in the form (the others
    /// keep the template's defaults, so Applica alone is enough).
    static func params(_ spec: MotionSpec, values: [String: JSONValue], at time: Double) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for (k, v) in values where spec.field(k) != nil { fields[k] = v }
        return ["template": .string(spec.id), "start": .number(time), "fields": .object(fields)]
    }

    private func apply() {
        store.run("motion.add", Self.params(spec, values: values, at: playhead.time))
        GraphicsActions.playAround(store, at: playhead.time)
    }
}
