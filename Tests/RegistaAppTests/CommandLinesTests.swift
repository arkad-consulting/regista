import Foundation
import RegistaCore
import RegistaMCP
import Testing
@testable import Regista

// The Claude panel's second line (#79): every command the four recipes name says what happened in a sentence a person
// reads, in each interface language, never the result's raw fields («numero 2 · righe [2]», «durata 3.53»).

/// The commands the recipes name (their tools, as recipe.get hands them to Claude).
@MainActor
private let recipeCommands: [String] = {
    let text = Recipes.all.map { $0.text() }.joined(separator: "\n")
    let words = Set(text.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "_")).inverted))
    return Commands.all.map { $0.id }.filter { words.contains(MCPServer.toolName($0)) }.sorted()
}()

/// A representative result of each command, in the shape the command returns.
private let sampleResults: [String: JSONValue] = {
    let clip: JSONValue = ["id": "c3", "asset": "a1", "start": 1.5, "end": 3.5, "duration": 2, "sourceIn": 0, "sourceOut": 2]
    let titleClip: JSONValue = ["id": "c4", "asset": "", "start": 0, "end": 2.5, "duration": 2.5, "title": ["text": "OGGI", "font": "Impact", "size": 120, "color": "#FFFFFF"]]
    let asset: JSONValue = ["id": "a1", "name": "ripresa", "path": "/scratch/ripresa.mov", "duration": 6]
    let check: JSONValue = ["kind": "talking-head-reel", "kindTitle": "Reel", "pass": false, "failures": 2, "warnings": 1,
                            "violations": [["check": "title-captions", "severity": "fail", "time": 0.5]], "checks": [], "sheetProblems": []]
    let take: JSONValue = ["take": 1, "label": "1/1", "start": 0.4, "end": 2.1, "text": "Oggi Regista monta il reel.", "complete": true, "wer": 0]
    let job: JSONValue = ["jobId": "g1", "status": "done", "provider": "comfyui", "kind": "image", "prompt": "a chair", "cost": 0,
                          "path": "/scratch/generated/chair.png", "assetId": "a2"]
    return [
        "adjust.set": ["scope": "project", "grade": ["exposure": 0.1]],
        "audio.addMusic": ["trackId": "t5", "clips": [clip], "measuredLUFS": -18.2, "gain": -3.8, "level": -22, "duck": -12, "underSpeechLUFS": -34],
        "audio.checkDucking": ["pass": true, "voiceLUFS": -15.1, "musicUnderSpeechLUFS": -34.4, "underDB": 19.3, "minUnder": 15],
        "audio.clean": ["asset": asset, "trackId": "t2", "commands": [], "loudness": ["integrated": -15.02, "truePeak": -1.6, "lra": 4.2], "lagMs": 0],
        "brandkit.apply": ["kit": "journey-kit", "name": "Journey Kit", "titles": ["hook"], "captionTracks": ["t3"], "titlesRestyled": 1, "logos": 0, "warnings": []],
        "brandkit.check": ["pass": true, "kit": "journey-kit", "captions": [:], "logos": []],
        "brandkit.list": ["kits": [["id": "neutral", "name": "Neutral"], ["id": "journey-kit", "name": "Journey Kit"]], "active": "neutral"],
        "skill.list": ["skills": [["skill": "long-interview", "title": "Intervista lunga"]], "builtIns": [], "folder": "/scratch/skills"],
        "skill.get": ["skill": "long-interview", "title": "Intervista lunga", "steps": "1. Leggi le domande."],
        "skill.create": ["skill": "long-interview", "title": "Intervista lunga", "steps": "1. Leggi le domande."],
        "skill.set": ["skill": "long-interview", "title": "Intervista lunga", "steps": "1. Leggi le domande."],
        "skill.duplicate": ["skill": "intervista-due", "title": "Intervista due", "basedOn": "talking-head-reel"],
        "skill.remove": ["removed": "long-interview", "title": "Intervista lunga"],
        "skill.export": ["path": "/scratch/intervista-lunga.md", "skill": "long-interview", "title": "Intervista lunga", "bytes": 120],
        "skill.import": ["added": "long-interview", "replaced": false, "skill": ["skill": "long-interview", "title": "Intervista lunga"]],
        "callout.add": ["clip": clip, "trackId": "t6", "box": [100, 200, 300, 120], "warnings": []],
        "captions.checkFaces": ["pass": true, "chunks": 5, "framesChecked": 40, "framesWithFaces": 40, "overlappingChunks": 0, "moved": 1, "placedOverFaces": 0, "warnings": []],
        "captions.checkTiming": ["words": 10, "framesDecoded": 180, "detected": 10, "undetected": 0, "withinTolerance": 10, "maxAbsError": 1, "pass": true],
        "captions.clear": ["trackId": "t3", "removed": 1, "shortened": 1, "chunks": 4],
        "captions.generate": ["trackId": "t3", "style": "talking-head-v1", "chunks": 5, "language": "it", "stopWordEnds": [], "words": 10,
                              "keywordsShown": 2, "sourceTrack": "t1", "stale": false, "preview": ["OGGI REGISTA", "MONTA IL REEL"], "suggestedKeywords": ["REEL"]],
        "captions.get": ["trackId": "t3", "style": "talking-head-v1", "chunks": 5, "keywords": ["REGISTA"], "fixes": [:],
                         "list": [["text": "OGGI REGISTA", "start": 0.4, "end": 1.2], ["text": "MONTA IL REEL", "start": 1.2, "end": 2.1]]],
        "captions.place": ["trackId": "t3", "scope": "track", "trackPlace": ["align": "left", "x": 60, "y": 300], "chunks": [], "clamped": 0],
        "captions.setKeywords": ["trackId": "t3", "style": "talking-head-v1", "chunks": 5, "words": 10, "keywordsShown": 3, "keywords": ["REGISTA", "PAUSE", "REEL"]],
        "captions.setStyle": ["trackId": "t3", "style": "elegant-serif", "chunks": 6, "words": 10, "keywordsShown": 2, "id": "elegant-serif", "rechunked": true],
        "clip.follow": ["clipId": "c7", "target": "hand", "point": "palm", "assetId": "a1", "keyframes": 24, "visible": 0.92],
        "clip.place": ["clip": clip, "box": [100, 200, 300, 120], "center": [250, 260], "warnings": []],
        "clip.set": ["clips": [clip, clip]],
        "clip.speed": ["clip": clip, "linked": [], "duration": 4, "rate": 0.5],
        "cursor.style": ["recordingId": "r1", "drawn": true, "style": ["scale": 1.5, "clickRipple": true], "warnings": []],
        "edit.autoCut": ["commands": [], "segments": [["line": 1, "take": 1, "sourceIn": 0.4, "sourceOut": 2.1, "start": 0],
                                                      ["line": 2, "take": 1, "sourceIn": 3, "sourceOut": 4.8, "start": 1.7]],
                         "videoTrackId": "t1", "audioTrackId": "t2", "duration": 3.53],
        "edit.autoZoom": ["clicks": [["time": 1.2, "x": 400, "y": 300, "zoom": 1.8], ["time": 3.4, "x": 900, "y": 500, "zoom": 1.8]], "groups": 2, "keys": 6],
        "edit.beatSync": ["mode": "punch", "tempo": 120, "beats": 16, "times": [0.5, 1, 1.5], "added": [["at": 0.5], ["at": 1]]],
        "edit.punchIns": ["trackId": "t1", "mode": "line", "clips": [["clipId": "c1", "framing": "base"], ["clipId": "c2", "framing": "punch"]], "commands": [], "faces": 1],
        "effect.add": ["effectId": "e1", "clip": clip],
        "effects.catalog": ["items": [["id": "fade", "label": "Fade"], ["id": "blur", "label": "Blur"]], "categories": ["effects"]],
        "effects.check": ["pass": true, "items": [["clipId": "c3", "kind": "blur", "visible": true]], "identity": ["maxDiff": 0, "mean": 0]],
        "effects.preview": ["item": "counter", "command": "motion.add", "params": [:], "path": "/scratch/preview.png", "images": [["path": "/scratch/preview.png"]]],
        "cover.set": ["cover": ["time": 2.5, "title": "Tre parole qui", "preset": .null, "place": "center"]],
        "cover.make": ["path": "/scratch/reel-cover.png", "width": 1080, "height": 1920, "cover": ["time": 2.5, "place": "center"],
                       "check": ["pass": true, "overflows": []]],
        "cover.check": ["cover": ["time": 2.5, "place": "top"], "check": ["pass": false, "overflows": [["side": "top", "pixels": 40]]]],
        "export.mlt": ["path": "/scratch/reel.mlt", "captionImages": 5, "titleImages": 1, "warnings": []],
        "export.render": ["path": "/scratch/reel.mp4", "preset": "9:16", "width": 1080, "height": 1920, "fps": 30, "frames": 106, "duration": 3.53,
                          "rules": check, "warnings": [], "loudness": ["integrated": -15.1, "truePeak": -1.7]],
        "export.srt": ["path": "/scratch/reel.srt", "cues": 5],
        "faces.checkFraming": ["pass": true, "framesChecked": 24, "framesWithFaces": 24, "framesCut": 0, "cuts": []],
        "faces.track": ["assetId": "a1", "sidecar": "/scratch/faces.json", "frames": 180, "detected": 176, "detectedRatio": 0.9778, "multiFaceFrames": 0, "cuts": 0],
        "frame.contactSheet": ["path": "/scratch/sheet.png", "times": [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5], "images": [["path": "/scratch/sheet.png"]]],
        "frame.elements": ["time": 1, "frame": [1080, 1920], "elements": [["kind": "caption"], ["kind": "title"]]],
        "frame.render": ["frames": ["/scratch/f1.png", "/scratch/f2.png"], "warnings": []],
        "generate.check": ["models": [["model": "flux", "state": "ready"]], "ready": true, "summary": "flux: ready"],
        "generate.estimate": ["estimateId": "e1", "provider": "higgsfield", "model": "seedance", "kind": "video", "credits": 12.5, "paid": true,
                              "cached": false, "seconds": 5, "budgetRemaining": 2, "approval": "needed"],
        "generate.list": ["assets": [["assetId": "a2", "path": "/scratch/generated/chair.png"]], "jobs": [job], "budget": ["remaining": 2], "approvals": []],
        "generate.providers": ["providers": [["name": "comfyui", "available": true], ["name": "higgsfield", "available": false]], "tier": "pro", "budgetRemaining": 2],
        "generate.run": job,
        "generate.status": ["jobs": [job]],
        "generate.upscale": job,
        "graphics.blenderTitle": ["clip": clip, "seconds": 4, "cached": false, "renderSeconds": 72.4, "frames": "/scratch/frames"],
        "graphics.checkBehindSubject": ["clipId": "c4", "source": "render", "samples": [], "hiddenRatio": 0.3, "visibleRatio": 0.7, "pass": true],
        "graphics.checkLayout": ["pass": true, "captionBand": [1230, 1460], "checked": 3, "extents": [], "violations": []],
        "graphics.hyperframes": ["clip": clip, "seconds": 3, "cached": true, "renderSeconds": 0, "frames": "/scratch/frames"],
        "hands.track": ["assetId": "a1", "sidecar": "/scratch/hands.json", "from": 1, "to": 3, "frames": 60, "withHand": 52, "openPalm": 40, "meanPalm": [540, 900]],
        "history.undo": ["undone": "title.add", "undo": 9, "redo": 1],
        "keys.overlay": ["trackId": "t7", "badges": [["text": "⌘C", "start": 1.2, "end": 2]], "keys": 1, "dropped": 0, "allKeys": false, "warnings": []],
        "layout.apply": ["layout": "bubble", "from": 0, "to": 12.5, "cameraClips": ["c9"], "boxes": [:], "warnings": []],
        "layout.presets": ["width": 1920, "height": 1080, "presets": [["preset": "bubble"], ["preset": "split"], ["preset": "screen"]]],
        "layout.speaker": ["layout": "split-card", "from": 0, "to": 8, "clips": [], "speakerBox": [0, 0, 540, 960], "freeArea": [540, 0, 540, 960], "warnings": []],
        "logo.add": ["clip": clip, "trackId": "t8", "box": [800, 100, 200, 200], "insideSafeZone": true, "warnings": []],
        "logo.animate": ["clip": clip, "motion": "sting"],
        "look.apply": ["scope": "clips", "clips": [["clipId": "c3"]]],
        "matte.track": ["assetId": "a1", "directory": "/scratch/matte", "frames": 75, "segmented": 75, "cached": 0, "missing": 0, "tracked": 75],
        "media.checkOverlay": ["pass": true, "clips": [["clipId": "c3", "psnr": 42]]],
        "media.checkSync": ["lagMs": 3.3, "lagFrames": 0.1, "correlation": 0.94, "windows": 4],
        "media.extractAudio": ["assetId": "a1", "speech": "/scratch/speech.wav", "working": "/scratch/working.wav"],
        "media.import": ["asset": asset, "existing": false, "liveTakeMarkers": nil],
        "media.list": ["roots": [["path": "/scratch", "exists": true]], "projectsDirectory": "/scratch/projects", "exportsDirectory": "/scratch/exports",
                       "files": [["path": "/scratch/a.mov", "kind": "video", "bytes": 1000], ["path": "/scratch/b.md", "kind": "text", "bytes": 20]]],
        "meters.add": ["clip": clip, "trackId": "t9", "samples": 120, "loudest": 2.2],
        "motion.add": ["clip": clip, "trackId": "t10", "template": "counter", "fields": [:], "place": "top", "warnings": []],
        "overlay.add": ["clip": clip, "trackId": "t11", "asset": asset, "box": [0, 0, 1080, 1920], "warnings": []],
        "profile.create": ["profile": ["id": "mia", "name": "Mia", "active": true], "folder": "/scratch/profiles/mia"],
        "progress.add": ["clip": clip, "trackId": "t12"],
        "project.format": ["width": 1080, "height": 1920, "layouts": []],
        "project.new": ["open": true, "name": "Reel di Claude", "path": nil, "dirty": false, "settings": ["width": 1080, "height": 1920, "fps": 30], "duration": 0, "assets": [], "tracks": []],
        "project.save": ["path": "/scratch/Reel di Claude.regista", "file": "/scratch/Reel di Claude.regista/project.json"],
        "project.state": ["open": true, "name": "Reel di Claude", "dirty": true, "settings": ["width": 1080, "height": 1920, "fps": 30], "duration": 3.53, "assets": [], "tracks": []],
        "recipe.get": ["name": "talking-head-reel", "title": "Talking-head reel (9:16, captioned)", "text": "# Talking-head reel", "kind": "talking-head-reel"],
        "recording.check": ["path": "/scratch/tutorial.mp4", "width": 1920, "height": 1080, "sync": ["pass": true], "pass": true],
        "recording.import": ["recordingId": "r1", "session": "/scratch/rec", "synthetic": true, "start": 0, "duration": 8.4, "assets": ["screen": "a1"], "tracks": ["screen": "t1"],
                             "clips": ["screen": "c1"], "sources": [], "events": ["clicks": 3, "keys": 2]],
        "rules.check": check,
        "rules.fix": ["applied": [["check": "title-captions"], ["check": "logo-pause"]], "check": ["pass": true, "failures": 0, "warnings": 0, "violations": []]],
        "script.fromTranscript": ["assetId": "a1", "language": "it", "count": 3, "lines": ["Uno.", "Due.", "Tre."]],
        "script.set": ["lines": ["Oggi Regista monta il reel.", "Le pause spariscono da sole."], "count": 2, "keywords": []],
        "sfx.add": ["clip": clip, "trackId": "t13", "gain": -12],
        "sfx.checkOnsets": ["pass": true, "effects": 3, "rows": []],
        "sfx.library": ["directory": "/scratch/sfx", "bank": "built-in", "effects": [["name": "whoosh-soft"], ["name": "pop"]]],
        "sfx.onCuts": ["placed": 4, "at": [1.7, 3.2, 5, 6.1], "commands": []],
        "status.add": ["clip": clip, "trackId": "t14"],
        "sticker.add": ["clip": clip, "trackId": "t15", "box": [100, 100, 200, 200], "warnings": []],
        "style.apply": ["style": "energico", "applied": [["look": "film"], ["kind": "punchZoom"], ["kind": "whoosh"]], "skipped": [["kind": "music", "why": "no music"]]],
        "takes.list": ["assetId": "a1", "source": "transcript", "lines": [["line": 1, "text": "Uno.", "takes": [take], "chosen": 1],
                                                                          ["line": 2, "text": "Due.", "takes": [take], "chosen": 1]], "read": 2, "missing": []],
        "takes.select": ["line": 2, "chosen": 1, "auto": 2],
        "text.read": ["path": "/scratch/copione.md", "bytes": 120, "text": "## Testo\n1. Uno."],
        "timeline.delete": ["deleted": ["c3"], "removedGaps": 0],
        "timeline.move": ["clip": clip, "trackId": "t1"],
        "timeline.place": ["clip": clip, "trackId": "t1"],
        "timeline.trim": ["clip": clip, "linked": []],
        "title.add": ["clip": titleClip, "trackId": "t4", "box": [100, 200, 880, 300], "warnings": []],
        "track.add": ["track": ["id": "t16", "kind": "video", "name": "V2", "clips": []], "index": 2],
        "transcript.deleteWords": ["removed": "ehm allora", "from": 2.2, "to": 2.9, "commands": []],
        "transcript.run": ["assetId": "a1", "engine": "whisperx", "model": "small", "language": "it", "words": 10, "cached": false, "seconds": 4.2,
                           "text": "Oggi Regista monta il reel. Le pause spariscono da sole."],
        "transcript.fillers": ["trackId": "t1", "language": "it", "count": 3, "fillers": [], "seconds": ["sure": 0.7, "maybe": 0.4, "repeat": 0], "delete": [:]],
        "transcript.timeline": ["trackId": "t1", "count": 10, "text": "Oggi Regista…", "words": [["i": 0, "text": "Oggi", "start": 0.4, "end": 0.7]]],
        "transition.add": ["transition": ["id": "x1", "kind": "flash", "at": 1.7, "duration": 0.2]],
        "voice.lexicon": ["language": "it", "file": "/scratch/lexicon.json", "entries": [["word": "Regista", "say": "Re-gì-sta"]]],
        "voice.list": ["profile": ["id": "mia", "name": "Mia", "active": true], "languages": [["language": "it", "ready": true, "tones": ["neutral"]]],
                       "engine": ["available": true]],
        "voice.preview": ["paragraphs": [["index": 0, "text": "Uno.", "seconds": 2.1, "cached": false], ["index": 1, "text": "Due.", "seconds": 1.9, "cached": false]],
                          "seconds": 4, "renderSeconds": 6.5],
        "voice.say": ["trackId": "t17", "clips": [["clipId": "c20", "assetId": "a5", "start": 0, "duration": 2.1], ["clipId": "c21", "assetId": "a6", "start": 2.4, "duration": 1.9]],
                      "paragraphs": 2, "end": 4.3, "captions": "captions.generate {sourceTrackId: \"t17\"}", "aiDisclosure": "AI-generated voice"],
    ]
}()

