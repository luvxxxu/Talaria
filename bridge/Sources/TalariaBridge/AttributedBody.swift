import Foundation
import TalariaObjC

/// Text of a Messages `attributedBody` blob.
///
/// Recent macOS versions often leave `message.text` NULL and keep the body only
/// in `attributedBody`, an NSAttributedString archived with NSArchiver.
public enum AttributedBody {
    public static func text(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let text = TLRStringFromAttributedBody(data) {
            return text
        }
        return TypedStreamText.decode(data)
    }
}

/// Byte-level fallback for blobs Apple's unarchiver rejects.
///
/// It locates the NSString payload: the class name is followed by the type marker
/// `84 01 2B` ("+", a byte string) and a typedstream integer with the UTF-8 byte
/// length — a byte below 0x80 is the length itself, 0x81 is followed by a 2-byte
/// and 0x82 by a 4-byte little-endian length.
public enum TypedStreamText {
    private static let classMarker = Array("NSString".utf8)
    private static let stringType: [UInt8] = [0x84, 0x01, 0x2B]
    // The string type marker sits right after the class chain; don't search
    // further, so an unrelated "+" later in the blob can't be mistaken for it.
    private static let maxMarkerDistance = 32

    public static func decode(_ data: Data) -> String? {
        let blob = [UInt8](data)
        guard let start = find(classMarker, in: blob, from: 0, to: blob.count) else { return nil }
        let limit = min(blob.count, start + classMarker.count + maxMarkerDistance)
        guard let marker = find(stringType, in: blob, from: start, to: limit) else { return nil }
        var pos = marker + stringType.count
        guard pos < blob.count else { return nil }

        let tag = blob[pos]
        pos += 1
        let size: Int
        switch tag {
        case 0x81: size = 2
        case 0x82: size = 4
        case 0..<0x80: size = 0
        default: return nil
        }
        var length = Int(tag)
        if size > 0 {
            guard pos + size <= blob.count else { return nil }
            length = (0..<size).reduce(0) { $0 | Int(blob[pos + $1]) << (8 * $1) }
            pos += size
        }
        guard pos + length <= blob.count else { return nil }
        return String(decoding: blob[pos..<(pos + length)], as: UTF8.self)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int, to end: Int) -> Int? {
        var index = start
        while index + needle.count <= end {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}
