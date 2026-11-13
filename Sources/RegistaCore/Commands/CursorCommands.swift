import Foundation

// cursor.style (issue #42): how the drawn cursor of a screen recording looks. Takes recorded without the system
// cursor (session cursorInVideo false) get it drawn by the compositor on the screen layer; the style lives on the
// recording (RecordingLink.cursor), so cuts and layouts never lose it.

enum CursorStyleCommand: Command {
    static let id = "cursor.style"
    static let summary = "Style the drawn cursor of a screen recording made without the system cursor (Registra's «Nascondi il cursore», or recording.synthesize cursor: false): the compositor redraws the macOS cursor from the logged path on the screen layer, so it follows the crop and zoom keyframes — smoothed by a critically damped spring, bigger, faded out after 2 s idle (0.3 s, back on movement), with an expanding ring on each click. Only the given fields change (reset: true goes back to the defaults first); one undo step. Takes with the cursor baked into the video store the style but cannot hide that cursor (a warning says so). Returns the style and whether it is drawn."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("visible", .boolean, "Draw the cursor (default true; false hides it, ripples included)."),
        .optional("scale", .number, "Size relative to the system cursor, 0.5–4 (default 1.5)."),
        .optional("smoothing", .number, "Spring smoothing of the path, 0 (raw) – 1 (floaty) (default 0.5)."),
        .optional("hideWhenIdle", .boolean, "Fade out after 2 s without movement or click (default true)."),
        .optional("clickRipple", .boolean, "An expanding ring on each click (default true)."),
        .optional("color", .string, "Ripple colour #RRGGBB (default white; \"\" = default)."),
        .optional("reset", .boolean, "Start from the defaults instead of the current style."),
        Recording.recordingParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (index, link) = try Recording.link(p, project, command: id)
        guard link.screen != nil else { throw CommandError.conflict("\(id): the recording has no screen") }
        var style = p.bool("reset") == true ? CursorStyle() : (link.cursor ?? CursorStyle())
        if let v = p.bool("visible") { style.visible = v }
        if let v = p.number("scale") {
            guard v >= 0.5, v <= 4 else { throw CommandError.invalid("\(id): scale must be 0.5…4") }
            style.scale = v
        }
        if let v = p.number("smoothing") {
            guard v >= 0, v <= 1 else { throw CommandError.invalid("\(id): smoothing must be 0…1") }
            style.smoothing = v
        }
        if let v = p.bool("hideWhenIdle") { style.hideWhenIdle = v }
        if let v = p.bool("clickRipple") { style.clickRipple = v }
        if let c = p.string("color") {
            if c.isEmpty {
                style.color = nil
            } else {
                guard c.count == 7, c.hasPrefix("#"), c.dropFirst().allSatisfy(\.isHexDigit) else {
                    throw CommandError.invalid("\(id): color must be #RRGGBB")
                }
                style.color = c.uppercased()
            }
        }
        project.recordings![index].cursor = style == CursorStyle() ? nil : style
        ctx.project = project
        let drawn = link.cursorInVideo == false
        var warnings: [JSONValue] = []
        if !drawn {
            warnings.append("this take has the system cursor recorded in the video: the style is kept but nothing is drawn (record with «Nascondi il cursore» for a drawn cursor)")
        }
        return ["recordingId": .string(link.id), "drawn": .bool(drawn && style.visible),
                "style": json(style), "warnings": .array(warnings)]
    }

    static func json(_ s: CursorStyle) -> JSONValue {
        ["visible": .bool(s.visible), "scale": .number(s.scale), "smoothing": .number(s.smoothing), "hideWhenIdle": .bool(s.hideWhenIdle),
         "clickRipple": .bool(s.clickRipple), "color": .string(s.color ?? "#FFFFFF")]
    }
}
