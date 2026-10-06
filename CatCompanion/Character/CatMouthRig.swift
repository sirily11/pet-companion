import AppKit
import SceneKit
import simd

/// A separate, fully three-dimensional lip rim, oral surface, tongue, and
/// philtrum. All vertices follow the cat's curved face and its head bone.
@MainActor
final class CatMouthRig {
    let root = SCNNode()
    let lips = SCNNode()
    let cavity = SCNNode()
    let tongue = SCNNode()
    private let surface: HeadSurface
    private let segments = 80
    private let tubeSides = 8
    private let centerX: Float = 0.009
    private let topY: Float = 0.128
    private(set) var opening: Float = 0
    private var lastFrame: LipFrame?
    private let lipMaterial = SCNMaterial()
    private let cavityMaterial = SCNMaterial()

    init(surface: HeadSurface) {
        self.surface = surface
        root.name = "MouthRig"
        lips.name = "Lips"; cavity.name = "MouthInterior"; tongue.name = "Tongue"
        lipMaterial.diffuse.contents = NSColor(calibratedRed: 0.34, green: 0.12, blue: 0.075, alpha: 1)
        lipMaterial.lightingModel = .lambert
        cavityMaterial.diffuse.contents = NSColor(calibratedRed: 0.22, green: 0.045, blue: 0.035, alpha: 1)
        cavityMaterial.lightingModel = .constant
        cavityMaterial.isDoubleSided = true
        let tongueShape = SCNSphere(radius: 1)
        tongueShape.segmentCount = 24
        tongue.geometry = tongueShape
        tongue.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.94, green: 0.32, blue: 0.36, alpha: 1)
        tongue.geometry?.firstMaterial?.lightingModel = .lambert
        root.addChildNode(cavity); root.addChildNode(tongue); root.addChildNode(lips)
        addPhiltrum()
        apply(.silence)
    }

    func apply(_ frame: LipFrame) {
        let energy = min(1, max(0, frame.open))
        let rounded = min(1, max(0, frame.round / max(energy, 0.01)))
        let clamped = LipFrame(open: energy, round: rounded, closed: frame.closed)
        guard lastFrame != clamped else { return }
        lastFrame = clamped
        opening = energy < 0.025 ? 0 : energy
        let halfWidth: Float = 0.0105 * (1 - rounded * 0.30)
        let gap: Float = 0.0002 + 0.014 * opening
        let points = (0..<segments).map { index -> SIMD3<Float> in
            let angle = Float(index) / Float(segments) * 2 * .pi
            let u = cos(angle), v = sin(angle)
            let x = centerX + halfWidth * u
            let smile = 0.0025 * u * u * (1 - rounded * 0.5)
            let y = topY + smile + (v >= 0 ? 0.0005 * v : gap * v)
            return SIMD3(x, y, surface.depth(x: x, y: y) + 0.0011)
        }
        rebuildCavity(points)
        rebuildLips(points)
        tongue.isHidden = opening < 0.15
        tongue.simdScale = SIMD3(halfWidth * 0.53, gap * 0.25, 0.0007)
        let tongueY = topY - gap * 0.70
        tongue.simdPosition = SIMD3(centerX, tongueY, surface.depth(x: centerX, y: tongueY) + 0.0015)
    }

    private func rebuildCavity(_ rim: [SIMD3<Float>]) {
        let center = rim.reduce(SIMD3<Float>.zero, +) / Float(rim.count)
        let vertices = [center] + rim
        var indices: [Int32] = []
        for index in 0..<segments {
            indices.append(0)
            indices.append(Int32(index + 1))
            indices.append(Int32((index + 1) % segments + 1))
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices.map(SCNVector3.init))],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [cavityMaterial]
        cavity.geometry = geometry
    }

    private func rebuildLips(_ rim: [SIMD3<Float>]) {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        let radius: Float = 0.00065
        for index in 0..<segments {
            let tangent = simd_normalize(rim[(index + 1) % segments] - rim[(index + segments - 1) % segments])
            let outward = simd_normalize(SIMD3(tangent.y, -tangent.x, 0))
            for side in 0..<tubeSides {
                let angle = Float(side) / Float(tubeSides) * 2 * .pi
                let normal = outward * cos(angle) + SIMD3<Float>(0, 0, sin(angle))
                vertices.append(SCNVector3(rim[index] + normal * radius))
                normals.append(SCNVector3(normal))
            }
        }
        var indices: [Int32] = []
        for index in 0..<segments {
            for side in 0..<tubeSides {
                let a = Int32(index * tubeSides + side)
                let b = Int32(((index + 1) % segments) * tubeSides + side)
                let c = Int32(index * tubeSides + (side + 1) % tubeSides)
                let d = Int32(((index + 1) % segments) * tubeSides + (side + 1) % tubeSides)
                indices += [a, b, c, c, b, d]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [lipMaterial]
        lips.geometry = geometry
    }

    private func addPhiltrum() {
        let a = SIMD3<Float>(centerX, 0.1335, surface.depth(x: centerX, y: 0.1335) + 0.0009)
        let b = SIMD3<Float>(centerX, topY, surface.depth(x: centerX, y: topY) + 0.0011)
        let stem = SCNNode(geometry: SCNCylinder(radius: 0.00055, height: CGFloat(simd_distance(a, b))))
        stem.name = "Philtrum"
        stem.geometry?.materials = [lipMaterial]
        stem.simdPosition = (a + b) / 2
        stem.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(b - a))
        root.addChildNode(stem)
    }
}
