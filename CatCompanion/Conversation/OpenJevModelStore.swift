import Foundation
import CryptoKit
import Combine

struct OpenJevManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    let version: Int
    let checkpointRevision: String
    let baseRevision: String
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static func bundled() -> OpenJevManifest {
        let url = Bundle.main.url(forResource: "OpenJevManifest", withExtension: "json")!
        return try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func verify(at root: URL) throws {
        for file in files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.path)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(file.bytes),
                  try Self.digest(url) == file.sha256 else { throw OpenJevError.corruptDownload }
        }
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum OpenJevError: LocalizedError {
    case notInstalled, corruptDownload, unsupportedCheckpoint, contextTooLong, insufficientMemory, downloadFailed
    var errorDescription: String? {
        switch self {
        case .notInstalled: "Download Open-Jev in Settings → Manage local model before using local decisions."
        case .corruptDownload: "A model file failed verification. Resume the download to replace it."
        case .unsupportedCheckpoint: "The local checkpoint is incompatible. Remove it and download Open-Jev again."
        case .contextTooLong: "This interaction history exceeds the local model’s 4,096-token limit. Switch to Cloud JEV or select another pet to reset its history."
        case .insufficientMemory: "There isn’t enough memory to load Open-Jev. Close other apps or switch to Cloud JEV."
        case .downloadFailed: "Couldn’t download the model. Check your connection and available disk space, then resume."
        }
    }
}

/// Range downloads preserve partial files across cancellation and app launches.
/// Delegate work runs on its own serial queue, including file I/O.
private final class ModelFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: OpenJevManifest.File
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var lastReported: Int64 = 0
    private var failure: Error?
    private let lock = NSLock()
    private var cancelled = false

    init(file: OpenJevManifest.File, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.destination = destination; self.progress = progress
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                received = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var request = URLRequest(url: file.url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                lock.lock(); self.task = task; let stopped = cancelled; lock.unlock()
                task.resume()
                if stopped { task.cancel() }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else { throw OpenJevError.downloadFailed }
            if http.statusCode == 206 {
                guard http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(received)-") == true else {
                    throw OpenJevError.downloadFailed
                }
            } else { received = 0 }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: destination)
            self.handle = handle
            try handle.truncate(atOffset: UInt64(received))
            try handle.seekToEnd()
            progress(received)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard received + Int64(data.count) <= file.bytes, let handle else { throw OpenJevError.corruptDownload }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if received - lastReported >= 1024 * 1024 || received == file.bytes {
                lastReported = received; progress(received)
            }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        let resultError = failure ?? error ?? (received == file.bytes ? nil : OpenJevError.downloadFailed)
        if let resultError { continuation?.resume(throwing: resultError) }
        else { continuation?.resume() }
        continuation = nil; self.task = nil
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

@MainActor
final class OpenJevModelStore: ObservableObject {
    enum Phase: String { case notInstalled, downloading, paused, verifying, ready, removing, failed }
    typealias Download = @Sendable (OpenJevManifest.File, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    @Published private(set) var phase: Phase = .notInstalled
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var error: String?
    let manifest: OpenJevManifest
    let root: URL
    let runtime: OpenJevRuntime
    var onWillRemove: (() -> Void)?
    private let download: Download
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var installedURL: URL { root.appendingPathComponent("installed", isDirectory: true) }
    var stagingURL: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var isInstalled: Bool { phase == .ready }
    var progress: Double { min(1, Double(downloadedBytes) / Double(max(1, manifest.totalBytes))) }
    private struct Receipt: Codable { let checkpointRevision: String; let baseRevision: String }

    init(root: URL? = nil, manifest: OpenJevManifest? = nil, download: Download? = nil) {
        let manifest = manifest ?? .bundled()
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetPaw/OpenJev2B", isDirectory: true)
        self.manifest = manifest; self.root = root
        runtime = OpenJevRuntime(directory: root.appendingPathComponent("installed"), manifest: manifest)
        self.download = download ?? { file, destination, progress in
            try await ModelFileDownload(file: file, destination: destination, progress: progress).run()
        }
        if let data = try? Data(contentsOf: installedURL.appendingPathComponent("installation.json")),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
           receipt.checkpointRevision == manifest.checkpointRevision, receipt.baseRevision == manifest.baseRevision,
           manifest.files.allSatisfy({ (try? installedURL.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.bytes) }) {
            phase = .ready; downloadedBytes = manifest.totalBytes
        } else if FileManager.default.fileExists(atPath: stagingURL.path) {
            phase = .paused
            downloadedBytes = manifest.files.reduce(0) { $0 + Int64((try? stagingURL.appendingPathComponent($1.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }

    func startDownload() {
        guard task == nil, !isInstalled, phase != .removing else { return }
        error = nil; phase = .downloading
        let token = UUID(); generation = token
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            var completed: Int64 = 0
            do {
                try FileManager.default.createDirectory(at: self.stagingURL, withIntermediateDirectories: true)
                for file in self.manifest.files {
                    try Task.checkCancellation()
                    let destination = self.stagingURL.appendingPathComponent(file.path)
                    let complete = try await Task.detached {
                        guard (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) else { return false }
                        return try OpenJevManifest.digest(destination) == file.sha256
                    }.value
                    if !complete {
                        if ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= Int(file.bytes) { try FileManager.default.removeItem(at: destination) }
                        let prior = completed
                        try await self.download(file, destination) { [weak self] current in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.downloadedBytes = prior + current
                            }
                        }
                        self.phase = .verifying
                        let valid = try await Task.detached { try OpenJevManifest.digest(destination) == file.sha256 }.value
                        guard valid else { try? FileManager.default.removeItem(at: destination); throw OpenJevError.corruptDownload }
                        self.phase = .downloading
                    }
                    completed += file.bytes; self.downloadedBytes = completed
                }
                try Task.checkCancellation()
                let receipt = Receipt(checkpointRevision: self.manifest.checkpointRevision, baseRevision: self.manifest.baseRevision)
                try JSONEncoder().encode(receipt).write(to: self.stagingURL.appendingPathComponent("installation.json"), options: .atomic)
                if FileManager.default.fileExists(atPath: self.installedURL.path) { try FileManager.default.removeItem(at: self.installedURL) }
                try FileManager.default.moveItem(at: self.stagingURL, to: self.installedURL)
                self.phase = .ready
            } catch {
                guard self.generation == token else { return }
                if Task.isCancelled { self.phase = .paused }
                else { self.phase = .failed; self.error = (error as? OpenJevError)?.localizedDescription ?? OpenJevError.downloadFailed.localizedDescription }
            }
        }
    }
    func pause() { task?.cancel() }

    func remove() async {
        phase = .removing
        onWillRemove?()
        let current = task; current?.cancel(); await current?.value
        generation = UUID(); task = nil; phase = .removing
        await runtime.unload()
        do {
            let root = root
            try await Task.detached { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }.value
            downloadedBytes = 0; phase = .notInstalled; error = nil
        } catch { phase = .failed; self.error = "Couldn’t remove the model. Close any app using these files and try again." }
    }
}
