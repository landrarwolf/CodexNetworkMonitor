import Foundation
import Testing
@testable import MonitorCore

struct PNGPrivacyTests {
    private let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private var header: Data { chunk("IHDR", payload: Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])) }
    private var colors: Data {
        chunk("sRGB", payload: Data([0])) + chunk("gAMA", payload: Data([0, 0, 177, 143]))
    }
    // Valid zlib data using one uncompressed DEFLATE block: a synthetic 1x1
    // RGBA scanline with filter 0, a black pixel, and full opacity.
    private var pixels: Data {
        chunk("IDAT", payload: Data([120, 1, 1, 5, 0, 250, 255, 0, 0, 0, 0, 255, 1, 4, 1, 0]))
    }
    private var end: Data { chunk("IEND", payload: Data()) }
    private var clean: Data { signature + header + colors + pixels + end }

    private func chunk(_ type: String, payload: Data) -> Data {
        let length = UInt32(payload.count)
        var output = bigEndian(length)
        let body = Data(type.utf8) + payload
        output.append(body)
        var crc = UInt32.max
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        }
        output.append(bigEndian(crc ^ UInt32.max))
        return output
    }
    private func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    @Test func removesEveryPrivateMetadataTypeWhilePreservingImageAndColorBytes() throws {
        let metadataTypes = ["tEXt", "iTXt", "zTXt", "eXIf", "tIME"]
        var beforePixels = Data(), afterPixels = Data()
        for (index, type) in metadataTypes.enumerated() {
            let metadata = chunk(type, payload: Data("synthetic metadata".utf8))
            if index.isMultiple(of: 2) { beforePixels.append(metadata) }
            else { afterPixels.append(metadata) }
        }
        let original = signature + header + beforePixels + colors + pixels + afterPixels + end
        let sanitized = try #require(PNGPrivacy.sanitized(original))
        #expect(sanitized == clean)
        #expect(PNGPrivacy.sanitized(sanitized) == sanitized)
    }
    @Test func preservesMetadataFreePNGWithoutChangingAnyChunkOrCRC() {
        #expect(PNGPrivacy.sanitized(clean) == clean)
    }
    @Test func rejectsEveryTruncatedPrefix() {
        for length in 0..<clean.count {
            #expect(PNGPrivacy.sanitized(Data(clean.prefix(length))) == nil)
        }
    }
    @Test func rejectsInvalidSignatureAndOversizedLength() {
        var wrongSignature = clean
        wrongSignature[0] = 0
        #expect(PNGPrivacy.sanitized(wrongSignature) == nil)
        let impossibleLength = signature + bigEndian(UInt32.max) + Data("IHDR".utf8) + Data(repeating: 0, count: 17)
        #expect(PNGPrivacy.sanitized(impossibleLength) == nil)
    }
    @Test func rejectsMissingRequiredChunks() {
        #expect(PNGPrivacy.sanitized(signature + pixels + end) == nil)
        #expect(PNGPrivacy.sanitized(signature + header + colors + end) == nil)
        #expect(PNGPrivacy.sanitized(signature + header + colors + pixels) == nil)
    }
    @Test func rejectsTrailingDataAndMalformedEnd() {
        #expect(PNGPrivacy.sanitized(clean + Data([0])) == nil)
        #expect(PNGPrivacy.sanitized(clean + end) == nil)
        #expect(PNGPrivacy.sanitized(signature + header + pixels + chunk("IEND", payload: Data([0]))) == nil)
    }
    @Test func rejectsMalformedOrDuplicateHeaderAndInvalidChunkType() {
        #expect(PNGPrivacy.sanitized(signature + chunk("IHDR", payload: Data(repeating: 0, count: 12)) + pixels + end) == nil)
        #expect(PNGPrivacy.sanitized(signature + header + header + pixels + end) == nil)
        #expect(PNGPrivacy.sanitized(signature + header + chunk("iDA0", payload: Data()) + pixels + end) == nil)
    }
}
