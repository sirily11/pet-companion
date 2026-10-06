import AppKit
import SceneKit
import simd

/// A tapered, closed tube curled beside the body. Its first ring is embedded
/// in the hip; four overlapping bone influences bend the remaining length.
enum CatTailGeometry {
    static let boneNames = ["tail", "tailMiddle", "tailCurl", "tailTip"]
    static let rings = 64
    static let sides = 20
    static let controlPoints: [SIMD3<Float>] = [
        SIMD3(-0.058, 0.042, -0.025),
        SIMD3(-0.090, 0.032, -0.017),
        SIMD3(-0.117, 0.037, 0.012),
        SIMD3(-0.129, 0.066, 0.023),
        SIMD3(-0.127, 0.094, 0.025),
        SIMD3(-0.112, 0.107, 0.022),
        SIMD3(-0.099, 0.098, 0.022)
    ]

    static func center(at fraction: Float) -> SIMD3<Float> {
        let value = min(1, max(0, fraction)) * Float(controlPoints.count - 1)
        let index = min(controlPoints.count - 2, Int(value))
        let t = value - Float(index)
        let a = controlPoints[max(0, index - 1)]
        let b = controlPoints[index]
        let c = controlPoints[index + 1]
        let d = controlPoints[min(controlPoints.count - 1, index + 2)]
        return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t)
    }

    private static func tangent(at t: Float) -> SIMD3<Float> {
        simd_normalize(center(at: min(1, t + 0.001)) - center(at: max(0, t - 0.001)))
    }

    static func make() -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var uv: [CGPoint] = []
        for ring in 0...rings {
            let t = Float(ring) / Float(rings)
            let point = center(at: t)
            let direction = tangent(at: t)
            let normal = simd_normalize(simd_cross(direction, SIMD3(0, 0, 1)))
            let binormal = simd_normalize(simd_cross(direction, normal))
            let radius: Float = 0.003 + 0.017 * pow(1 - t, 0.55)
            for side in 0...sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let outward = normal * cos(angle) + binormal * sin(angle)
                vertices.append(SCNVector3(point + outward * radius))
                normals.append(SCNVector3(outward))
                colors.append(color(t: t, angle: angle, normal: outward))
                uv.append(CGPoint(x: CGFloat(side) / CGFloat(sides), y: CGFloat(t)))
            }
        }
        let baseCenter = Int32(vertices.count)
        vertices.append(SCNVector3(center(at: 0)))
        normals.append(SCNVector3(-tangent(at: 0)))
        colors.append(color(t: 0, angle: 0, normal: -tangent(at: 0)))
        uv.append(CGPoint(x: 0.5, y: 0))
        let tipCenter = Int32(vertices.count)
        vertices.append(SCNVector3(center(at: 1) + tangent(at: 1) * 0.003))
        normals.append(SCNVector3(tangent(at: 1)))
        colors.append(color(t: 1, angle: 0, normal: tangent(at: 1)))
        uv.append(CGPoint(x: 0.5, y: 1))
        var indices: [Int32] = []
        for ring in 0..<rings {
            for side in 0..<sides {
                let a = Int32(ring * (sides + 1) + side)
                let b = a + Int32(sides + 1)
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        for side in 0..<sides {
            indices += [baseCenter, Int32(side + 1), Int32(side)]
            let last = Int32(rings * (sides + 1) + side)
            indices += [tipCenter, last, last + 1]
        }
        let colorSource = SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color,
            vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uv), colorSource], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.roughness.contents = 1
        geometry.materials = [material]
        geometry.name = "CurledTail"
        return geometry
    }

    private static func color(t: Float, angle: Float, normal: SIMD3<Float>) -> SIMD4<Float> {
        let light = SIMD3<Float>(0.95, 0.46, 0.21)
        let stripe = SIMD3<Float>(0.89, 0.31, 0.10)
        let cream = SIMD3<Float>(1.0, 0.88, 0.71)
        let band = sin(t * .pi * 8 + 0.12 * sin(angle))
        let mix = smooth((band - 0.15) / 0.55)
        let paint = light + (stripe - light) * mix
        let tip = smooth((t - 0.79) / 0.11)
        let shade: Float = 0.86 + 0.14 * max(0, simd_dot(normal, simd_normalize(SIMD3(-0.3, 0.8, 0.5))))
        let rgb = (paint + (cream - paint) * tip) * shade
        return SIMD4(rgb.x, rgb.y, rgb.z, 1)
    }
    private static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }

    static func skinSources() -> (weights: SCNGeometrySource, indices: SCNGeometrySource) {
        var weights: [SIMD4<Float>] = []
        var indices: [SIMD4<UInt16>] = []
        for ring in 0...rings {
            let scaled = Float(ring) / Float(rings) * 3
            let first = min(2, Int(scaled))
            let blend = scaled - Float(first)
            for _ in 0...sides {
                weights.append(SIMD4(1 - blend, blend, 0, 0))
                indices.append(SIMD4(UInt16(first), UInt16(first + 1), 0, 0))
            }
        }
        weights += [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0)]
        indices += [SIMD4(0, 1, 0, 0), SIMD4(2, 3, 0, 0)]
        let weightSource = SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights,
            vectorCount: weights.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let indexSource = SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices,
            vectorCount: indices.count, usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        return (weightSource, indexSource)
    }
}
