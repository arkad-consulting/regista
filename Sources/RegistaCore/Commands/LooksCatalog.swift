import Foundation

// The "looks" items of issue #22 (rounds 2–3) in effects.catalog: caption styles, speaker layouts, the blur transition,
// following a face or a hand, the status row, the level meters and the console theme. Same schema as every item:
// what it looks like, when to propose it, when not to, fields with examples, the one command it runs.

enum LooksCatalog {
    typealias Item = EffectsCatalog.Item
    typealias Field = EffectsCatalog.Field

    static let guides: [String: CatalogGuide] = [
        // Caption styles
        "caption-talking-head-v1": CatalogGuide(
            "Big Impact capitals in white with a black outline, a few words at a time, word by word, the keyword on a coloured (brand highlight) box.",
            useWhen: "The default caption style: energetic talking-head reels, unless the person's caption style choice or the user asks for another look.",
            avoid: "Calm premium, fashion or lifestyle brands (it shouts), long sentences, reels that already carry a lot of graphics."),
        "caption-elegant-serif": CatalogGuide(
            "Cream serif italic (Didot Italic), no outline and no box, one calm phrase at a time with a faint shadow; keywords turn soft gold (the brand highlight).",
            useWhen: "Premium, beauty, fashion, interiors, hospitality, personal storytelling — quiet confident delivery; pairs with film or airy looks.",
            avoid: "Fast energetic hooks, screen recordings, very bright or busy backgrounds where thin serif strokes vanish, shouted or comedic delivery."),
        "caption-bold-keyword": CatalogGuide(
            "Bold white geometric sans in sentence case on up to two balanced lines, the keyword in the brand accent colour (orange by default), no box, soft shadow; whole phrase at once.",
            useWhen: "Modern creator / tech / education reels, explainers, the console theme; when one word per line carries the point.",
            avoid: "Footage whose accent colour clashes with the background, very long lines (it wraps to two lines, never three), brands that want all caps."),
        "caption-ghost-karaoke": CatalogGuide(
            "The whole phrase is on screen in a semibold sans: words already spoken are bright white, the next ones ghosted at ~28 %, lighting up word by word as they are said.",
            useWhen: "Conversational, fast-talking creators; reels watched on mute where following along matters; a subtle alternative to word-by-word pop.",
            avoid: "Slow delivery with long pauses (the ghost words hang), bright backgrounds (the ghosted words disappear), lines with many short words."),
        // Speaker layouts
        "layout-letterbox-headline": CatalogGuide(
            "9:16 frame with a black (or brand) top band holding a persistent one-line headline, the speaker as a 16:9 picture in the middle band, and an empty bottom band where Instagram's buttons sit; captions land under the picture.",
            useWhen: "Footage shot landscape, podcast/interview clips, a reel whose promise should stay readable the whole time ('I finally solved AI video editing').",
            avoid: "Vertical close-ups that lose the face when cropped to 16:9, reels with lots of top-band graphics, more than one headline per reel."),
        "layout-split-card": CatalogGuide(
            "The speaker in a rounded card with a thin white border and soft shadow on one side, the other side left free on a light canvas for a graphic (prompt bar, screenshot, chart).",
            useWhen: "While a graphic or UI the speaker talks about must be visible next to the face; tutorials, product demos, 'here is what I typed' moments.",
            avoid: "Long stretches (the face gets small), nothing to show in the free area, footage with the face at the frame edge."),
        "layout-pip-bubble": CatalogGuide(
            "The speaker in a circle with a white ring in a corner (kept clear of the Instagram rail and the caption band) while full-frame B-roll or a graphic plays under it — face cam over B-roll.",
            useWhen: "B-roll, screen recordings or motion graphics that should fill the frame while the voice continues; keeps the human present.",
            avoid: "When nothing full-frame plays under it (the speaker would show twice), tiny faces, more than ~6 s at a time without cutting back."),
        "layout-inset-frame": CatalogGuide(
            "The whole shot zooms out of full frame into a styled card on a dark backdrop: neon (brand-accent glow, corner brackets, a ● PREVIEW chip), glass (frosted rim) or plain; centred, or top-left with a panel beside it; zooms back to full frame at the end.",
            useWhen: "'Behind the edit' / live-console reels, showing the shot as a product preview, making room for side panels (meters, status rows, layer lists); the console theme uses it.",
            avoid: "Emotional close moments (the face gets small), very short ranges (< 2 s: the zoom has no time), reels already framed in a device or another card."),
        "layout-full": CatalogGuide(
            "Back to the speaker filling the frame: removes the box, crop and card from the range.",
            useWhen: "Ending a letterbox/split/inset section, or when the user wants the plain picture back.",
            avoid: "Undoing a layout the user chose on purpose without asking; ranges without a layout (nothing changes)."),
        // Transition
        "transition-blur": CatalogGuide(
            "At a cut, the picture defocuses (a smooth blur ramp) into the cut and the next shot comes back into focus, ~0.6 s; also into or out of a full-frame graphic.",
            useWhen: "Soft topic changes, going into a dream/flashback or into a graphic card, premium calm edits where a whip is too loud.",
            avoid: "Fast energetic reels (it feels slow), every cut, moments where captions or text must stay readable during the blur."),
        // Following
        "follow-hand-object": CatalogGuide(
            "An object (logo, sticker, image) floats a little above the speaker's open palm, follows the hand smoothly, slowly spins, with a glowing ellipse halo under it; fades in when the palm opens and out when it closes.",
            useWhen: "The speaker presents something with an open hand ('this is the tool', 'look at this'): the brand logo or product appears 'in the hand'. Needs hands.track over the gesture.",
            avoid: "Footage where the hand is out of frame or always closed, fast gestures, third-party logos (only the brand kit's logo or generic icons), more than one per reel."),
        "follow-face": CatalogGuide(
            "An overlay (label, sticker, icon) rides along with the speaker's head — beside it or just above it — as they move.",
            useWhen: "A name tag or a thought icon that must stay with a moving speaker, playful beats; needs faces.track.",
            avoid: "Anything covering the face, static speakers (a fixed position is calmer), long durations."),
        // HUD
        "status-bar": CatalogGuide(
            "A thin top row in mono type on dark glass pills: a pulsing red REC dot, 'EDITING LIVE' and a running timer on the left; a numbered chapter badge ('02 EFFECTS') on the right that slides in at each section.",
            useWhen: "'Watch me edit' / behind-the-scenes / tutorial reels with clear sections; the console theme. Chapters = the script's sections, set at the second each starts.",
            avoid: "Calm premium or emotional reels, reels with a busy top band of cards, fake chapters that do not match what is said."),
        "audio-meters": CatalogGuide(
            "Stereo L/R level meters — segmented bars from green to yellow to the brand accent with a falling peak tick — moving with the real sound of the edit, placed either side of the speaker's card.",
            useWhen: "A sound beat: music drops, a sound effect, 'listen to this', audio-cleanup before/after; a few seconds inside the console look.",
            avoid: "The whole reel (it distracts), reels without music or effects (speech alone barely moves them), full-frame talking heads without a card (they cover the frame edges)."),
        // Theme
        "style-console": CatalogGuide(
            "A whole-reel theme in one undo step: a dark grid backdrop with an accent glow (the background-scene template), the speaker in a neon inset card (PREVIEW chip, accent glow, corner brackets), the status row with REC timer and numbered chapters, bold-keyword captions in the brand accent.",
            useWhen: "Reels about editing, AI tools, building something live, tech tutorials; creators with an orange/neon brand; pass chapters from the script's sections.",
            avoid: "Lifestyle, beauty, premium-calm brands, emotional storytelling, footage where the face must stay large, reels already themed with another layout."),
    ]

