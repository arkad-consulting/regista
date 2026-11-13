import Foundation
import Testing
@testable import RegistaCore

// MARK: Time

@Test func commonFrameAndSampleRatesAreWholeTicks() {
    for rate in [Rational(24000, 1001), Rational(24), Rational(25), Rational(30000, 1001), Rational(30),
                 Rational(50), Rational(60000, 1001), Rational(60), Rational(120)] {
        #expect(MediaTime.ticksPerSecond * rate.den % rate.num == 0, "\(rate)")
    }
    for hz: Int64 in [44100, 48000, 96000] { #expect(MediaTime.ticksPerSecond % hz == 0) }
}

@Test func timeConversionsAreExact() {
    #expect(MediaTime(seconds: 10).ticks == 10 * MediaTime.ticksPerSecond)
    #expect(MediaTime(value: 56822, timescale: 600).displaySeconds == 94.703333)
    // 30 000 frames at 29.97 add up without drift.
    let frame = MediaTime.frameDuration(at: Rational(30000, 1001))
    #expect(MediaTime(ticks: frame.ticks * 30000).seconds == 1001)
    #expect(MediaTime(seconds: 10.01).snapped(to: Rational(30)) == MediaTime(seconds: 10))
    #expect(MediaTime(seconds: 10.02).snapped(to: Rational(30)) == MediaTime(ticks: MediaTime.frameDuration(at: Rational(30)).ticks * 301))
}

@Test func rationalParsing() {
    #expect(Rational(parsing: "30000/1001") == Rational(30000, 1001))
    #expect(Rational(parsing: "60/2") == Rational(30))
    #expect(Rational(parsing: "0/0") == nil)
    #expect(Rational(parsing: "25")?.doubleValue == 25)
}

@Test func mediaTimeEncodesAsTicks() throws {
    let data = try JSONEncoder().encode(MediaTime(seconds: 1))
    #expect(String(decoding: data, as: UTF8.self) == "705600000")
    #expect(try JSONDecoder().decode(MediaTime.self, from: data) == MediaTime(seconds: 1))
}

// MARK: JSON

@Test func jsonValueRoundTripAndPaths() throws {
    let v = try JSONValue.parse(#"{"a":[1,2.5,{"b":true}],"s":"x","n":null}"#)
    #expect(v.value(at: "a.2.b") == .bool(true))
    #expect(v.value(at: "a.1") == .number(2.5))
    #expect(v.value(at: "a.9") == nil)
    #expect(v["n"] == .null)
    #expect(v.text() == #"{"a":[1,2.5,{"b":true}],"n":null,"s":"x"}"#)
    #expect(try JSONValue.parse("1") == .number(1))   // not a Bool
}

// MARK: ffprobe

/// Trimmed ffprobe output of the 2026-10-26 test take (iPhone, portrait via display matrix).
let ffprobeFixture = #"""
{"streams":[
 {"index":0,"codec_name":"h264","codec_type":"video","width":1920,"height":1080,"r_frame_rate":"30/1",
  "avg_frame_rate":"568200/18941","time_base":"1/600","duration_ts":56822,"duration":"94.703333",
  "side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]},
 {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"time_base":"1/48000",
  "duration_ts":4545760,"duration":"94.703333"}],
 "format":{"duration":"94.703333"}}
"""#

@Test func parsesFFProbeOutput() throws {
    let m = try FFProbe.parse(Data(ffprobeFixture.utf8))
    #expect(m.video?.width == 1080)
    #expect(m.video?.height == 1920)
    #expect(m.video?.rotation == -90)
    #expect(m.video?.frameRate == Rational(30))
    #expect(m.audio?.sampleRate == 48000)
    #expect(m.audio?.channels == 2)
    #expect(m.duration == MediaTime(value: 56822, timescale: 600))
}

@Test func ffprobeWithoutStreamsFails() {
    #expect(throws: CommandError.self) { try FFProbe.parse(Data(#"{"streams":[],"format":{}}"#.utf8)) }
}
