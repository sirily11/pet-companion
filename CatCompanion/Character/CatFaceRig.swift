import AppKit
import SceneKit
import simd

/// Facial features follow the curved head surface. No illustrated face card or
/// second head is used: eyelids, brows, nose, whiskers, and mouth are 3D geometry.
@MainActor
final class CatFaceRig {
    let root = SCNNode()
    private(set) var expression = "bright"
    private let surface: HeadSurface
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private let leftBrow = SCNNode()
    private let rightBrow = SCNNode()
    private let dark = SCNMaterial()
    private let brown = SCNMaterial()
    private var openEyes: [(node: SCNNode, scale: SIMD3<Float>)] = []

    init(surface: HeadSurface) {
        self.surface = surface
        root.name = "FaceRig"
        dark.diffuse.contents = NSColor(calibratedRed: 0.12, green: 0.055, blue: 0.04, alpha: 1)
        dark.lightingModel = .lambert
        brown.diffuse.contents = NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.15, alpha: 1)
        brown.lightingModel = .lambert
        leftEye.name = "LeftEye"; rightEye.name = "RightEye"
        leftBrow.name = "LeftBrow"; rightBrow.name = "RightBrow"
        [leftEye, rightEye, leftBrow, rightBrow].forEach(root.addChildNode)
        makeNose()
        makeWhiskers()
        configureExpression("bright")
    }

    func setExpression(_ value: String) {
        guard value != expression else { return }
        expression = value
        configureExpression(value)
    }

    private func configureExpression(_ value: String) {
        openEyes = []
        for eye in [leftEye, rightEye] { eye.childNodes.forEach { $0.removeFromParentNode() }; eye.geometry = nil }
        let centers = [SIMD2<Float>(-0.039, 0.151), SIMD2<Float>(0.049, 0.156)]
        for (index, eye) in [leftEye, rightEye].enumerated() {
            let center = centers[index]
            if value == "bright" || value == "surprised" || (value == "wink" && index == 1) {
                let shape = SCNSphere(radius: 1)
                shape.segmentCount = 32
                eye.geometry = shape
                eye.geometry?.materials = [dark]
                eye.simdPosition = SIMD3(center.x, center.y - 0.001, surface.depth(x: center.x, y: center.y) + 0.0018)
                eye.simdScale = SIMD3(0.012, value == "surprised" ? 0.017 : 0.0145, 0.004)
                openEyes.append((eye, eye.simdScale))
                // Warm amber at the bottom, a deep pupil, and two catchlights
                // give the small face rounded, glossy eyes rather than flat dots.
                addEyeDetail(to: eye, name: "Iris", color: NSColor(calibratedRed: 0.57, green: 0.31, blue: 0.14, alpha: 1),
                             position: SIMD3(0, -0.18, 0.80), scale: SIMD3(0.70, 0.68, 0.22))
                addEyeDetail(to: eye, name: "Pupil", color: NSColor(calibratedRed: 0.10, green: 0.045, blue: 0.03, alpha: 1),
                             position: SIMD3(0, 0.08, 0.94), scale: SIMD3(0.48, 0.60, 0.12))
                addEyeDetail(to: eye, name: "EyeHighlight", color: .white,
                             position: SIMD3(-0.28, 0.31, 1.04), scale: SIMD3(0.25, 0.21, 0.13))
                addEyeDetail(to: eye, name: "EyeHighlightSmall", color: NSColor(calibratedRed: 1, green: 0.94, blue: 0.84, alpha: 1),
                             position: SIMD3(0.31, -0.30, 1.03), scale: SIMD3(0.11, 0.10, 0.08))
            } else {
                eye.simdPosition = .zero; eye.simdScale = SIMD3(repeating: 1)
                let rise: Float = value == "sleepy" ? -0.0012 : 0.0055
                let points = (0...32).map { i -> SIMD2<Float> in
                    let t = Float(i) / 32 * 2 - 1
                    return SIMD2(center.x + 0.014 * t, center.y + rise * (1 - t * t))
                }
                eye.geometry = tube(points: points, radius: 0.0019, material: dark, taper: true)
            }
        }
        for (index, brow) in [leftBrow, rightBrow].enumerated() {
            let center = centers[index]
            let y = center.y + (value == "surprised" ? 0.025 : 0.020)
            let points = (0...20).map { i -> SIMD2<Float> in
                let t = Float(i) / 20 * 2 - 1
                return SIMD2(center.x + 0.0055 * t, y + 0.0028 * (1 - t * t))
            }
            brow.geometry = tube(points: points, radius: 0.0012, material: brown, taper: true)
        }
    }

    func animate(time: Float, gaze: SIMD2<Float> = .zero) {
        // A quick close and slower reopen every few seconds; the two cycles
        // occasionally overlap for a double blink without an identical loop.
        func blink(period: Float, offset: Float) -> Float {
            let phase = (time + offset).truncatingRemainder(dividingBy: period)
            guard phase < 0.24 else { return 0 }
            return sin(phase / 0.24 * .pi)
        }
        let closure = max(blink(period: 5.7, offset: 1.2), blink(period: 9.4, offset: 3.6))
        for (eye, scale) in openEyes {
            eye.simdScale = SIMD3(scale.x, scale.y * (1 - closure * 0.94), scale.z)
            eye.childNode(withName: "Iris", recursively: false)?.simdPosition = SIMD3(gaze.x * 0.12, -0.18 + gaze.y * 0.10, 0.80)
            eye.childNode(withName: "Pupil", recursively: false)?.simdPosition = SIMD3(gaze.x * 0.16, 0.08 + gaze.y * 0.12, 0.94)
        }
    }

    private func addEyeDetail(to eye: SCNNode, name: String, color: NSColor, position: SIMD3<Float>, scale: SIMD3<Float>) {
        let detail = SCNNode(geometry: SCNSphere(radius: 1))
        detail.name = name
        detail.geometry?.firstMaterial?.diffuse.contents = color
        detail.geometry?.firstMaterial?.lightingModel = .constant
        detail.simdPosition = position
        detail.simdScale = scale
        eye.addChildNode(detail)
    }

    private func makeNose() {
        // Rounded, downward-pointing nose with a genuine curved front surface.
        let nose = SCNNode()
        nose.name = "Nose"
        let center = SIMD3<Float>(0.009, 0.1365, surface.depth(x: 0.009, y: 0.1365) + 0.0005)
        var points: [SCNVector3] = [SCNVector3(center + SIMD3(0, 0, 0.004))]
        let count = 48
        for i in 0..<count {
            let angle = Float(i) / Float(count) * 2 * .pi
            let x = 0.0047 * cos(angle)
            let y = 0.0030 * sin(angle) + 0.0008 * cos(angle) * cos(angle)
            points.append(SCNVector3(center + SIMD3(x, y, 0)))
        }
        points.append(SCNVector3(center + SIMD3(0, 0, -0.002)))
        let back = Int32(points.count - 1)
        var indices: [Int32] = []
        for i in 0..<count {
            let a = Int32(i + 1), b = Int32((i + 1) % count + 1)
            indices += [0, a, b, back, b, a]
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.98, green: 0.47, blue: 0.51, alpha: 1)
        material.lightingModel = .lambert
        geometry.materials = [material]
        nose.geometry = geometry
        root.addChildNode(nose)
        let glint = SCNNode(geometry: SCNSphere(radius: 1))
        glint.name = "NoseHighlight"
        glint.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 1, green: 0.80, blue: 0.80, alpha: 1)
        glint.geometry?.firstMaterial?.lightingModel = .constant
        glint.simdScale = SIMD3(0.0015, 0.00065, 0.0003)
        glint.simdPosition = center + SIMD3(-0.001, 0.0015, 0.0034)
        root.addChildNode(glint)
    }

    private func makeWhiskers() {
        for side: Float in [-1, 1] {
            for row in 0..<2 {
                let centerX: Float = side < 0 ? -0.045 : 0.055
                let y: Float = 0.126 - Float(row) * 0.009
                let points = (0...24).map { i -> SIMD2<Float> in
                    let t = Float(i) / 24 * 2 - 1
                    return SIMD2(centerX + 0.0115 * t, y + 0.002 * (1 - t * t) + side * 0.0015 * t)
                }
                let node = SCNNode(geometry: tube(points: points, radius: 0.0009, material: brown, taper: true))
                node.name = side < 0 ? "LeftWhisker-\(row)" : "RightWhisker-\(row)"
                root.addChildNode(node)
            }
        }
    }

    private func tube(points: [SIMD2<Float>], radius: Float, material: SCNMaterial, taper: Bool) -> SCNGeometry {
        let centers = points.map { SIMD3($0.x, $0.y, surface.depth(x: $0.x, y: $0.y) + 0.0008) }
        let sides = 10
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        for i in centers.indices {
            let tangent = simd_normalize(centers[min(centers.count - 1, i + 1)] - centers[max(0, i - 1)])
            let outward = simd_normalize(SIMD3(tangent.y, -tangent.x, 0))
            let t = Float(i) / Float(centers.count - 1)
            let size = radius * (taper ? 0.2 + 0.8 * pow(max(0, sin(t * .pi)), 0.35) : 1)
            for side in 0..<sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let normal = outward * cos(angle) + SIMD3<Float>(0, 0, sin(angle))
                vertices.append(SCNVector3(centers[i] + normal * size)); normals.append(SCNVector3(normal))
            }
        }
        var indices: [Int32] = []
        for i in 0..<(centers.count - 1) {
            for side in 0..<sides {
                let a = Int32(i * sides + side), b = a + Int32(sides)
                let c = Int32(i * sides + (side + 1) % sides), d = c + Int32(sides)
                indices += [a, b, c, c, b, d]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return geometry
    }
}
