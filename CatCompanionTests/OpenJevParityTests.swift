import XCTest
@testable import CatCompanion

/// Optional real-weight tests. CI remains offline and model-free; local
/// validation downloads into ignored build/openjev-reference explicitly.
final class OpenJevParityTests: XCTestCase {
    struct Oracle: Decodable {
        let temperature: Double
        let checkpointRevision: String
        let fixtures: [Fixture]
    }
    struct Fixture: Decodable {
        let name: String
        let prompts: [String]
        let tokenIDs: [[Int]]
        let probabilities: [Double]
    }
    func testTrainedCheckpointParityAndLatency() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelDirectory = workspace.appendingPathComponent("build/openjev-reference")
        guard FileManager.default.isReadableFile(atPath: modelDirectory.appendingPathComponent("base/model.safetensors-00001-of-00001.safetensors").path),
              let fixtureURL = Bundle(for: Self.self).url(forResource: "OpenJevParityFixtures", withExtension: "json") else {
            throw XCTSkip("Run the explicit trained-model validation workflow to install the pinned local oracle files.")
        }
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixtureURL))
        let manifest = OpenJevManifest.bundled()
        XCTAssertEqual(oracle.checkpointRevision, manifest.checkpointRevision)
        let runtime = OpenJevRuntime(directory: modelDirectory, manifest: manifest)
        var durations: [Double] = [], maximumError = 0.0, coldSeconds = 0.0
        let coldStart = Date()
        for fixture in oracle.fixtures {
            for (prompt, expected) in zip(fixture.prompts, fixture.tokenIDs) {
                let tokens = try await runtime.tokenIDsForValidation(prompt: prompt)
                XCTAssertEqual(tokens, expected, "Tokenizer mismatch: \(fixture.name)")
            }
            let started = Date()
            let scores = try await runtime.scoreForValidation(prompts: fixture.prompts)
            if durations.isEmpty { coldSeconds = Date().timeIntervalSince(coldStart) }
            durations.append(Date().timeIntervalSince(started))
            let probabilities = try OpenJevPrompts.probabilities(scores: scores, temperature: oracle.temperature)
            let expectedIndex = fixture.probabilities.indices.max(by: { fixture.probabilities[$0] < fixture.probabilities[$1] })
            let actualIndex = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] })
            XCTAssertEqual(actualIndex, expectedIndex, "Choice differs: \(fixture.name)")
            XCTAssertEqual((probabilities.max() ?? 0) >= 0.45, (fixture.probabilities.max() ?? 0) >= 0.45, "Fallback differs: \(fixture.name)")
            for (actual, expected) in zip(probabilities, fixture.probabilities) {
                maximumError = max(maximumError, abs(actual - expected))
                XCTAssertEqual(actual, expected, accuracy: 0.001, fixture.name)
            }
        }
        let warm = Array(durations.dropFirst()).sorted()
        let p50 = warm.isEmpty ? 0 : warm[warm.count / 2]
        let p95 = warm.isEmpty ? 0 : warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))]
        let report = "Open-Jev: \(oracle.fixtures.count) fixtures; maximum probability error \(maximumError); cold load + first score \(coldSeconds) s; warm P50 \(p50) s; P95 \(p95) s."
        print(report)
        let attachment = XCTAttachment(string: report); attachment.lifetime = .keepAlways
        add(attachment)
        await runtime.unload()
    }
}
