import AVFAudio
import XCTest
@testable import GeckoKit

final class CallToneTests: XCTestCase {
    /// The player the app loops them with has to accept both tones, and each
    /// has to last its whole cadence (the trailing pause is part of the loop).
    func testTonesAreAudiblePlayableLoops() throws {
        for (tone, seconds) in [(CallTone.incoming, 3.0), (.outgoing, 6.0)] {
            let wav = tone.wav
            XCTAssertEqual(try AVAudioPlayer(data: wav).duration, seconds, accuracy: 0.001)

            let samples = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, Int(Int16.max) / 5, "\(tone) is silent")
            XCTAssertLessThan(peak, Int(Int16.max), "\(tone) clips")
        }
    }
}
