import Foundation
import zlib

/// Imports only runtime data. The active pointer changes after the model renders successfully.
struct CompanionStore {
    static let maximumBytes = 512 * 1024 * 1024
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatCompanion/Companions", isDirectory: true)
    }

    func current() throws -> CompanionPackage? {
        let pointer = directory.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let name = try JSONDecoder().decode(String.self, from: Data(contentsOf: pointer))
        guard UUID(uuidString: name) != nil else { throw CompanionImportError.unsafePath }
        return try CompanionPackage.load(from: directory.appendingPathComponent(name, isDirectory: true))
    }

    func prepare(_ selectedURL: URL) throws -> CompanionPackage {
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let isFolder = try selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let root: URL
        if isFolder {
            root = selectedURL
        } else {
            guard selectedURL.pathExtension.lowercased() == "zip" else {
                throw CompanionImportError.invalid("Choose a companion folder or ZIP file.")
            }
            // Work on a private snapshot so the checked archive cannot change during extraction.
            let archive = staging.appendingPathComponent("archive.zip")
            guard (try selectedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maximumBytes else {
                throw CompanionImportError.tooLarge
            }
            try fm.copyItem(at: selectedURL, to: archive)
            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            try CompanionZIP.extract(archive, to: extracted)
            root = try Self.packageRoot(in: extracted)
        }
        let source = try CompanionPackage.load(from: root)
        let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let files = Set(["companion.json", source.manifest.personality, source.manifest.poses] + source.manifest.models)
            for path in files {
                let original = try CompanionPackage.file(path, in: root)
                let target = destination.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: target)
            }
            return try CompanionPackage.load(from: destination)
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    func activate(_ package: CompanionPackage) throws {
        let name = package.root.lastPathComponent
        guard UUID(uuidString: name) != nil, package.root.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw CompanionImportError.unsafePath
        }
        let previous = try? current()?.root
        try JSONEncoder().encode(name).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        if let previous, previous != package.root { try? FileManager.default.removeItem(at: previous) }
    }

    func discard(_ package: CompanionPackage) {
        guard package.root.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              UUID(uuidString: package.root.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: package.root)
    }

    private static func packageRoot(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("companion.json").path) { return directory }
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let roots = try children.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true &&
                fm.fileExists(atPath: $0.appendingPathComponent("companion.json").path)
        }
        guard roots.count == 1 else { throw CompanionImportError.invalid("The ZIP must contain one companion folder with companion.json.") }
        return roots[0]
    }
}

/// Reads standard ZIPs without scripts or subprocesses. Writes only validated paths and bounded data.
enum CompanionZIP {
    private struct Entry {
        let name: String
        let start: Int
        let compressed: Int
        let size: Int
        let method: Int
        let crc: UInt32
    }

    static func validate(_ url: URL) throws {
        _ = try entries(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func extract(_ url: URL, to destination: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try entries(in: data)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let target = destination.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") {
                guard entry.size == 0 else { throw CompanionImportError.unsafePath }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let compressed = data.subdata(in: entry.start..<entry.start + entry.compressed)
            let bytes: Data
            if entry.method == 0 {
                guard compressed.count == entry.size else { throw CompanionImportError.invalid("The ZIP file size is invalid.") }
                bytes = compressed
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw CompanionImportError.invalid("Couldn’t read the ZIP compression.")
                }
                defer { inflateEnd(&stream) }
                var output = Data(count: entry.size + 1)
                let status = compressed.withUnsafeBytes { input in
                    output.withUnsafeMutableBytes { buffer in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                        stream.avail_in = UInt32(entry.compressed)
                        stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = UInt32(entry.size + 1)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == entry.compressed else {
                    throw CompanionImportError.invalid("The ZIP contains damaged or oversized compressed data.")
                }
                output.count = entry.size
                bytes = output
            }
            let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count)) }
            guard UInt32(checksum) == entry.crc else { throw CompanionImportError.invalid("A file in the ZIP failed its integrity check.") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .withoutOverwriting)
        }
    }

    private static func entries(in data: Data) throws -> [Entry] {
        guard data.count >= 22, data.count <= CompanionStore.maximumBytes else { throw CompanionImportError.tooLarge }
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw CompanionImportError.invalid("The ZIP is truncated.") }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50, offset + 22 + (try number(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw CompanionImportError.invalid("Use a standard, single-part ZIP file.")
        }
        let count = try number(end + 10, 2)
        let directorySize = try number(end + 12, 4)
        var offset = try number(end + 16, 4)
        let directoryStart = offset
        guard (1...1000).contains(count), try number(end + 8, 2) == count,
              offset + directorySize == end else { throw CompanionImportError.invalid("The ZIP directory is unsupported.") }
        var names = Set<String>(), total = 0
        var ranges: [Range<Int>] = []
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014b50 else { throw CompanionImportError.invalid("The ZIP directory is invalid.") }
            let flags = try number(offset + 8, 2), method = try number(offset + 10, 2)
            let compressed = try number(offset + 20, 4), size = try number(offset + 24, 4)
            let length = try number(offset + 28, 2)
            let extra = try number(offset + 30, 2), comment = try number(offset + 32, 2)
            let mode = (try number(offset + 38, 4) >> 16) & 0xf000
            let local = try number(offset + 42, 4)
            guard offset + 46 + length + extra + comment <= end, length > 0,
                  let name = String(data: data.subdata(in: offset + 46..<offset + 46 + length), encoding: .utf8) else {
                throw CompanionImportError.invalid("The ZIP contains an invalid filename.")
            }
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard CompanionPackage.safeRelativePath(path), names.insert(path.lowercased()).inserted,
                  mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw CompanionImportError.unsafePath }
            guard flags & 1 == 0, method == 0 || method == 8, size <= CompanionStore.maximumBytes,
                  try number(offset + 34, 2) == 0,
                  try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else {
                throw CompanionImportError.invalid("Encrypted, linked, or unsupported ZIP entries cannot be imported.")
            }
            let localLength = try number(local + 26, 2), localExtra = try number(local + 28, 2)
            let start = local + 30 + localLength + localExtra
            guard localLength == length, start + compressed <= directoryStart,
                  data.subdata(in: local + 30..<local + 30 + localLength) == data.subdata(in: offset + 46..<offset + 46 + length),
                  !ranges.contains(where: { $0.overlaps(local..<start + compressed) }) else { throw CompanionImportError.unsafePath }
            if flags & 8 == 0 {
                guard try number(local + 18, 4) == compressed, try number(local + 22, 4) == size else {
                    throw CompanionImportError.invalid("The ZIP entry sizes are inconsistent.")
                }
            }
            ranges.append(local..<start + compressed)
            entries.append(Entry(name: name, start: start, compressed: compressed, size: size, method: method, crc: UInt32(try number(offset + 16, 4))))
            total += size
            guard total <= CompanionStore.maximumBytes else { throw CompanionImportError.tooLarge }
            offset += 46 + length + extra + comment
        }
        guard offset == end else { throw CompanionImportError.invalid("The ZIP has unexpected directory data.") }
        return entries
    }
}
