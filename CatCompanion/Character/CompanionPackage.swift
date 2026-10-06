import Foundation

struct CompanionManifest: Codable {
    let formatVersion: Int
    let id: String
    let name: String
    let rig: String
    let models: [String]
    let primaryModel: String
    let personality: String
    let poses: String
    let defaultPose: String
}

struct CompanionPersonality: Codable {
    let description: String
    let instructions: String
    let voice: String
}

struct CompanionPackage {
    let root: URL
    let manifest: CompanionManifest
    let personality: CompanionPersonality
    let poses: [CatPose]
    var modelURL: URL { root.appendingPathComponent(manifest.primaryModel) }
    var defaultPose: CatPose { poses.first { $0.id == manifest.defaultPose }! }

    static func load(from root: URL) throws -> CompanionPackage {
        let manifest: CompanionManifest = try decode("companion.json", from: root)
        guard manifest.formatVersion == 1, manifest.rig == "painted-cat-v1" else {
            throw CompanionImportError.invalid("This companion needs an unsupported package version or character rig.")
        }
        guard validID(manifest.id), !manifest.name.isEmpty, manifest.name.count <= 100,
              (1...8).contains(manifest.models.count), Set(manifest.models).count == manifest.models.count,
              manifest.models.contains(manifest.primaryModel) else {
            throw CompanionImportError.invalid("The companion manifest is incomplete or has duplicate models.")
        }
        let personality: CompanionPersonality = try decode(manifest.personality, from: root)
        let poses: [CatPose] = try decode(manifest.poses, from: root)
        guard !personality.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              personality.instructions.count <= 16_000, personality.description.count <= 2000,
              !personality.voice.isEmpty, personality.voice.count <= 64 else {
            throw CompanionImportError.invalid("Add a personality and voice to personality.json.")
        }
        guard (1...64).contains(poses.count), Set(poses.map(\.id)).count == poses.count,
              poses.contains(where: { $0.id == manifest.defaultPose }) else {
            throw CompanionImportError.invalid("Poses must have unique IDs and include the default pose.")
        }
        let joints = Set(RigJoint.skeleton.map(\.name)).subtracting(["root", "neck", "jaw"] + CatTailGeometry.boneNames)
        for pose in poses {
            guard validID(pose.id), !pose.title.isEmpty, pose.title.count <= 100,
                  !pose.symbol.isEmpty, pose.symbol.count <= 100,
                  ["bright", "happy", "sleepy", "surprised", "wink"].contains(pose.expression),
                  !pose.criteria.isEmpty, pose.criteria.count <= 2000,
                  pose.jointAngles.keys.allSatisfy({ joints.contains($0) }),
                  pose.jointAngles.values.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) <= 1.5 } }),
                  pose.jointWaves.count <= 32,
                  pose.jointWaves.allSatisfy({ joints.contains($0.joint) && (0...2).contains($0.axis) &&
                      $0.amplitude.isFinite && abs($0.amplitude) <= 0.5 && $0.frequency.isFinite && (0...20).contains($0.frequency) }),
                  [pose.breathingAmplitude, pose.bounceAmplitude].allSatisfy({ $0.isFinite && (0...0.01).contains($0) }),
                  [pose.breathingFrequency, pose.bounceFrequency].allSatisfy({ $0.isFinite && (0...20).contains($0) }) else {
                throw CompanionImportError.invalid("Pose \(pose.id) contains unsupported joints, expressions, or movement values.")
            }
            for signals in [pose.tail.yaw, pose.tail.pitch, pose.tail.curl] {
                guard signals.count <= 16, signals.allSatisfy({ signal in
                    [signal.amplitude, signal.tipScale, signal.tipOffset].allSatisfy { $0.isFinite && abs($0) <= 1 } &&
                    signal.frequency.isFinite && (0...20).contains(signal.frequency) &&
                    signal.period.isFinite && (0...60).contains(signal.period) &&
                    (signal.kind != .flick || signal.period >= 2.5) &&
                    (-1000...1000).contains(signal.seed) && signal.decay.isFinite && (0...10).contains(signal.decay)
                }) else { throw CompanionImportError.invalid("Pose \(pose.id) contains invalid tail motion.") }
            }
        }
        var total = 0
        for path in manifest.models {
            guard path.lowercased().hasSuffix(".usdz") else {
                throw CompanionImportError.invalid("Companion models must be self-contained USDZ files.")
            }
            let url = try file(path, in: root)
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        guard total > 0, total <= CompanionStore.maximumBytes else { throw CompanionImportError.tooLarge }
        return CompanionPackage(root: root, manifest: manifest, personality: personality, poses: poses)
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    static func file(_ path: String, in root: URL) throws -> URL {
        guard safeRelativePath(path) else { throw CompanionImportError.unsafePath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/"), resolved.path == url.standardizedFileURL.path else {
            throw CompanionImportError.unsafePath
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CompanionImportError.unsafePath }
        guard let size = values.fileSize, size > 0, size <= CompanionStore.maximumBytes else { throw CompanionImportError.tooLarge }
        return url
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func decode<T: Decodable>(_ path: String, from root: URL) throws -> T {
        let url = try file(path, in: root)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2 * 1024 * 1024 else {
            throw CompanionImportError.tooLarge
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw CompanionImportError.invalid("Couldn’t read \(path). Check the companion package format.") }
    }
}

enum CompanionImportError: LocalizedError {
    case invalid(String), unsafePath, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .unsafePath: "The package contains an unsafe file path or link. Use a folder or ZIP with regular files."
        case .tooLarge: "The companion package is empty or exceeds the 512 MB size limit."
        }
    }
}
