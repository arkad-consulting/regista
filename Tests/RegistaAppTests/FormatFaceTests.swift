import AppKit
@testable import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The format everywhere, and the face always in frame (#150, #153): a take of another format joins a project, or a take
// becomes a project of a format chosen on Registra; its clip is framed on the face, never cut around the centre. The
// takes are synthetic 1920×1080 movies; the faces come from a stand-in tracker (a face right of centre, where a person
// sitting beside the camera usually is), so no test depends on what Vision sees in a drawing.

/// A face right of centre in a 1920×1080 take, for 6 s: what faces.track gets instead of Vision.
struct RightOfCentreFaces: FaceTracker {
    static let width = 1920, height = 1080

    func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack {
        let frames = (0..<180).map { i -> FaceTrack.Frame in
            let box = [1330 + 20 * sin(Double(i) / 25), 330 + 6 * sin(Double(i) / 17), 230, 290.0]
            return FaceTrack.Frame(t: Double(i) / 30, raw: box, smooth: box)
        }
        return FaceTrack(video: video.path, engine: "stand-in", width: Self.width, height: Self.height, fps: 30,
                         minCutoff: options.minCutoff, beta: options.beta, cuts: [], frames: frames)
    }
}

/// A 6 s 1920×1080 camera take (a synthetic talking head, no sound), in a scratch folder.
func landscapeTake(_ name: String = "Registrazione 2026-11-22 \(UUID().uuidString.prefix(8)).mov") throws -> URL {
    let dir = rigTempDir("landscape-take")
    var head = SyntheticTalkingHead(frames: 180, output: dir.appendingPathComponent(name), matteDirectory: dir.appendingPathComponent("matte"))
    head.width = RightOfCentreFaces.width
    head.height = RightOfCentreFaces.height
    try CGScreenSynthesizer().writeTalkingHead(head)
    return head.output
}

/// A workbench on the rig's services with the face stand-in, without the engine socket.
@MainActor func faceBench(_ tag: String) -> Workbench {
    _ = NSApplication.shared
    _ = rigFolder
    return Workbench(defaults: TestDefaults.make(tag), seedFolders: [], socketPath: nil, services: {
        var s = RigServices.make(in: rigTempDir("face-services"))
        s.faces = RightOfCentreFaces()
        return s
    })
}

@MainActor func untilFramed(_ seconds: Double = 30, _ done: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
}

/// The crop of the first clip of V1, and whether faces.checkFraming passes on the edit.
@MainActor func framing(_ tab: EditorStore) async throws -> (crop: [Double]?, pass: Bool) {
    let p = try #require(tab.project)
    let clip = try #require(p.tracks.first { $0.kind == .video }?.clips.first)
    let v = try #require(p.asset(clip.assetID)?.video)
    let check = try await tab.silent("faces.checkFraming", ["every": 1])
    return (clip.transform?.cropRect(sourceWidth: v.width, sourceHeight: v.height), check["pass"] == true)
}

@MainActor
@Test func aLandscapeTakeJoiningAVerticalProjectIsFramedOnTheFace() async throws {
    let b = faceBench("format-face-join")
    let tab = b.newTab()
    b.select(tab.tabID)
    try await tab.perform("project.new", ["name": "verticale", "directory": .string(rigTempDir("projects").path), "width": 1080, "height": 1920])
    tab.recordingChoice = .thisProject
    tab.importRecording(try landscapeTake(), session: false, newProject: false)
    try await untilFramed { b.notice != nil }
    let p = try #require(tab.project)
    #expect(p.settings.width == 1080 && p.settings.height == 1920, "the take changed the project's format")
    #expect(p.assets.first?.analysis?.faces != nil, "the faces were not tracked")
    let (crop, pass) = try await framing(tab)
    let c = try #require(crop, "the clip was not framed: it is cut around its centre")
    #expect(abs(c[0] / c[1] - 1080.0 / 1920) < 0.01 && c[2] > 900, "the crop is not on the face: \(c)")
    #expect(pass, "faces.checkFraming fails after the take joined")
    // The centred crop the take had before would cut the head (the bug).
    let centred = RenderJob.fit([1920, 1080, 0, 0], aspect: 1080.0 / 1920, within: (1920, 1080))
    let face = try RightOfCentreFaces().track(URL(fileURLWithPath: "/"), options: FaceTrackOptions()).frames[0].all
    #expect(!FaceFraming.cutHeads(face, crop: centred, frame: (1920, 1080), headroom: 0.02).isEmpty)
}
