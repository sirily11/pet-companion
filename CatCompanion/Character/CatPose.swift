import Foundation
import SceneKit

/// Pose definitions belong to the imported companion, including every motion coefficient.
struct CatPose: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let expression: String
    let criteria: String
    let jointAngles: [String: [Float]]
    let jointWaves: [JointWave]
    let breathingAmplitude: Float
    let breathingFrequency: Float
    let bounceAmplitude: Float
    let bounceFrequency: Float
    let tail: TailMotion

    struct JointWave: Codable, Equatable {
        let joint: String
        let axis: Int
        let amplitude: Float
        let frequency: Float
    }
    struct TailMotion: Codable, Equatable {
        let yaw: [MotionSignal]
        let pitch: [MotionSignal]
        let curl: [MotionSignal]
    }
    struct MotionSignal: Codable, Equatable {
        enum Kind: String, Codable { case sine, noise, flick, constant }
        let kind: Kind
        let amplitude: Float
        let frequency: Float
        let seed: Int
        let period: Float
        let tipScale: Float
        let tipOffset: Float
        let lag: Bool
        let decay: Float
    }
}

struct RigJoint: Identifiable {
    let name: String
    let parent: String?
    let rest: SIMD3<Float>
    var id: String { name }

    // All rest coordinates are meters in the original Y-up USDZ coordinate space.
    static let skeleton: [RigJoint] = [
        .init(name: "root", parent: nil, rest: .zero),
        .init(name: "body", parent: "root", rest: SIMD3(0, 0.045, 0)),
        .init(name: "neck", parent: "body", rest: SIMD3(0, 0.092, 0)),
        .init(name: "head", parent: "neck", rest: SIMD3(0, 0.145, 0.004)),
        .init(name: "leftEar", parent: "head", rest: SIMD3(-0.065, 0.20, 0)),
        .init(name: "rightEar", parent: "head", rest: SIMD3(0.048, 0.219, 0)),
        .init(name: "leftArm", parent: "body", rest: SIMD3(-0.050, 0.071, 0.020)),
        .init(name: "leftPaw", parent: "leftArm", rest: SIMD3(-0.018, 0.021, 0.041)),
        .init(name: "rightArm", parent: "body", rest: SIMD3(0.060, 0.073, 0.022)),
        .init(name: "rightPaw", parent: "rightArm", rest: SIMD3(0.051, 0.021, 0.044)),
        .init(name: "tail", parent: "body", rest: CatTailGeometry.center(at: 0)),
        .init(name: "tailMiddle", parent: "tail", rest: CatTailGeometry.center(at: 1 / 3)),
        .init(name: "tailCurl", parent: "tailMiddle", rest: CatTailGeometry.center(at: 2 / 3)),
        .init(name: "tailTip", parent: "tailCurl", rest: CatTailGeometry.center(at: 1)),
        .init(name: "jaw", parent: "head", rest: SIMD3(0.009, 0.123, 0.079))
    ]
    static let meshJoints = [
        "Body": "body", "Head": "head", "LeftEar": "leftEar", "RightEar": "rightEar",
        "LeftForeleg": "leftArm", "RightForeleg": "rightArm", "LeftPaw": "leftPaw",
        "RightPaw": "rightPaw", "Tail": "tail"
    ]
}
