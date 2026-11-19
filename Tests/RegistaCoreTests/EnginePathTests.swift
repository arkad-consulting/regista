import Foundation
import Testing
@testable import RegistaCore

// #115: the engines Regista starts with uv (WhisperX, VoxCPM2 and its training) and HyperFrames find Regista's own ffmpeg
// first on their PATH (a Mac without Homebrew has no other), and a uv engine never downloads a Python at run time.

@Test func theEnginesRunWithRegistasFFmpegFirstOnThePath() throws {
    var config = EngineConfig()
    config.ffmpeg = "/Applications/Regista.app/Contents/Helpers/ffmpeg"
    let folder = "/Applications/Regista.app/Contents/Helpers"
    #expect(config.enginePath().hasPrefix(folder + ":"))
    #expect(config.enginePath(first: ["/node/bin"]).hasPrefix("/node/bin:" + folder + ":"), "HyperFrames: its Node.js, then the app's ffmpeg")
    #expect(config.enginePath().hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"))
    #expect(config.uvEnvironment["UV_PYTHON_DOWNLOADS"] == "never")
    // VoxCPM2 and its training.
    let vox = VoxCPMProvider.environment(config)
    #expect(vox["PATH"]?.hasPrefix(folder + ":") == true && vox["UV_PYTHON_DOWNLOADS"] == "never" && vox["HF_HUB_OFFLINE"] == "1", "\(vox)")
    // WhisperX (since #109).
    #expect(WhisperXTranscriber(config: config).environment["PATH"]?.hasPrefix(folder + ":") == true)
}
