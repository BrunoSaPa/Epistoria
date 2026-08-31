import CryptoKit
import Foundation
import ZIPFoundation

public enum PortableArchiveError: Error, Equatable, LocalizedError {
    case invalidArchive
    case unsafeEntry
    case tooLarge
    case missingPackageRoot
    case unsupportedFormat
    case missingMetadata

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The selected ZIP is not a valid Epistoria export."
        case .unsafeEntry:
            "The selected ZIP contains an unsafe or duplicate path."
        case .tooLarge:
            "The selected ZIP exceeds Epistoria's safe import limits."
        case .missingPackageRoot:
            "The selected ZIP does not contain an epistoria-export folder."
        case .unsupportedFormat:
            "The selected ZIP is not an allowed Epistoria export version."
        case .missingMetadata:
            "The selected ZIP does not contain readable export metadata."
        }
    }
}

public struct PortableArchiveInspection: Equatable, Sendable {
    public var formatVersion: String
    public var sha256: String
    public var byteCount: Int64

    public init(formatVersion: String, sha256: String, byteCount: Int64) {
        self.formatVersion = formatVersion
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Verifies the container and metadata of a previously created readable export, then calculates
/// a streaming checksum. Reset flows can retain this small receipt without copying notebook data.
public struct PortableArchiveInspector: Sendable {
    private struct Metadata: Decodable {
        var formatVersion: String
    }

    public init() {}

    public func inspect(
        zipURL: URL,
        allowedFormats: Set<String>
    ) throws -> PortableArchiveInspection {
        let values = try zipURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 2 * 1_024 * 1_024 * 1_024
        else { throw PortableArchiveError.invalidArchive }

        let archive: Archive
        do { archive = try Archive(url: zipURL, accessMode: .read) }
        catch { throw PortableArchiveError.invalidArchive }
        guard let entry = archive["epistoria-export/metadata.json"],
              entry.type == .file,
              entry.uncompressedSize <= 1_048_576
        else { throw PortableArchiveError.missingMetadata }
        var metadataData = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                guard metadataData.count + chunk.count <= 1_048_576 else {
                    throw PortableArchiveError.tooLarge
                }
                metadataData.append(chunk)
            }
        } catch let error as PortableArchiveError {
            throw error
        } catch {
            throw PortableArchiveError.invalidArchive
        }
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData)
        else { throw PortableArchiveError.missingMetadata }
        guard allowedFormats.contains(metadata.formatVersion) else {
            throw PortableArchiveError.unsupportedFormat
        }

        let input = try FileHandle(forReadingFrom: zipURL)
        defer { try? input.close() }
        var digest = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return PortableArchiveInspection(
            formatVersion: metadata.formatVersion,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(fileSize)
        )
    }
}

/// Extracts an Epistoria portability ZIP without following links or accepting traversal paths.
public struct PortableArchiveExtractor: Sendable {
    public init() {}

    public func extract(zipURL: URL, into destinationRoot: URL) throws -> URL {
        let values = try zipURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PortableArchiveError.invalidArchive }
        guard (values.fileSize ?? 0) <= 2 * 1_024 * 1_024 * 1_024 else {
            throw PortableArchiveError.tooLarge
        }
        let archive: Archive
        do { archive = try Archive(url: zipURL, accessMode: .read) }
        catch { throw PortableArchiveError.invalidArchive }

        var paths = Set<String>()
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            guard count <= 100_000 else { throw PortableArchiveError.tooLarge }
            guard entry.type != .symlink, Self.isSafe(path: entry.path) else {
                throw PortableArchiveError.unsafeEntry
            }
            guard paths.insert(entry.path).inserted else {
                throw PortableArchiveError.unsafeEntry
            }
            guard entry.uncompressedSize <= 512 * 1_024 * 1_024 else {
                throw PortableArchiveError.tooLarge
            }
            let next = total.addingReportingOverflow(entry.uncompressedSize)
            guard !next.overflow, next.partialValue <= 4 * 1_024 * 1_024 * 1_024 else {
                throw PortableArchiveError.tooLarge
            }
            total = next.partialValue
            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0 else { throw PortableArchiveError.tooLarge }
                let allowed = entry.compressedSize.multipliedReportingOverflow(by: 200)
                guard !allowed.overflow, entry.uncompressedSize <= allowed.partialValue else {
                    throw PortableArchiveError.tooLarge
                }
            }
        }
        guard paths.contains(where: { $0 == "epistoria-export" || $0.hasPrefix("epistoria-export/") })
        else { throw PortableArchiveError.missingPackageRoot }

        let package = destinationRoot.appendingPathComponent("epistoria-export", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destinationRoot.path
        )
        #endif
        do {
            for entry in archive {
                guard entry.path != "epistoria-export" else { continue }
                let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                guard components.first == "epistoria-export" else {
                    throw PortableArchiveError.unsafeEntry
                }
                let relative = components.dropFirst().joined(separator: "/")
                guard !relative.isEmpty else { continue }
                let destination = package.appendingPathComponent(relative)
                if entry.type == .directory {
                    try FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                } else {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try archive.extract(entry, to: destination, skipCRC32: false)
                    #if os(iOS)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: destination.path
                    )
                    #endif
                }
            }
        } catch let error as PortableArchiveError {
            throw error
        } catch {
            throw PortableArchiveError.invalidArchive
        }
        return package
    }

    private static func isSafe(path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains("\0")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, component in
            if component.isEmpty { return index == components.count - 1 }
            return component != "." && component != ".."
        }
    }
}
