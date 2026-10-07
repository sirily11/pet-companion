import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import Tokenizers
import zlib

/// PEFT adds its float32 adapter result to the promoted base result, then
/// casts once. MLX's standard LoRA layer casts the delta before adding, which
/// changes this trained checkpoint's probabilities over repeated layers.
private final class OpenJevLoRALinear: Linear {
    let adapterA: MLXArray
    let adapterB: MLXArray
    init(base: Linear, a: MLXArray, b: MLXArray) {
        adapterA = a; adapterB = b
        eval(a, b)
        super.init(weight: base.weight, bias: base.bias)
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let base = super.callAsFunction(x.asType(weight.dtype))
        let delta = 2 * matmul(matmul(x.asType(.float32), adapterA), adapterB)
        return (base.asType(.float32) + delta).asType(base.dtype)
    }
}

/// Reproduce the reference's json.dumps(ensure_ascii=False, sort_keys=True),
/// including separator whitespace. Prompt/token parity depends on these bytes.
enum OpenJevPrompts {
    static func render(_ value: Any) throws -> String {
        if let string = value as? String {
            let bytes = try JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes])
            return String(String(decoding: bytes, as: UTF8.self).dropFirst().dropLast())
        }
        if let dictionary = value as? [String: Any] {
            return "{" + (try dictionary.keys.sorted().map { try render($0) + ": " + render(dictionary[$0]!) }).joined(separator: ", ") + "}"
        }
        if let array = value as? [Any] { return "[" + (try array.map(render)).joined(separator: ", ") + "]" }
        if value is NSNull { return "null" }
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func candidates(state: [String: Any], question: JevQuestion) throws -> [String] {
        let prefix = "Context:\n\(try render(state))\n\nQuestion: \(question.instructions)\n"
        return question.choices.map {
            prefix + "Proposed answer: \($0.id): \($0.criteria)\nIs this proposed answer correct? Answer Yes or No."
        }
    }

    static func probabilities(scores: [Double], temperature: Double) throws -> [Double] {
        guard !scores.isEmpty, scores.allSatisfy(\.isFinite), temperature.isFinite, temperature > 0,
              let maximum = scores.max() else { throw OpenJevError.unsupportedCheckpoint }
        let weights = scores.map { exp(($0 - maximum) / temperature) }
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }
}

/// Read only the two known float32 storages from the pinned tensor ZIP. No
/// Python, pickle interpretation, executable objects, or arbitrary checkpoints.
enum OpenJevHead {
    static func read(_ data: Data) throws -> (weight: [Float], bias: Float) {
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw OpenJevError.unsupportedCheckpoint }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        guard data.count >= 22, data.count <= 32_768 else { throw OpenJevError.unsupportedCheckpoint }
        guard let end = stride(from: data.count - 22, through: 0, by: -1).first(where: {
            (try? number($0, 4)) == 0x06054b50
        }) else { throw OpenJevError.unsupportedCheckpoint }
        var cursor = try number(end + 16, 4)
        let count = try number(end + 10, 2)
        guard count <= 16 else { throw OpenJevError.unsupportedCheckpoint }
        var storages: [String: Data] = [:]
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50, try number(cursor + 10, 2) == 0 else { throw OpenJevError.unsupportedCheckpoint }
            let size = try number(cursor + 24, 4), length = try number(cursor + 28, 2)
            let extra = try number(cursor + 30, 2), comment = try number(cursor + 32, 2)
            let local = try number(cursor + 42, 4)
            guard try number(local, 4) == 0x04034b50, cursor + 46 + length <= data.count else { throw OpenJevError.unsupportedCheckpoint }
            let name = String(decoding: data[cursor + 46..<cursor + 46 + length], as: UTF8.self)
            let start = local + 30 + (try number(local + 26, 2)) + (try number(local + 28, 2))
            guard size <= 16_384, start + size <= data.count else { throw OpenJevError.unsupportedCheckpoint }
            let bytes = data.subdata(in: start..<start + size)
            let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count)) }
            guard Int(checksum) == (try number(cursor + 16, 4)), storages[name] == nil else { throw OpenJevError.unsupportedCheckpoint }
            storages[name] = bytes
            cursor += 46 + length + extra + comment
        }
        guard storages["head/byteorder"] == Data("little".utf8),
              let weight = storages["head/data/0"], weight.count == 2048 * 4,
              let bias = storages["head/data/1"], bias.count == 4 else { throw OpenJevError.unsupportedCheckpoint }
        func floats(_ bytes: Data) -> [Float] {
            stride(from: 0, to: bytes.count, by: 4).map { index in
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
                return Float(bitPattern: bits)
            }
        }
        let values = floats(weight), offset = floats(bias)[0]
        guard values.allSatisfy(\.isFinite), offset.isFinite else { throw OpenJevError.unsupportedCheckpoint }
        return (values, offset)
    }
}