    static var items: [Item] {
        func item(_ id: String, _ c: EffectsCatalog.Category, _ label: String, _ command: String, _ needs: EffectsCatalog.Needs, _ symbol: String,
                  _ fields: [Field], _ build: @escaping @Sendable (EffectTarget, Double, Project) -> [String: JSONValue]) -> Item {
            let g = guides[id] ?? CatalogGuide.missing
            return Item(id: id, category: c, label: label, summary: g.description, guide: g, fields: fields, command: command, needs: needs, symbol: symbol,
                        engine: nil, build: { t, i, p in .object(build(t, i, p)) })
        }
        let s = EffectsCatalog.s
        var out: [Item] = []
        // Caption styles: captions.generate keeps the track's keywords and fixes and switches the style.
        let styleLabels = ["talking-head-v1": "Talking head", "elegant-serif": "Serif elegante", "bold-keyword": "Bold + parola chiave", "ghost-karaoke": "Karaoke fantasma"]
        let styleSymbols = ["talking-head-v1": "captions.bubble.fill", "elegant-serif": "textformat.alt", "bold-keyword": "bold", "ghost-karaoke": "text.word.spacing"]
        for st in CaptionStyle.all {
            out.append(item("caption-\(st.id)", .captions, styleLabels[st.id] ?? st.id, "captions.generate", .picture, styleSymbols[st.id] ?? "captions.bubble",
                 [Field("style", "choice", .string(st.id), "Caption style preset.", choices: CaptionStyle.all.map(\.id)),
                  Field("keywords", "list", ["SITO", "SICURO"], "Keywords (any case; default: the track's)."),
                  Field("avoidFaces", "boolean", true, "Move chunks off faces (needs faces.track).")]) { _, _, _ in ["style": .string(st.id)] })
        }
        // Speaker layouts.
        let range = [Field("from", "time", 0, "Timeline start of the layout."), Field("to", "time", 6, "Timeline end of the layout.")]
        func rangeParams(_ t: EffectTarget, _ o: [String: JSONValue]) -> [String: JSONValue] {
            var o = o
            o["from"] = s(t.start)
            if let e = t.end { o["to"] = s(e) }
            return o
        }
        out.append(item("layout-letterbox-headline", .layouts, "Letterbox + titolo", "layout.speaker", .moment, "rectangle.split.1x2",
                        range + [Field("headline", "text", "I finally solved AI video editing", "The persistent headline of the top band.")]) { t, _, _ in
            rangeParams(t, ["preset": "letterbox-headline", "headline": "Il tuo titolo"])
        })
        out.append(item("layout-split-card", .layouts, "Card laterale", "layout.speaker", .moment, "rectangle.lefthalf.inset.filled",
                        range + [Field("side", "choice", "left", "Side of the speaker's card.", choices: ["left", "right"]),
                                 Field("background", "color", "#F4F2EE", "Canvas colour (#RRGGBB or brand role).")]) { t, _, _ in
            rangeParams(t, ["preset": "split-card"])
        })
        out.append(item("layout-pip-bubble", .layouts, "Bolla", "layout.speaker", .moment, "person.crop.circle",
                        range + [Field("corner", "choice", "bottomRight", "Corner of the bubble.", choices: LayoutSpec.corners),
                                 Field("size", "choice", "M", "Bubble size.", choices: LayoutSpec.sizes),
                                 Field("brollAssetId", "text", "a2", "Asset filling the frame under the bubble.")]) { t, _, _ in
            rangeParams(t, ["preset": "pip-bubble"])
        })
        out.append(item("layout-inset-frame", .layouts, "Riquadro neon", "layout.speaker", .moment, "rectangle.inset.filled",
                        range + [Field("frame", "choice", "neon", "Card style.", choices: LayerMask.frames),
                                 Field("position", "choice", "center", "Where the card sits.", choices: SpeakerLayout.positions),
                                 Field("label", "text", "PREVIEW", "Chip in the top-left corner (empty: none)."),
                                 Field("animate", "number", 0.5, "Seconds of the zoom from/to full frame.")]) { t, _, _ in
            rangeParams(t, ["preset": "inset-frame"])
        })
        out.append(item("layout-full", .layouts, "Schermo intero", "layout.speaker", .moment, "rectangle.fill", range) { t, _, _ in
            rangeParams(t, ["preset": "full"])
        })
        // Following a face or a hand (the follower is the clip chosen in the app, or clipId).
        out.append(item("follow-hand-object", .motion, "Oggetto in mano", "clip.follow", .clip, "hand.raised.fill",
                        [Field("clipId", "clip", "c7", "The object to hold (a logo, sticker or image clip over the gesture)."),
                         Field("hover", "number", 90, "Px above the palm."), Field("spin", "number", 2.5, "Seconds per turn (0 = still)."),
                         Field("halo", "boolean", true, "Glowing ellipse under the object.")]) { t, _, _ in
            var o: [String: JSONValue] = ["target": "hand", "hover": 90, "spin": 2.5, "halo": true]
            if let c = t.clipID { o["clipId"] = .string(c) }
            return o
        })
        out.append(item("follow-face", .motion, "Segui il viso", "clip.follow", .clip, "face.dashed",
                        [Field("clipId", "clip", "c7", "The overlay that rides along."),
                         Field("point", "choice", "top", "center or top (just above the head).", choices: ["center", "top"]),
                         Field("offset", "point", [160, 0], "[dx, dy] px from the point.")]) { t, _, _ in
            var o: [String: JSONValue] = ["target": "face", "point": "top"]
            if let c = t.clipID { o["clipId"] = .string(c) }
            return o
        })
        // HUD.
        out.append(item("status-bar", .text, "Barra di stato", "status.add", .picture, "record.circle",
                        [Field("label", "text", "EDITING LIVE", "Text after the REC dot."),
                         Field("chapters", "list", [["at": 0, "label": "LIVE"], ["at": 8, "label": "EFFECTS"]], "One chapter per script section: {at, label}."),
                         Field("timerRate", "number", 8, "Timer speed (1 = real time).")]) { _, _, _ in ["label": "EDITING LIVE"] })
        out.append(item("audio-meters", .motion, "Vu-meter", "meters.add", .moment, "chart.bar.fill",
                        [EffectsCatalog.Fields.start, Field("end", "time", 10, "Timeline end (default start + 6 s)."),
                         Field("color", "color", "accent", "Top segments (#RRGGBB or brand role).")]) { t, _, _ in
            var o: [String: JSONValue] = ["start": s(t.start)]
            if let e = t.end { o["end"] = s(e) }
            return o
        })
        // Transition.
        out.append(item("transition-blur", .transitions, "Sfocatura", "transition.add", .moment, "camera.aperture",
                        [Field("at", "time", 6.4, "Time of the cut (default: the nearest cut within 1 s of start)."),
                         Field("duration", "time", 0.6, "Seconds, centred on the cut.")]) { t, i, p in
            let cuts = p.tracks.first { $0.kind == .video }?.clips.dropFirst().map(\.start) ?? []
            let at = cuts.min { abs(($0 - t.start).seconds) < abs(($1 - t.start).seconds) }.flatMap { abs(($0 - t.start).seconds) <= 1 ? $0 : nil } ?? t.start
            return ["kind": "blur", "at": s(at), "duration": EffectsCatalog.n(0.6 * (0.6 + 0.8 * i))]
        })
        return out
    }
}
