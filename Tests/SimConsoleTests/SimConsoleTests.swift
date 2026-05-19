import XCTest
@testable import SimConsole

final class SimConsoleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SimConsole.bootstrap(.init(subsystem: "com.simconsole.tests", maxBodyChars: 20))
    }

    func testJsonProducesSortedKeys() {
        let s = SimConsole.json(["b": 2, "a": 1])
        XCTAssertEqual(s, "{\"a\":1,\"b\":2}")
    }

    func testJsonHandlesUnencodableValuesGracefully() {
        struct Unencodable {}
        let s = SimConsole.json(["x": Unencodable()])
        XCTAssertTrue(s.contains("unencodable") || s.contains("Unencodable"))
    }

    func testBootstrapEnablesEmission() {
        SimConsole.bootstrap(.init(subsystem: "com.test", enabled: false))
        XCTAssertFalse(SimConsole.isEnabled)
        SimConsole.bootstrap(.init(subsystem: "com.test", enabled: true))
        XCTAssertTrue(SimConsole.isEnabled)
    }

    func testMaxBodyCharsHonored() {
        SimConsole.bootstrap(.init(subsystem: "com.test", maxBodyChars: 10))
        XCTAssertEqual(SimConsole.maxBodyChars, 10)
    }
}