actor OpenJevRuntime {
    private final class Loaded: @unchecked Sendable {
        let model: Qwen35TextModel
        let tokenizer: any Tokenizers.Tokenizer
        let head: Linear
        let temperature: Double
        init(model: Qwen35TextModel, tokenizer: any Tokenizers.Tokenizer, head: Linear, temperature: Double) {
            self.model = model; self.tokenizer = tokenizer; self.head = head; self.temperature = temperature
        }
    }
    let directory: URL
    private let manifest: OpenJevManifest
    private var loaded: Loaded?
    private var loading: Task<Loaded, Error>?
    private var revision = UUID()

    init(directory: URL, manifest: OpenJevManifest) { self.directory = directory; self.manifest = manifest }

    private func load() async throws -> Loaded {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("checkpoint/model.json").path) else {
            throw OpenJevError.notInstalled
        }
        guard ProcessInfo.processInfo.physicalMemory >= UInt64(manifest.totalBytes) * 2 else { throw OpenJevError.insufficientMemory }
        try manifest.verify(at: directory)
        try Task.checkCancellation()
        let base = directory.appendingPathComponent("base")
        let tokenizer = try await AutoTokenizer.from(modelFolder: base)
        try Task.checkCancellation()
        struct Configuration: Decodable { let text_config: Qwen35TextConfiguration }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: base.appendingPathComponent("config.json")))
        let model = Qwen35TextModel(configuration.text_config)
        Memory.cacheLimit = 64 * 1024 * 1024
        var weights = try MLX.loadArrays(url: base.appendingPathComponent("model.safetensors-00001-of-00001.safetensors")).mapValues { $0.asType(.float32) }
        // Keep the downloaded, unquantized checkpoint values unchanged, while
        // computing in float32. Cross-backend BF16 rounding is too large for
        // the 0.001 probability contract; the oracle uses matching float32.
        // Hugging Face evaluates (1 + weight.float()) inside each shifted
        // RMSNorm. Preserve that addition in float32 during layout conversion.
        for key in Array(weights.keys) where [".input_layernorm.weight", ".post_attention_layernorm.weight", ".q_norm.weight", ".k_norm.weight", ".norm.weight"].contains(where: key.hasSuffix) && !key.contains("linear_attn.norm") {
            weights[key] = weights[key]!.asType(.float32)
        }
        weights = try model.prepareCheckpoint(ModelCheckpoint(weights: weights)).weights
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        weights = [:]
        // The reference PEFT backbone is a text model rooted at `layers`;
        // Swift Qwen has a `model.layers` namespace. Normalize every tensor.
        let adapterURL = directory.appendingPathComponent("checkpoint/adapter/adapter_model.safetensors")
        let rawAdapter = try MLX.loadArrays(url: adapterURL)
        var adapter: [String: MLXArray] = [:]
        for (name, tensor) in rawAdapter {
            let stem = "base_model.model."
            guard name.hasPrefix(stem) else { throw OpenJevError.unsupportedCheckpoint }
            var key = String(name.dropFirst(stem.count))
            let suffix: String
            if key.hasSuffix(".lora_A.weight") { suffix = ".lora_A.weight"; key = String(key.dropLast(suffix.count)) + ".lora_a" }
            else if key.hasSuffix(".lora_B.weight") { suffix = ".lora_B.weight"; key = String(key.dropLast(suffix.count)) + ".lora_b" }
            else { throw OpenJevError.unsupportedCheckpoint }
            let components = key.split(separator: ".")
            guard components.count >= 5, components[0] == "layers", Int(components[1]) != nil else { throw OpenJevError.unsupportedCheckpoint }
            adapter["model." + key] = tensor.transposed()
        }
        var replacements: [(String, Module)] = []
        for (path, module) in model.leafModules().flattened() {
            if let a = adapter.removeValue(forKey: path + ".lora_a"),
               let b = adapter.removeValue(forKey: path + ".lora_b"), let linear = module as? Linear {
                replacements.append((path, OpenJevLoRALinear(base: linear, a: a, b: b)))
            }
        }
        guard !replacements.isEmpty, adapter.isEmpty else { throw OpenJevError.unsupportedCheckpoint }
        try model.update(modules: ModuleChildren.unflattened(replacements), verify: .noUnusedKeys)
        model.train(false)
        try model.prepare()
        let headData = try Data(contentsOf: directory.appendingPathComponent("checkpoint/head.pt"))
        let values = try OpenJevHead.read(headData)
        let head = Linear(weight: MLXArray(values.weight, [1, 2048]), bias: MLXArray([values.bias]))
        struct Calibration: Decodable { let temperature: Double }
        let calibration = try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: directory.appendingPathComponent("checkpoint/temperature.json")))
        guard calibration.temperature.isFinite, calibration.temperature > 0 else { throw OpenJevError.unsupportedCheckpoint }
        eval(model, head)
        Memory.cacheLimit = 256 * 1024 * 1024
        try Task.checkCancellation()
        return Loaded(model: model, tokenizer: tokenizer, head: head, temperature: calibration.temperature)
    }

    private func ready() async throws -> Loaded {
        if let loaded { return loaded }
        let token = revision
        let task: Task<Loaded, Error>
        if let loading { task = loading }
        else { task = Task { try await self.load() }; loading = task }
        do {
            let value = try await task.value
            guard revision == token else { throw CancellationError() }
            loaded = value; loading = nil
            return value
        } catch { if revision == token { loading = nil }; throw error }
    }

    func evaluate(context: JevContext, includeAnimation: Bool) async throws -> [String: JevAnswer] {
        try Task.checkCancellation()
        let value = try await ready()
        try Task.checkCancellation()
        var result: [String: JevAnswer] = [:]
        for question in context.questions(includeAnimation: includeAnimation) {
            let prompts = try OpenJevPrompts.candidates(state: context.state, question: question)
            let scores = try score(prompts: prompts, loaded: value)
            let probabilities = try OpenJevPrompts.probabilities(scores: scores, temperature: value.temperature)
            let index = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] })!
            result[question.id] = .init(type: "choice", choice: question.choices[index].id,
                                       probabilities: Dictionary(uniqueKeysWithValues: zip(question.choices.map(\.id), probabilities)))
        }
        return result
    }

    /// An uncached, no-padding oracle. Equal-length candidates share a batch;
    /// recurrent/attention state is never reused across requests in this v1.
    private func score(prompts: [String], loaded: Loaded) throws -> [Double] {
        let tokens = try prompts.map { prompt in
            try loaded.tokenizer.applyChatTemplate(messages: [["role": "user", "content": prompt]],
                chatTemplate: nil, addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil,
                additionalContext: ["enable_thinking": false])
        }
        guard tokens.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else { throw OpenJevError.contextTooLong }
        let groups = Dictionary(grouping: tokens.indices, by: { tokens[$0].count })
        var scores = [Double](repeating: 0, count: prompts.count)
        for length in groups.keys.sorted() {
            let indices = groups[length]!
            for start in stride(from: 0, to: indices.count, by: 2) {
                try Task.checkCancellation()
                let batch = Array(indices[start..<min(start + 2, indices.count)])
                let input = MLXArray(batch.flatMap { tokens[$0] }).reshaped([batch.count, length])
                // Public state emission exposes post-normalization hidden states.
                // MLX is lazy: the vocabulary logits in this result are never
                // evaluated, so only the trained scalar head performs readout.
                var state = LMOutput.State(); state[mtpEmitFlagKey] = true
                let output = loaded.model(LMInput.Text(tokens: input), cache: nil, state: state)
                guard let hidden = output.state?[mtpLastHiddenStatesKey] else { throw OpenJevError.unsupportedCheckpoint }
                let last = hidden[0..., length - 1, 0...].asType(.float32)
                let values = loaded.head(last).reshaped([batch.count]).asArray(Float.self)
                for (index, score) in zip(batch, values) { scores[index] = Double(score) }
            }
        }
        return scores
    }

    // The test harness uses the same loader, tokenizer, scorer and calibration
    // as production, with fixed prompts exported by the PyTorch reference.
    func scoreForValidation(prompts: [String]) async throws -> [Double] { try score(prompts: prompts, loaded: await ready()) }
    func tokenIDsForValidation(prompt: String) async throws -> [Int] {
        let value = try await ready()
        return try value.tokenizer.applyChatTemplate(messages: [["role": "user", "content": prompt]], chatTemplate: nil,
            addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil, additionalContext: ["enable_thinking": false])
    }
    func unload() async {
        revision = UUID()
        let current = loading; current?.cancel()
        _ = try? await current?.value
        loading = nil; loaded = nil
        Memory.clearCache()
    }
}
