import Foundation
import AVFAudio

public struct AudioSourceAdapter: SourceAdapter {
    public let sourceType = SourceKind.audio
    public let supportedExtensions: Set<String> = ["aac", "caf", "m4a", "mp3", "wav"]
    public let maximumBytes = 384 * 1_024 * 1_024

    public init() {}

    public func validate(data: Data, filename: String, mimeType _: String) throws {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw SourceAdapterError.unsupportedType }
        let valid = switch ext {
        case "wav": Self.isValidWAVE(data)
        case "mp3": Self.isValidMP3(data)
        case "aac": Self.isValidAAC(data)
        case "m4a": Self.isValidM4A(data)
        case "caf": Self.isValidCAF(data)
        default: false
        }
        guard valid,
              let player = try? AVAudioPlayer(data: data),
              player.duration.isFinite,
              player.duration > 0
        else { throw SourceAdapterError.malformed }
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .audio, mimeType: mimeType)
    }

    public func extractText(data _: Data) throws -> String? { nil }
    public func thumbnail(data _: Data) throws -> Data? { nil }
    public func readableExport(data: Data) throws -> Data { data }

    private static func isValidWAVE(_ data: Data) -> Bool {
        guard data.count >= 44,
              ascii(data, 0..<4) == "RIFF",
              ascii(data, 8..<12) == "WAVE",
              let declared = uint32LE(data, at: 4),
              UInt64(declared) + 8 <= UInt64(data.count)
        else { return false }
        var offset = 12
        var hasFormat = false
        var hasAudio = false
        while offset <= data.count - 8 {
            guard let size = uint32LE(data, at: offset + 4) else { return false }
            let payloadStart = offset + 8
            guard let payloadSize = Int(exactly: size), payloadSize <= data.count - payloadStart else {
                return false
            }
            let kind = ascii(data, offset..<(offset + 4))
            if kind == "fmt ", payloadSize >= 16 { hasFormat = true }
            if kind == "data", payloadSize > 0 { hasAudio = true }
            let padded = payloadSize + (payloadSize % 2)
            guard padded <= data.count - payloadStart else { return false }
            offset = payloadStart + padded
        }
        return hasFormat && hasAudio
    }

    private static func isValidMP3(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        var start = 0
        if ascii(data, 0..<3) == "ID3" {
            guard data.count >= 10,
                  data[6...9].allSatisfy({ $0 & 0x80 == 0 })
            else { return false }
            let tagSize = Int(data[6]) << 21 | Int(data[7]) << 14 | Int(data[8]) << 7 | Int(data[9])
            guard tagSize <= data.count - 10 else { return false }
            start = 10 + tagSize
        }
        let upper = min(data.count - 4, start + 65_536)
        guard start <= upper else { return false }
        for offset in start...upper {
            let first = data[offset]
            let second = data[offset + 1]
            let third = data[offset + 2]
            guard first == 0xff, second & 0xe0 == 0xe0 else { continue }
            let version = (second >> 3) & 0x03
            let layer = (second >> 1) & 0x03
            let bitrate = (third >> 4) & 0x0f
            let sampleRate = (third >> 2) & 0x03
            if version != 0x01, layer != 0, bitrate != 0, bitrate != 0x0f, sampleRate != 0x03 {
                return true
            }
        }
        return false
    }

    private static func isValidAAC(_ data: Data) -> Bool {
        if data.count >= 4, ascii(data, 0..<4) == "ADIF" { return true }
        guard data.count >= 7 else { return false }
        let upper = min(data.count - 7, 4_096)
        for offset in 0...upper where data[offset] == 0xff && data[offset + 1] & 0xf6 == 0xf0 {
            let frameLength = Int(data[offset + 3] & 0x03) << 11
                | Int(data[offset + 4]) << 3
                | Int(data[offset + 5] >> 5)
            if frameLength >= 7, frameLength <= data.count - offset { return true }
        }
        return false
    }

    private static func isValidM4A(_ data: Data) -> Bool {
        guard let boxes = isoBoxes(data),
              boxes.contains(where: { $0.type == "ftyp" }),
              boxes.contains(where: { $0.type == "moov" }),
              boxes.contains(where: { $0.type == "mdat" })
        else { return false }
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }), ftyp.payloadRange.count >= 8 else {
            return false
        }
        var brands = [ascii(data, ftyp.payloadRange.lowerBound..<(ftyp.payloadRange.lowerBound + 4))]
        var offset = 8
        while offset <= ftyp.payloadRange.count - 4 {
            let start = ftyp.payloadRange.lowerBound + offset
            brands.append(ascii(data, start..<(start + 4)))
            offset += 4
        }
        return brands.contains { ["M4A ", "M4B ", "isom", "iso2", "mp41", "mp42"].contains($0) }
    }

    private static func isValidCAF(_ data: Data) -> Bool {
        guard data.count >= 16, ascii(data, 0..<4) == "caff" else { return false }
        var offset = 8
        var hasDescription = false
        var hasAudio = false
        while offset <= data.count - 12 {
            let kind = ascii(data, offset..<(offset + 4))
            guard let size = uint64BE(data, at: offset + 4) else {
                return false
            }
            let payloadStart = offset + 12
            let payloadSize: Int
            if size == UInt64.max, kind == "data" {
                payloadSize = data.count - payloadStart
            } else {
                guard size <= UInt64(Int.max) else { return false }
                payloadSize = Int(size)
            }
            guard payloadSize <= data.count - payloadStart else { return false }
            if kind == "desc", payloadSize >= 32 { hasDescription = true }
            if kind == "data", payloadSize > 4 { hasAudio = true }
            offset = payloadStart + payloadSize
        }
        return hasDescription && hasAudio
    }

    private struct ISOBox {
        var type: String
        var payloadRange: Range<Int>
    }

    private static func isoBoxes(_ data: Data) -> [ISOBox]? {
        guard data.count >= 16 else { return nil }
        var boxes: [ISOBox] = []
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
            guard boxSize >= UInt64(headerSize), boxSize <= UInt64(data.count - offset),
                  let count = Int(exactly: boxSize)
            else { return nil }
            boxes.append(ISOBox(
                type: type,
                payloadRange: (offset + headerSize)..<(offset + count)
            ))
            offset += count
        }
        return offset == data.count ? boxes : nil
    }

    private static func ascii(_ data: Data, _ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
        return String(decoding: data[range], as: UTF8.self)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
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
