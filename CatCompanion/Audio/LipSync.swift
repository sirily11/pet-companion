import Foundation

struct LipFrame: Equatable {
    var open: Float
    var round: Float
    var closed: Float
    static let silence = LipFrame(open: 0, round: 0, closed: 1)

    func blended(toward other: LipFrame, amount: Float) -> LipFrame {
        LipFrame(open: open + (other.open - open) * amount,
                 round: round + (other.round - round) * amount,
                 closed: closed + (other.closed - closed) * amount)
    }
}

/// Audio-driven viseme approximation: RMS opens the jaw; low zero-crossing
/// energy rounds the mouth. Analysis runs on rendered audio, not network arrival.
enum LipSyncAnalyzer {
    static func analyze(_ samples: [Float]) -> LipFrame {
        guard !samples.isEmpty else { return .silence }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.006 else { return .silence }
        let energy = min(1, max(0, (rms - 0.006) * 9))
        var crossings = 0
        for i in 1..<samples.count where (samples[i] >= 0) != (samples[i - 1] >= 0) { crossings += 1 }
        let ratio = Float(crossings) / Float(samples.count)
        let round = min(0.65, max(0, (0.14 - ratio) * 5)) * energy
        return LipFrame(open: energy, round: round, closed: 1 - energy)
    }
}

struct LipEnvelopeFrame {
    let offset: TimeInterval
    let frame: LipFrame
}

/// Short windows preserve syllables even when AVAudioEngine delivers a large
/// render buffer. Offsets are scheduled against that buffer's audio host time.
enum PlaybackLipEnvelope {
    static func frames(samples: [Float], sampleRate: Double) -> [LipEnvelopeFrame] {
        guard sampleRate > 0 else { return [] }
        let window = max(1, Int(sampleRate * 0.01))
        return stride(from: 0, to: samples.count, by: window).map { start in
            let end = min(start + window, samples.count)
            return LipEnvelopeFrame(offset: Double(start) / sampleRate,
                frame: LipSyncAnalyzer.analyze(Array(samples[start..<end])))
        }
    }
}

enum PCM16 {
    static func decode(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
}
