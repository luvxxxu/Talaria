import TalariaObjC
import XCTest
@testable import TalariaBridge

final class AttributedBodyTests: XCTestCase {
    let cases: [(String, String)] = [
        ("short", "hello"),
        ("korean", "안녕하세요 Hermes 👋"),
        ("long", String(repeating: "가나다라마바사 ", count: 40)),  // 2-byte length
    ]

    func testAppleUnarchiver() throws {
        for (name, expected) in cases {
            // The Objective-C path on its own, so a silent fallback can't hide a failure.
            XCTAssertEqual(TLRStringFromAttributedBody(try fixture(name)), expected, name)
            XCTAssertEqual(AttributedBody.text(from: try fixture(name)), expected, name)
        }
    }

    func testByteFallback() throws {
        for (name, expected) in cases {
            XCTAssertEqual(TypedStreamText.decode(try fixture(name)), expected, name)
        }
    }

    func testFallbackFourByteLength() {
        let text = String(repeating: "x", count: 70_000)
        var blob = Data([0x84, 0x84, 0x08]) + Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B, 0x82])
        withUnsafeBytes(of: UInt32(text.utf8.count).littleEndian) { blob.append(contentsOf: $0) }
        blob.append(Data(text.utf8))
        XCTAssertEqual(TypedStreamText.decode(blob), text)
    }

    func testGarbageNeverCrashes() throws {
        // NSUnarchiver raises on these; the Objective-C shim must swallow it.
        let samples: [Data?] = [
            nil,
            Data(),
            Data("no string here".utf8),
            Data("\u{4}\u{b}streamtyped garbage NSString".utf8),
            try fixture("long").prefix(200),
            Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) }),
        ]
        for sample in samples {
            XCTAssertNil(AttributedBody.text(from: sample))
        }
    }
}
