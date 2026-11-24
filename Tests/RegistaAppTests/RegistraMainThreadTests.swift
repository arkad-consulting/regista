import AppKit
import Combine
import CoreVideo
import IOSurface
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #162: what Registra does on the main thread while the preview is live. Each screen frame (and the face's place for
// the format guide) used to be published on the recorder itself: thirty to sixty times a second every view of the
// recorder was drawn again — the Registra screen and the menu bar's commands — and each drawing asked the capture
// system for its default camera and microphone (AVCaptureDevice.default, which waits while a capture session starts).
// They now have their own object, observed by the picture and the guide alone, and the default devices are read when
// the devices are listed. The capture stand-in can be made slow (`defaultDelay`): the main thread must not meet it.

@MainActor private func surface() throws -> IOSurface {
    try #require(IOSurface(properties: [.width: 64, .height: 36, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]))
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RegistraMainThreadTests {
    @Test func screenFramesRedrawOnlyThePictureAndNeverWaitOnTheCaptureSystem() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.capture.screen = true
        app.recorder.sources.apply(.screenFace)
        app.recorder.sources.videoFormat = "9:16"
        app.hostEditor(Navigation(activity: .record, rightTab: .claude))
        await app.settle()
        #expect(app.recorder.isReady, "Registra did not prepare the recorder")
        // From now on the capture system answers in 0.2 s, as it can while a session starts.
        app.capture.defaultDelay = 0.2
        let asked = app.capture.log.filter { $0.hasPrefix("defaultDevice") }.count
        var redraws = 0
        let sink = app.recorder.objectWillChange.sink { redraws += 1 }
        let frames = [try surface(), try surface()]
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<30 {
            app.recorder.previewFeed.surface = frames[i % 2]
            // The face's place for the format guide, as the camera's face detection gives it (four a second).
            if i % 8 == 0 { app.recorder.previewFeed.faceX = Double(i) / 30 }
            app.rig.pump(0.01)
        }
        await app.settle()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        sink.cancel()
        #expect(redraws == 0, "30 screen frames and 4 face places changed the recorder \(redraws) times (each one redraws the screen and the menus)")
        #expect(app.capture.log.filter { $0.hasPrefix("defaultDevice") }.count == asked,
                "drawing asked the capture system for its default devices: \(app.capture.log.suffix(6))")
        // 30 frames and a settle with nothing waiting: well under one slow answer per frame (30 × 0.2 s).
        #expect(seconds < 2, "30 frames took \(String(format: "%.2f", seconds)) s on the main thread")
        #expect(app.recorder.screenFrame === frames[1], "the preview does not hold the last frame")
        // The Registra screen still draws (a click on a format after the frames).
        app.capture.defaultDelay = 0
        let nine = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.name == "4:5" }, "no format bar")
        app.rig.click(nine.centre)
        await app.settle()
        #expect(app.recorder.sources.videoFormat == "4:5")
        app.recorder.sources.videoFormat = nil
        app.recorder.sources.apply(.face)
    }
}
}
