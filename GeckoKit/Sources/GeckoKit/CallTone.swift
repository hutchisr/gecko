import Foundation

/// The sounds of a ringing call, synthesised so the app ships no audio files.
enum CallTone {
    /// What the person being called hears.
    case incoming
    /// Ringback: what the caller hears while the other side rings.
    case outgoing

    /// Sine tones played one after another; no frequencies is silence.
    private var notes: [(hz: [Double], seconds: Double)] {
        switch self {
        case .incoming:
            // A rising three-note figure, twice, then a pause.
            let figure: [(hz: [Double], seconds: Double)] =
                [([880], 0.15), ([1108.73], 0.15), ([1318.51], 0.4), ([], 0.2)]
            return figure + figure + [([], 1.2)]
        case .outgoing:
            // The North American ringback cadence.
            return [([440, 480], 2), ([], 4)]
        }
    }

    /// One pass of the tone as a 16-bit mono WAV file, made to be looped.
    var wav: Data {
        let rate = 16_000
        var samples: [Int16] = []
        samples.reserveCapacity(Int(notes.reduce(0) { $0 + $1.seconds } * Double(rate)))
        for note in notes {
            for i in 0..<Int(note.seconds * Double(rate)) {
                let t = Double(i) / Double(rate)
                // 10 ms ramps keep the edges of a note from clicking.
                let envelope = min(1, t / 0.01, (note.seconds - t) / 0.01)
                let sum = note.hz.reduce(0) { $0 + sin(2 * .pi * $1 * t) }
                // 0.3 per sine leaves headroom for two at once.
                samples.append(Int16(sum * envelope * 0.3 * Double(Int16.max)))
            }
        }

        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        put(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16))             // format chunk size
        put(UInt16(1))              // PCM
        put(UInt16(1))              // mono
        put(UInt32(rate))
        put(UInt32(rate * 2))       // bytes per second
        put(UInt16(2))              // bytes per frame
        put(UInt16(16))             // bits per sample
        data.append(contentsOf: "data".utf8)
        put(UInt32(byteCount))
        samples.forEach(put)
        return data
    }
}
