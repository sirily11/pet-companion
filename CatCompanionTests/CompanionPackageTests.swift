import XCTest
import SceneKit
@testable import CatCompanion

enum TestCompanion {
    static func package() throws -> CompanionPackage {
        let root = try XCTUnwrap(Bundle(for: CompanionPackageTests.self).url(forResource: "orange-kitten", withExtension: nil))
        return try CompanionPackage.load(from: root)
    }
    static func pose(_ id: String) throws -> CatPose {
        try XCTUnwrap(package().poses.first { $0.id == id })
    }
}

final class CompanionPackageTests: XCTestCase {
    private func temporaryStore() throws -> CompanionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CompanionStore(directory: directory)
    }

    @MainActor func testFreshAppHasNoBundledPetOrPoses() {
        let character = CatSceneController(animate: false)
        XCTAssertNil(character.package)
        XCTAssertNil(character.pose)
        XCTAssertTrue(character.poses.isEmpty)
        XCTAssertTrue(character.meshes.isEmpty)
        XCTAssertNil(Bundle.main.url(forResource: "cat-happy-v2", withExtension: "usdz"))
    }

    @MainActor func testFolderImportSurvivesSourceRemovalAndRestoresAllData() throws {
        let store = try temporaryStore()
        XCTAssertNil(try store.current())
        let source = try store.prepare(TestCompanion.package().root)
        let package = try store.prepare(source.root)
        store.discard(source)
        XCTAssertEqual(package.poses.count, 12)
        XCTAssertEqual(package.manifest.models.count, 3)
        let character = CatSceneController(package: package, animate: false)
        XCTAssertNil(character.loadError)
        try store.activate(package)
        let restored = try XCTUnwrap(store.current())
        XCTAssertEqual(restored.poses, package.poses)
        XCTAssertEqual(restored.personality.instructions, package.personality.instructions)
        XCTAssertTrue(restored.modelURL.path.hasPrefix(store.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.root.appendingPathComponent("source").path))
        for path in restored.manifest.models {
            XCTAssertNoThrow(try SCNScene(url: restored.root.appendingPathComponent(path), options: [.checkConsistency: true]))
        }
    }

    func testZIPImportAndReplacementRestoreTheNewCompanion() throws {
        let store = try temporaryStore()
        let first = try store.prepare(TestCompanion.package().root)
        try store.activate(first)
        let zip = store.directory.appendingPathComponent("companion.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", first.root.path, zip.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let second = try store.prepare(zip)
        XCTAssertEqual(second.poses, first.poses)
        XCTAssertEqual(second.manifest.models.count, 3)
        try store.activate(second)
        XCTAssertEqual(try store.current()?.root, second.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.path))
    }

    func testMissingModelAndBadPoseDoNotReplaceSavedCompanion() throws {
        let store = try temporaryStore()
        let active = try store.prepare(TestCompanion.package().root)
        try store.activate(active)
        let broken = try store.prepare(TestCompanion.package().root)
        defer { store.discard(broken) }
        try FileManager.default.removeItem(at: broken.modelURL)
        XCTAssertThrowsError(try store.prepare(broken.root))
        XCTAssertEqual(try store.current()?.root, active.root)
        let invalid = try store.prepare(TestCompanion.package().root)
        defer { store.discard(invalid) }
        let path = invalid.root.appendingPathComponent(invalid.manifest.poses)
        var poses = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
        poses[1]["id"] = poses[0]["id"]
        try JSONSerialization.data(withJSONObject: poses).write(to: path)
        XCTAssertThrowsError(try store.prepare(invalid.root))
        XCTAssertEqual(try store.current()?.root, active.root)
    }

    @MainActor func testInvalidSceneImportPreservesActivePetAndRestartRestoresIt() async throws {
        let store = try temporaryStore()
        let coordinator = CompanionCoordinator(companionStore: store)
        await coordinator.importCompanion(from: try TestCompanion.package().root)
        XCTAssertNil(coordinator.importError)
        let original = coordinator.character
        let installed = try XCTUnwrap(store.current())
        let broken = try store.prepare(TestCompanion.package().root)
        defer { store.discard(broken) }
        try Data("Not a USDZ model".utf8).write(to: broken.modelURL)
        await coordinator.importCompanion(from: broken.root)
        XCTAssertNotNil(coordinator.importError)
        XCTAssertTrue(coordinator.character === original)
        XCTAssertEqual(try store.current()?.root, installed.root)
        XCTAssertFalse(coordinator.isImporting)
        let restarted = CompanionCoordinator(companionStore: store)
        XCTAssertEqual(restarted.character.package?.root, installed.root)
        XCTAssertEqual(restarted.live.companion?.personality.instructions, installed.personality.instructions)
    }

    func testPackageCannotReferenceFilesOutsideItsFolderOrLinks() throws {
        let store = try temporaryStore()
        let package = try store.prepare(TestCompanion.package().root)
        defer { store.discard(package) }
        XCTAssertThrowsError(try CompanionPackage.file("../outside.usdz", in: package.root))
        let link = package.root.appendingPathComponent("linked.usdz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.modelURL)
        XCTAssertThrowsError(try CompanionPackage.file("linked.usdz", in: package.root))
    }

    func testZIPRejectsTraversalLinksAndOversizedEntries() throws {
        let store = try temporaryStore()
        for (name, mode, size) in [("../escape.txt", UInt32(0x8000), UInt32(1)), ("link", UInt32(0xa000), UInt32(1)), ("huge", UInt32(0x8000), UInt32(CompanionStore.maximumBytes + 1))] {
            let zip = store.directory.appendingPathComponent(UUID().uuidString + ".zip")
            try archive(name: name, mode: mode, size: size).write(to: zip)
            XCTAssertThrowsError(try CompanionZIP.validate(zip))
        }
    }

    func testZIPRejectsCorruptionDuringExtraction() throws {
        let store = try temporaryStore()
        let zip = store.directory.appendingPathComponent("bad-crc.zip")
        try archive(name: "file", mode: 0x8000, size: 1).write(to: zip)
        XCTAssertThrowsError(try CompanionZIP.extract(zip, to: store.directory.appendingPathComponent("output")))
    }

    func testImportedPersonalityAndPoseChoicesAreUsedByAI() throws {
        let store = try temporaryStore()
        let package = try store.prepare(TestCompanion.package().root)
        defer { store.discard(package) }
        let personality = package.root.appendingPathComponent(package.manifest.personality)
        try Data(#"{"description":"Quiet pet","instructions":"You are a thoughtful quiet pet.","voice":"Puck"}"#.utf8).write(to: personality)
        let posesURL = package.root.appendingPathComponent(package.manifest.poses)
        var poses = [package.defaultPose]
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(poses)) as! [[String: Any]]
        var custom = data[0]
        custom["id"] = "greet"
        custom["title"] = "Greeting"
        custom["criteria"] = "Use for a greeting."
        poses += try JSONDecoder().decode([CatPose].self, from: JSONSerialization.data(withJSONObject: [custom]))
        try JSONEncoder().encode(poses).write(to: posesURL)
        let imported = try CompanionPackage.load(from: package.root)
        let config = try XCTUnwrap(GatewayAPI.sessionEvent(companion: imported)["config"] as? [String: Any])
        XCTAssertEqual(config["voice"] as? String, "Puck")
        XCTAssertTrue((config["instructions"] as? String)?.contains("thoughtful quiet pet") == true)
        XCTAssertTrue((config["instructions"] as? String)?.contains("idle, greet") == true)
        XCTAssertFalse((config["instructions"] as? String)?.contains("sleepy") == true)
    }

    private func archive(name: String, mode: UInt32, size: UInt32) -> Data {
        var data = Data()
        func append(_ value: UInt32, bytes: Int) { for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
        let filename = Data(name.utf8)
        append(0x04034b50, bytes: 4); append(20, bytes: 2); append(0, bytes: 2); append(0, bytes: 2)
        append(0, bytes: 4); append(0, bytes: 4); append(1, bytes: 4); append(size, bytes: 4)
        append(UInt32(filename.count), bytes: 2); append(0, bytes: 2); data.append(filename); data.append(65)
        let directory = UInt32(data.count)
        append(0x02014b50, bytes: 4); append(0x0314, bytes: 2); append(20, bytes: 2)
        append(0, bytes: 2); append(0, bytes: 2); append(0, bytes: 4); append(0, bytes: 4)
        append(1, bytes: 4); append(size, bytes: 4); append(UInt32(filename.count), bytes: 2)
        append(0, bytes: 2); append(0, bytes: 2); append(0, bytes: 2); append(0, bytes: 2)
        append(mode << 16, bytes: 4); append(0, bytes: 4); data.append(filename)
        let directorySize = UInt32(data.count) - directory
        append(0x06054b50, bytes: 4); append(0, bytes: 2); append(0, bytes: 2)
        append(1, bytes: 2); append(1, bytes: 2); append(directorySize, bytes: 4); append(directory, bytes: 4); append(0, bytes: 2)
        return data
    }
}
