import SceneKit
import simd

/// Samples the existing head surface and its UVs. Clearing the painted face
/// uses a procedural material mask; the supplied texture files remain untouched.
struct HeadSurface {
    struct Sample { let position: SIMD3<Float>; let uv: SIMD2<Float> }
    private let spacing: Float = 0.001
    private var grid: [SIMD2<Int32>: Sample] = [:]
    let positions: [SIMD3<Float>]
    let textureCoordinates: [SIMD2<Float>]
    private let texturePositions: [SIMD3<Float>]
    private let textureVertexIndices: [Int]
    private let faceIndices: [Int32]

    init?(geometry: SCNGeometry) {
        guard let vertices = geometry.sources(for: .vertex).first,
              let texture = geometry.sources(for: .texcoord).first,
              vertices.usesFloatComponents, texture.usesFloatComponents,
              vertices.bytesPerComponent == 4, texture.bytesPerComponent == 4 else { return nil }
        positions = Self.read(vertices).map { SIMD3($0[0], $0[1], $0[2]) }
        textureCoordinates = Self.read(texture).map { SIMD2($0[0], $0[1]) }
        let channels = geometry.geometrySourceChannels ?? geometry.sources.map { _ in NSNumber(value: 0) }
        guard let vertexSourceIndex = geometry.sources.firstIndex(where: { $0.semantic == .vertex }),
              let uvSourceIndex = geometry.sources.firstIndex(where: { $0.semantic == .texcoord }) else { return nil }
        let vertexChannel = channels[vertexSourceIndex].intValue
        let uvChannel = channels[uvSourceIndex].intValue
        var mapped = [SIMD3<Float>](repeating: .zero, count: texture.vectorCount)
        var vertexMapping = [Int](repeating: 0, count: texture.vectorCount)
        var unifiedIndices: [Int32] = []
        for element in geometry.elements {
            guard element.primitiveType == .triangles else { return nil }
            let count = element.primitiveCount * 3
            let channelCount = element.indicesChannelCount
            let indices: [UInt32] = element.data.withUnsafeBytes { bytes in
                (0..<(element.data.count / element.bytesPerIndex)).map { i in
                    switch element.bytesPerIndex {
                    case 1: return UInt32(bytes.loadUnaligned(fromByteOffset: i, as: UInt8.self))
                    case 2: return UInt32(bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    default: return bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    }
                }
            }
            func index(_ slot: Int, channel: Int) -> Int {
                Int(indices[element.hasInterleavedIndicesChannels ? slot * channelCount + channel : channel * count + slot])
            }
            for slot in 0..<count {
                let vertex = index(slot, channel: vertexChannel)
                let uv = index(slot, channel: uvChannel)
                guard positions.indices.contains(vertex), mapped.indices.contains(uv) else { return nil }
                mapped[uv] = positions[vertex]
                vertexMapping[uv] = vertex
                unifiedIndices.append(Int32(uv))
            }
        }
        texturePositions = mapped
        textureVertexIndices = vertexMapping
        faceIndices = unifiedIndices
        for i in texturePositions.indices {
            let p = texturePositions[i]
            guard p.z > 0.005 else { continue }
            let cell = key(x: p.x, y: p.y)
            if let existing = grid[cell] {
                let center = SIMD2(Float(cell.x) * spacing, Float(cell.y) * spacing)
                if simd_distance_squared(SIMD2(p.x, p.y), center) >= simd_distance_squared(SIMD2(existing.position.x, existing.position.y), center) { continue }
            }
            grid[cell] = Sample(position: p, uv: textureCoordinates[i])
        }
    }

    private static func read(_ source: SCNGeometrySource) -> [[Float]] {
        source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { index in
                (0..<source.componentsPerVector).map { component in
                    bytes.loadUnaligned(fromByteOffset: source.dataOffset + index * source.dataStride + component * 4, as: Float.self)
                }
            }
        }
    }
    private func key(x: Float, y: Float) -> SIMD2<Int32> { SIMD2(Int32((x / spacing).rounded()), Int32((y / spacing).rounded())) }
    private func nearby(x: Float, y: Float) -> [Sample] {
        let cell = key(x: x, y: y)
        var result: [Sample] = []
        for dy: Int32 in -2...2 {
            for dx: Int32 in -2...2 {
                if let sample = grid[cell &+ SIMD2(dx, dy)] { result.append(sample) }
            }
        }
        return result
    }
    func sample(x: Float, y: Float) -> Sample? {
        nearby(x: x, y: y).min {
            simd_distance_squared(SIMD2($0.position.x, $0.position.y), SIMD2(x, y)) <
                simd_distance_squared(SIMD2($1.position.x, $1.position.y), SIMD2(x, y))
        }
    }
    func depth(x: Float, y: Float) -> Float {
        // Taking the frontmost nearby sample keeps the lip surface clear of the
        // original cheek even where its triangulation is relatively coarse.
        nearby(x: x, y: y).map(\.position.z).max() ?? 0.076
    }
    func unifiedHeadGeometry(from geometry: SCNGeometry) -> SCNGeometry {
        // Resolve the USD's separate position/UV indices into one vertex stream.
        // This removes the multi-index skinning ambiguity behind the face-card
        // artifacts while preserving every original triangle and UV seam.
        let normalSource = geometry.sources(for: .normal).first!
        let originalNormals = Self.read(normalSource).map { SIMD3($0[0], $0[1], $0[2]) }
        let normals = textureVertexIndices.map { originalNormals[$0] }
        let coordinates = textureCoordinates.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let localPositions = texturePositions.map { SIMD4($0.x, $0.y, $0.z, Float(1)) }
        let localSource = SCNGeometrySource(data: localPositions.withUnsafeBytes { Data($0) }, semantic: .color,
            vectorCount: localPositions.count, usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let unified = SCNGeometry(sources: [SCNGeometrySource(vertices: texturePositions.map(SCNVector3.init)),
            SCNGeometrySource(normals: normals.map(SCNVector3.init)), SCNGeometrySource(textureCoordinates: coordinates), localSource],
            elements: [SCNGeometryElement(indices: faceIndices, primitiveType: .triangles)])
        unified.materials = geometry.materials
        unified.name = "UnifiedHead"
        return unified
    }

    func clearPaintedFace(on material: SCNMaterial) {
        // The illustration has a second cheek/head outline. Replace the whole
        // front facial area with softly blended fur, then use actual 3D features.
        material.shaderModifiers = [
            .geometry: """
                #pragma varyings
                float3 catFacePosition;
                #pragma body
                out.catFacePosition = _geometry.color.xyz;
                _geometry.color = float4(1.0);
                """,
            .surface: """
                #pragma body
                float3 p = in.catFacePosition;
                float front = smoothstep(-0.030, 0.012, p.z);
                float face = front * (1.0 - smoothstep(0.186, 0.205, p.y));
                float center = abs(p.x - 0.006);
                float creamWidth = mix(0.100, 0.028, smoothstep(0.094, 0.185, p.y));
                float muzzle = 1.0 - smoothstep(creamWidth * 0.68, creamWidth, center);
                float3 cream = float3(1.0, 0.92, 0.81);
                float3 orange = float3(1.0, 0.60, 0.33);
                float3 fur = mix(orange, cream, muzzle);
                float stripe = smoothstep(0.045, 0.073, center) * max(0.0, sin((p.y + center * 0.40) * 210.0));
                fur = mix(fur, float3(0.87, 0.41, 0.21), stripe * 0.25);
                float2 leftCheek = (p.xy - float2(-0.046, 0.135)) / float2(0.021, 0.013);
                float2 rightCheek = (p.xy - float2(0.055, 0.137)) / float2(0.021, 0.013);
                float blush = (exp(-dot(leftCheek, leftCheek)) + exp(-dot(rightCheek, rightCheek))) * 0.43;
                float3 skin = mix(fur, float3(1.0, 0.53, 0.53), min(0.45, blush));
                _surface.diffuse.rgb = mix(_surface.diffuse.rgb, skin, face);
                """
        ]
    }
}
