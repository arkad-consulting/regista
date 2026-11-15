import Foundation

/// Holds the open project and runs commands against it. One owner (the app's main actor, the
/// CLI or the MCP server loop): not thread-safe by design.
public final class Engine {
    public struct LogEntry: Sendable {
        public var command: String
        public var params: JSONValue
        /// nil on success.
        public var error: String?
    }

    public private(set) var context: CommandContext
    /// Every command executed this session, failed ones included.
    public private(set) var log: [LogEntry] = []
    public let registry: [String: any Command.Type]

    public var project: Project? { context.project }
    public var projectURL: URL? { context.projectURL }
    public var isDirty: Bool { context.dirty }

    public init(prober: MediaProber = FFProbe(), services: EngineServices = .standard(),
                commands: [any Command.Type] = Commands.all) {
        context = CommandContext(prober: prober, services: services)
        registry = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    }

    /// A throwaway engine on a copy of `project` (the app's effect previews apply a gallery tile there and render it,
    /// without touching the real edit or its history).
    public convenience init(scratch project: Project, services: EngineServices) {
        self.init(prober: FFProbe(), services: services)
        context.project = project
    }

    /// Sorted by id.
    public var descriptors: [CommandDescriptor] {
        registry.values.map { $0.descriptor }.sorted { $0.id < $1.id }
    }

    /// Validates, runs and commits one command. On error nothing changes.
    @discardableResult
    public func execute(_ id: String, params: JSONValue = .null) throws -> JSONValue {
        do {
            let result = try run(id, params)
            log.append(LogEntry(command: id, params: params))
            return result
        } catch {
            log.append(LogEntry(command: id, params: params, error: "\(error)"))
            throw error
        }
    }

    private func run(_ id: String, _ raw: JSONValue) throws -> JSONValue {
        guard let command = registry[id] else {
            let near = registry.keys.filter { $0.hasPrefix(id.split(separator: ".").first.map(String.init) ?? id) }.sorted()
            let hint = near.isEmpty ? "" : " — did you mean \(near.joined(separator: ", "))?"
            throw CommandError(.unknownCommand, "Unknown command '\(id)'\(hint)")
        }
        var raw = raw
        if ProjectTarget.accepts(id) {
            // The headless engine holds one project: `project` must name it (the app strips it before its tab runs).
            let (target, rest) = try ProjectTarget.split(raw)
            if let target {
                guard context.project != nil, ProjectTarget.matches(target, tabID: ProjectTarget.headlessTabID, path: context.projectURL) else {
                    let open = context.project.map { "\(ProjectTarget.headlessTabID) (\(context.projectURL?.path ?? $0.name))" } ?? "none"
                    throw CommandError(.notFound, "\(id): no open project matches project '\(target)' — this engine holds one project (open: \(open)); project.list shows it")
                }
            }
            raw = rest
        }
        let params = try CommandParams(validating: raw, for: command.descriptor)
        var ctx = context
        let before = ctx.project
        let result = try command.run(params, &ctx)

        switch command.kind {
        case .edit:
            if let before, let after = ctx.project, before != after {
                ctx.history.record(.init(command: id, params: raw, before: before, after: after))
                ctx.dirty = true
            }
        case .query, .session, .history:
            break
        }
        if let change = ctx.kitChange {
            // A brand kit written (create, update, logo, font, import, delete): one step that puts the folder back.
            ctx.kitChange = nil
            ctx.history.record(.init(command: id, params: raw, before: ctx.project, after: ctx.project, kit: change))
        }
        context = ctx
        return result
    }
}

