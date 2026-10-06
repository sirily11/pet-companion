import Foundation
import simd

/// Evaluates imported motion signals for the three distal joints; the hip stays fixed.
enum CatTailMotion {
    static func targets(motion: CatPose.TailMotion, time: Float, moodElapsed: Float, manualSwing: Float) -> [SIMD3<Float>] {
        (0..<3).map { index in
            let yaw = evaluate(motion.yaw, index: index, time: time, elapsed: moodElapsed) + manualSwing * 0.40
            let pitch = evaluate(motion.pitch, index: index, time: time, elapsed: moodElapsed)
            let curl = evaluate(motion.curl, index: index, time: time, elapsed: moodElapsed)
            return SIMD3(pitch, min(0.45, max(-0.45, yaw)), curl)
        }
    }

    private static func evaluate(_ signals: [CatPose.MotionSignal], index: Int, time: Float, elapsed: Float) -> Float {
        let tip = [Float(0.10), 0.40, 1][index]
        return signals.reduce(0) { total, signal in
            let phase = time * signal.frequency - (signal.lag ? Float(index) * 0.48 : 0)
            let value: Float
            switch signal.kind {
            case .sine: value = sin(phase)
            case .noise: value = noise(phase, seed: signal.seed)
            case .flick: value = flick(time: time, period: signal.period, seed: signal.seed)
            case .constant: value = 1
            }
            return total + signal.amplitude * value * (signal.tipOffset + signal.tipScale * tip) * exp(-max(0, elapsed) * signal.decay)
        }
    }

    private static func hash(_ index: Int, seed: Int) -> Float {
        let value = sin(Double(index) * 127.1 + Double(seed) * 311.7) * 43758.5453
        return Float(value - floor(value))
    }
    private static func noise(_ time: Float, seed: Int) -> Float {
        let index = Int(floor(time))
        let fraction = time - Float(index)
        let blend = fraction * fraction * (3 - 2 * fraction)
        let a = hash(index, seed: seed), b = hash(index + 1, seed: seed)
        return (a + (b - a) * blend) * 2 - 1
    }
    private static func flick(time: Float, period: Float, seed: Int) -> Float {
        let cycle = Int(floor(time / period))
        let phase = time - Float(cycle) * period
        let start = 1.1 + hash(cycle, seed: seed) * (period - 2.5)
        let elapsed = phase - start
        guard elapsed > 0, elapsed < 1.1 else { return 0 }
        let envelope = pow(sin(elapsed / 1.1 * .pi), 2)
        return sin(elapsed * 13) * envelope
    }
}
