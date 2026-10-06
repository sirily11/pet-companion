import Foundation
import simd

enum PetReaction: Equatable {
    case touch, tap, petting, longPress
    case swipe(SIMD2<Float>)

    var title: String {
        switch self {
        case .touch: "Gentle touch"
        case .tap: "Hello!"
        case .petting: "Enjoying the pets"
        case .longPress: "Cuddle time"
        case .swipe: "Feeling playful"
        }
    }

    var duration: Float {
        switch self {
        case .touch: 0.8
        case .tap: 1.4
        case .petting: 1.6
        case .longPress: 2.2
        case .swipe: 1.5
        }
    }

    var poseIDs: [String] {
        switch self {
        case .touch: []
        case .tap: ["happy", "excited"]
        case .petting, .longPress: ["cuddle", "happy"]
        case .swipe: ["playful", "wave", "excited"]
        }
    }

    var preferredExpression: String? {
        switch self {
        case .touch: nil
        case .tap, .petting, .longPress: "happy"
        case .swipe: "wink"
        }
    }

    var sustainsWhileHeld: Bool {
        switch self {
        case .touch, .petting, .longPress: true
        case .tap, .swipe: false
        }
    }
}

/// Classifies a contact independently of AppKit so a stroke cannot also become a tap.
struct PetContact {
    static let longPressDelay: TimeInterval = 0.55
    static let quickTouchDuration: TimeInterval = 0.25
    static let movementSlop: CGFloat = 10
    private let origin: CGPoint
    private let beganAt: TimeInterval
    private var previous: CGPoint
    private var previousTime: TimeInterval
    private var travel: CGFloat = 0
    private(set) var recognizedHold = false
    private(set) var recognizedSwipe = false

    init(point: CGPoint, time: TimeInterval) {
        origin = point; previous = point
        beganAt = time; previousTime = time
    }

    mutating func move(to point: CGPoint, at time: TimeInterval) -> PetReaction? {
        let step = hypot(point.x - previous.x, point.y - previous.y)
        let interval = max(0.001, time - previousTime)
        travel += step
        previous = point; previousTime = time
        guard !recognizedSwipe else { return nil }
        let delta = SIMD2<Float>(Float(point.x - origin.x), Float(point.y - origin.y))
        let distance = simd_length(delta)
        if !recognizedHold, distance >= 36, time - beganAt <= 0.45, step / interval >= 180 {
            recognizedSwipe = true
            return .swipe(delta / distance)
        }
        return travel > Self.movementSlop ? .petting : nil
    }

    mutating func hold(at time: TimeInterval) -> PetReaction? {
        guard !recognizedHold, !recognizedSwipe, travel <= Self.movementSlop,
              time - beganAt >= Self.longPressDelay else { return nil }
        recognizedHold = true
        return .longPress
    }

    mutating func end(at point: CGPoint, time: TimeInterval) -> PetReaction? {
        if let reaction = move(to: point, at: time), case .swipe = reaction { return reaction }
        guard !recognizedSwipe else { return nil }
        if travel > Self.movementSlop { return .petting }
        guard !recognizedHold else { return nil }
        if let reaction = hold(at: time) { return reaction }
        return time - beganAt <= Self.quickTouchDuration ? .tap : .touch
    }
}