/// The standard command set.
public enum Commands {
    public static let all: [any Command.Type] = [
        ProjectNew.self, ProjectFormat.self, ProjectOpen.self, ProjectSave.self, ProjectClose.self, ProjectState.self, ProjectList.self,
        RecipeGet.self, MediaList.self, TextRead.self, MediaImport.self,
        TrackAdd.self, TrackSet.self, TrackDelete.self,
        TimelinePlace.self, TimelineCut.self, TimelineTrim.self, TimelineMove.self, TimelineDelete.self, TimelineLink.self, TimelineDuplicate.self, ClipSet.self,
        HistoryUndo.self, HistoryRedo.self,
        EnginesStatus.self, MediaExtractAudio.self, MediaMeasureLoudness.self,
        TranscriptRun.self, TranscriptGet.self, TranscriptEvaluate.self,
        AudioClean.self, FacesTrack.self,
        ScriptSet.self, ScriptFromTranscriptCommand.self, TakesList.self, TakesSelect.self, TakesCompare.self, EditAutoCut.self,
        ScriptPrepare.self, TakesLive.self, TeleprompterSimulate.self,
        EditPunchIns.self, TranscriptTimeline.self, TranscriptDeleteWords.self, TranscriptEditText.self,
        CaptionsGenerate.self, CaptionsGet.self, CaptionsSetKeywords.self, CaptionsSetStyle.self, ExportSRT.self,
        ExportRender.self, FrameRender.self, FrameContactSheet.self, ExportMLT.self,
        MediaProbe.self, MediaCompare.self, CaptionsCheckTiming.self, MediaCheckSync.self, CaptionsCheckFaces.self, FacesCheckFraming.self,
        UIScreenshot.self, PreviewFrame.self,
        OverlayAdd.self, ClipKeyframe.self, LayoutSpeaker.self, HandsTrack.self, ClipFollow.self, StatusAdd.self, MetersAdd.self, TitleAdd.self, EffectAdd.self, EffectRemove.self, TransitionAdd.self, TransitionRemove.self,
        BrandkitList.self, BrandkitApply.self, GraphicsCheckLayout.self,
        BrandkitCreate.self, BrandkitUpdate.self, BrandkitSetLogo.self, BrandkitSetFont.self, BrandkitExport.self, BrandkitImport.self,
        BrandkitDelete.self, BrandkitCheck.self, BrandkitPreview.self, LogoAdd.self,
        AudioAddMusic.self, AudioDuck.self, SFXLibrary.self, SFXAdd.self, SFXOnCuts.self, AudioCheckDucking.self, SFXCheckOnsets.self,
        TimelineMapTimes.self, MediaCheckOverlay.self, GraphicsBlenderTitle.self, GraphicsBlender3D.self, GraphicsHyperframes.self,
        GenerateProviders.self, GenerateCheck.self, GenerateEstimate.self, GenerateApprove.self, GenerateRun.self, GenerateUpscale.self,
        GenerateStatus.self, GenerateList.self, MatteTrackCommand.self, GraphicsCheckBehindSubject.self,
        RecordingImport.self, LayoutPresets.self, LayoutApply.self, EditAutoZoom.self, RecordingSynthesize.self, RecordingCheck.self, CursorStyleCommand.self, KeysOverlay.self,
        CaptionsPlace.self, ClipPlace.self, FrameElements.self, MediaCheckPlacement.self, VoiceList.self,
        ProfileGet.self, ProfileCreate.self, ProfileSwitch.self, ProfileAdopt.self, ProfileDelete.self,
        VoiceEnrollScript.self, VoiceEnrollAdd.self, VoiceEnrollStatus.self, VoiceEnrollTrain.self, VoiceSay.self, VoicePreview.self, VoiceLexiconCommand.self,
    ] + effects + rules

    /// Editing rules (#31).
    static let rules: [any Command.Type] = [
        RulesList.self, RulesGet.self, RulesSet.self, RulesReset.self, RulesAddKind.self, RulesRemoveKind.self, ProjectSetKind.self,
        RulesCheck.self, RulesFix.self, CaptionsClear.self,
    ]

    /// Effects for users (issue #16).
    static let effects: [any Command.Type] = [
        LookList.self, LookApply.self, AdjustSet.self, ClipSpeed.self, StickerAdd.self, CalloutAdd.self, ProgressAdd.self, LogoAnimate.self,
        EffectsCatalogList.self, EffectsPreview.self, StyleApply.self, EditBeatSync.self, EffectsCheck.self, MotionAdd.self, MediaSynthesize.self,
    ]
}