/// What makes a second line unreadable: a bracket, a raw key, a field's name before its value, a bare number.
@MainActor
func lineProblems(_ line: String, result: JSONValue) -> [String] {
    var out: [String] = []
    if line.isEmpty { out.append("empty") }
    if line.rangeOfCharacter(from: CharacterSet(charactersIn: "[]{}")) != nil { out.append("a bracket") }
    if line.contains("%@") || line.contains("result.") { out.append("a format left unfilled") }
    func keys(_ v: JSONValue) -> [String] {
        if let o = v.objectValue { return o.keys + o.values.flatMap(keys) }
        if let a = v.arrayValue { return a.flatMap(keys) }
        return []
    }
    let all = Set(keys(result))
    // A key in camelCase (assetId, keywordsShown) is never a word of a sentence.
    for k in all where k.contains(where: \.isUppercase) && line.contains(k) { out.append("the raw key «\(k)»") }
    // The old second line: a field's name in words, then its value («durata 3.53», «righe [2]»).
    for k in all where Summary.resultLabel(k) != k {
        if line.range(of: Summary.resultLabel(k) + " [0-9\\[]", options: .regularExpression) != nil { out.append("the field «\(Summary.resultLabel(k))» with its value") }
    }
    // Every number reads as a count (a noun after it), an ordinal (a noun before it), a time, a size or a level with its unit.
    // (A digit inside a word is not a number: «reel.mp4», «3D».)
    let scanner = try! NSRegularExpression(pattern: "(?<![\\p{L}\\d])\\d+(?:[.,:]\\d+)*(?![\\p{L}\\d])")
    let ns = line as NSString
    for m in scanner.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
        let token = ns.substring(with: m.range)
        let after = ns.substring(from: m.range.location + m.range.length)
        let before = ns.substring(to: m.range.location)
        if token.range(of: "^\\d+:\\d\\d\\.\\d$", options: .regularExpression) != nil { continue }   // 0:03.5
        if after.hasPrefix("×") || before.hasSuffix("×") { continue }                                    // 1080×1920
        if after.range(of: "^ (LUFS|dB|ms|s|BPM)\\b", options: .regularExpression) != nil { continue }
        let decimal = token.contains(".") || token.contains(",")
        if after.range(of: "^ \\p{L}", options: .regularExpression) != nil { continue }               // 2 righe, 12,5 crediti
        if !decimal, before.range(of: "\\p{L} $", options: .regularExpression) != nil { continue }     // riga 2
        out.append("the bare number «\(token)»")
    }
    return out
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct CommandLinesTests {
    /// Every command a recipe names has a representative result here and a sentence for it, readable in it / en / fr / pt.
    @Test(arguments: ["it", "en", "fr", "pt"])
    func everyRecipeCommandSaysWhatHappened(_ language: String) {
        #expect(recipeCommands.count > 60, "the recipes name only \(recipeCommands.count) commands: \(recipeCommands)")
        Words.override = MouseRig.table(language)
        Words.applies = { true }
        defer { Words.override = nil; Words.applies = nil }
        for id in recipeCommands {
            guard let result = sampleResults[id] else { Issue.record("no representative result of \(id)"); continue }
            guard let line = CommandLines.line(id, result) else { Issue.record("\(id) has no sentence"); continue }
            let problems = lineProblems(line, result: result)
            #expect(problems.isEmpty, "\(language) \(id): «\(line)»: \(problems.joined(separator: ", "))")
        }
    }

    /// The register of the sentences, as #79 asks for it.
    @Test func theSentencesReadAsTheIssueAsks() {
        Words.override = MouseRig.table("it")
        Words.applies = { true }
        defer { Words.override = nil; Words.applies = nil }
        #expect(CommandLines.line("script.set", sampleResults["script.set"]!) == "2 righe di copione")
        #expect(CommandLines.line("skill.create", sampleResults["skill.create"]!) == "Creata la skill «Intervista lunga»")
        #expect(CommandLines.line("skill.import", sampleResults["skill.import"]!) == "Aggiunta la skill «Intervista lunga»")
        #expect(CommandLines.line("skill.export", sampleResults["skill.export"]!) == "Skill esportata in intervista-lunga.md")
        #expect(CommandLines.line("takes.list", sampleResults["takes.list"]!) == "2 riprese trovate, una per riga")
        #expect(CommandLines.line("edit.autoCut", sampleResults["edit.autoCut"]!) == "Tagliato a 0:03.5 in 2 pezzi")
        #expect(CommandLines.line("transcript.run", sampleResults["transcript.run"]!) == "10 parole trascritte")
        #expect(CommandLines.line("audio.clean", sampleResults["audio.clean"]!) == "Voce pulita a −15 LUFS")
        #expect(CommandLines.line("export.render", sampleResults["export.render"]!) == "Esportato reel.mp4 · 0:03.5")
        // Singular when one.
        #expect(CommandLines.line("script.set", ["lines": ["Uno."], "count": 1]) == "1 riga di copione")
        #expect(CommandLines.line("transcript.run", ["words": 1]) == "1 parola trascritta")
        // A command without a sentence of its own: no second line.
        #expect(CommandLines.line("timeline.link", ["linked": ["c1", "c2"]]) == nil)
    }

    /// #133: zero takes the singular in French only («0 mot clé»), the plural in Italian, English and Portuguese; one
    /// is singular and two plural everywhere — in the Claude panel's sentences (keywords, caption blocks, filler words,
    /// transcribed words), the teleprompter's counts (a %d plural) and the credits.
    @Test(arguments: [
        ("it", ["0 blocchi di sottotitoli · 0 parole chiave", "1 blocco di sottotitoli · 1 parola chiave", "2 blocchi di sottotitoli · 2 parole chiave"],
         ["0 intercalari trovati", "1 intercalare trovato", "2 intercalari trovati"], ["0 parole trascritte", "1 parola trascritta", "2 parole trascritte"],
         ["0 riprese", "1 ripresa", "2 riprese"], ["0 crediti", "1 credito", "2 crediti"]),
        ("en", ["0 caption blocks · 0 keywords", "1 caption block · 1 keyword", "2 caption blocks · 2 keywords"],
         ["0 filler words found", "1 filler word found", "2 filler words found"], ["0 words transcribed", "1 word transcribed", "2 words transcribed"],
         ["0 takes", "1 take", "2 takes"], ["0 credits", "1 credit", "2 credits"]),
        ("fr", ["0 bloc de sous-titres · 0 mot clé", "1 bloc de sous-titres · 1 mot clé", "2 blocs de sous-titres · 2 mots clés"],
         ["0 mot de remplissage trouvé", "1 mot de remplissage trouvé", "2 mots de remplissage trouvés"], ["0 mot transcrit", "1 mot transcrit", "2 mots transcrits"],
         ["0 prise", "1 prise", "2 prises"], ["0 crédit", "1 crédit", "2 crédits"]),
        ("pt", ["0 blocos de legendas · 0 palavras-chave", "1 bloco de legendas · 1 palavra-chave", "2 blocos de legendas · 2 palavras-chave"],
         ["0 palavras de preenchimento encontradas", "1 palavra de preenchimento encontrada", "2 palavras de preenchimento encontradas"],
         ["0 palavras transcritas", "1 palavra transcrita", "2 palavras transcritas"], ["0 tomadas", "1 tomada", "2 tomadas"], ["0 créditos", "1 crédito", "2 créditos"]),
    ])
    func zeroOneAndTwoInTheLanguage(_ language: String, captions: [String], fillers: [String], words: [String], takes: [String], credits: [String]) {
        Words.override = MouseRig.table(language)
        Words.applies = { true }
        defer { Words.override = nil; Words.applies = nil }
        for n in 0...2 {
            let caption = CommandLines.line("captions.generate", ["trackId": "t3", "style": "talking-head-v1", "chunks": .number(Double(n)), "keywordsShown": .number(Double(n))])
            #expect(caption == captions[n], "\(language) \(n): «\(caption ?? "")»")
            let filler = CommandLines.line("transcript.fillers", ["trackId": "t1", "count": .number(Double(n)), "fillers": [], "delete": [:]])
            #expect(filler == fillers[n], "\(language) \(n): «\(filler ?? "")»")
            let word = CommandLines.line("transcript.run", ["words": .number(Double(n))])
            #expect(word == words[n], "\(language) \(n): «\(word ?? "")»")
            let take = PrompterEditorView.counts(takes: n, words: 160).components(separatedBy: " · ").first
            #expect(take == takes[n], "\(language) \(n): «\(take ?? "")»")
            #expect(GenWords.credits(Double(n)) == credits[n], "\(language) \(n): «\(GenWords.credits(Double(n)))»")
        }
        #expect(Plural.singular(1.5, language: language) == (language == "fr"), "\(language): 1.5 in the singular is French only")
    }

    /// Every singular handed to Plural (and to CommandLines.count) writes its number as a standalone 1 in French, where
    /// it also stands for 0: «0 mot clé», never a singular without its number.
    @Test func everyFrenchSingularCarriesItsNumber() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Regista")
        let table = MouseRig.table("fr")
        // The singular and plural keys side by side (Plural.text, count), or the singular alone (Plural.one).
        let pair = try NSRegularExpression(pattern: #"(?:Plural\.text|\bcount)\(.*?"([^"]+)", "[^"]+"(?:, lookup: lookup)?\)"#)
        let single = try NSRegularExpression(pattern: #"Plural\.one\("([^"]+)""#)
        var keys = Set<String>()
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for re in [pair, single] {
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range(at: 1), in: text) { keys.insert(String(text[r])) }
                }
            }
        }
        // Never asked with 0: the alert only comes for a track that holds clips («et son clip» says the one).
        keys.remove("Eliminare la pista %@ con 1 clip?")
        let wanted = ["1 parola chiave", "1 ripresa", "Foglio di 1 fotogramma", "Voce: 1 paragrafo"]
        #expect(wanted.allSatisfy(keys.contains), "the scan missed some singulars: \(wanted.filter { !keys.contains($0) })")
        for key in keys.sorted() where key.contains("1") {
            let french = table.localizedString(forKey: key, value: nil, table: nil)
            #expect(french.range(of: #"(?<![\d.,])1(?![\d.,×])"#, options: .regularExpression) != nil, "«\(key)» is «\(french)» in French: no number to write 0 in")
        }
    }

    /// The log's row: the sentence as the second line, the raw fields only in its tooltip; a failed command keeps its error.
    @Test func theLogShowsTheSentenceAndKeepsTheDetails() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let store = app.store.bench.active
        _ = try await store.perform("project.new", ["name": "Righe", "directory": .string(rigTempDir("lines").path)])
        _ = try await store.perform("script.set", ["text": "Uno.\nDue."])
        let entry = try #require(store.activity.last { $0.command == "script.set" })
        #expect(entry.result == "2 righe di copione" || entry.result == CommandLines.line("script.set", ["count": 2]), "the second line reads «\(entry.result)»")
        #expect(!entry.details.isEmpty, "the raw fields are gone from the tooltip too")
        _ = try? await store.perform("takes.select", ["line": 9, "take": 1])
        let failed = try #require(store.activity.last { $0.command == "takes.select" })
        #expect(failed.status == .failed && !failed.result.isEmpty, "a failed command lost its error: \(failed)")
    }
}
}
