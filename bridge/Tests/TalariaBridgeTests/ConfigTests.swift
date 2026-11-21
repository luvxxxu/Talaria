import XCTest
@testable import TalariaBridge

final class ConfigTests: XCTestCase {
    var directory: URL!
    var path: String { directory.appendingPathComponent("bridge.env").path }

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testEnvFileAndOverrides() throws {
        try write("""
            # comment
            TALARIA_TOKEN='abc'
            export TALARIA_ALLOWED_HANDLES=me@icloud.com, +821012345678
            TALARIA_HOST=100.64.0.5
            TALARIA_PORT=9000
            """)
        let config = try BridgeConfig.load(envFile: path, environment: ["TALARIA_PORT": "9100", "HOME_IGNORED": "x"])
        XCTAssertEqual(config.token, "abc")
        XCTAssertEqual(config.allowedHandles, ["me@icloud.com", "+821012345678"])
        XCTAssertEqual(config.host, "100.64.0.5")
        XCTAssertEqual(config.port, 9100)
        XCTAssertEqual(config.envFile, path)
    }

    func testRequirements() throws {
        try write("TALARIA_TOKEN=short\n")
        let config = try BridgeConfig.load(envFile: path, environment: [:])
        XCTAssertThrowsError(try config.requireToken())
        XCTAssertThrowsError(try config.requireAllowlist())
    }

    func testTypingMode() throws {
        try write("TALARIA_TYPING=UI\n")
        XCTAssertEqual(try BridgeConfig.load(envFile: path, environment: [:]).typing, .ui)
        try write("\n")
        XCTAssertEqual(try BridgeConfig.load(envFile: path, environment: [:]).typing, .off)
    }

    func testBadValues() throws {
        for bad in ["TALARIA_PORT=abc\n", "TALARIA_PORT=70000\n", "TALARIA_POLL_INTERVAL=0\n", "TALARIA_TYPING=yes\n", "JUSTAWORD\n"] {
            try write(bad)
            XCTAssertThrowsError(try BridgeConfig.load(envFile: path, environment: [:]), bad)
        }
    }

    func testExplicitMissingFile() {
        XCTAssertThrowsError(try BridgeConfig.load(envFile: directory.appendingPathComponent("nope.env").path, environment: [:]))
    }
}
