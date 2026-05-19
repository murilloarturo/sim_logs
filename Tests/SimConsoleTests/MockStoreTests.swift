import XCTest
@testable import SimConsole

final class MockStoreTests: XCTestCase {

    func testMockMatchExactRequiresSameMethod() {
        let m = MockMatch(method: "GET", url: "https://api.example.com/x")
        var req = URLRequest(url: URL(string: "https://api.example.com/x")!)
        req.httpMethod = "POST"
        XCTAssertFalse(m.matches(req))
        req.httpMethod = "GET"
        XCTAssertTrue(m.matches(req))
    }

    func testMockMatchExactRequiresSameURL() {
        let m = MockMatch(method: "GET", url: "https://api.example.com/x")
        var req = URLRequest(url: URL(string: "https://api.example.com/y")!)
        req.httpMethod = "GET"
        XCTAssertFalse(m.matches(req))
    }

    func testMockMatchMethodCaseInsensitive() {
        let m = MockMatch(method: "post", url: "https://api.example.com/x")
        var req = URLRequest(url: URL(string: "https://api.example.com/x")!)
        req.httpMethod = "POST"
        XCTAssertTrue(m.matches(req))
    }

    func testMockMatchBodyContains() {
        let m = MockMatch(method: "POST", url: "https://api.example.com/x", bodyContains: "needle")
        var req = URLRequest(url: URL(string: "https://api.example.com/x")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{\"key\":\"value\"}".utf8)
        XCTAssertFalse(m.matches(req))
        req.httpBody = Data("{\"key\":\"this contains needle inside\"}".utf8)
        XCTAssertTrue(m.matches(req))
    }

    func testRoundtripEncoding() throws {
        let mock = Mock(
            match: MockMatch(method: "GET", url: "https://api.example.com/users/1"),
            response: MockResponse(status: 404, headers: ["Content-Type": "application/json"],
                                   body: "{\"error\":\"not_found\"}"),
            delayMs: 100,
            enabled: true
        )
        let file = MockFile(version: 1, mocks: [mock])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(MockFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.mocks, [mock])
    }

    func testMockStoreReloadsOnMtimeChange() throws {
        let tmp = NSTemporaryDirectory() + "/simconsole-mock-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Write a first version of the file.
        let m1 = Mock(
            match: MockMatch(method: "GET", url: "https://example.com/a"),
            response: MockResponse(status: 200, body: "{\"v\":1}")
        )
        try JSONEncoder().encode(MockFile(version: 1, mocks: [m1]))
            .write(to: URL(fileURLWithPath: tmp))

        let store = MockStore.shared
        store._reloadFromPath(tmp)
        XCTAssertEqual(store._currentMocks().count, 1)
        XCTAssertEqual(store._currentMocks().first?.response.status, 200)

        // Touch the file with a new mtime by overwriting it.
        sleep(1) // mtime has 1s resolution on some filesystems
        let m2 = Mock(
            match: MockMatch(method: "GET", url: "https://example.com/a"),
            response: MockResponse(status: 500, body: "{\"v\":2}")
        )
        try JSONEncoder().encode(MockFile(version: 1, mocks: [m2]))
            .write(to: URL(fileURLWithPath: tmp))

        // Next access should reload.
        let mocks = store._currentMocks()
        XCTAssertEqual(mocks.first?.response.status, 500)
    }
}
