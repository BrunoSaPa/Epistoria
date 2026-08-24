import AVFoundation
import Foundation

public struct VideoSourceAdapter: DecoderValidatedSourceAdapter {
    public let sourceType = ResourceKind.video
    public let supportedExtensions: Set<String> = ["m4v", "mov", "mp4"]
    public let maximumBytes = 384 * 1_024 * 1_024

    public init() {}

    public func validate(data: Data, filename: String, mimeType _: String) throws {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw SourceAdapterError.unsupportedType }
        guard Self.hasValidContainer(data, extension: ext) else {
            throw SourceAdapterError.malformed
        }

    }

    public func validateWithDecoder(data: Data, filename: String, mimeType: String) async throws {
        try validate(data: data, filename: filename, mimeType: mimeType)
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let temporaryURL = try ProtectedVideoFileStore.write(data, filenameExtension: ext)
        defer { try? ProtectedVideoFileStore.remove(temporaryURL) }
        do {
            let asset = AVURLAsset(url: temporaryURL)
            let isPlayable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard isPlayable, duration.isFinite, duration > 0, !tracks.isEmpty else {
                throw SourceAdapterError.malformed
            }
        } catch {
            throw SourceAdapterError.malformed
        }
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .video, mimeType: mimeType)
    }

    public func extractText(data _: Data) throws -> String? { nil }
    public func thumbnail(data _: Data) throws -> Data? { nil }
    public func readableExport(data: Data) throws -> Data { data }

    private static func hasValidContainer(_ data: Data, extension ext: String) -> Bool {
        guard let boxes = boxes(in: data),
              boxes.contains(where: { $0.type == "moov" && !$0.payloadRange.isEmpty }),
              boxes.contains(where: { $0.type == "mdat" && !$0.payloadRange.isEmpty })
        else { return false }

        guard let fileType = boxes.first(where: { $0.type == "ftyp" }),
              fileType.payloadRange.count >= 8
        else { return ext == "mov" && boxes.contains(where: { $0.type == "wide" }) }

        var brands = [ascii(data, fileType.payloadRange.lowerBound..<(fileType.payloadRange.lowerBound + 4))]
        var offset = fileType.payloadRange.lowerBound + 8
        while offset <= fileType.payloadRange.upperBound - 4 {
            brands.append(ascii(data, offset..<(offset + 4)))
            offset += 4
        }
        let supportedBrands: Set<String> = [
            "M4V ", "avc1", "iso2", "iso4", "iso5", "iso6", "isom", "mp41", "mp42", "qt  ",
        ]
        return !supportedBrands.isDisjoint(with: brands)
    }

    private struct ISOBox {
        var type: String
        var payloadRange: Range<Int>
    }

    private static func boxes(in data: Data) -> [ISOBox]? {
        guard data.count >= 16 else { return nil }
        var result: [ISOBox] = []
        var offset = 0
        while offset <= data.count - 8 {
            guard let shortSize = uint32BE(data, at: offset) else { return nil }
            let type = ascii(data, (offset + 4)..<(offset + 8))
            let headerSize: Int
            let boxSize: UInt64
            if shortSize == 1 {
                guard offset <= data.count - 16, let extended = uint64BE(data, at: offset + 8) else {
                    return nil
                }
                headerSize = 16
                boxSize = extended
            } else if shortSize == 0 {
                headerSize = 8
                boxSize = UInt64(data.count - offset)
            } else {
                headerSize = 8
                boxSize = UInt64(shortSize)
            }
            guard boxSize >= UInt64(headerSize),
                  boxSize <= UInt64(data.count - offset),
                  let count = Int(exactly: boxSize)
            else { return nil }
            result.append(ISOBox(
                type: type,
                payloadRange: (offset + headerSize)..<(offset + count)
            ))
            offset += count
        }
        return offset == data.count ? result : nil
    }

    private static func ascii(_ data: Data, _ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
        return String(decoding: data[range], as: UTF8.self)
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func uint64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(data[offset + $1]) }
    }
}

public enum ProtectedVideoFileStore {
    private static let directoryName = "com.epistoria.protected-video"
    private static let supportedExtensions: Set<String> = ["m4v", "mov", "mp4"]

    public static func write(
        _ data: Data,
        filenameExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let ext = filenameExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw SourceAdapterError.unsupportedType }
        let directory = directoryURL(fileManager: fileManager)
        #if os(iOS)
        let directoryAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.complete,
        ]
        #else
        let directoryAttributes: [FileAttributeKey: Any]? = nil
        #endif
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(directoryValues)

        let url = directory.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(ext)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        // Data Protection is an iOS guarantee. The macOS target exists for deterministic
        // Core tests and trusted-worker reuse; direct creation avoids runner sandbox failures.
        try data.write(to: url)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        return url
    }

    public static func remove(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard url.deletingLastPathComponent().standardizedFileURL
            == directoryURL(fileManager: fileManager).standardizedFileURL
        else { return }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public static func removeAllTemporaryFiles(fileManager: FileManager = .default) throws {
        let directory = directoryURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { try fileManager.removeItem(at: file) }
        }
    }

    private static func directoryURL(fileManager: FileManager) -> URL {
        #if os(iOS)
        let component = directoryName
        #else
        // macOS only hosts Core tests and trusted-worker code. A process-scoped folder
        // avoids inheriting a test runner's stale sandbox provenance between launches.
        let component = "\(directoryName).\(ProcessInfo.processInfo.processIdentifier)"
        #endif
        return fileManager.temporaryDirectory.appendingPathComponent(component, isDirectory: true)
    }
}
