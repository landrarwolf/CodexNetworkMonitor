import Foundation

/// Removes PNG metadata while preserving image and color chunks byte for byte.
public enum PNGPrivacy {
    /// Returns nil for an incomplete or malformed container. CRC validation is
    /// left to the public-file checker; retained chunks keep their original CRCs.
    public static func sanitized(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= signature.count,
              Array(bytes.prefix(signature.count)) == signature else { return nil }

        let privateChunks: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "tIME"]
        var output = Data(signature)
        var offset = signature.count
        var sawHeader = false
        var sawImageData = false

        while offset < bytes.count {
            let remaining = bytes.count - offset
            guard remaining >= 12 else { return nil }
            let rawLength = UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
            // Check against remaining bytes before adding offsets or lengths.
            guard let length = Int(exactly: rawLength), length <= remaining - 12 else { return nil }
            let end = offset + length + 12
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
            let type = String(decoding: typeBytes, as: UTF8.self)

            if !sawHeader {
                guard type == "IHDR", length == 13 else { return nil }
                sawHeader = true
            } else if type == "IHDR" {
                return nil
            }
            if type == "IDAT" { sawImageData = true }
            if type == "IEND" {
                guard length == 0, sawImageData, end == bytes.count else { return nil }
                output.append(contentsOf: bytes[offset..<end])
                return output
            }
            if !privateChunks.contains(type) { output.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        return nil
    }
}
